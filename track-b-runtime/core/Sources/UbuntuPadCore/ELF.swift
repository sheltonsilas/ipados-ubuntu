import Foundation

/// Errors produced while reading an ELF image.
///
/// Every case is deliberately explicit: a failed load must be explainable in a bug report, never a
/// silent "unsupported binary".
public enum ELFError: Error, Equatable, CustomStringConvertible {
    case truncated(needed: Int, available: Int)
    case badMagic
    case unsupportedClass(UInt8)
    case unsupportedEndianness(UInt8)
    case unsupportedType(UInt16)
    case unsupportedMachine(UInt16)
    case malformedProgramHeaders

    public var description: String {
        switch self {
        case let .truncated(needed, available):
            return "ELF truncated: needed \(needed) bytes, only \(available) available"
        case .badMagic:
            return "not an ELF file (bad magic)"
        case let .unsupportedClass(value):
            return "unsupported ELF class \(value) (only 64-bit is supported)"
        case let .unsupportedEndianness(value):
            return "unsupported ELF data encoding \(value)"
        case let .unsupportedType(value):
            return "unsupported ELF type \(value) (only ET_EXEC=2 and ET_DYN=3 are supported)"
        case let .unsupportedMachine(value):
            return "unsupported ELF machine \(value) (only AArch64=183 is supported)"
        case .malformedProgramHeaders:
            return "malformed program header table"
        }
    }
}

public enum ELFType: UInt16 {
    case executable = 2   // ET_EXEC — static or fixed-address linked binary
    case sharedObject = 3 // ET_DYN — PIE executable or shared library
}

public enum ELFMachine: UInt16 {
    case aarch64 = 183
}

/// Segment types we care about in Phase 2.
public enum SegmentType: Equatable {
    case null
    case load
    case dynamic
    case interpreter
    case note
    case programHeaders
    case tls
    case gnuRelro
    case gnuStack
    case other(UInt32)

    init(rawValue: UInt32) {
        switch rawValue {
        case 0: self = .null
        case 1: self = .load
        case 2: self = .dynamic
        case 3: self = .interpreter
        case 4: self = .note
        case 6: self = .programHeaders
        case 7: self = .tls
        case 0x6474_e552: self = .gnuRelro
        case 0x6474_e551: self = .gnuStack
        default: self = .other(rawValue)
        }
    }
}

public struct ELFHeader: Equatable {
    public let type: UInt16
    public let machine: UInt16
    public let entryPoint: UInt64
    public let programHeaderOffset: UInt64
    public let programHeaderEntrySize: UInt16
    public let programHeaderCount: UInt16

    public var elfType: ELFType? { ELFType(rawValue: type) }
    public var isAArch64: Bool { machine == ELFMachine.aarch64.rawValue }
}

public struct ProgramHeader: Equatable {
    public let index: Int
    public let type: SegmentType
    public let flags: UInt32
    public let fileOffset: UInt64
    public let virtualAddress: UInt64
    public let physicalAddress: UInt64
    public let fileSize: UInt64
    public let memorySize: UInt64
    public let alignment: UInt64

    public var isExecutable: Bool { flags & 0x1 != 0 }
    public var isWritable: Bool { flags & 0x2 != 0 }
    public var isReadable: Bool { flags & 0x4 != 0 }
}

/// A parsed ELF64 little-endian AArch64 image.
///
/// Phase 2 grows this into the real loader; Phase 0 only needs header and program-header parsing,
/// which is what the tests below pin down against both a synthetic image and a real Ubuntu binary.
public struct ELFImage: Equatable {
    public static let headerSize = 64
    public static let programHeaderSize = 56

    public let header: ELFHeader
    public let programHeaders: [ProgramHeader]

    public var loadSegments: [ProgramHeader] { programHeaders.filter { $0.type == .load } }

    public init(header: ELFHeader, programHeaders: [ProgramHeader]) {
        self.header = header
        self.programHeaders = programHeaders
    }

