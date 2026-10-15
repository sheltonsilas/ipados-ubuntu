import Foundation
import XCTest

@testable import UbuntuPadCore

/// Reads a built initial stack exactly the way an AArch64 Linux program does at `_start`: SP points at
/// argc, then the argv pointers, a NULL, the envp pointers, a NULL, and the auxv key/value pairs.
///
/// Parsing the blob back is the point of these tests — it proves the *shape* without needing an
/// Apple-silicon runner to execute anything.
struct ParsedStack {
    let argc: Int
    let argv: [String]
    let envp: [String]
    let auxv: [UInt64: UInt64]

    init(layout: InitialStackLayout) {
        let base = layout.bytesBaseAddress
        let bytes = [UInt8](layout.bytes)

        func word(at address: UInt64) -> UInt64 {
            let offset = Int(address - base)
            var value: UInt64 = 0
            for index in 0..<8 { value |= UInt64(bytes[offset + index]) << (8 * UInt64(index)) }
            return value
        }

        func string(at address: UInt64) -> String {
            var offset = Int(address - base)
            var collected: [UInt8] = []
            while offset < bytes.count, bytes[offset] != 0 {
                collected.append(bytes[offset])
                offset += 1
            }
            return String(decoding: collected, as: UTF8.self)
        }

        var cursor = layout.stackPointer
        argc = Int(word(at: cursor))
        cursor += 8
        argv = (0..<argc).map { index -> String in
            defer { cursor += 8 }
            return string(at: word(at: cursor + UInt64(index * 8)))
        }
        cursor += UInt64(argc * 8)
        XCTAssertEqual(word(at: cursor), 0, "argv must be NULL-terminated")
        cursor += 8

        var environment: [String] = []
        while word(at: cursor) != 0 {
            environment.append(string(at: word(at: cursor)))
            cursor += 8
        }
        envp = environment
        cursor += 8

        var vector: [UInt64: UInt64] = [:]
        while true {
            let key = word(at: cursor)
            let value = word(at: cursor + 8)
            if key == 0 { break }
            vector[key] = value
            cursor += 16
        }
        auxv = vector
    }
}

final class InitialStackTests: XCTestCase {
    private let geometry4K = PageGeometry(guestPageSize: 4096, hostPageSize: 4096)!
    private let geometry16K = PageGeometry(guestPageSize: 4096, hostPageSize: 16384)!

    private func image() throws -> ELFImage {
        try ELFImage.parse(ELFFixture.image(entry: 0x4000_0500))
    }

    private func builder(
        geometry: PageGeometry,
        stackTop: UInt64 = 0x7fff_0000,
        arguments: [String] = ["/guest/hello", "--flag"],
        environment: [String] = ["PATH=/bin", "TERM=dumb"]
    ) throws -> InitialStackBuilder {
        try InitialStackBuilder(
            geometry: geometry,
            stackTop: stackTop,
            arguments: arguments,
            environment: environment,
            image: try image(),
            loadBias: 0,
            executablePath: arguments.first ?? "",
            hardwareCapabilities: 0x1f)
    }

    func testStackIsParseableByAGuest() throws {
        let layout = try builder(geometry: geometry4K).build()
        let parsed = ParsedStack(layout: layout)

        XCTAssertEqual(parsed.argc, 2)
        XCTAssertEqual(parsed.argv, ["/guest/hello", "--flag"])
        XCTAssertEqual(parsed.envp, ["PATH=/bin", "TERM=dumb"])
    }

    func testStackPointerIsSixteenByteAligned() throws {
        for geometry in [geometry4K, geometry16K] {
            let layout = try builder(geometry: geometry, arguments: ["/bin/x"]).build()
            XCTAssertEqual(layout.stackPointer % 16, 0, "AArch64 requires a 16-byte aligned SP")
        }
    }

    /// The 16 KiB problem, stated as a test: the guest is told 4 KiB no matter what the host uses.
    func testGuestIsToldFourKiBPageSizeOnA16KiBHost() throws {
        let layout = try builder(geometry: geometry16K).build()
        let parsed = ParsedStack(layout: layout)
        XCTAssertEqual(parsed.auxv[AuxiliaryVectorKey.pagesz.rawValue], 4096)
        XCTAssertEqual(layout.auxiliaryVector.count, 18)
    }

    func testAuxiliaryVectorDescribesTheImage() throws {
        let layout = try builder(geometry: geometry4K).build()
        let parsed = ParsedStack(layout: layout)

        // The fixture's program header table (file offset 64) is not inside its LOAD segment, so the
        // fallback applies. `testProgramHeaderAddressFollowsTheContainingSegment` covers the real case.
        XCTAssertEqual(parsed.auxv[AuxiliaryVectorKey.phdr.rawValue], 0 + 64)
        XCTAssertEqual(parsed.auxv[AuxiliaryVectorKey.phent.rawValue], 56)
        XCTAssertEqual(parsed.auxv[AuxiliaryVectorKey.phnum.rawValue], 1)
        XCTAssertEqual(parsed.auxv[AuxiliaryVectorKey.entry.rawValue], 0x4000_0500)
        XCTAssertEqual(parsed.auxv[AuxiliaryVectorKey.hwcap.rawValue], 0x1f)
        XCTAssertEqual(parsed.auxv[AuxiliaryVectorKey.clktck.rawValue], 100)
        XCTAssertEqual(parsed.auxv[AuxiliaryVectorKey.secure.rawValue], 0)
        XCTAssertEqual(parsed.auxv[AuxiliaryVectorKey.sysinfoEhdr.rawValue], 0, "no vDSO yet")
        XCTAssertEqual(parsed.auxv[AuxiliaryVectorKey.base.rawValue], 0, "static binary: no interpreter")
    }

