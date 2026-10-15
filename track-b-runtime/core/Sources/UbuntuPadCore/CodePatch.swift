import Foundation

/// AArch64 instruction encodings Track B has to recognise by number.
///
/// Phase 2 needs exactly one: `SVC`. A Linux arm64 program reaches the kernel with `svc #0`
/// (`0xD4000001`). On Darwin that same instruction would be interpreted by XNU as a *Darwin* syscall
/// (with Darwin's own numbering, taken from x16), so the runtime must replace every one of them
/// before the guest executes. See DECISIONS.md (decision 0012) for why the replacement is a
/// breakpoint trap rather than a branch trampoline.
public enum AArch64Instruction {
    /// `svc #0` — the Linux syscall instruction.
    public static let svcZero: UInt32 = 0xD400_0001
    /// The pattern used to replace each `svc`: `brk #0x123`. Chosen to be unlikely in compiler output
    /// (compilers emit `brk #1` / `brk #0x1` for traps and `brk #0x3e8` in some runtimes) and easy to
    /// recognise in a handler that only has the program counter to work with.
    public static let breakpointSentinel: UInt32 = 0xD420_2460
    public static let breakpointSentinelImmediate: UInt16 = 0x123

    /// `svc` with any immediate. Linux only uses `#0`, but recognising the whole family means an
    /// unexpected immediate is patched (and reported) instead of being executed as a Darwin syscall.
    public static func isSupervisorCall(_ word: UInt32) -> Bool {
        word & 0xFFE0_001F == 0xD400_0001
    }

    public static func isBreakpoint(_ word: UInt32) -> Bool {
        word & 0xFFE0_001F == 0xD420_0000
    }

    /// `brk #imm16`, used to describe what a trap means in diagnostics.
    public static func breakpointImmediate(_ word: UInt32) -> UInt16 {
        UInt16((word >> 5) & 0xFFFF)
    }
}

/// One patched instruction site: where the `svc` was, and what it was.
public struct PatchSite: Equatable, Sendable {
    public let address: UInt64
    public let original: UInt32
    public init(address: UInt64, original: UInt32) {
        self.address = address
        self.original = original
    }
}

/// Where in the file offset → guest address space a scan happens.
public struct PatchPlan: Equatable, Sendable {
    public let sites: [PatchSite]
    /// The patched image, identical to the input except that each site now holds the sentinel.
    public let patchedImage: Data
    /// Executable ranges that were scanned, for the diagnostic report.
    public let scannedRanges: [Range<UInt64>]

    public init(sites: [PatchSite], patchedImage: Data, scannedRanges: [Range<UInt64>]) {
        self.sites = sites
        self.patchedImage = patchedImage
        self.scannedRanges = scannedRanges
    }

    public var patchedCount: Int { sites.count }
}

public enum PatchPlanError: Error, Equatable, CustomStringConvertible {
    case imageTooSmallForSegment(name: String)
    case noExecutableSegment

    public var description: String {
        switch self {
        case let .imageTooSmallForSegment(name):
            return "segment \(name) extends past the end of the image"
        case .noExecutableSegment:
            return "no executable PT_LOAD segment: there is no code to patch"
        }
    }
}

/// Finds and replaces every Linux syscall instruction in the image's executable segments.
///
/// Design notes that matter:
/// - Scanning is a 4-byte sweep of executable `PT_LOAD` content only. It is not a disassembler, so a
///   `svc #0` byte pattern sitting in *data* inside an executable segment would be patched too. Those
///   bytes are only reachable as code if the guest jumps into data, in which case it is already
///   broken; the count is reported so a surprising number is visible.
/// - Patching happens while the image is still writable, before it is made executable. That keeps the
///   runtime free of simultaneously writable+executable pages, which is what a non-jailbroken iOS app
///   is allowed to do (see docs/RESEARCH/jit-and-entitlements-on-ios.md).
public struct PatchPlanner {
    private let instructionSize = 4

    public init() {}

    public func plan(image: ELFImage, bytes: Data, imageBase: UInt64 = 0) throws -> PatchPlan {
        let executableSegments = image.loadSegments.filter { $0.isExecutable }
        guard !executableSegments.isEmpty else { throw PatchPlanError.noExecutableSegment }

        var patched = bytes
        var sites: [PatchSite] = []
        var scanned: [Range<UInt64>] = []

        for segment in executableSegments {
            let fileOffset = Int(segment.fileOffset)
            let end = fileOffset + Int(segment.fileSize)
            guard end <= patched.count else {
                throw PatchPlanError.imageTooSmallForSegment(
                    name: "PT_LOAD[\(segment.index)] @0x\(String(segment.virtualAddress, radix: 16))")
            }
            let virtualStart = imageBase + segment.virtualAddress
            scanned.append(virtualStart..<(virtualStart + segment.fileSize))

            var offset = fileOffset
            while offset + instructionSize <= end {
                let word = readLittleEndianUInt32(patched, at: offset)
                if AArch64Instruction.isSupervisorCall(word) {
                    sites.append(PatchSite(address: virtualStart + UInt64(offset - fileOffset), original: word))
                    writeLittleEndianUInt32(&patched, at: offset, value: AArch64Instruction.breakpointSentinel)
                }
                offset += instructionSize
            }
        }

        return PatchPlan(
            sites: sites.sorted { $0.address < $1.address },
            patchedImage: patched,
            scannedRanges: scanned)
    }

    private func readLittleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private func writeLittleEndianUInt32(_ data: inout Data, at offset: Int, value: UInt32) {
        data[offset] = UInt8(value & 0xff)
        data[offset + 1] = UInt8((value >> 8) & 0xff)
        data[offset + 2] = UInt8((value >> 16) & 0xff)
        data[offset + 3] = UInt8((value >> 24) & 0xff)
    }
}

extension PatchPlan {
    /// The site at an exact address, used by diagnostics and by the trap handler's bookkeeping. The
    /// handler itself decides whether a trap is a syscall by inspecting the instruction word live —
    /// it only has a program counter and a mapping, not a copy of the image.
    public func site(at address: UInt64) -> PatchSite? {
        sites.first { $0.address == address }
    }
}

/// What a trap handler concluded when a breakpoint arrived.
public enum TrapClassification: Equatable, Sendable {
    case syscallSite(PatchSite)
    case guestBreakpoint
}
