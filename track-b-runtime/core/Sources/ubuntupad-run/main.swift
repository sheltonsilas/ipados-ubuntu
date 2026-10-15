import Foundation
import UbuntuPadCore
import UbuntuPadHost

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/*
 * ubuntupad-run — Track B's test bed.
 *
 * It exists so the runtime can be exercised somewhere that is not the owner's iPad: an Apple-silicon
 * GitHub runner has the same architecture, the same 16 KiB pages and the same code-signing rules, so a
 * guest program that runs there exercises the real design rather than a Linux stand-in.
 *
 * Output is deliberately machine-readable, one fact per line, and writes are unbuffered so the guest's
 * own output keeps its exact place between the `guest-stdout-begin` and `guest-stdout-end` markers.
 * CI greps those markers instead of trusting an exit code.
 *
 * Usage:
 *   ubuntupad-run probe
 *   ubuntupad-run run <elf> [args...] [--env K=V]... [--verbose]
 */

let version = "0.2.0"

/// Unbuffered write to standard output, preserving order with the guest's own writes.
func emit(_ line: String) {
    let bytes = Array((line + "\n").utf8)
    bytes.withUnsafeBufferPointer { buffer in
        guard let base = buffer.baseAddress else { return }
        var written = 0
        while written < buffer.count {
            let result = write(1, base.advanced(by: written), buffer.count - written)
            if result <= 0 { break }
            written += result
        }
    }
}

/// Errors are the runner's own, so they go to standard error and print the reason.
func fail(_ message: String) -> Never {
    let bytes = Array(("ubuntupad-run: error: " + message + "\n").utf8)
    bytes.withUnsafeBufferPointer { buffer in
        if let base = buffer.baseAddress { _ = write(2, base, buffer.count) }
    }
    exit(2)
}

func probe() -> Int32 {
    let hostPageSize = Int(up_page_size())
    emit("ubuntupad-run: version=\(version)")
    emit("mode=probe")
    emit("host_page_size=\(hostPageSize)")
    emit("guest_page_size=4096")
    emit("total_memory_bytes=\(up_total_memory())")
    emit("can_run_guest=\(up_can_run_guest())")
    emit("guest_architecture=aarch64")
    emit("host_architecture=\(hostArchitecture())")
    emit("monotonic_nanoseconds=\(up_monotonic_nanoseconds())")
    emit("wall_clock_nanoseconds=\(up_wall_clock_nanoseconds())")

    // How much of the low address space the running binary reserves. macOS arm64 defaults to 4 GiB,
    // which would make a Linux executable's usual 0x400000 unmappable; the runner shrinks it at link
    // time (decision 0015), so this line is the evidence that the flag took effect.
    emit("reserved_low_region_bytes=\(up_reserved_low_region_size())")

    // Can this process get executable memory for a *static* image? Writing the text before making it
    // executable is the whole non-JIT strategy, so the probe answers it explicitly instead of leaving
    // it to be discovered halfway through a guest run.
    var landed: UInt64 = 0
    let probeLength = hostPageSize
    if up_reserve(0, probeLength, Int32(UP_RESERVE_HINT), &landed) != nil {
        let writeResult = up_protect(landed, probeLength, 0x1 | 0x2)
        let executeResult = up_protect(landed, probeLength, 0x1 | 0x4)
        emit("rw_mapping=\(writeResult == 0 ? "ok" : "failed")")
        emit("rx_mapping=\(executeResult == 0 ? "ok" : "failed")")
        emit("write_execute_mapping=\(up_protect(landed, probeLength, 0x1 | 0x2 | 0x4) == 0 ? "ok" : "refused")")
        _ = up_release(landed, probeLength)
    } else {
        emit("rw_mapping=failed")
        emit("rx_mapping=unknown")
    }
    return 0
}

func hostArchitecture() -> String {
    #if arch(arm64)
    return "arm64"
    #elseif arch(x86_64)
    return "x86_64"
    #else
    return "unknown"
    #endif
}

func runGuest(arguments: [String]) -> Int32 {
    var executablePath: String?
    var guestArguments: [String] = []
    var environment: [String] = ["PATH=/usr/bin:/bin", "HOME=/root", "TERM=dumb", "LC_ALL=C"]
    var verbose = false
    var skipRelocations = false

    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--verbose", "-v":
            verbose = true
        case "--skip-relocations":
            // A deliberately broken run, used by CI to show that the relocation pass is load-bearing:
            // without it a position-independent guest reads wild pointers instead of its own data.
            skipRelocations = true
        case "--env":
            index += 1
            guard index < arguments.count else { fail("--env needs a KEY=VALUE argument") }
            environment.append(arguments[index])
        case "--":
            index += 1
            while index < arguments.count {
                if executablePath == nil { executablePath = arguments[index] } else { guestArguments.append(arguments[index]) }
                index += 1
            }
            continue
        default:
            if argument.hasPrefix("-") && executablePath == nil {
                fail("unknown option \(argument); try `probe` or `run <elf>`")
            }
            if executablePath == nil {
                executablePath = argument
            } else {
                guestArguments.append(argument)
            }
        }
        index += 1
    }

    guard let executablePath else { fail("usage: ubuntupad-run run <elf> [args...]") }

    emit("ubuntupad-run: version=\(version)")
    emit("mode=run")
    let argv = [executablePath] + guestArguments
    emit("argv=\(argv.joined(separator: " "))")

    let runner = GuestRunner(
        options: GuestRunner.Options(
            executablePath: executablePath,
            arguments: argv,
            environment: environment,
            verbose: verbose,
            skipRelocations: skipRelocations),
        emit: { emit("ubuntupad-run: " + $0) })

    do {
        let result = try runner.run()
        emit("ubuntupad-run: exit=\(result.reason) status=\(result.exitStatus)")
        if result.reason == "fault" {
            emit(
                "ubuntupad-run: fault signal=\(result.faultSignal) address=0x\(String(result.faultAddress, radix: 16)) pc=0x\(String(result.trapPC, radix: 16))"
            )
        }
        if result.reason == "breakpoint" {
            emit("ubuntupad-run: unexpected breakpoint at pc=0x\(String(result.trapPC, radix: 16))")
        }
        for line in result.traceSummary.split(separator: "\n") {
            emit("ubuntupad-run: \(line)")
        }
        if verbose {
            emit("ubuntupad-run: unimplemented_syscalls=\(result.unimplemented.map(String.init).joined(separator: ","))")
        }
        if result.reason != "normal" { return 1 }
        return result.exitStatus
    } catch {
        fail("\(error)")
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    fail("usage: ubuntupad-run probe | run <elf> [args...]")
}
switch command {
case "probe":
    exit(probe())
case "run":
    exit(runGuest(arguments: Array(arguments.dropFirst())))
case "--version", "version":
    emit("ubuntupad-run \(version)")
    exit(0)
default:
    fail("unknown command \(command); try `probe` or `run <elf>`")
}
