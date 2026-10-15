import Foundation

/// The relationship between guest page size and host page size.
///
/// This exists because of a real, documented trap: an Ubuntu arm64 binary is linked for 4 KiB pages,
/// while Apple silicon (iPadOS and macOS on M-series) uses **16 KiB** pages. Anything that maps guest
/// segments, changes guest protections, or reports a page size to the guest has to bridge the two
/// without ever letting the guest learn the host's page size.
///
/// The model is deliberately "identity" — a guest virtual address is a host virtual address — so this
/// type does not translate addresses, only *alignments*. See DECISIONS.md (decision 0011).
public struct PageGeometry: Equatable, Sendable {
    public let guestPageSize: Int
    public let hostPageSize: Int

    /// Fails when the two sizes are not a power-of-two multiple of each other, which would make the
    /// rounding-outward rule below unsound.
    public init?(guestPageSize: Int = 4096, hostPageSize: Int) {
        guard
            guestPageSize > 0, hostPageSize > 0,
            hostPageSize % guestPageSize == 0,
            guestPageSize.nonzeroBitCount == 1, hostPageSize.nonzeroBitCount == 1
        else { return nil }
        self.guestPageSize = guestPageSize
        self.hostPageSize = hostPageSize
    }

    /// How many guest pages fit in one host page (1 on a 4 KiB host, 4 on Apple silicon).
    public var guestPagesPerHostPage: Int { hostPageSize / guestPageSize }

    public func roundUpToGuestPage(_ value: UInt64) -> UInt64 {
        roundUp(value, to: UInt64(guestPageSize))
    }

    public func roundDownToGuestPage(_ address: UInt64) -> UInt64 {
        address - (address % UInt64(guestPageSize))
    }

    public func roundDownToHostPage(_ address: UInt64) -> UInt64 {
        address - (address % UInt64(hostPageSize))
    }

    public func roundUpToHostPage(_ address: UInt64) -> UInt64 {
        roundUp(address, to: UInt64(hostPageSize))
    }

    /// The host-page-aligned range that must be touched in order to protect `guestRange`.
    ///
    /// Rounds *outward* on both ends, which is what Linux itself does (its `mprotect` widens a range
    /// to whole pages). Widening is the only sound choice: the host cannot protect less than one host
    /// page, and refusing the call would break guests that legitimately protect sub-page ranges.
    /// `widensBeyondRequest` on the returned change tells the caller when neighbouring guest data
    /// was affected, so the runtime can report it instead of hiding it.
    public func hostAlignedRange(covering guestRange: Range<UInt64>) -> Range<UInt64> {
        let lower = roundDownToHostPage(guestRange.lowerBound)
        let upper = roundUpToHostPage(guestRange.upperBound)
        return lower..<max(upper, lower + UInt64(hostPageSize))
    }

    /// Host bytes needed to hold `guestLength` bytes of guest memory.
    public func hostPageCount(coveringGuestLength guestLength: UInt64) -> Int {
        Int(roundUp(guestLength, to: UInt64(hostPageSize)) / UInt64(hostPageSize))
    }

    private func roundUp(_ value: UInt64, to alignment: UInt64) -> UInt64 {
        let remainder = value % alignment
        return remainder == 0 ? value : value + (alignment - remainder)
    }
}

/// Guest-visible access rights. Mirrors the ELF `p_flags` bits and Linux `PROT_*`.
public struct GuestProtection: OptionSet, Equatable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let read = GuestProtection(rawValue: 0x4)
    public static let write = GuestProtection(rawValue: 0x2)
    public static let execute = GuestProtection(rawValue: 0x1)

    public static let readWrite: GuestProtection = [.read, .write]
    public static let readExecute: GuestProtection = [.read, .execute]
    public static let all: GuestProtection = [.read, .write, .execute]
    public static let none: GuestProtection = []

    /// From ELF `p_flags` (PF_R=4, PF_W=2, PF_X=1) — the encoding used by program headers.
    public init(elfFlags: UInt32) {
        self.init(rawValue: elfFlags & 0x7)
    }

    /// From a guest `mmap`/`mprotect` argument, which uses Linux `PROT_*` (PROT_READ=1, PROT_WRITE=2,
    /// PROT_EXEC=4). Note that these are **not** the ELF flag bits: mixing the two silently swaps
    /// read and execute, so the conversion is a named function rather than a raw-value initialiser.
    /// Returns nil when the guest sets a bit the runtime does not understand (PROT_GROWSDOWN etc.).
    public static func fromLinuxProt(_ value: UInt32) -> GuestProtection? {
        guard value & ~0x7 == 0 else { return nil }
        var protection = GuestProtection.none
        if value & 0x1 != 0 { protection.insert(.read) }
        if value & 0x2 != 0 { protection.insert(.write) }
        if value & 0x4 != 0 { protection.insert(.execute) }
        return protection
    }

    /// The raw Linux `PROT_*` value, for reporting what the guest asked for.
    public var linuxProtValue: UInt32 {
        var value: UInt32 = 0
        if contains(.read) { value |= 0x1 }
        if contains(.write) { value |= 0x2 }
        if contains(.execute) { value |= 0x4 }
        return value
    }

    public var description: String {
        var text = ""
        text += contains(.read) ? "r" : "-"
        text += contains(.write) ? "w" : "-"
        text += contains(.execute) ? "x" : "-"
        return text
    }

    /// Linux `PROT_*` bits for the host `mmap`/`mprotect` calls (identical values on Darwin).
    public var hostProtBits: Int32 {
        var bits: Int32 = 0
        if contains(.read) { bits |= 0x1 }
        if contains(.write) { bits |= 0x2 }
        if contains(.execute) { bits |= 0x4 }
        return bits
    }
}

