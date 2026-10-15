import Foundation
import XCTest

@testable import UbuntuPadCore

final class AArch64InstructionTests: XCTestCase {
    /// If this constant is wrong the runtime either patches nothing or plants a `brk` whose immediate
    /// the handler does not recognise — both are silent, total failures. Pin it.
    func testSentinelIsTheBreakpointTheHandlerLooksFor() {
        XCTAssertEqual(AArch64Instruction.breakpointSentinel, 0xD420_0000 | (0x123 << 5))
        XCTAssertTrue(AArch64Instruction.isBreakpoint(AArch64Instruction.breakpointSentinel))
        XCTAssertEqual(
            AArch64Instruction.breakpointImmediate(AArch64Instruction.breakpointSentinel), 0x123)
    }

    func testRecognisesSvcIncludingTheImmediateVariants() {
        XCTAssertTrue(AArch64Instruction.isSupervisorCall(0xD400_0001), "svc #0 is what Linux uses")
        XCTAssertTrue(AArch64Instruction.isSupervisorCall(0xD400_0041), "svc #2")
        XCTAssertFalse(AArch64Instruction.isSupervisorCall(0xD400_0000))
        XCTAssertFalse(AArch64Instruction.isSupervisorCall(0xD503_201F), "nop")
        XCTAssertFalse(AArch64Instruction.isSupervisorCall(0xD65F_03C0), "ret")
        XCTAssertFalse(AArch64Instruction.isSupervisorCall(0xD420_2460), "our own brk sentinel")
    }

    func testLinuxSvcZeroIsNotConfusedWithBreakpoint() {
        XCTAssertFalse(AArch64Instruction.isBreakpoint(AArch64Instruction.svcZero))
        XCTAssertFalse(AArch64Instruction.isSupervisorCall(AArch64Instruction.breakpointSentinel))
    }
}

final class PatchPlannerTests: XCTestCase {
    private let planner = PatchPlanner()

    /// Builds a one-segment synthetic image whose code area is the given words.
    private func image(words: [UInt32], executable: Bool = true) throws -> (ELFImage, Data) {
        var payload = Data()
        for word in words {
            for index in 0..<4 { payload.append(UInt8((word >> (8 * UInt32(index))) & 0xff)) }
        }
        // Reuse the fixture, then overwrite its payload area with our code.
        var bytes = ELFFixture.image(entry: 0x4000_0000)
        let image = try ELFImage.parse(bytes)
        let segment = try XCTUnwrap(image.loadSegments.first)
        let start = Int(segment.fileOffset)
        for (index, byte) in payload.enumerated() where start + index < bytes.count {
            bytes[start + index] = byte
        }
        if !executable {
            // Flip PF_X off by rewriting the program header's flags word in place.
            var patched = bytes
            let headerBase = Int(image.header.programHeaderOffset)
            for index in 0..<4 { patched[headerBase + 4 + index] = 0 }
            return (try ELFImage.parse(patched), patched)
        }
        return (try ELFImage.parse(bytes), bytes)
    }

    func testPatchesEverySvcAndLeavesEverythingElseAlone() throws {
        let svc = AArch64Instruction.svcZero
        let nop: UInt32 = 0xD503_201F
        let (image, bytes) = try image(words: [nop, svc, nop, svc, svc])

        let plan = try planner.plan(image: image, bytes: bytes)

        XCTAssertEqual(plan.patchedCount, 3)
        XCTAssertEqual(plan.site(at: 0x4000_0004)?.original, svc)
        XCTAssertEqual(plan.site(at: 0x4000_000C)?.original, svc)
        XCTAssertEqual(plan.site(at: 0x4000_0010)?.original, svc)
        XCTAssertNil(plan.site(at: 0x4000_0000))
        XCTAssertEqual(plan.scannedRanges.count, 1)
    }

    func testPatchedImageHoldsTheSentinelAtEverySite() throws {
        let (image, bytes) = try image(words: [AArch64Instruction.svcZero])
        let plan = try planner.plan(image: image, bytes: bytes)
        let segment = try XCTUnwrap(image.loadSegments.first)

        let offset = Int(segment.fileOffset)
        let word = plan.patchedImage[offset..<(offset + 4)].withUnsafeBytes { raw -> UInt32 in
            UInt32(raw[0]) | (UInt32(raw[1]) << 8) | (UInt32(raw[2]) << 16) | (UInt32(raw[3]) << 24)
        }
        XCTAssertEqual(word, AArch64Instruction.breakpointSentinel)
        XCTAssertNotEqual(plan.patchedImage, bytes, "the image must actually differ")
        XCTAssertEqual(plan.patchedImage.count, bytes.count, "patching must not resize the image")
    }

