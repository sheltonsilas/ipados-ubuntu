import Foundation
import XCTest

@testable import UbuntuPadCore

/// The placement decision is the answer to a platform fact that took real time to learn: on Apple
/// silicon the low 4 GiB of every arm64 process is `__PAGEZERO`, reserved by the kernel, so a Linux
/// executable linked at its usual 0x400000 cannot be mapped at its own addresses — not by hinting
/// (the address is not free) and not by forcing (the reservation is a kernel rule, and shrinking it at
/// link time yields a binary the kernel kills at startup). See DECISIONS.md decision 0019.
///
/// That decision therefore lives in portable code and is tested here, on Linux, where the floor does
/// not exist and every branch can be reached deterministically. The end-to-end run on macOS then only
/// has to confirm that the plan was carried out.
final class ImagePlacementTests: XCTestCase {
    private static let fourGiB: UInt64 = 4 * 1024 * 1024 * 1024
    private static let sixtyFourKiB: UInt64 = 64 * 1024

    /// A synthetic image with exactly the segment geometry the case needs.
    private func image(
        kind: ELFType,
        entry: UInt64 = 0x1000,
        segments: [(virtualAddress: UInt64, fileSize: UInt64, memorySize: UInt64, alignment: UInt64)]
    ) -> ELFImage {
        ELFImage(
            header: ELFHeader(
                type: kind.rawValue,
                machine: ELFMachine.aarch64.rawValue,
                entryPoint: entry,
                programHeaderOffset: UInt64(ELFImage.headerSize),
                programHeaderEntrySize: UInt16(ELFImage.programHeaderSize),
                programHeaderCount: UInt16(segments.count)),
            programHeaders: segments.enumerated().map { index, segment in
                ProgramHeader(
                    index: index,
                    type: .load,
                    flags: 0x5,
                    fileOffset: 0,
                    virtualAddress: segment.virtualAddress,
                    physicalAddress: segment.virtualAddress,
                    fileSize: segment.fileSize,
                    memorySize: segment.memorySize,
                    alignment: segment.alignment)
            })
    }

    // MARK: - a host with no reserved low region (Linux)

    func testFixedAddressImageMapsIdentityWhereTheAddressIsFree() throws {
        let executable = image(
            kind: .executable,
            segments: [(0x40_0000, 0x1000, 0x1000, 0x1000)])

        let placement = try ImagePlacementPlanner().plan(image: executable, reservedLowRegion: 0)
        XCTAssertEqual(placement, .identity)
        XCTAssertEqual(placement.bias, 0)
    }

    /// Even with the address space free, a position-independent image is given a bias: mapping at
    /// address 0 would mean asking the kernel for a hint of 0, which every `mmap` treats as "no
    /// preference", so the image would land somewhere the caller did not verify.
    func testPositionIndependentImageIsBiasedEvenWithoutAFloor() throws {
        let pie = image(
            kind: .sharedObject,
            segments: [(0, 0x1000, 0x2000, Self.sixtyFourKiB)])

        let placement = try ImagePlacementPlanner().plan(image: pie, reservedLowRegion: 0)
        guard case let .biased(bias) = placement else {
            return XCTFail("expected a bias, got \(placement)")
        }
        XCTAssertGreaterThanOrEqual(bias, ImagePlacementPlanner.defaultBiasTarget)
        XCTAssertEqual(bias % Self.sixtyFourKiB, 0, "the bias must keep the image's alignment")
    }

    // MARK: - a host with the 4 GiB reservation (Apple silicon)

    func testFixedAddressImageInsideTheReservedRegionIsRefusedWithAReason() throws {
        let executable = image(
            kind: .executable,
            segments: [(0x40_0000, 0x1000, 0x1000, 0x1000)])

        let placement = try ImagePlacementPlanner().plan(
            image: executable, reservedLowRegion: Self.fourGiB)

        guard case let .refused(reason) = placement else {
            return XCTFail("a fixed-address image below the floor cannot run; got \(placement)")
        }
        XCTAssertTrue(placement.isRefused)
        XCTAssertEqual(placement.bias, 0)
        // The message has to be usable by whoever hits this: what the image is, where it was linked,
        // why forcing the address will not help, and what would.
        XCTAssertTrue(reason.contains("fixed-address (ET_EXEC)"), reason)
        XCTAssertTrue(reason.contains("0x400000"), reason)
        XCTAssertTrue(reason.contains("4 GiB"), reason)
        XCTAssertTrue(reason.contains("position-independent"), reason)
    }