    func testRandomBytesAreReachableThroughAtRandom() throws {
        let layout = try builder(geometry: geometry4K).build()
        let parsed = ParsedStack(layout: layout)
        let address = try XCTUnwrap(parsed.auxv[AuxiliaryVectorKey.random.rawValue])
        XCTAssertTrue(
            (layout.bytesBaseAddress..<layout.stackTop).contains(address),
            "AT_RANDOM must point inside the stack the runtime writes")

        let offset = Int(address - layout.bytesBaseAddress)
        XCTAssertEqual(layout.bytes.count - offset >= 16, true)
        let slice = [UInt8](layout.bytes[offset..<(offset + 16)])
        XCTAssertEqual(slice.count, 16)
        XCTAssertNotEqual(slice, Array(repeating: UInt8(0), count: 16), "AT_RANDOM must not be zeros")
    }

    func testExecfnPointsAtTheExecutablePath() throws {
        let layout = try builder(geometry: geometry4K).build()
        let parsed = ParsedStack(layout: layout)
        let address = try XCTUnwrap(parsed.auxv[AuxiliaryVectorKey.execfn.rawValue])
        var offset = Int(address - layout.bytesBaseAddress)
        var collected: [UInt8] = []
        while layout.bytes[offset] != 0 {
            collected.append(layout.bytes[offset])
            offset += 1
        }
        XCTAssertEqual(String(decoding: collected, as: UTF8.self), "/guest/hello")
    }

    func testEmptyArgumentListIsStillValid() throws {
        let layout = try InitialStackBuilder(
            geometry: geometry4K,
            stackTop: 0x7fff_0000,
            arguments: [],
            environment: [],
            image: try image(),
            loadBias: 0,
            executablePath: "/guest/x"
        ).build()
        let parsed = ParsedStack(layout: layout)
        XCTAssertEqual(parsed.argc, 0)
        XCTAssertTrue(parsed.argv.isEmpty)
        XCTAssertTrue(parsed.envp.isEmpty)
    }

    func testRejectsMisalignedStackTop() throws {
        XCTAssertThrowsError(try builder(geometry: geometry4K, stackTop: 0x7fff_0008)) { error in
            XCTAssertEqual(error as? InitialStackError, .stackTopMisaligned(address: 0x7fff_0008))
        }
    }

    func testRejectsShortRandomBytes() throws {
        XCTAssertThrowsError(try InitialStackBuilder(
            geometry: geometry4K,
            stackTop: 0x7fff_0000,
            arguments: ["/x"],
            environment: [],
            image: try image(),
            loadBias: 0,
            executablePath: "/x",
            randomBytes: Data([1, 2, 3])
        )) { error in
            XCTAssertEqual(error as? InitialStackError, .randomBytesTooShort(count: 3))
        }
    }

    /// The program header table is *inside* the first PT_LOAD of a real binary, so AT_PHDR must be the
    /// segment's virtual address plus the offset within it — not `e_phoff`.
    func testProgramHeaderAddressFollowsTheContainingSegment() throws {
        guard let path = ProcessInfo.processInfo.environment["UBUNTUPAD_TEST_BINARY"] else {
            throw XCTSkip("UBUNTUPAD_TEST_BINARY is not set")
        }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let image = try ELFImage.parse(bytes)
        let address = InitialStackBuilder.programHeaderAddress(image: image, loadBias: 0)

        let tableOffset = image.header.programHeaderOffset
        let owner = try XCTUnwrap(
            image.loadSegments.first {
                tableOffset >= $0.fileOffset && tableOffset < $0.fileOffset + $0.fileSize
            },
            "e_phoff must fall inside a PT_LOAD in a real static binary")
        XCTAssertEqual(address, owner.virtualAddress + (tableOffset - owner.fileOffset))
        XCTAssertGreaterThan(address, tableOffset, "AT_PHDR must be a mapped guest address, not a file offset")
    }

    /// Real binary, real auxiliary vector: CI sets UBUNTUPAD_TEST_BINARY to a cross-compiled static
    /// aarch64 program, so this asserts the builder against a genuine Ubuntu arm64 ELF.
    func testBuildsStackForTheRealTestBinary() throws {
        guard let path = ProcessInfo.processInfo.environment["UBUNTUPAD_TEST_BINARY"] else {
            throw XCTSkip("UBUNTUPAD_TEST_BINARY is not set")
        }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let image = try ELFImage.parse(bytes)
        let layout = try InitialStackBuilder(
            geometry: geometry16K,
            stackTop: 0x7ffe_0000,
            arguments: ["/guest/hello-arm64"],
            environment: ["PATH=/usr/bin"],
            image: image,
            loadBias: 0,
            executablePath: "/guest/hello-arm64"
        ).build()
        let parsed = ParsedStack(layout: layout)

        XCTAssertEqual(parsed.argc, 1)
        XCTAssertEqual(parsed.argv, ["/guest/hello-arm64"])
        XCTAssertEqual(parsed.auxv[AuxiliaryVectorKey.phnum.rawValue], UInt64(image.header.programHeaderCount))
        XCTAssertEqual(parsed.auxv[AuxiliaryVectorKey.phent.rawValue], UInt64(image.header.programHeaderEntrySize))
        XCTAssertEqual(parsed.auxv[AuxiliaryVectorKey.entry.rawValue], image.header.entryPoint)
        XCTAssertEqual(parsed.auxv[AuxiliaryVectorKey.pagesz.rawValue], 4096)
        XCTAssertEqual(
            parsed.auxv[AuxiliaryVectorKey.phdr.rawValue],
            InitialStackBuilder.programHeaderAddress(image: image, loadBias: 0))
    }
}
