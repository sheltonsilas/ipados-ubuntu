import Foundation

/// Dynamic relocations, which are what make a position-independent guest loadable at a bias.
///
/// This is the second half of the answer to the low-memory problem in `ImagePlacement`: an image loaded
/// at a bias must have its absolute addresses rewritten, and for a dynamically *linked* binary those
/// addresses are described by the dynamic section (`PT_DYNAMIC` → `DT_RELA`). Ubuntu's arm64 packages
/// are position-independent by default, so this is the path real programs take, not an exotic one.
///
/// Scope: `R_AARCH64_RELATIVE` only — the relocation a PIE image uses for its own data pointers — plus
/// enough of the dynamic section to find the table. Symbol-based relocations belong with the dynamic
/// linker (Phase 4) and are reported rather than guessed at.
public enum RelocationType: UInt32 {
    case none = 0
    case relative = 1027  // R_AARCH64_RELATIVE
    case iRelative = 1032  // R_AARCH64_IRELATIVE — requires *running* a resolver: refused here
    case other = 0xFFFF_FFFF
}

public struct DynamicEntry: Equatable, Sendable {
    public let tag: Int64
    public let value: UInt64
    public init(tag: Int64, value: UInt64) {
        self.tag = tag
        self.value = value
    }
}

/// `DT_*` tags this runtime reads. Values are identical on every ELF64 architecture.
public enum DynamicTag {
    public static let rela: Int64 = 7
    public static let relaSize: Int64 = 8
    public static let relaEntrySize: Int64 = 9
    public static let relaCount: Int64 = 0x6ffffff9
    public static let flags1: Int64 = 0x6ffffffb
    public static let null: Int64 = 0
}

public struct DynamicSection: Equatable, Sendable {
    public let entries: [DynamicEntry]

    public init(entries: [DynamicEntry]) {
        self.entries = entries
    }

    public func value(of tag: Int64) -> UInt64? {
        entries.first { $0.tag == tag }?.value
    }

    /// Reads the dynamic section out of an already-parsed image. The table lives at
    /// `p_vaddr - loadBias` in the *file*, which is why the bias has to be known before it is read.
    public static func parse(image: ELFImage, bytes: Data, loadBias: UInt64 = 0) throws -> DynamicSection? {
        guard let segment = image.programHeaders.first(where: { $0.type == .dynamic }) else { return nil }

        // The segment's file offset is the authoritative source: the table is part of the image file.
        let entrySize = 16  // Elf64_Dyn: d_tag (8) + d_un (8)
        let start = Int(segment.fileOffset)
        let end = start + Int(segment.fileSize)
        guard end <= bytes.count, segment.fileSize % UInt64(entrySize) == 0 else {
            throw RelocationError.malformedDynamicSection(
                detail: "PT_DYNAMIC at file offset 0x\(String(start, radix: 16)) has \(segment.fileSize) bytes")
        }

        var entries: [DynamicEntry] = []
        var offset = start
        while offset + entrySize <= end {
            let tag = Int64(bitPattern: bytes.readUInt64(at: offset))
            let value = bytes.readUInt64(at: offset + 8)
            entries.append(DynamicEntry(tag: tag, value: value))
            offset += entrySize
            if tag == DynamicTag.null { break }
        }
        return DynamicSection(entries: entries)
    }
}

public struct RelativeRelocation: Equatable, Sendable {
    /// Offset from the image's load base (i.e. the `r_offset` in the table).
    public let offset: UInt64
    /// The value to write, already relative to the load base.
    public let addend: UInt64
    public init(offset: UInt64, addend: UInt64) {
        self.offset = offset
        self.addend = addend
    }
}

public enum RelocationError: Error, Equatable, CustomStringConvertible {
    case malformedDynamicSection(detail: String)
    case malformedRelocationTable(detail: String)
    case unsupportedRelocation(type: UInt32, offset: UInt64)
    case relocationOutsideImage(offset: UInt64)
    case relocationInZeroFilledMemory(offset: UInt64)

    public var description: String {
        switch self {
        case let .malformedDynamicSection(detail):
            return "malformed dynamic section: \(detail)"
        case let .malformedRelocationTable(detail):
            return "malformed relocation table: \(detail)"
        case let .unsupportedRelocation(type, offset):
            return
                "relocation type \(type) at 0x\(String(offset, radix: 16)) is not implemented (only R_AARCH64_RELATIVE is); this needs the dynamic linker"
        case let .relocationOutsideImage(offset):
            return "relocation at 0x\(String(offset, radix: 16)) points outside the loaded image"
        case let .relocationInZeroFilledMemory(offset):
            return
                "relocation at 0x\(String(offset, radix: 16)) targets zero-filled memory (.bss), which has no bytes in the file to patch; it must be applied after the mapping exists, and this runtime patches the image before mapping it"
        }
    }
}

