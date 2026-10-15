import Combine
import Darwin
import Foundation
import UbuntuPadCore
import UbuntuPadRunner

/// Runs the Linux guest programs that are bundled in the app, and measures what this device allows.
///
/// This is Track B's first device-visible result (decision 0020). It calls **exactly** the pipeline CI
/// executes — `UbuntuPadRunner.GuestRunner`, the same library `ubuntupad-run` links — so a guest that
/// `runtime-e2e` runs on an Apple-silicon runner is the same code path the owner sees here. The one
/// question CI cannot answer is whether *this* device lets the app execute pages it wrote, which is what
/// the probe reports.
///
/// Everything the user sees is also what the copy button copies: the report is built from the same
/// lines, and its wording matches `ubuntupad-run probe` so two pasted blocks can be diffed.
@MainActor
final class GuestRunModel: ObservableObject {
    /// A guest program that is actually present in the app bundle.
    struct Program: Identifiable {
        let id: String
        let title: String
        let detail: String
        let arguments: [String]
    }

    enum State: Equatable {
        case idle
        case running(String)
        case finished
    }

    /// The programs the app offers, in order. One that is not in the bundle is simply not listed: a
    /// local build without the CI artifact says so instead of showing a button that cannot work.
    private static let candidates: [Program] = [
        Program(
            id: "hello-pie-nostdlib",
            title: "Hello from Linux",
            detail: "a static, position-independent arm64 Linux program; the text below is printed by "
                + "guest code running on this device's CPU, with the write() serviced by our own runtime",
            arguments: []),
        Program(
            id: "stack-probe-nostdlib",
            title: "Linux process stack",
            detail: "the guest reads argc/argv/envp/auxv back off the stack the runtime built for it, so "
                + "this shows the Linux process environment it sees",
            arguments: ["alpha", "beta"]),
    ]

    @Published private(set) var state: State = .idle
    @Published private(set) var available: [Program] = []
    @Published private(set) var output: [String] = []
    @Published private(set) var outcome: String?
    /// Measured once, at launch: it is one `mmap` and one `mprotect`, and it never executes anything.
    @Published private(set) var probe: HostProbe = probeHost()

    init() {
        available = Self.candidates.filter { Self.bundlePath(for: $0.id) != nil }
    }

    /// Whether this device lets the app execute code it wrote. On Apple platforms this is what the
    /// JIT/executable-memory question reduces to, and it is measured rather than assumed.
    var jitStatus: JITStatus {
        guard probe.canRunGuest else { return .notProbed }
        switch probe.readExecuteMapping {
        case "failed": return .disabled
        case "ok":
            // mprotect accepting PROT_EXEC only measures a permission change. It does not prove that
            // the CPU may execute those bytes. The only positive evidence is a guest that completed
            // successfully through this runner.
            return outcome?.contains("exit=normal status=0") == true ? .enabled : .notProbed
        default: return .notProbed
        }
    }

    func run(_ program: Program) {
        if case .running = state { return }
        guard let path = Self.bundlePath(for: program.id) else {
            outcome = "the app bundle does not contain \(program.id)"
            return
        }

        state = .running(program.title)
        output = []
        outcome = nil

        let arguments = [path] + program.arguments
        // The guest runs off the main thread: it is a synchronous run of foreign code, and a guest that
        // faults must not take the user interface with it.
        DispatchQueue.global(qos: .userInitiated).async {
            var lines: [String] = []
            var descriptors: [Int32] = [0, 0]
            guard pipe(&descriptors) == 0 else {
                DispatchQueue.main.async {
                    self.outcome = "could not create the guest output pipe"
                    self.state = .finished
                }
                return
            }
            let readerFD = descriptors[0]
            let writerFD = descriptors[1]
            // Read concurrently: a guest that writes more than the pipe capacity must not deadlock in
            // its SIGTRAP handler. Keep this transport off the main queue, which remains responsive.
            let readerQueue = DispatchQueue(label: "dev.sheltonsilas.UbuntuPad.guest-output")
            readerQueue.async {
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = buffer.withUnsafeMutableBytes { raw in
                        read(readerFD, raw.baseAddress, raw.count)
                    }
                    if count <= 0 { break }
                    let chunk = String(decoding: buffer.prefix(count), as: UTF8.self)
                    DispatchQueue.main.async { self.output.append(chunk) }
                }
                close(readerFD)
            }
            let runner = GuestRunner(
                options: GuestRunner.Options(
                    executablePath: path,
                    arguments: arguments,
                    environment: ["PATH=/usr/bin:/bin", "HOME=/root", "TERM=dumb", "LC_ALL=C"],
                    verbose: true,
                    consoleFileDescriptor: writerFD),
                emit: { lines.append($0) })

            let summary: String
            do {
                summary = Self.describe(try runner.run())
            } catch {
                // Refusals are first-class here: the runtime says *why* it will not run an image, and
                // that text belongs on the screen, not in a log the owner cannot see.
                summary = "refused: \(error)"
            }

            close(writerFD)
            // Closing the writer lets the reader observe EOF. Wait for its final chunk to be queued
            // before appending runner diagnostics and marking the run complete.
            readerQueue.sync {}

            let collected = lines
            DispatchQueue.main.async {
                self.output.append(contentsOf: collected)
                self.outcome = summary
                self.state = .finished
            }
        }
    }

    /// The facts the copy button includes, in the wording CI prints where they overlap.
    var reportLines: [String] {
        var lines = probe.render()
        lines.append(
            "guest_programs="
                + (available.isEmpty
                    ? "none in this bundle (a build without the CI artifact)"
                    : available.map(\.id).joined(separator: ",")))
        if let outcome {
            lines.append("guest_run=\(outcome)")
            lines.append(contentsOf: output.map { "guest-log: \($0)" })
        }
        return lines
    }

    private static func bundlePath(for resource: String) -> String? {
        Bundle.main.url(forResource: resource, withExtension: nil)?.path
    }

    private static func describe(_ result: GuestRunner.Result) -> String {
        var parts = [
            "exit=\(result.reason)",
            "status=\(result.exitStatus)",
            "syscalls_serviced=\(result.syscallCount)",
            "patched_syscall_sites=\(result.patchedSites)",
            "placement=\(result.placement)",
            "bias=0x\(String(result.bias, radix: 16))",
            "relative_relocations=\(result.relativeRelocations)",
            "host_pages_touched=\(result.protectionPages)",
        ]
        if !result.unimplemented.isEmpty {
            parts.append(
                "unimplemented_syscalls=\(result.unimplemented.map(String.init).joined(separator: ","))")
        }
        return parts.joined(separator: " ")
    }
}
