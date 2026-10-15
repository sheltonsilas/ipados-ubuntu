import Foundation

/// `AT_*` keys of the Linux auxiliary vector. Values match the kernel's `include/uapi/linux/auxvec.h`
/// and are identical across architectures.
public enum AuxiliaryVectorKey: UInt64 {
    case null = 0
    case phdr = 3
    case phent = 4
    case phnum = 5
    case pagesz = 6
    case base = 7
    case flags = 8
    case entry = 9
    case uid = 11
    case euid = 12
    case gid = 13
    case egid = 14
    case hwcap = 16
    case clktck = 17
    case secure = 23
    case random = 25
    case hwcap2 = 26
    case execfn = 31
    case sysinfoEhdr = 33
}

public struct AuxiliaryVectorEntry: Equatable, Sendable {
    public let key: UInt64
    public let value: UInt64
    public init(key: UInt64, value: UInt64) {
        self.key = key
        self.value = value
    }
    public init(_ key: AuxiliaryVectorKey, _ value: UInt64) {
        self.init(key: key.rawValue, value: value)
    }
}

public enum InitialStackError: Error, Equatable, CustomStringConvertible {
    case stackTopMisaligned(address: UInt64)
    case randomBytesTooShort(count: Int)

    public var description: String {
        switch self {
        case let .stackTopMisaligned(address):
            return "stack top 0x\(String(address, radix: 16)) is not 16-byte aligned"
        case let .randomBytesTooShort(count):
            return "AT_RANDOM needs at least 16 bytes, got \(count)"
        }
    }
}

/// The layout of a freshly built guest stack, ready to be written into guest memory.
///
/// `bytes` must be placed so that its **end** lands exactly at `stackTop`; the guest is then entered
/// with SP = `stackPointer`. Returning bytes instead of writing them keeps this type pure, so the
/// whole structure can be parsed back — the way a guest would — by tests running on Linux.
public struct InitialStackLayout: Equatable, Sendable {
    public let bytes: Data
    public let stackPointer: UInt64
    public let stackTop: UInt64
    public let argc: Int32
    public let arguments: [String]
    public let environment: [String]
    public let auxiliaryVector: [AuxiliaryVectorEntry]

    /// Absolute guest address of `bytes[startIndex]`.
    public var bytesBaseAddress: UInt64 { stackTop - UInt64(bytes.count) }
}

/// Builds the Linux process initial stack: strings at the top, then auxv, envp, argv and argc.
///
/// This is the part of "starting a program" that a bare jump-to-entry forgets, and getting it wrong
/// produces programs that crash in ways that look like loader bugs. Building it in the portable core
/// means its shape is verified by tests on Linux even though execution only happens on an
/// Apple-silicon runner (see docs/RESEARCH on the platform limits).
public struct InitialStackBuilder {
    /// AArch64 must keep SP 16-byte aligned at all times; the kernel 16-byte aligns the vectors too.
    public static let stackAlignment: UInt64 = 16

    private let geometry: PageGeometry
    private let stackTop: UInt64
    private let arguments: [String]
    private let environment: [String]
    private let image: ELFImage
    private let loadBias: UInt64
    private let executablePath: String
    private let randomBytes: Data
    private let hardwareCapabilities: UInt64
    private let hardwareCapabilities2: UInt64
    private let userID: UInt32
    private let groupID: UInt32
    private let executableAddress: UInt64

    public init(
        geometry: PageGeometry,
        stackTop: UInt64,
        arguments: [String],
        environment: [String],
        image: ELFImage,
        loadBias: UInt64 = 0,
        executablePath: String,
        randomBytes: Data = Data((0..<16).map { UInt8(($0 &* 37 &+ 11) & 0xff) }),
        hardwareCapabilities: UInt64 = 0,
        hardwareCapabilities2: UInt64 = 0,
        userID: UInt32 = 0,
        groupID: UInt32 = 0,
        executableAddress: UInt64? = nil
    ) throws {
        guard geometry.guestPageSize > 0, geometry.hostPageSize > 0 else {
            throw GuestMemoryError.invalidGeometry
        }
        guard randomBytes.count >= 16 else {
            throw InitialStackError.randomBytesTooShort(count: randomBytes.count)
        }
        guard stackTop % InitialStackBuilder.stackAlignment == 0 else {
            throw InitialStackError.stackTopMisaligned(address: stackTop)
        }
        self.geometry = geometry
        self.stackTop = stackTop
        self.arguments = arguments
        self.environment = environment
        self.image = image
        self.loadBias = loadBias
        self.executablePath = executablePath
        self.randomBytes = randomBytes
        self.hardwareCapabilities = hardwareCapabilities
        self.hardwareCapabilities2 = hardwareCapabilities2
        self.userID = userID
        self.groupID = groupID
        self.executableAddress = executableAddress ?? image.header.entryPoint
    }

