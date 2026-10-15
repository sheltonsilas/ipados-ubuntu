import SwiftUI
import UIKit
import UbuntuPadCore

/// The app's only screen. It exists so the owner can send an agent everything needed to diagnose a
/// device problem with one paste — and, since Phase 2, so that the owner can actually watch a Linux
/// program run on their iPad.
struct DiagnosticsView: View {
    @StateObject private var guest = GuestRunModel()
    @State private var device = DeviceFacts.report()
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    statusCard
                    guestSection
                    Text(reportText)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    roadmap
                }
                .padding()
            }
            .navigationTitle("UbuntuPad")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(copied ? "Copied" : "Copy") {
                        UIPasteboard.general.string = reportText
                        copied = true
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Refresh") {
                        device = DeviceFacts.report()
                        copied = false
                    }
                }
            }
        }
    }

    /// Whatever is on the screen is exactly what the Copy button copies: the device facts plus the
    /// measurement the runtime made plus the guest's own output. Nothing is added at copy time, so a
    /// pasted block can be trusted to be what the owner saw.
    private var reportText: String {
        var report = device
        report.jit = guest.jitStatus
        report.notes.append(contentsOf: guest.reportLines)
        return report.render()
    }

    private var isRunning: Bool {
        if case .running = guest.state { return true }
        return false
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Ubuntu Desktop for iPadOS")
                .font(.title2.bold())
            Text("Phase 2 build — a native arm64 Linux runtime runs a real Linux program inside this app.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("App pipeline", systemImage: "checkmark.seal")
            Label(
                "Linux runtime: \(guest.probe.canRunGuest ? "ready" : "unavailable on this CPU")",
                systemImage: "cpu")
            Label("Executable memory: \(guest.jitStatus.rawValue)", systemImage: "bolt")
            Label("Host page size: \(guest.probe.pageSize / 1024) KiB", systemImage: "square.grid.3x3")
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var guestSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Linux runtime (Track B)")
                .font(.headline)
            Text(guest.probe.summary)
                .font(.callout)
                .foregroundStyle(.secondary)

            if guest.available.isEmpty {
                Text(
                    "This build has no guest program bundled, so there is nothing to run. CI builds one "
                        + "for released IPAs; see track-b-runtime/ios/Guest/README.md."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            } else {
                ForEach(guest.available) { program in
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            guest.run(program)
                        } label: {
                            Label("Run \(program.title)", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isRunning)
                        Text(program.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if case let .running(title) = guest.state {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("running \(title)…")
                }
                .font(.callout)
            }

            if let outcome = guest.outcome {
                Text(outcome)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }

            if !guest.output.isEmpty {
                Text(guest.output.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text(
                "Marked **unverified on device** until this is tried on a real iPad: how to install, how to "
                    + "enable JIT and what to expect is in docs/SETUP.md."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var roadmap: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Coming next")
                .font(.headline)
            Text("Track B: processes and a shell (Phase 3), then the Ubuntu rootfs (Phase 4).")
            Text("Track A: an emulated Ubuntu desktop, the fallback and the performance benchmark.")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}

#Preview {
    DiagnosticsView()
}