public enum GuestMemoryError: Error, Equatable, CustomStringConvertible {
    case invalidGeometry
    case regionOverlapsExisting(name: String, start: UInt64, end: UInt64)
    case zeroLengthRegion(name: String)
    case notMapped(address: UInt64)
    case rangeNotFullyMapped(start: UInt64, end: UInt64)

    public var description: String {
        switch self {
        case .invalidGeometry:
            return "host page size is not a multiple of the guest page size"
        case let .regionOverlapsExisting(name, start, end):
            return "region \(name) overlaps an existing region (0x\(String(start, radix: 16))-0x\(String(end, radix: 16)))"
        case let .zeroLengthRegion(name):
            return "region \(name) has zero length"
        case let .notMapped(address):
            return "no guest region contains 0x\(String(address, radix: 16))"
        case let .rangeNotFullyMapped(start, end):
            return "guest range 0x\(String(start, radix: 16))-0x\(String(end, radix: 16)) is not fully mapped"
        }
    }
}

/// One mapped area of guest memory.
public struct GuestRegion: Equatable, Sendable {
    public let name: String
    /// Guest-page-aligned range of guest virtual addresses.
    public let guestRange: Range<UInt64>
    public var protection: GuestProtection

    public var hostRange: Range<UInt64> { guestRange }
    public var size: UInt64 { guestRange.upperBound - guestRange.lowerBound }
    public var end: UInt64 { guestRange.upperBound }

    public func contains(_ address: UInt64) -> Bool { guestRange.contains(address) }
}

/// A host `mprotect` work item derived from a guest protection change.
public struct ProtectionChange: Equatable, Sendable {
    public let hostRange: Range<UInt64>
    public let protection: GuestProtection
    /// True when the host page rounding reached beyond the range the guest actually asked about.
    public let widensBeyondRequest: Bool
}

/// The guest's address space, as far as the runtime is concerned.
///
/// Scope: this type is bookkeeping, not a page table. It answers the three questions the runtime
/// actually asks — "is this address mapped?", "what protection does it have?", "which host pages must
/// I touch to change it?" — and it stays testable on Linux, where the guest page size and host page
/// size can be set independently of the machine running the tests.
public struct GuestAddressSpace: Equatable, Sendable {
    public let geometry: PageGeometry
    public private(set) var regions: [GuestRegion]

    public init(geometry: PageGeometry) {
        self.geometry = geometry
        self.regions = []
    }

    /// Maps a new region. The range is widened to whole guest pages first, then rejected if it
    /// overlaps anything already mapped — a silent overlap would let one guest subsystem corrupt
    /// another, which is exactly the class of bug that is impossible to debug later.
    @discardableResult
    public mutating func map(
        name: String,
        guestRange: Range<UInt64>,
        protection: GuestProtection
    ) throws -> GuestRegion {
        let start = geometry.roundDownToGuestPage(guestRange.lowerBound)
        let end = geometry.roundUpToGuestPage(guestRange.upperBound)
        guard end > start else { throw GuestMemoryError.zeroLengthRegion(name: name) }

        for existing in regions where existing.guestRange.lowerBound < end && start < existing.guestRange.upperBound {
            throw GuestMemoryError.regionOverlapsExisting(
                name: existing.name, start: existing.guestRange.lowerBound, end: existing.guestRange.upperBound)
        }

        let region = GuestRegion(name: name, guestRange: start..<end, protection: protection)
        regions.append(region)
        regions.sort { $0.guestRange.lowerBound < $1.guestRange.lowerBound }
        return region
    }

    public func region(containing address: UInt64) -> GuestRegion? {
        regions.first { $0.contains(address) }
    }

    /// Validates a guest pointer/length pair before the runtime dereferences it — this is the check
    /// that turns a guest bug into an `EFAULT` instead of a host crash.
    public func validateBuffer(address: UInt64, length: UInt64) -> Bool {
        guard length > 0 else { return true }
        let end = address.addingReportingOverflow(length)
        guard !end.overflow else { return false }
        for region in regions {
            // Requirement is only that the whole range is mapped; the protections themselves are
            // enforced by the host, so a read-only mapping is still "mapped" here.
            if address >= region.guestRange.lowerBound, end.partialValue <= region.guestRange.upperBound {
                return true
            }
        }
        return false
    }

