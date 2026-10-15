import Foundation
import UbuntuPadCore
import UbuntuPadHost

/// The platform facts the runtime depends on — **measured**, not assumed.
///
/// This lives in the runner library rather than in the command-line tool so that the iPad app reports
/// the same facts, in the same words, as `ubuntupad-run probe`: the one question this project cannot
/// settle from documentation is whether a non-jailbroken app can write a page and then execute it
/// (decision 0020), and an answer is only useful if it comes from the same code on both hosts.
///
/// `render()` is the single definition of those lines. `main.swift` prints it, the app shows it and puts
/// it in the copyable diagnostics block, and CI greps it — three consumers, one source of truth.
public struct HostProbe {
    public var pageSize: Int
    public var guestPageSize: Int
    public var totalMemoryBytes: UInt64
    /// What this process may still allocate, when the host will say. `nil` means "the host would not
    /// say", which is not the same answer as "almost nothing left".
    public var availableMemoryBytes: UInt64?
    public var canRunGuest: Bool
    public var reservedLowRegionBytes: UInt64
    public var monotonicNanoseconds: UInt64
    public var wallClockNanoseconds: UInt64
    public var hostArchitecture: String
    /// `ok` / `failed`: a readable-and-writable mapping, which every guest image needs.
    public var readWriteMapping: String
    /// `ok` / `failed`: **the** question. The image text is written while the mapping is writable and
    /// this call is what makes it executable, so a `failed` here means no guest program can run on this
    /// host at all.
    public var readExecuteMapping: String
    /// `ok` / `refused`, or `nil` when the reserve itself failed. Reported because it is interesting
    /// (Apple silicon refuses a writable-and-executable page for an unentitled process) but never
    /// required: the runtime deliberately never asks for one.
    public var writeExecuteMapping: String?

    /// One fact per line, stable order, identical wording on every host — a future session diffs two
    /// pasted blocks.
    public func render() -> [String] {
        var lines = [
            "host_page_size=\(pageSize)",
            "guest_page_size=\(guestPageSize)",
            "total_memory_bytes=\(totalMemoryBytes)",
            "available_memory_bytes=" + (availableMemoryBytes.map(String.init) ?? "unknown"),
            "can_run_guest=\(canRunGuest ? 1 : 0)",
            "guest_architecture=aarch64",
            "host_architecture=\(hostArchitecture)",
            "monotonic_nanoseconds=\(monotonicNanoseconds)",
            "wall_clock_nanoseconds=\(wallClockNanoseconds)",
            "reserved_low_region_bytes=\(reservedLowRegionBytes)",
            "rw_mapping=\(readWriteMapping)",
            "rx_mapping=\(readExecuteMapping)",
        ]
        if let writeExecuteMapping {
            lines.append("write_execute_mapping=\(writeExecuteMapping)")
        }
        return lines
    }

    /// One sentence a non-programmer can act on, for the app's screen.
    public var summary: String {
        if !canRunGuest { return "this device cannot run AArch64 guest code" }
        if readExecuteMapping == "ok" {
            return "this device allows executable code written by the app"
        }
        return "this device refuses to execute code the app wrote (JIT is not enabled for it)"
    }
}

/// Measures the host. Never executes anything it mapped: a failed `mprotect` is an answer, and sending
/// the CPU into memory that the kernel refuses to mark executable would kill the process and tell us
/// nothing (the same reasoning as `JITStatus` in the core).
public func probeHost() -> HostProbe {
    let pageSize = Int(up_page_size())
    let available = up_available_memory()

    var readWrite = "failed"
    var readExecute = "unknown"
    var writeExecute: String?

    var landed: UInt64 = 0
    let length = max(pageSize, 4096)
    if up_reserve(0, length, Int32(UP_RESERVE_HINT), &landed) != nil {
        readWrite = up_protect(landed, length, 0x1 | 0x2) == 0 ? "ok" : "failed"
        readExecute = up_protect(landed, length, 0x1 | 0x4) == 0 ? "ok" : "failed"
        writeExecute = up_protect(landed, length, 0x1 | 0x2 | 0x4) == 0 ? "ok" : "refused"
        _ = up_release(landed, length)
    }

    return HostProbe(
        pageSize: pageSize,
        guestPageSize: 4096,
        totalMemoryBytes: up_total_memory(),
        availableMemoryBytes: available > 0 ? available : nil,
        canRunGuest: up_can_run_guest() != 0,
        reservedLowRegionBytes: up_reserved_low_region_size(),
        monotonicNanoseconds: up_monotonic_nanoseconds(),
        wallClockNanoseconds: up_wall_clock_nanoseconds(),
        hostArchitecture: hostArchitecture(),
        readWriteMapping: readWrite,
        readExecuteMapping: readExecute,
        writeExecuteMapping: writeExecute)
}

/// The architecture this binary was compiled for, which is not the same question as "can it run guest
/// code": on a Linux x86_64 runner the answer is `x86_64` and `can_run_guest=0`.
func hostArchitecture() -> String {
    #if arch(arm64)
    return "arm64"
    #elseif arch(x86_64)
    return "x86_64"
    #else
    return "unknown"
    #endif
}
