import Foundation
import XCTest

@testable import UbuntuPadCore

/// The relocation pass is the second half of the answer to the reserved-low-memory problem: an image
/// that has been *moved* to a bias only works if its own absolute addresses are rewritten.
///
/// These tests build tiny images by hand so that the table layout, the virtual-address-to-file-offset
/// conversion and each refusal are pinned down deterministically, then (when a cross toolchain is
/// available) check the same code against a real `-static-pie` binary.
final class RelocationTests: XCTestCase {
    // MARK: - synthetic images with a PT_DYNAMIC segment

    private enum Layout {
        static let headerSize = 64
        static let programHeaderSize = 56
        static let dynamicVaddr: UInt64 = 0x100
        static let dynamicSize = 64  // four Elf64_Dyn entries
        static let relaVaddr: UInt64 = 0x140
        static let relaEntrySize = 24
    }

    private struct Entry {
        var offset: UInt64
        var type: UInt32
        var addend: Int64
    }

    private static func payloadStart(programHeaderCount: Int) -> UInt64 {
        UInt64(Layout.headerSize + Layout.programHeaderSize * programHeaderCount)
    }

    /// Builds an image with one readable/writable `PT_LOAD` and a `PT_DYNAMIC` describing `entries`.
    ///
    /// The load segment starts at virtual address 0 and at a *different* file offset, which is the
    /// arrangement that catches the mistake of treating `r_offset` as a file offset: for many real PIE
    /// images the two coincide, so the difference is invisible until it is not.
    private static func image(entries: [Entry]) -> Data {
        let payloadStart = payloadStart(programHeaderCount: 2)
        let payloadSize = Layout.relaVaddr + UInt64(entries.count * Layout.relaEntrySize)
        let memorySize = payloadSize + 0x100  // a zero-filled tail, so .bss cases are reachable

        var bytes = Data()
        bytes.append(contentsOf: [0x7f, 0x45, 0x4c, 0x46, 2, 1, 1, 0])
        bytes.append(Data(repeating: 0, count: 8))
        bytes.putLE(ELFType.sharedObject.rawValue)
        bytes.putLE(ELFMachine.aarch64.rawValue)
        bytes.putLE(UInt32(1))
        bytes.putLE(UInt64(0x1040))  // e_entry: somewhere inside the image
        bytes.putLE(UInt64(Layout.headerSize))  // e_phoff
        bytes.putLE(UInt64(0))  // e_shoff
        bytes.putLE(UInt32(0))
        bytes.putLE(UInt16(Layout.headerSize))
        bytes.putLE(UInt16(Layout.programHeaderSize))
        bytes.putLE(UInt16(2))
        bytes.putLE(UInt16(0))
        bytes.putLE(UInt16(0))
        bytes.putLE(UInt16(0))
        precondition(bytes.count == Layout.headerSize)

        // PT_LOAD
        bytes.putLE(UInt32(1))
        bytes.putLE(UInt32(0x6))  // read + write
        bytes.putLE(payloadStart)
        bytes.putLE(UInt64(0))
        bytes.putLE(UInt64(0))
        bytes.putLE(payloadSize)
        bytes.putLE(memorySize)
        bytes.putLE(UInt64(0x1000))

        // PT_DYNAMIC
        bytes.putLE(UInt32(2))
        bytes.putLE(UInt32(0x6))
        bytes.putLE(payloadStart + Layout.dynamicVaddr)
        bytes.putLE(Layout.dynamicVaddr)
        bytes.putLE(Layout.dynamicVaddr)
        bytes.putLE(UInt64(Layout.dynamicSize))
        bytes.putLE(UInt64(Layout.dynamicSize))
        bytes.putLE(UInt64(8))

        // The payload, at virtual address 0.
        bytes.append(Data(repeating: 0xaa, count: Int(Layout.dynamicVaddr)))
        bytes.putLE(UInt64(DynamicTag.rela))
        bytes.putLE(Layout.relaVaddr)
        bytes.putLE(UInt64(DynamicTag.relaSize))
        bytes.putLE(UInt64(entries.count * Layout.relaEntrySize))
        bytes.putLE(UInt64(DynamicTag.relaEntrySize))
        bytes.putLE(UInt64(Layout.relaEntrySize))
        bytes.putLE(UInt64(DynamicTag.null))
        bytes.putLE(UInt64(0))
        precondition(bytes.count == Int(payloadStart + Layout.dynamicVaddr + UInt64(Layout.dynamicSize)))

        for entry in entries {
            bytes.putLE(entry.offset)
            bytes.putLE(UInt64(entry.type))
            bytes.putLE(UInt64(bitPattern: entry.addend))
        }
        precondition(bytes.count == Int(payloadStart + payloadSize))
        return bytes
    }

