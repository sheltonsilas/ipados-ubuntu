import Foundation

/// Where a guest image can actually be loaded, decided *before* anything is mapped.
///
/// This type exists because of a platform fact that cost real time to learn and is not negotiable:
/// **on Apple silicon every arm64 process reserves the low 4 GiB of its address space.** XNU's Mach-O
/// loader requires a 4 GiB `__PAGEZERO` (`LOAD_BADMACHO` otherwise), so no mapping — not even
/// `MAP_FIXED` — can be created there, and shrinking the reservation at link time produces a binary the
/// kernel kills before `main` runs. A Linux executable is normally linked at `0x400000`, which is inside
/// that region.
///
/// The consequence for Track B: an **ET_EXEC image below the floor cannot run on this platform at all**,
/// and an image that *is* loadable must either already live above the floor or be position-independent
/// so it can be placed at a chosen bias. That decision is made here, in the portable core, so it can be
/// tested exhaustively on a Linux runner where the floor does not exist.
///
/// See DECISIONS.md decision 0019 and `docs/RESEARCH/jit-and-entitlements-on-ios.md`.
public enum ImagePlacement: Equatable, Sendable {
    /// Map the image at exactly its link-time addresses (no bias).
    case identity
    /// Map the image at `bias + link-time address`; the bias is a multiple of the image's alignment.
    case biased(bias: UInt64)
    /// The image cannot be loaded on this host, and the message says why in the guest's own terms.
    case refused(reason: String)

    public var bias: UInt64 {
        switch self {
        case .identity: return 0
        case let .biased(bias): return bias
        case .refused: return 0
        }
    }

    public var isRefused: Bool {
        if case .refused = self { return true }
        return false
    }
}

public enum ImagePlacementError: Error, Equatable, CustomStringConvertible {
    case noLoadableSegments
    case notAArch64(UInt16)

    public var description: String {
        switch self {
        case .noLoadableSegments:
            return "the image has no PT_LOAD segments, so there is nothing to place"
        case let .notAArch64(machine):
            return "the image targets ELF machine \(machine), not AArch64"
        }
    }
}

public struct ImagePlacementPlanner {
    /// Where a position-independent image would like to live.
    ///
    /// A bias is only ever a *suggestion*: another mapping may already own the address, and a host that
    /// says no is answering by placing the image elsewhere — which the runtime must not accept, because
    /// a guest address is a host address here.
    ///
    /// 448 GiB is measured, not guessed. On `macos-15` (16 KiB pages, Xcode 16) that is where the kernel
    /// itself puts a hinted mapping: hints at 8 GiB were refused outright, and so were all twelve
    /// candidates between 64 GiB and 240 GiB, while it accepted 448 GiB and *offered* it as the answer to
    /// every refusal. Nothing here depends on that number being right — the runner retries and adapts
    /// (`biasCandidates`, and the address a refused hint returns) — but starting in the right band keeps
    /// the run report readable and saves twelve doomed syscalls.
    public static let defaultBiasTarget: UInt64 = 0x70_0000_0000  // 448 GiB, where macOS maps user memory

    /// How far apart successive attempts are placed (16 GiB), and how many there are. Each candidate
    /// keeps the image's alignment, so one of them succeeds unless the address space is genuinely full.
    public static let biasRetryStep: UInt64 = 0x4_0000_0000
    public static let biasAttemptCount = 12

    public init() {}

