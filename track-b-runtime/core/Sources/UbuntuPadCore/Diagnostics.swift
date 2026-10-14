import Foundation

/// Whether the app can currently execute generated code.
///
/// Phase 0 deliberately does **not** probe this by trying to execute memory: on iOS an
/// unentitled `mprotect(PROT_EXEC)` + jump is killed by the kernel, which would look like a crash
/// and teach us nothing. The probe (and its documentation) belongs to Phase 2.
public enum JITStatus: String, Codable, Sendable, CaseIterable {
    case enabled
    case disabled
    case notProbed
}

/// A snapshot of everything an agent needs in order to diagnose a device problem.
///
/// This type is platform-independent on purpose: the iOS shell fills it in from Apple-only APIs,
/// while tests and CI can build the same report on Linux.
public struct DiagnosticsReport: Codable, Equatable, Sendable {
    public var appVersion: String
    public var runtimeVersion: String
    public var platform: String
    public var deviceModel: String
    public var pageSizeBytes: Int
    public var physicalMemoryBytes: UInt64
    public var jit: JITStatus
    public var notes: [String]

    public init(
        appVersion: String,
        runtimeVersion: String,
        platform: String,
        deviceModel: String,
        pageSizeBytes: Int,
        physicalMemoryBytes: UInt64,
        jit: JITStatus,
        notes: [String] = []
    ) {
        self.appVersion = appVersion
        self.runtimeVersion = runtimeVersion
        self.platform = platform
        self.deviceModel = deviceModel
        self.pageSizeBytes = pageSizeBytes
        self.physicalMemoryBytes = physicalMemoryBytes
        self.jit = jit
        self.notes = notes
    }

    /// Plain-text rendering used by the app's "Copy diagnostics" button and by tests.
    ///
    /// Stable ordering and one `key: value` per line, so that a pasted block in a GitHub issue can
    /// be diffed between sessions.
    public func render() -> String {
        var lines: [String] = [
            "UbuntuPad diagnostics",
            "app_version: \(appVersion)",
            "runtime_version: \(runtimeVersion)",
            "platform: \(platform)",
            "device_model: \(deviceModel)",
            "page_size_bytes: \(pageSizeBytes) (\(pageSizeBytes / 1024) KiB)",
            "physical_memory_bytes: \(physicalMemoryBytes) (\(physicalMemoryBytes / (1024 * 1024)) MiB)",
            "jit: \(jit.rawValue)",
        ]
        for note in notes {
            lines.append("note: \(note)")
        }
        return lines.joined(separator: "\n")
    }
}