    /// Host-page-aligned protection changes for a guest request.
    ///
    /// One entry per distinct host-page run, so the caller can skip `mprotect` calls that would
    /// change nothing (a guest that protects four 4 KiB pages inside one host page produces a single
    /// change on Apple silicon, and four on a 4 KiB Linux host).
    public func protectionChanges(
        for guestRange: Range<UInt64>,
        to protection: GuestProtection
    ) -> [ProtectionChange] {
        let hostAligned = geometry.hostAlignedRange(covering: guestRange)
        var changes: [ProtectionChange] = []
        var cursor = hostAligned.lowerBound
        while cursor < hostAligned.upperBound {
            let pageEnd = cursor + UInt64(geometry.hostPageSize)
            let widens = cursor < geometry.roundDownToGuestPage(guestRange.lowerBound)
                || pageEnd > geometry.roundUpToGuestPage(guestRange.upperBound)
            changes.append(
                ProtectionChange(
                    hostRange: cursor..<min(pageEnd, hostAligned.upperBound),
                    protection: protection,
                    widensBeyondRequest: widens))
            cursor = pageEnd
        }
        return changes
    }

    /// The protection plan for the whole address space, one entry per host page (adjacent pages with
    /// identical protection are merged).
    ///
    /// This is where the 16 KiB page size actually bites: two guest segments with different
    /// protections that share one host page cannot be protected independently, so the page gets the
    /// **union** of their rights and `mergedDistinctProtections` says so. Reporting the merge is the
    /// point — silently widening a read-only region to writable would be a security surprise, and
    /// silently narrowing it would break the guest.
    public func hostPageProtectionPlan() -> [ProtectionChange] {
        guard let lowest = regions.map({ geometry.roundDownToHostPage($0.guestRange.lowerBound) }).min(),
            let highest = regions.map({ geometry.roundUpToHostPage($0.guestRange.upperBound) }).max()
        else { return [] }

        var plan: [ProtectionChange] = []
        var cursor = lowest
        while cursor < highest {
            let pageEnd = cursor + UInt64(geometry.hostPageSize)
            var protection = GuestProtection.none
            var contributors: Set<UInt32> = []
            for region in regions
            where region.guestRange.lowerBound < pageEnd && cursor < region.guestRange.upperBound {
                protection.formUnion(region.protection)
                contributors.insert(region.protection.rawValue)
            }
            if !protection.isEmpty {
                plan.append(
                    ProtectionChange(
                        hostRange: cursor..<pageEnd,
                        protection: protection,
                        widensBeyondRequest: contributors.count > 1))
            }
            cursor = pageEnd
        }

        // Merge neighbouring pages that ended up with the same protection: fewer syscalls, and a plan
        // that is easier to read in a bug report.
        var merged: [ProtectionChange] = []
        for change in plan {
            if let last = merged.last, last.protection == change.protection,
                last.widensBeyondRequest == change.widensBeyondRequest,
                last.hostRange.upperBound == change.hostRange.lowerBound
            {
                merged[merged.count - 1] = ProtectionChange(
                    hostRange: last.hostRange.lowerBound..<change.hostRange.upperBound,
                    protection: last.protection,
                    widensBeyondRequest: last.widensBeyondRequest)
            } else {
                merged.append(change)
            }
        }
        return merged
    }

    /// Removes fully contained regions. A partial overlap is refused rather than rounded, because
    /// rounding a guest `munmap` would silently unmap its neighbour.
    public mutating func unmap(guestRange: Range<UInt64>) -> Bool {
        let overlapping = regions.filter {
            $0.guestRange.lowerBound < guestRange.upperBound && guestRange.lowerBound < $0.guestRange.upperBound
        }
        guard !overlapping.isEmpty else { return false }
        for region in overlapping where !(region.guestRange.lowerBound >= guestRange.lowerBound && region.guestRange.upperBound <= guestRange.upperBound) {
            return false
        }
        regions.removeAll { region in overlapping.contains(region) }
        return true
    }

    /// Total host bytes the guest has mapped, which is what memory-pressure reporting needs.
    public var mappedBytes: UInt64 {
        regions.reduce(0) { $0 + geometry.roundUpToHostPage($1.guestRange.upperBound) - geometry.roundDownToHostPage($1.guestRange.lowerBound) }
    }

    public func report() -> String {
        var lines = [
            "guest_page_size=\(geometry.guestPageSize) host_page_size=\(geometry.hostPageSize) guest_pages_per_host_page=\(geometry.guestPagesPerHostPage)"
        ]
        for region in regions {
            lines.append(
                "region \(region.name) 0x\(String(region.guestRange.lowerBound, radix: 16))-0x\(String(region.guestRange.upperBound, radix: 16)) \(region.protection.description) \(region.size) bytes"
            )
        }
        lines.append("mapped_host_bytes=\(mappedBytes)")
        return lines.joined(separator: "\n")
    }

    private func roundUpToHostPage(_ value: UInt64) -> UInt64 {
        geometry.roundUpToHostPage(value)
    }
}