    func testFixedAddressImageAboveTheFloorStillMapsIdentity() throws {
        let executable = image(
            kind: .executable,
            segments: [(Self.fourGiB, 0x1000, 0x1000, 0x1000)])

        let placement = try ImagePlacementPlanner().plan(
            image: executable, reservedLowRegion: Self.fourGiB)
        XCTAssertEqual(placement, .identity)
    }

    func testPositionIndependentImageIsMovedAboveTheReservedRegion() throws {
        let pie = image(
            kind: .sharedObject,
            segments: [(0, 0x1000, 0x2000, Self.sixtyFourKiB)])

        let placement = try ImagePlacementPlanner().plan(
            image: pie, reservedLowRegion: Self.fourGiB)

        guard case let .biased(bias) = placement else {
            return XCTFail("expected a bias, got \(placement)")
        }
        XCTAssertGreaterThanOrEqual(bias, Self.fourGiB, "the image must clear the reserved region")
        XCTAssertEqual(bias % Self.sixtyFourKiB, 0)
    }

    /// The property that makes the bias safe: every segment must stay congruent to its link-time
    /// address modulo its own alignment, which is the ELF rule
    /// `(bias + p_vaddr) % p_align == p_offset % p_align` surviving the shift.
    func testBiasPreservesSegmentAlignmentForAnImageNotLinkedAtZero() throws {
        let pie = image(
            kind: .sharedObject,
            segments: [(0x4000, 0x1000, 0x2000, Self.sixtyFourKiB)])

        let placement = try ImagePlacementPlanner().plan(
            image: pie, reservedLowRegion: Self.fourGiB)

        guard case let .biased(bias) = placement else {
            return XCTFail("expected a bias, got \(placement)")
        }
        XCTAssertEqual(
            (bias + 0x4000) % Self.sixtyFourKiB, 0x4000 % Self.sixtyFourKiB,
            "the bias must not disturb the image's alignment")
        XCTAssertGreaterThanOrEqual(bias + 0x4000, Self.fourGiB)
    }

    func testEverySegmentClearsTheFloorAfterTheBias() throws {
        // Two segments far apart, the second one the highest: the planner has to consider the whole
        // image, not just its first segment.
        let pie = image(
            kind: .sharedObject,
            segments: [
                (0, 0x2000, 0x2000, 0x1000),
                (0x20_0000, 0x1000, 0x1000, 0x1000),
            ])

        let placement = try ImagePlacementPlanner().plan(
            image: pie, reservedLowRegion: Self.fourGiB)
        guard case let .biased(bias) = placement else {
            return XCTFail("expected a bias, got \(placement)")
        }
        for segment in pie.loadSegments {
            XCTAssertGreaterThanOrEqual(segment.virtualAddress + bias, Self.fourGiB)
        }
    }

    // MARK: - retrying a refused bias

    /// A bias is a suggestion, and a hint the host refuses is not a failure of the plan — but the
    /// *next* address must obey the same two rules (above the floor, aligned), or the image would be
    /// correct at one base and silently broken at the next. That conversion is tested here rather than
    /// in the runner, because it is the same arithmetic in both places.
    func testEveryRetryCandidateKeepsTheImagesAlignmentAndClearsTheFloor() throws {
        let planner = ImagePlacementPlanner()
        let candidates = planner.biasCandidates(
            lowest: 0, atOrAbove: Self.fourGiB, alignment: Self.sixtyFourKiB)

        XCTAssertEqual(candidates.count, ImagePlacementPlanner.biasAttemptCount)
        XCTAssertEqual(candidates.first, Self.fourGiB)
        XCTAssertEqual(Set(candidates).count, candidates.count, "candidates must be distinct")
        for (index, bias) in candidates.enumerated() {
            XCTAssertEqual(bias % Self.sixtyFourKiB, 0, "candidate \(index) breaks the alignment rule")
            XCTAssertGreaterThanOrEqual(bias, Self.fourGiB)
            if index > 0 {
                XCTAssertGreaterThan(bias, candidates[index - 1], "candidates must increase")
            }
        }
    }

