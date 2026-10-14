import SwiftUI
import UIKit
import UbuntuPadCore

/// The only screen in Phase 0. It exists so the owner can send an agent everything needed to
/// diagnose a device problem with one screenshot or one paste.
struct DiagnosticsView: View {
    @State private var report = DeviceFacts.report()
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    statusCard
                    Text(report.render())
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
                        UIPasteboard.general.string = report.render()
                        copied = true
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Refresh") {
                        report = DeviceFacts.report()
                        copied = false
                    }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Ubuntu Desktop for iPadOS")
                .font(.title2.bold())
            Text("Phase 0 foundation build — no Linux runtime in this app yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("App pipeline", systemImage: "checkmark.seal")
            Label("Linux runtime", systemImage: "hourglass")
                .foregroundStyle(.secondary)
            Label("JIT: \(report.jit.rawValue)", systemImage: "bolt.slash")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var roadmap: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Coming next")
                .font(.headline)
            Text("Track A: an emulated Ubuntu arm64 desktop (UTM-based).")
            Text("Track B: native arm64 binaries with Linux syscalls translated in-app.")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}

#Preview {
    DiagnosticsView()
}
