import Foundation
import XCTest

@testable import UbuntuPadCore

/// Builds synthetic ELF64 images so the parser can be tested for the cases a real binary will not
/// exercise (bad magic, wrong machine, truncation).
enum ELFFixture {
    static func image(
        type: UInt16 = 2,
        machine: UInt16 = 183,
        entry: UInt64 = 0x4000_0000,
        interp: String? = nil,
        magic: [UInt8] = [0x7f, 0x45, 0x4c, 0x46],
        elfClass: UInt8 = 2,
        encoding: UInt8 = 1
    ) -> Data {
        var segments: [(UInt32, UInt32, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64)] = []
        // (type, flags, offset, vaddr, paddr, filesz, memsz, align)
        var payload = Data()
        var cursor: UInt64 = 0x1000

        if let interp {
            let bytes = Data(interp.utf8) + Data([0])
            segments.append((3, 0x4, cursor, 0x4002_0000, 0x4002_0000, UInt64(bytes.count), UInt64(bytes.count), 1))
            payload.append(bytes)
            cursor += UInt64(bytes.count)
        }
        segments.append((1, 0x5, cursor, 0x4000_0000, 0x4000_0000, 0x40, 0x40, 0x1000))
        payload.append(Data(repeating: 0x90, count: 0x40))

        let headerSize = ELFImage.headerSize
        let phSize = ELFImage.programHeaderSize
        let phoff = UInt64(headerSize)
        let payloadStart = phoff + UInt64(phSize * segments.count)

        // Re-point file offsets at the real position of each payload block.
        var dataOffset = payloadStart
        var rebuilt: [(UInt32, UInt32, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64)] = []
        for segment in segments {
            var copy = segment
            copy.2 = dataOffset
            dataOffset += copy.5
            rebuilt.append(copy)
        }

        var out = Data()
        out.append(contentsOf: magic)
        out.append(elfClass)
        out.append(encoding)
        out.append(contentsOf: [1, 0, 0, 0, 0, 0, 0, 0, 0, 0])  // version, osabi, abiversion, padding
        out.appendLE(type)
        out.appendLE(machine)
        out.appendLE(UInt32(1))  // e_version
        out.appendLE(entry)
        out.appendLE(phoff)  // e_phoff
        out.appendLE(UInt64(0))  // e_shoff
        out.appendLE(UInt32(0))  // e_flags
        out.appendLE(UInt16(headerSize))
        out.appendLE(UInt16(phSize))
        out.appendLE(UInt16(rebuilt.count))
        out.appendLE(UInt16(0))  // e_shentsize
        out.appendLE(UInt16(0))  // e_shnum
        out.appendLE(UInt16(0))  // e_shstrndx
        precondition(out.count == headerSize)

        for segment in rebuilt {
            out.appendLE(segment.0)
            out.appendLE(segment.1)
            out.appendLE(segment.2)
            out.appendLE(segment.3)
            out.appendLE(segment.4)
            out.appendLE(segment.5)
            out.appendLE(segment.6)
            out.appendLE(segment.7)
        }
        out.append(payload)
        return out
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(contentsOf: [UInt8(value & 0xff), UInt8((value >> 8) & 0xff)])
    }
    mutating func appendLE(_ value: UInt32) {
        for index in 0..<4 { append(UInt8((value >> (8 * UInt32(index))) & 0xff)) }
    }
    mutating func appendLE(_ value: UInt64) {
        for index in 0..<8 { append(UInt8((value >> (8 * UInt64(index))) & 0xff)) }
    }
}

final class ELFTests: XCTestCase {
    func testParsesHeaderAndSegments() throws {
        let bytes = ELFFixture.image(entry: 0x4000_1234)
        let image = try ELFImage.parse(bytes)

        XCTAssertEqual(image.header.type, ELFType.executable.rawValue)
        XCTAssertTrue(image.header.isAArch64)
        XCTAssertEqual(image.header.machine, ELFMachine.aarch64.rawValue)
        XCTAssertEqual(image.header.entryPoint, 0x4000_1234)
        XCTAssertEqual(image.header.programHeaderEntrySize, 56)
        XCTAssertEqual(image.loadSegments.count, 1)

        let load = try XCTUnwrap(image.loadSegments.first)
        XCTAssertEqual(load.virtualAddress, 0x4000_0000)
        XCTAssertTrue(load.isExecutable)
        XCTAssertTrue(load.isWritable)
        XCTAssertTrue(load.isReadable)
        XCTAssertNil(image.interpreterPath(in: bytes), "fixture has no PT_INTERP")
    }