    private func parsedImage(_ bytes: Data) throws -> (ELFImage, DynamicSection) {
        let image = try ELFImage.parse(bytes)
        let dynamic = try XCTUnwrap(DynamicSection.parse(image: image, bytes: bytes))
        return (image, dynamic)
    }

    // MARK: - the happy path

    func testAppliesRelativeRelocationsAtTheAddressesTheTableNames() throws {
        let bytes = Self.image(entries: [
            Entry(offset: 0x40, type: RelocationType.relative.rawValue, addend: 0x2000),
            Entry(offset: 0x50, type: RelocationType.relative.rawValue, addend: 0x100),
        ])
        let (image, dynamic) = try parsedImage(bytes)

        var table = RelocationTable()
        try table.parse(dynamic: dynamic, image: image, bytes: bytes)
        XCTAssertEqual(table.relativeCount, 2)
        XCTAssertEqual(table.unsupportedCount, 0)

        var patched = bytes
        let bias: UInt64 = 0x2_0000_0000
        XCTAssertEqual(try table.apply(to: &patched, image: image, bias: bias), 2)

        let payloadStart = Self.payloadStart(programHeaderCount: 2)
        // r_offset is a virtual address; the bytes live at payloadStart + vaddr.
        XCTAssertEqual(readUInt64(patched, at: Int(payloadStart + 0x40)), bias + 0x2000)
        XCTAssertEqual(readUInt64(patched, at: Int(payloadStart + 0x50)), bias + 0x100)
        // Nothing else was touched.
        XCTAssertEqual(readUInt64(patched, at: Int(payloadStart + 0x30)), 0xaaaa_aaaa_aaaa_aaaa)
    }

    // MARK: - refusals, because a half-relocated image is worse than a refused one

    func testSymbolBasedRelocationsAreReportedRatherThanGuessedAt() throws {
        let bytes = Self.image(entries: [
            Entry(offset: 0x40, type: 1025, addend: 0),  // R_AARCH64_ABS64
            Entry(offset: 0x48, type: RelocationType.iRelative.rawValue, addend: 0),
        ])
        let (image, dynamic) = try parsedImage(bytes)

        var table = RelocationTable()
        try table.parse(dynamic: dynamic, image: image, bytes: bytes)

        XCTAssertEqual(table.relativeCount, 0)
        XCTAssertEqual(table.unsupportedCount, 2)
        XCTAssertEqual(table.unsupported.map { $0.type }, [1025, RelocationType.iRelative.rawValue])
    }

    func testRelocationIntoZeroFilledMemoryIsRefused() throws {
        let payloadSize = Layout.relaVaddr + UInt64(Layout.relaEntrySize)
        let bytes = Self.image(entries: [
            Entry(offset: payloadSize + 0x10, type: RelocationType.relative.rawValue, addend: 0)
        ])
        let (image, dynamic) = try parsedImage(bytes)

        var table = RelocationTable()
        try table.parse(dynamic: dynamic, image: image, bytes: bytes)
        XCTAssertEqual(table.relativeCount, 1, "the relocation is well formed; only its target is not")

        var patched = bytes
        XCTAssertThrowsError(try table.apply(to: &patched, image: image, bias: 0x1000)) { error in
            XCTAssertEqual(
                error as? RelocationError,
                .relocationInZeroFilledMemory(offset: payloadSize + 0x10))
        }
    }

    func testRelocationOutsideTheImageIsRefused() throws {
        let bytes = Self.image(entries: [
            Entry(offset: 0xdead_0000, type: RelocationType.relative.rawValue, addend: 0)
        ])
        let (image, dynamic) = try parsedImage(bytes)

        var table = RelocationTable()
        try table.parse(dynamic: dynamic, image: image, bytes: bytes)

        var patched = bytes
        XCTAssertThrowsError(try table.apply(to: &patched, image: image, bias: 0)) { error in
            XCTAssertEqual(error as? RelocationError, .relocationOutsideImage(offset: 0xdead_0000))
        }
    }