    public static func parse(_ bytes: Data) throws -> ELFImage {
        // e_ident
        guard bytes.count >= headerSize else {
            throw ELFError.truncated(needed: headerSize, available: bytes.count)
        }
        guard bytes[0] == 0x7f, bytes[1] == 0x45, bytes[2] == 0x4c, bytes[3] == 0x46 else {
            throw ELFError.badMagic
        }
        let elfClass = bytes[4]
        guard elfClass == 2 else { throw ELFError.unsupportedClass(elfClass) }
        let encoding = bytes[5]
        // 1 = ELFDATA2LSB. Apple silicon and Ubuntu arm64 are both little-endian; big-endian
        // support would be dead weight.
        guard encoding == 1 else { throw ELFError.unsupportedEndianness(encoding) }

        let type: UInt16 = bytes.readUInt16(at: 16)
        let machine: UInt16 = bytes.readUInt16(at: 18)
        guard ELFType(rawValue: type) != nil else { throw ELFError.unsupportedType(type) }
        guard machine == ELFMachine.aarch64.rawValue else {
            throw ELFError.unsupportedMachine(machine)
        }

        let entry = bytes.readUInt64(at: 24)
        let phoff = bytes.readUInt64(at: 32)
        let phentsize = bytes.readUInt16(at: 54)
        let phnum = bytes.readUInt16(at: 56)

        guard phentsize >= UInt16(programHeaderSize), phnum > 0 else {
            throw ELFError.malformedProgramHeaders
        }
        let tableEnd = phoff + UInt64(phentsize) * UInt64(phnum)
        guard tableEnd <= UInt64(bytes.count) else {
            throw ELFError.truncated(needed: Int(tableEnd), available: bytes.count)
        }

        var headers: [ProgramHeader] = []
        headers.reserveCapacity(Int(phnum))
        for index in 0..<Int(phnum) {
            let base = Int(phoff) + index * Int(phentsize)
            let segmentType = bytes.readUInt32(at: base)
            let flags = bytes.readUInt32(at: base + 4)
            let fileOffset = bytes.readUInt64(at: base + 8)
            let vaddr = bytes.readUInt64(at: base + 16)
            let paddr = bytes.readUInt64(at: base + 24)
            let fileSize = bytes.readUInt64(at: base + 32)
            let memorySize = bytes.readUInt64(at: base + 40)
            let alignment = bytes.readUInt64(at: base + 48)

            // A segment that claims more file content than the file holds is a corrupt image; fail
            // loudly rather than mapping garbage.
            if fileSize > 0 {
                guard fileOffset + fileSize <= UInt64(bytes.count) else {
                    throw ELFError.truncated(
                        needed: Int(fileOffset + fileSize), available: bytes.count)
                }
            }

            headers.append(
                ProgramHeader(
                    index: index,
                    type: SegmentType(rawValue: segmentType),
                    flags: flags,
                    fileOffset: fileOffset,
                    virtualAddress: vaddr,
                    physicalAddress: paddr,
                    fileSize: fileSize,
                    memorySize: memorySize,
                    alignment: alignment
                ))
        }

        return ELFImage(
            header: ELFHeader(
                type: type,
                machine: machine,
                entryPoint: entry,
                programHeaderOffset: phoff,
                programHeaderEntrySize: phentsize,
                programHeaderCount: phnum
            ),
            programHeaders: headers
        )
    }

    /// The dynamic linker path from PT_INTERP, or `nil` for static binaries.
    public func interpreterPath(in bytes: Data) -> String? {
        guard
            let interp = programHeaders.first(where: { $0.type == .interpreter }),
            interp.fileSize > 0
        else { return nil }
        let start = Int(interp.fileOffset)
        let end = start + Int(interp.fileSize)
        guard end <= bytes.count else { return nil }
        let slice = bytes[start..<end]
        let trimmed = slice.prefix { $0 != 0 }
        return String(decoding: trimmed, as: UTF8.self)
    }
}

// MARK: - little-endian helpers

extension Data {
    fileprivate func readUInt16(at offset: Int) -> UInt16 {
        var value: UInt16 = 0
        withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            // Unaligned load: build it byte-wise so this works for any offset.
            value = UInt16(base.load(fromByteOffset: offset, as: UInt8.self))
                | (UInt16(base.load(fromByteOffset: offset + 1, as: UInt8.self)) << 8)
        }
        return value
    }

    fileprivate func readUInt32(at offset: Int) -> UInt32 {
        UInt32(readUInt16(at: offset)) | (UInt32(readUInt16(at: offset + 2)) << 16)
    }

    fileprivate func readUInt64(at offset: Int) -> UInt64 {
        UInt64(readUInt32(at: offset)) | (UInt64(readUInt32(at: offset + 4)) << 32)
    }
}
