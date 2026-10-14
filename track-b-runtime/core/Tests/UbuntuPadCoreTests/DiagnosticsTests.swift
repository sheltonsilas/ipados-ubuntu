import Foundation
import XCTest

@testable import UbuntuPadCore

final class DiagnosticsTests: XCTestCase {
    func testRenderIsStableAndComplete() {
        let report = DiagnosticsReport(
            appVersion: "0.1.0",
            runtimeVersion: "0.1.0",
            platform: "test",
            deviceModel: "test-model",
            pageSizeBytes: 16384,
            physicalMemoryBytes: 4 * 1024 * 1024 * 1024,
            jit: .notProbed,
            notes: ["phase 0"]
        )

        let lines = report.render().split(separator: "\n").map(String.init)
        XCTAssertEqual(
            lines,
            [
                "UbuntuPad diagnostics",
                "app_version: 0.1.0",
                "runtime_version: 0.1.0",
                "platform: test",
                "device_model: test-model",
                "page_size_bytes: 16384 (16 KiB)",
                "physical_memory_bytes: 4294967296 (4096 MiB)",
                "jit: notProbed",
                "note: phase 0",
            ])
    }

    func testReportRoundTripsThroughJSON() throws {
        let report = DiagnosticsReport(
            appVersion: "1.2.3",
            runtimeVersion: "0.1.0",
            platform: "iOS 18.0",
            deviceModel: "iPad14,3",
            pageSizeBytes: 16384,
            physicalMemoryBytes: 8 * 1024 * 1024 * 1024,
            jit: .enabled
        )
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(DiagnosticsReport.self, from: data)
        XCTAssertEqual(decoded, report)
    }

    /// The raw values are what appears in a pasted issue report, so they are part of the contract.
    func testJITStatusRawValuesAreStable() {
        XCTAssertEqual(JITStatus.enabled.rawValue, "enabled")
        XCTAssertEqual(JITStatus.disabled.rawValue, "disabled")
        XCTAssertEqual(JITStatus.notProbed.rawValue, "notProbed")
        XCTAssertEqual(JITStatus.allCases.count, 3)
    }
}