    func testImageWithoutADynamicSectionHasNoRelocations() throws {
        // The fixture in ELFTests has a single PT_LOAD and nothing else.
        let bytes = ELFFixture.image()
        let image = try ELFImage.parse(bytes)
        XCTAssertNil(try DynamicSection.parse(image: image, bytes: bytes))
    }

    func testTruncatedDynamicSegmentIsReportedAsMalformed() throws {
        let bytes = Self.image(entries: [])
        let image = try ELFImage.parse(bytes)
        // DT_RELA pointing somewhere no segment covers: the table entry is well formed, its contents
        // are not, and the refusal says which address was wrong.
        let dynamic = DynamicSection(entries: [
            DynamicEntry(tag: DynamicTag.rela, value: 0x9000),
            DynamicEntry(tag: DynamicTag.relaSize, value: 48),
            DynamicEntry(tag: DynamicTag.relaEntrySize, value: 24),
        ])
        var table = RelocationTable()
        XCTAssertThrowsError(try table.parse(dynamic: dynamic, image: image, bytes: bytes)) { error in
            XCTAssertEqual(
                error as? RelocationError,
                .malformedRelocationTable(detail: "DT_RELA = 0x9000 is not inside any segment"))
        }
    }

    // MARK: - a real position-independent binary

    /// The same code, against what the Ubuntu toolchain actually emits. `tests.yml` builds
    /// `testdata/hello-pie-nostdlib.c` with `-static-pie` and points `UBUNTUPAD_TEST_PIE_BINARY` here;
    /// the program deliberately prints through a global pointer so that the relocation pass has real
    /// work to do. Skipped (never passed) when the variable is absent.
    func testParsesAndAppliesARealPIEBinarysRelocations() throws {
        guard let path = ProcessInfo.processInfo.environment["UBUNTUPAD_TEST_PIE_BINARY"] else {
            throw XCTSkip("UBUNTUPAD_TEST_PIE_BINARY is not set; skipping real-binary relocation check")
        }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let image = try ELFImage.parse(bytes)
        let dynamic = try XCTUnwrap(
            DynamicSection.parse(image: image, bytes: bytes),
            "a -static-pie binary must describe its relocations in PT_DYNAMIC")

        var table = RelocationTable()
        try table.parse(dynamic: dynamic, image: image, bytes: bytes)

        XCTAssertGreaterThan(
            table.relativeCount, 0,
            "the test program uses a global pointer precisely so that this is not zero")
        XCTAssertEqual(
            table.unsupportedCount, 0,
            "a -nostdlib -static-pie build of this program needs no symbol relocations")

        let bias: UInt64 = 0x2_0000_0000
        var patched = bytes
        XCTAssertEqual(
            try table.apply(to: &patched, image: image, bias: bias), table.relativeCount)

        // Every rewritten word must now be an address inside the image, which is the property the
        // guest depends on: a relocated pointer that falls outside the image would fault.
        let lowest = try XCTUnwrap(image.loadSegments.map(\.virtualAddress).min())
        let highest = try XCTUnwrap(image.loadSegments.map { $0.virtualAddress + $0.memorySize }.max())
        for relocation in table.relativeRelocations {
            let fileOffset = try XCTUnwrap(
                RelocationTable.fileOffset(forVirtualAddress: relocation.offset, in: image))
            let value = readUInt64(patched, at: Int(fileOffset))
            let target = value - bias
            XCTAssertTrue(
                target >= lowest && target <= highest,
                "relocated pointer 0x\(String(value, radix: 16)) does not point into the image")
        }
    }

    private func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(data[offset + index]) << (8 * UInt64(index))
        }
        return value
    }
}

private extension Data {
    mutating func putLE(_ value: UInt16) {
        append(contentsOf: [UInt8(value & 0xff), UInt8((value >> 8) & 0xff)])
    }
    mutating func putLE(_ value: UInt32) {
        for index in 0..<4 { append(UInt8((value >> (8 * UInt32(index))) & 0xff)) }
    }
    mutating func putLE(_ value: UInt64) {
        for index in 0..<8 { append(UInt8((value >> (8 * UInt64(index))) & 0xff)) }
    }
}