    /// Decides how `image` can be loaded on a host whose low address space is reserved up to
    /// `reservedLowRegion` (0 on a host with no such reservation, i.e. Linux).
    ///
    /// `biasTarget` is where a position-independent image would *like* to live. The returned bias keeps
    /// the image's own alignment requirements: a `PT_LOAD` with `p_align = 64 KiB` must be placed at a
    /// multiple of 64 KiB, which is why the target is rounded and why the caller must verify that the
    /// mapping really landed on it.
    public func plan(
        image: ELFImage,
        reservedLowRegion: UInt64,
        biasTarget: UInt64 = ImagePlacementPlanner.defaultBiasTarget
    ) throws -> ImagePlacement {
        guard image.header.machine == ELFMachine.aarch64.rawValue else {
            throw ImagePlacementError.notAArch64(image.header.machine)
        }
        let segments = image.loadSegments
        guard !segments.isEmpty else { throw ImagePlacementError.noLoadableSegments }

        let lowest = segments.map(\.virtualAddress).min() ?? 0
        let alignment = max(segments.map(\.alignment).max() ?? 1, 1)

        // A host with no reserved low region (Linux) can always use the link-time addresses, and that is
        // the only option for ET_EXEC there.
        if reservedLowRegion == 0 {
            return image.header.elfType == .executable
                ? .identity
                : .biased(bias: bias(lowest: lowest, atOrAbove: biasTarget, alignment: alignment))
        }

        if image.header.elfType == .executable {
            // ET_EXEC has no relocation information: it can only be mapped where it was linked.
            guard lowest >= reservedLowRegion else {
                return .refused(
                    reason: """
                        this is a fixed-address (ET_EXEC) executable linked at 0x\(String(lowest, radix: 16)), \
                        which is inside the \(reservedLowRegion / (1024 * 1024 * 1024)) GiB of low memory this \
                        platform reserves and never maps. There is no way to load it here — not even by \
                        forcing the address — because the reservation is a kernel rule, not an empty region \
                        of the address space. A position-independent (ET_DYN/PIE) build of the same program \
                        can be loaded at a bias instead, and that is what Ubuntu ships for arm64.
                        """)
            }
            return .identity
        }

        // ET_DYN: any bias works as long as it keeps the image's alignment, so put it above the floor.
        return .biased(
            bias: bias(lowest: lowest, atOrAbove: max(biasTarget, reservedLowRegion), alignment: alignment))
    }

    /// A bias that is a whole number of `alignment` steps **and** puts the image's lowest virtual
    /// address at or above `floor`.
    ///
    /// Being a multiple of the alignment is what keeps every segment's ELF alignment rule
    /// (`(bias + p_vaddr) % p_align == p_offset % p_align`) true after the shift, so the bias is derived
    /// from the image rather than rounded to a "nice" number. Public because the runner asks for a new
    /// bias when a host refuses one: the kernel's answer to a refused hint is a free address, and any
    /// address can be turned into a usable base only through this rule.
    public func bias(lowest: UInt64, atOrAbove floor: UInt64, alignment: UInt64) -> UInt64 {
        var gap = floor > lowest ? floor - lowest : 0
        guard alignment > 1 else { return gap }
        let remainder = gap % alignment
        if remainder != 0 { gap += alignment - remainder }
        return gap
    }

    /// The biases to try, in order, when a host will not honour the first one.
    ///
    /// Every candidate satisfies both rules above, so an image placed at any of them is correct; the
    /// list only exists because *where* a mapping lands is the host's decision when the requested
    /// address is taken. `step` is a multiple of 16 GiB so that the candidates stay aligned for every
    /// alignment an ELF image can declare (up to 64 KiB).
    public func biasCandidates(
        lowest: UInt64,
        atOrAbove floor: UInt64,
        alignment: UInt64,
        attempts: Int = ImagePlacementPlanner.biasAttemptCount,
        step: UInt64 = ImagePlacementPlanner.biasRetryStep
    ) -> [UInt64] {
        var candidates = [bias(lowest: lowest, atOrAbove: floor, alignment: alignment)]
        guard attempts > 1 else { return candidates }
        for attempt in 1..<attempts {
            let candidate = bias(
                lowest: lowest, atOrAbove: floor &+ UInt64(attempt) &* step, alignment: alignment)
            if !candidates.contains(candidate) { candidates.append(candidate) }
        }
        return candidates
    }
}