    /// The conversion the runner uses when the host answers a refused hint with a free address.
    func testABiasCanBeDerivedFromAnyFreeAddress() throws {
        let planner = ImagePlacementPlanner()
        // The address `macos-15` offered for the real guest image (lowest virtual address 0) in place of
        // every refused hint, and the one the first green end-to-end run was placed at.
        let offered: UInt64 = 0x70_0000_0000
        let bias = planner.bias(lowest: 0, atOrAbove: offered, alignment: Self.sixtyFourKiB)
        XCTAssertEqual(bias, offered)

        // An unaligned offer is rounded up rather than used as-is.
        let unaligned: UInt64 = 0x3_0000_8000
        let rounded = planner.bias(lowest: 0, atOrAbove: unaligned, alignment: Self.sixtyFourKiB)
        XCTAssertEqual(rounded, 0x3_0001_0000)
        XCTAssertEqual(rounded % Self.sixtyFourKiB, 0)

        // An image whose lowest address is already above the floor needs no bias at all.
        XCTAssertEqual(planner.bias(lowest: 0x5_0000_0000, atOrAbove: Self.fourGiB, alignment: 0x1000), 0)
    }

    /// The default target must be well clear of the floor and of the regions the platform uses for its
    /// own mappings; a hint inside those is refused, which is why the runner also retries.
    func testDefaultBiasTargetIsFarAboveTheReservedRegion() throws {
        XCTAssertGreaterThan(ImagePlacementPlanner.defaultBiasTarget, Self.fourGiB * 8)
        XCTAssertEqual(ImagePlacementPlanner.defaultBiasTarget % Self.sixtyFourKiB, 0)
        XCTAssertGreaterThanOrEqual(ImagePlacementPlanner.biasRetryStep, Self.sixtyFourKiB)
    }

    func testImageWithNoLoadableSegmentsIsAnError() throws {
        let noSegments = image(kind: .executable, segments: [])
        XCTAssertThrowsError(
            try ImagePlacementPlanner().plan(image: noSegments, reservedLowRegion: Self.fourGiB)
        ) { error in
            XCTAssertEqual(error as? ImagePlacementError, .noLoadableSegments)
        }
    }

    func testNonAArch64ImageIsAnError() throws {
        let wrongMachine = ELFImage(
            header: ELFHeader(
                type: ELFType.executable.rawValue,
                machine: 0x3e,  // EM_X86_64
                entryPoint: 0x4000,
                programHeaderOffset: 64,
                programHeaderEntrySize: 56,
                programHeaderCount: 1),
            programHeaders: [])
        XCTAssertThrowsError(
            try ImagePlacementPlanner().plan(image: wrongMachine, reservedLowRegion: 0)
        ) { error in
            XCTAssertEqual(error as? ImagePlacementError, .notAArch64(0x3e))
        }
    }

    /// Parses and places a real position-independent binary when CI provides one.
    ///
    /// `tests.yml` cross-compiles `testdata/hello-pie-nostdlib.c` with `-static-pie` and points
    /// `UBUNTUPAD_TEST_PIE_BINARY` at it, so this checks the planner against the toolchain Ubuntu
    /// actually ships rather than against a synthetic image. Skipped (never silently passed) when the
    /// variable is absent, as on a machine without a cross-compiler.
    func testPlacesARealPositionIndependentBinary() throws {
        guard let path = ProcessInfo.processInfo.environment["UBUNTUPAD_TEST_PIE_BINARY"] else {
            throw XCTSkip("UBUNTUPAD_TEST_PIE_BINARY is not set; skipping real-binary placement check")
        }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let real = try ELFImage.parse(bytes)

        XCTAssertEqual(real.header.elfType, .sharedObject, "a -static-pie build must be ET_DYN")

        // The floor is the macOS number, since that is the host this decision exists for.
        let placement = try ImagePlacementPlanner().plan(
            image: real, reservedLowRegion: Self.fourGiB)
        guard case let .biased(bias) = placement else {
            return XCTFail("a real PIE image must be placed at a bias, got \(placement)")
        }
        XCTAssertGreaterThan(bias, 0)

        let lowest = try XCTUnwrap(real.loadSegments.map(\.virtualAddress).min())
        XCTAssertLessThan(
            lowest, Self.fourGiB,
            "the point of the bias is that this image is linked inside the reserved region")
        for segment in real.loadSegments where segment.alignment > 1 {
            XCTAssertEqual(
                (segment.virtualAddress + bias) % segment.alignment,
                segment.virtualAddress % segment.alignment,
                "the bias must preserve the alignment rule for every segment")
            XCTAssertGreaterThanOrEqual(segment.virtualAddress + bias, Self.fourGiB)
        }
    }
}