    public func build() throws -> InitialStackLayout {
        // --- Pass 1: place the strings at the top of the stack, argv first, then envp, then the path
        // the kernel reports as AT_EXECFN, and finally the 16 bytes AT_RANDOM points at.
        let strings = arguments + environment + [executablePath]
        var stringBytes = 0
        for string in strings { stringBytes += string.utf8.count + 1 }
        let randomOffsetInStringArea = stringBytes
        stringBytes += randomBytes.count

        let stringsBase = (stackTop - UInt64(stringBytes))
            - (stackTop - UInt64(stringBytes)) % UInt64(InitialStackBuilder.stackAlignment)

        var stringAddresses: [UInt64] = []
        var cursor = stringsBase
        for string in strings {
            stringAddresses.append(cursor)
            cursor += UInt64(string.utf8.count + 1)
        }
        let randomAddress = stringsBase + UInt64(randomOffsetInStringArea)
        let executablePathAddress = stringAddresses[stringAddresses.count - 1]

        // --- Pass 2: the vector area. auxv is key/value pairs terminated by an AT_NULL pair.
        let auxiliaryVector = buildAuxiliaryVector(
            randomAddress: randomAddress, executablePathAddress: executablePathAddress)
        let auxiliaryWordCount = (auxiliaryVector.count + 1) * 2
        let vectorBytes = (1 + (arguments.count + 1) + (environment.count + 1) + auxiliaryWordCount) * 8
        let stackPointer = (stringsBase - UInt64(vectorBytes))
            - (stringsBase - UInt64(vectorBytes)) % UInt64(InitialStackBuilder.stackAlignment)

        var bytes = Data(count: Int(stackTop - stackPointer))
        let base = stackPointer

        func write(_ value: UInt64, at address: UInt64) {
            let offset = Int(address - base)
            for index in 0..<8 {
                bytes[offset + index] = UInt8((value >> (8 * UInt64(index))) & 0xff)
            }
        }

        var word = stackPointer
        // argc — the value SP points at when the guest starts.
        write(UInt64(arguments.count), at: word)
        word += 8
        for address in stringAddresses[0..<arguments.count] {
            write(address, at: word)
            word += 8
        }
        write(0, at: word)  // argv terminator
        word += 8
        for index in environment.indices {
            write(stringAddresses[arguments.count + index], at: word)
            word += 8
        }
        write(0, at: word)  // envp terminator
        word += 8
        for entry in auxiliaryVector {
            write(entry.key, at: word)
            write(entry.value, at: word + 8)
            word += 16
        }
        write(0, at: word)  // AT_NULL
        write(0, at: word + 8)

        // The string area, copied in so the returned blob is one contiguous image. The gap between the
        // vectors and the strings stays zeroed padding.
        for (index, string) in strings.enumerated() {
            let offset = Int(stringAddresses[index] - base)
            let utf8 = Array(string.utf8)
            for (byteIndex, byte) in utf8.enumerated() {
                bytes[offset + byteIndex] = byte
            }
            bytes[offset + utf8.count] = 0
        }
        let randomOffset = Int(randomAddress - base)
        for (index, byte) in randomBytes.enumerated() {
            bytes[randomOffset + index] = byte
        }

        return InitialStackLayout(
            bytes: bytes,
            stackPointer: stackPointer,
            stackTop: stackTop,
            argc: Int32(arguments.count),
            arguments: arguments,
            environment: environment,
            auxiliaryVector: auxiliaryVector)
    }

    /// Where the program header table lives in the *running* guest, which is not the same as the file
    /// offset: the table sits inside the first `PT_LOAD`, at that segment's virtual address plus the
    /// distance from the segment's file offset. A static binary's first segment usually starts at file
    /// offset 0, so this matters: reporting `e_phoff` itself would hand the guest a wild pointer.
    ///
    /// When no segment claims the table (a deliberately synthetic image, or a genuinely invalid one),
    /// the file offset is used as the fallback and the caller can see it is inconsistent.
    public static func programHeaderAddress(image: ELFImage, loadBias: UInt64 = 0) -> UInt64 {
        let tableOffset = image.header.programHeaderOffset
        if let segment = image.loadSegments.first(where: {
            tableOffset >= $0.fileOffset && tableOffset < $0.fileOffset + $0.fileSize
        }) {
            return loadBias + segment.virtualAddress + (tableOffset - segment.fileOffset)
        }
        return loadBias + tableOffset
    }

    private func buildAuxiliaryVector(
        randomAddress: UInt64,
        executablePathAddress: UInt64
    ) -> [AuxiliaryVectorEntry] {
        [
            AuxiliaryVectorEntry(.phdr, InitialStackBuilder.programHeaderAddress(image: image, loadBias: loadBias)),
            AuxiliaryVectorEntry(.phent, UInt64(image.header.programHeaderEntrySize)),
            AuxiliaryVectorEntry(.phnum, UInt64(image.header.programHeaderCount)),
            AuxiliaryVectorEntry(.pagesz, UInt64(geometry.guestPageSize)),
            // AT_BASE is the interpreter's load address; a static binary has none.
            AuxiliaryVectorEntry(.base, 0),
            AuxiliaryVectorEntry(.flags, 0),
            AuxiliaryVectorEntry(.entry, executableAddress),
            AuxiliaryVectorEntry(.uid, UInt64(userID)),
            AuxiliaryVectorEntry(.euid, UInt64(userID)),
            AuxiliaryVectorEntry(.gid, UInt64(groupID)),
            AuxiliaryVectorEntry(.egid, UInt64(groupID)),
            AuxiliaryVectorEntry(.hwcap, hardwareCapabilities),
            AuxiliaryVectorEntry(.hwcap2, hardwareCapabilities2),
            AuxiliaryVectorEntry(.clktck, 100),
            AuxiliaryVectorEntry(.secure, 0),
            AuxiliaryVectorEntry(.random, randomAddress),
            AuxiliaryVectorEntry(.execfn, executablePathAddress),
            // No vDSO: we service syscalls ourselves, so there is no ELF header to announce.
            AuxiliaryVectorEntry(.sysinfoEhdr, 0),
        ]
    }
}