    func testReadsInterpreterPath() throws {
        let path = "/lib/ld-linux-aarch64.so.1"
        let bytes = ELFFixture.image(type: 3, interp: path)
        let image = try ELFImage.parse(bytes)

        XCTAssertEqual(image.header.type, ELFType.sharedObject.rawValue)
        XCTAssertEqual(image.interpreterPath(in: bytes), path)
        XCTAssertEqual(image.programHeaders.filter { $0.type == .interpreter }.count, 1)
    }

    func testRejectsBadMagic() {
        let bytes = ELFFixture.image(magic: [0x7f, 0x45, 0x4c, 0x47])
        XCTAssertThrowsError(try ELFImage.parse(bytes)) { error in
            XCTAssertEqual(error as? ELFError, .badMagic)
        }
    }

    func testRejectsNonAArch64Machine() {
        let bytes = ELFFixture.image(machine: 0x3e)  // EM_X86_64
        XCTAssertThrowsError(try ELFImage.parse(bytes)) { error in
            XCTAssertEqual(error as? ELFError, .unsupportedMachine(0x3e))
        }
    }

    func testRejects32BitImages() {
        let bytes = ELFFixture.image(elfClass: 1)
        XCTAssertThrowsError(try ELFImage.parse(bytes)) { error in
            XCTAssertEqual(error as? ELFError, .unsupportedClass(1))
        }
    }

    func testRejectsTruncatedHeader() {
        let bytes = ELFFixture.image().prefix(32)
        XCTAssertThrowsError(try ELFImage.parse(Data(bytes))) { error in
            XCTAssertEqual(error as? ELFError, .truncated(needed: 64, available: 32))
        }
    }

    func testRejectsUnsupportedType() {
        let bytes = ELFFixture.image(type: 1)  // ET_REL
        XCTAssertThrowsError(try ELFImage.parse(bytes)) { error in
            XCTAssertEqual(error as? ELFError, .unsupportedType(1))
        }
    }

    /// Parses a real Ubuntu arm64 binary when CI provides one.
    ///
    /// The `tests` workflow installs `gcc-aarch64-linux-gnu`, compiles `testdata/hello.c`
    /// statically and points `UBUNTUPAD_TEST_BINARY` at it. When the variable is absent (a local
    /// run without a cross-compiler) the test is skipped, never silently passed.
    func testParsesRealStaticAArch64Binary() throws {
        guard let path = ProcessInfo.processInfo.environment["UBUNTUPAD_TEST_BINARY"] else {
            throw XCTSkip("UBUNTUPAD_TEST_BINARY is not set; skipping real-binary check")
        }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let image = try ELFImage.parse(bytes)

        XCTAssertTrue(image.header.isAArch64)
        XCTAssertEqual(image.header.type, ELFType.executable.rawValue, "static binary should be ET_EXEC")
        XCTAssertGreaterThan(image.header.entryPoint, 0)
        XCTAssertGreaterThanOrEqual(image.loadSegments.count, 2, "a static binary has several PT_LOADs")
        XCTAssertNil(image.interpreterPath(in: bytes), "a -static binary has no PT_INTERP")
        XCTAssertTrue(
            image.loadSegments.contains { $0.isExecutable },
            "static binary must have an executable segment")

        for segment in image.loadSegments {
            XCTAssertLessThanOrEqual(
                segment.fileSize, segment.memorySize, "p_filesz must not exceed p_memsz")
            if segment.alignment > 0 {
                XCTAssertEqual(
                    segment.virtualAddress % segment.alignment, segment.fileOffset % segment.alignment,
                    "ELF requires p_vaddr and p_offset to be congruent modulo the alignment")
            }
        }
    }
}
