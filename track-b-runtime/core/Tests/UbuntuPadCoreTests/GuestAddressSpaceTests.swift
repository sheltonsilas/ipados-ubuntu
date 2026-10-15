import XCTest

@testable import UbuntuPadCore

/// These tests are the reason the address-space model lives in the portable core: the 16 KiB
/// host-page behaviour of Apple silicon can be asserted on a 4 KiB Linux CI runner.
final class PageGeometryTests: XCTestCase {
    func testAppleSiliconGeometry() throws {
        let geometry = try XCTUnwrap(PageGeometry(guestPageSize: 4096, hostPageSize: 16384))
        XCTAssertEqual(geometry.guestPagesPerHostPage, 4)
        XCTAssertEqual(geometry.roundUpToGuestPage(4097), 8192)
        XCTAssertEqual(geometry.roundDownToGuestPage(0x1fff), 0x1000)
        XCTAssertEqual(geometry.roundUpToHostPage(0x4001), 0x8000)
        XCTAssertEqual(geometry.roundDownToHostPage(0x4001), 0x4000)
    }

    func testRejectsIncompatiblePageSizes() {
        XCTAssertNil(PageGeometry(guestPageSize: 4096, hostPageSize: 6144))
        XCTAssertNil(PageGeometry(guestPageSize: 8192, hostPageSize: 4096))
        XCTAssertNotNil(PageGeometry(guestPageSize: 4096, hostPageSize: 4096))
        XCTAssertNotNil(PageGeometry(guestPageSize: 16384, hostPageSize: 16384))
    }

    /// The rule that makes a 4 KiB guest work on 16 KiB pages: a guest protection request widens to
    /// the host page that contains it, exactly as Linux widens to *its* page boundaries.
    func testHostRangeRoundsOutwardToHostPages() throws {
        let geometry = try XCTUnwrap(PageGeometry(guestPageSize: 4096, hostPageSize: 16384))
        // One guest page in the middle of a host page.
        XCTAssertEqual(geometry.hostAlignedRange(covering: 0x5000..<0x6000), 0x4000..<0x8000)
        // A range that already spans host pages is not widened further than needed.
        XCTAssertEqual(geometry.hostAlignedRange(covering: 0x4000..<0x8000), 0x4000..<0x8000)
        // A single byte still forces a whole host page.
        XCTAssertEqual(geometry.hostAlignedRange(covering: 0x7000..<0x7001), 0x4000..<0x8000)
    }

    func testProtectionChangesArePerHostPage() throws {
        let geometry = try XCTUnwrap(PageGeometry(guestPageSize: 4096, hostPageSize: 16384))
        let space = GuestAddressSpace(geometry: geometry)

        // Four guest pages inside one host page collapse into a single host change.
        let single = space.protectionChanges(for: 0x4000..<0x8000, to: .read)
        XCTAssertEqual(single.count, 1)
        XCTAssertEqual(single[0].hostRange, 0x4000..<0x8000)
        XCTAssertFalse(single[0].widensBeyondRequest, "the request covered the whole host page")

        // A sub-page request widens, and says so.
        let widened = space.protectionChanges(for: 0x5000..<0x6000, to: .readExecute)
        XCTAssertEqual(widened.count, 1)
        XCTAssertEqual(widened[0].hostRange, 0x4000..<0x8000)
        XCTAssertTrue(widened[0].widensBeyondRequest)
        XCTAssertEqual(widened[0].protection, .readExecute)
    }

    func testProtectionChangesOnA4KiBHostAreOnePerGuestPage() throws {
        let geometry = try XCTUnwrap(PageGeometry(guestPageSize: 4096, hostPageSize: 4096))
        let space = GuestAddressSpace(geometry: geometry)
        let changes = space.protectionChanges(for: 0x4000..<0x8000, to: .read)
        XCTAssertEqual(changes.count, 4)
        XCTAssertEqual(changes.map(\.hostRange.lowerBound), [0x4000, 0x5000, 0x6000, 0x7000])
    }
}

final class GuestAddressSpaceTests: XCTestCase {
    private func makeSpace(hostPageSize: Int = 16384) throws -> GuestAddressSpace {
        let geometry = try XCTUnwrap(PageGeometry(guestPageSize: 4096, hostPageSize: hostPageSize))
        return GuestAddressSpace(geometry: geometry)
    }