    func testRefusesAnImageWithNoExecutableSegment() throws {
        let (image, bytes) = try image(words: [AArch64Instruction.svcZero], executable: false)
        XCTAssertThrowsError(try planner.plan(image: image, bytes: bytes)) { error in
            XCTAssertEqual(error as? PatchPlanError, .noExecutableSegment)
        }
    }

    func testDoesNotScanPastTheEndOfTheImage() throws {
        // A payload of five bytes leaves one trailing byte that must not be read as an instruction.
        var bytes = ELFFixture.image(entry: 0x4000_0000)
        let image = try ELFImage.parse(bytes)
        let segment = try XCTUnwrap(image.loadSegments.first)
        let start = Int(segment.fileOffset)
        let truncated = Data(bytes[0..<(start + 5)])
        XCTAssertThrowsError(try planner.plan(image: image, bytes: truncated)) { error in
            guard case PatchPlanError.imageTooSmallForSegment = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        bytes.removeAll()
    }

    /// The scan that matters: every `svc #0` in a real Ubuntu arm64 binary is found. If this passes but
    /// execution later traps somewhere else, the guest is generating code at runtime (documented as a
    /// Phase 2 non-goal).
    func testFindsSyscallSitesInTheRealTestBinary() throws {
        guard let path = ProcessInfo.processInfo.environment["UBUNTUPAD_TEST_BINARY"] else {
            throw XCTSkip("UBUNTUPAD_TEST_BINARY is not set")
        }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let image = try ELFImage.parse(bytes)
        let plan = try planner.plan(image: image, bytes: bytes)

        XCTAssertGreaterThan(plan.patchedCount, 3, "a real program with libc calls has several svc sites")
        XCTAssertEqual(Set(plan.sites.map(\.address)).count, plan.patchedCount, "sites must be unique")
        for site in plan.sites {
            XCTAssertEqual(site.original, AArch64Instruction.svcZero)
            XCTAssertTrue(
                plan.scannedRanges.contains { $0.contains(site.address) },
                "site 0x\(String(site.address, radix: 16)) is outside every scanned range")
        }
        // Sites must be sorted, which the trap handler's diagnostics rely on.
        XCTAssertEqual(plan.sites.map(\.address), plan.sites.map(\.address).sorted())
    }

    /// The freestanding probe programs are written by hand with exactly two syscalls, so the patch
    /// planner's answer is known in advance. This is the check that would catch a planner that missed a
    /// site (the guest would then make a Darwin syscall with Linux numbering) or over-patched (the
    /// guest would trip over a breakpoint we planted in data).
    func testFreestandingProbeHasExactlyItsTwoSyscallSites() throws {
        guard let path = ProcessInfo.processInfo.environment["UBUNTUPAD_TEST_NOSTDLIB_BINARY"] else {
            throw XCTSkip("UBUNTUPAD_TEST_NOSTDLIB_BINARY is not set")
        }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let image = try ELFImage.parse(bytes)
        let plan = try planner.plan(image: image, bytes: bytes)

        XCTAssertEqual(plan.patchedCount, 2, "write and exit_group, and nothing else")
        XCTAssertNil(image.interpreterPath(in: bytes), "the probe must stay statically linked")
        XCTAssertEqual(image.header.type, ELFType.executable.rawValue, "the probe is a fixed-address ET_EXEC")
        XCTAssertTrue(
            image.loadSegments.contains { $0.isExecutable },
            "there must be something executable to patch")
        XCTAssertEqual(plan.patchedImage.count, bytes.count)
    }

    func testRealBinaryHasSitesOnlyInExecutableSegments() throws {
        guard let path = ProcessInfo.processInfo.environment["UBUNTUPAD_TEST_BINARY"] else {
            throw XCTSkip("UBUNTUPAD_TEST_BINARY is not set")
        }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let image = try ELFImage.parse(bytes)
        let executable = image.loadSegments.filter { $0.isExecutable }
        let plan = try planner.plan(image: image, bytes: bytes)

        let executableRanges = executable.map {
            $0.virtualAddress..<($0.virtualAddress + $0.fileSize)
        }
        for site in plan.sites {
            XCTAssertTrue(
                executableRanges.contains { $0.contains(site.address) },
                "patched a site outside an executable PT_LOAD")
        }
    }
}
