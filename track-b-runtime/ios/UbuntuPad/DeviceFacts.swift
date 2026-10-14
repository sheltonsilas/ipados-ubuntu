import Darwin
import Foundation
import UbuntuPadCore

/// Gathers the Apple-only facts that the platform-independent core cannot know.
///
/// Everything here is read-only reporting: no probe executes generated code, because a failed JIT
/// probe kills the process and would tell us nothing (see `JITStatus`).
enum DeviceFacts {
    static func report() -> DiagnosticsReport {
        let bundle = Bundle.main
        let pageSize = Int(getpagesize())
        return DiagnosticsReport(
            appVersion: bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            runtimeVersion: BuildInfo.version,
            platform: platformName(),
            deviceModel: machineIdentifier(),
            pageSizeBytes: pageSize,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            jit: .notProbed,
            notes: [
                "jit probe not implemented yet (phase 2)",
                "host page size \(pageSize / 1024) KiB; Track B guest page model is a software 4 KiB",
                "no process can be spawned on iOS; Track B guest processes live inside this app",
            ]
        )
    }

    private static func platformName() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "iOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// `hw.machine` from `uname(2)`, e.g. `iPad14,3`, so an agent can correlate behaviour with
    /// hardware without asking the owner.
    private static func machineIdentifier() -> String {
        var info = utsname()
        guard uname(&info) == 0 else { return "unknown" }
        return withUnsafeBytes(of: &info.machine) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}