    func testMapsAndFindsRegions() throws {
        var space = try makeSpace()
        try space.map(name: "text", guestRange: 0x400000..<0x401000, protection: .readExecute)
        try space.map(name: "data", guestRange: 0x401000..<0x402000, protection: .readWrite)
        try space.map(name: "stack", guestRange: 0x7f0000..<0x7f1000, protection: .readWrite)

        XCTAssertEqual(space.region(containing: 0x400000)?.name, "text")
        XCTAssertEqual(space.region(containing: 0x400800)?.name, "text")
        XCTAssertEqual(space.region(containing: 0x401000)?.name, "data")
        XCTAssertNil(space.region(containing: 0x500000))
        XCTAssertEqual(space.regions.count, 3)
    }

    func testRegionRangeIsWidenedToGuestPages() throws {
        var space = try makeSpace()
        let region = try space.map(name: "odd", guestRange: 0x400123..<0x400456, protection: .read)
        XCTAssertEqual(region.guestRange.lowerBound, 0x400000)
        XCTAssertEqual(region.guestRange.upperBound, 0x401000)
    }

    func testRejectsOverlappingRegions() throws {
        var space = try makeSpace()
        try space.map(name: "first", guestRange: 0x400000..<0x402000, protection: .read)
        XCTAssertThrowsError(try space.map(name: "second", guestRange: 0x401000..<0x403000, protection: .readWrite)) {
            error in
            guard case let GuestMemoryError.regionOverlapsExisting(name, _, _) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(name, "first")
        }
        XCTAssertEqual(space.regions.count, 1, "a rejected mapping must not be recorded")
    }

    func testAdjacentRegionsDoNotOverlap() throws {
        var space = try makeSpace()
        try space.map(name: "a", guestRange: 0x400000..<0x401000, protection: .read)
        try space.map(name: "b", guestRange: 0x401000..<0x402000, protection: .read)
        XCTAssertEqual(space.regions.count, 2)
    }

    func testRejectsZeroLengthRegion() throws {
        var space = try makeSpace()
        XCTAssertThrowsError(try space.map(name: "empty", guestRange: 0x400000..<0x400000, protection: .read))
    }

    /// The check that turns a guest bug into EFAULT instead of a host crash.
    func testValidatesGuestBuffers() throws {
        var space = try makeSpace()
        try space.map(name: "text", guestRange: 0x400000..<0x401000, protection: .read)

        XCTAssertTrue(space.validateBuffer(address: 0x400000, length: 0x1000))
        XCTAssertTrue(space.validateBuffer(address: 0x400800, length: 0x800))
        XCTAssertFalse(space.validateBuffer(address: 0x400800, length: 0x900), "crosses the region end")
        XCTAssertFalse(space.validateBuffer(address: 0x3fffff, length: 8), "starts before the region")
        XCTAssertFalse(space.validateBuffer(address: 0, length: 8), "unmapped in this address space")
        XCTAssertTrue(space.validateBuffer(address: 0, length: 0), "a zero-length access is always valid")
        XCTAssertFalse(
            space.validateBuffer(address: UInt64.max - 3, length: 8), "overflow must not wrap")
    }

    func testMappedBytesCountsHostPages() throws {
        var space = try makeSpace()
        try space.map(name: "one", guestRange: 0x400000..<0x401000, protection: .read)
        // One guest page occupies a whole host page, so the reported footprint is 16 KiB, not 4 KiB.
        XCTAssertEqual(space.mappedBytes, 16384)
        XCTAssertTrue(space.report().contains("guest_pages_per_host_page=4"))
    }

