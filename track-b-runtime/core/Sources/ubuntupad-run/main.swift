import Foundation
import UbuntuPadCore
import UbuntuPadHost
// The run pipeline itself. It is a library so that the iPad app links exactly this code (decision 0020);
// this executable adds argument parsing and machine-readable output on top of it and nothing else.
import UbuntuPadRunner

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

/*
 * The probe is measured by `UbuntuPadRunner.probeHost()` and printed here. The app calls the same
 * function and shows the same lines, so a pasted device report and a CI log are directly comparable
 * (decision 0020); this function is only the printing.
 */
func probe() -> Int32 {
    let host = probeHost()
    emit("ubuntupad-run: version=\(version)")
    emit("mode=probe")
    for line in host.render() { emit(line) }
    return 0
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