/// Reads and applies the relative relocations of a position-independent image.
public struct RelocationTable {
    public private(set) var relativeRelocations: [RelativeRelocation] = []
    /// Relocations the runtime recognises but does not implement; a non-empty list means the image
    /// cannot be loaded correctly, and the loader refuses rather than running it half-relocated.
    public private(set) var unsupported: [(type: UInt32, offset: UInt64)] = []

    public init() {}

    public var relativeCount: Int { relativeRelocations.count }
    public var unsupportedCount: Int { unsupported.count }

    /// Parses `.rela.dyn` described by `dynamic`.
    ///
    /// Addends are kept relative to the load base: the runtime writes `bias + addend` at run time, which
    /// is what a self-relocating image would do with `base + addend`.
    public mutating func parse(
        dynamic: DynamicSection,
        image: ELFImage,
        bytes: Data
    ) throws {
        guard let tableAddress = dynamic.value(of: DynamicTag.rela) else { return }
        let tableSize = dynamic.value(of: DynamicTag.relaSize) ?? 0
        let entrySize = dynamic.value(of: DynamicTag.relaEntrySize) ?? 24
        guard tableSize > 0, entrySize >= 24 else { return }

        // `DT_RELA` is a *virtual* address; convert it to a file offset through the segment that
        // contains it, exactly as `AT_PHDR` is derived in the stack builder.
        guard let fileOffset = Self.fileOffset(forVirtualAddress: tableAddress, in: image) else {
            throw RelocationError.malformedRelocationTable(
                detail: "DT_RELA = 0x\(String(tableAddress, radix: 16)) is not inside any segment")
        }
        let entryCount = Int(tableSize / entrySize)
        for index in 0..<entryCount {
            let offset = Int(fileOffset) + index * Int(entrySize)
            guard offset + 24 <= bytes.count else {
                throw RelocationError.malformedRelocationTable(
                    detail: "entry \(index) of \(entryCount) is past the end of the image")
            }
            let target = bytes.readUInt64(at: offset)
            let info = bytes.readUInt64(at: offset + 8)
            let addend = bytes.readUInt64(at: offset + 16)
            let type = UInt32(truncatingIfNeeded: info & 0xffff_ffff)

            switch type {
            case RelocationType.relative.rawValue:
                relativeRelocations.append(RelativeRelocation(offset: target, addend: addend))
            case RelocationType.none.rawValue:
                continue
            default:
                unsupported.append((type: type, offset: target))
            }
        }
    }

    /// Applies the relative relocations to an image that is about to be mapped at `bias`.
    ///
    /// Writing `bias + addend` at `bias + r_offset` is exactly what a self-relocating PIE does for
    /// `R_AARCH64_RELATIVE`; the runtime does it because the guest's own startup code (if it has any)
    /// would otherwise have to, and a freestanding program has none.
    public func apply(to bytes: inout Data, image: ELFImage, bias: UInt64) throws -> Int {
        var applied = 0
        for relocation in relativeRelocations {
            // `r_offset` is a virtual address, and a segment's file offset is not the same number — in
            // a position-independent image the two often coincide, which is exactly the kind of
            // coincidence that hides a bug until some other layout appears. Convert explicitly.
            guard let fileOffset = Self.fileOffset(forVirtualAddress: relocation.offset, in: image) else {
                throw RelocationError.relocationOutsideImage(offset: relocation.offset)
            }
            guard Self.isFileBacked(virtualAddress: relocation.offset, in: image) else {
                throw RelocationError.relocationInZeroFilledMemory(offset: relocation.offset)
            }
            let start = Int(fileOffset)
            guard start + 8 <= bytes.count else {
                throw RelocationError.relocationOutsideImage(offset: relocation.offset)
            }
            let value = bias &+ relocation.addend
            for index in 0..<8 {
                bytes[start + index] = UInt8((value >> (8 * UInt64(index))) & 0xff)
            }
            applied += 1
        }
        return applied
    }

    /// True when the virtual address has bytes in the image file, i.e. it is not inside a segment's
    /// zero-filled tail (`.bss`).
    public static func isFileBacked(virtualAddress address: UInt64, in image: ELFImage) -> Bool {
        for segment in image.loadSegments
        where address >= segment.virtualAddress && address < segment.virtualAddress + segment.memorySize {
            return address - segment.virtualAddress < segment.fileSize
        }
        return false
    }

    /// The file offset of a virtual address, via the segment that contains it.
    public static func fileOffset(forVirtualAddress address: UInt64, in image: ELFImage) -> UInt64? {
        for segment in image.loadSegments
        where address >= segment.virtualAddress && address < segment.virtualAddress + segment.memorySize {
            return segment.fileOffset + (address - segment.virtualAddress)
        }
        return nil
    }
}

extension Data {
    /// Little-endian 64-bit read, also used by the relocation parser.
    func readUInt64(at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            for index in 0..<8 {
                value |= UInt64(base.load(fromByteOffset: offset + index, as: UInt8.self)) << (8 * UInt64(index))
            }
        }
        return value
    }
}