    /// The union rule, stated as a test: on a 16 KiB host, a read-only segment and a writable segment
    /// that share one host page cannot be protected separately, so the page gets both rights and the
    /// report says a merge happened.
    func testHostPagePlanMergesConflictingProtectionsOnA16KiBHost() throws {
        var space = try makeSpace(hostPageSize: 16384)
        // Two 4 KiB guest segments inside the same 16 KiB host page.
        try space.map(name: "ro", guestRange: 0x400000..<0x401000, protection: .read)
        try space.map(name: "rw", guestRange: 0x401000..<0x402000, protection: .readWrite)

        let plan = space.hostPageProtectionPlan()
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].hostRange, 0x400000..<0x404000)
        XCTAssertEqual(plan[0].protection, [.read, .write])
        XCTAssertTrue(plan[0].widensBeyondRequest, "a merged page must be reported, not hidden")
    }

    /// The same two segments on a 4 KiB host keep their own pages: no merge, no widening.
    func testHostPagePlanKeepsSegmentsSeparateOnA4KiBHost() throws {
        var space = try makeSpace(hostPageSize: 4096)
        try space.map(name: "ro", guestRange: 0x400000..<0x401000, protection: .read)
        try space.map(name: "rw", guestRange: 0x401000..<0x402000, protection: .readWrite)

        let plan = space.hostPageProtectionPlan()
        XCTAssertEqual(plan.count, 2)
        XCTAssertEqual(plan[0].protection, .read)
        XCTAssertEqual(plan[1].protection, .readWrite)
        XCTAssertEqual(plan.map(\.widensBeyondRequest), [false, false], "each page is exactly one segment")
    }

    func testHostPagePlanSkipsUnmappedPagesAndMergesNeighbours() throws {
        var space = try makeSpace(hostPageSize: 16384)
        // Two text segments with a gap between them, then a stack far away.
        try space.map(name: "text1", guestRange: 0x400000..<0x404000, protection: .readExecute)
        try space.map(name: "text2", guestRange: 0x480000..<0x484000, protection: .readExecute)
        try space.map(name: "stack", guestRange: 0x7f0000..<0x7f4000, protection: .readWrite)

        let plan = space.hostPageProtectionPlan()
        XCTAssertEqual(plan.count, 3, "the page between the two text segments is not in the plan")
        XCTAssertEqual(plan[0].hostRange, 0x400000..<0x404000, "adjacent equal pages are merged")
        XCTAssertEqual(plan[0].protection, .readExecute)
        XCTAssertEqual(plan[1].hostRange, 0x480000..<0x484000)
        XCTAssertEqual(plan[2].protection, .readWrite)
        XCTAssertEqual(plan[2].hostRange, 0x7f0000..<0x7f4000)
    }

    func testHostPagePlanOfAnEmptySpaceIsEmpty() throws {
        let space = try makeSpace()
        XCTAssertTrue(space.hostPageProtectionPlan().isEmpty)
    }

    func testUnmapRemovesOnlyFullyContainedRegions() throws {
        var space = try makeSpace()
        try space.map(name: "heap", guestRange: 0x600000..<0x604000, protection: .readWrite)
        try space.map(name: "stack", guestRange: 0x7f0000..<0x7f4000, protection: .readWrite)

        XCTAssertFalse(space.unmap(guestRange: 0x5ff000..<0x601000), "a partial overlap must be refused")
        XCTAssertFalse(space.unmap(guestRange: 0x900000..<0x901000), "an unmapped range is not success")
        XCTAssertEqual(space.regions.count, 2)

        XCTAssertTrue(space.unmap(guestRange: 0x600000..<0x604000))
        XCTAssertEqual(space.regions.map(\.name), ["stack"])
    }

    func testLinuxProtConversionIsNotTheELFFlagEncoding() {
        // PROT_READ=1, PROT_WRITE=2, PROT_EXEC=4 — the reverse of the ELF PF_x bit order for read/exec.
        XCTAssertEqual(GuestProtection.fromLinuxProt(1), .read)
        XCTAssertEqual(GuestProtection.fromLinuxProt(2), .write)
        XCTAssertEqual(GuestProtection.fromLinuxProt(4), .execute)
        XCTAssertEqual(GuestProtection.fromLinuxProt(7), .all)
        // `GuestProtection.none` is written out in full on purpose: on an Optional<GuestProtection>,
        // a bare `.none` means *nil* (Optional.none), not the empty option set, so `.none` here would
        // silently turn this assertion into a tautology. CI caught exactly that on the first run.
        XCTAssertEqual(GuestProtection.fromLinuxProt(0), GuestProtection.none)
        XCTAssertNotNil(GuestProtection.fromLinuxProt(0), "a zero protection is valid, not a failure")
        XCTAssertNil(GuestProtection.fromLinuxProt(1 << 20), "PROT_GROWSDOWN and friends are refused")
        XCTAssertEqual(GuestProtection.readExecute.linuxProtValue, 5)
        XCTAssertEqual(GuestProtection(elfFlags: 0x5), .readExecute, "ELF PF_R|PF_X")
        XCTAssertEqual(GuestProtection(elfFlags: 0x5).hostProtBits, 0x1 | 0x4)
    }
}
