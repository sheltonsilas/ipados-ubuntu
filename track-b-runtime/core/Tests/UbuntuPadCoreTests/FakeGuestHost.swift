import Foundation

@testable import UbuntuPadCore

/// A `GuestSyscallHost` backed by really allocated memory and nothing else.
///
/// It exists so the syscall *policy* can be tested exhaustively on any machine: the interesting
/// behaviour (bad file descriptor, unmapped buffer, absurd length, unknown syscall) is decided in
/// `UbuntuPadCore`, not by macOS. The real host used by `ubuntupad-run` implements the same protocol
/// with mmap and a signal handler, so anything proven here holds there too.
final class FakeGuestHost: GuestSyscallHost {
    /// Guest memory lives at 0x400000, like a non-PIE static binary's first segment.
    static let base: UInt64 = 0x40_0000
    static let size = 0x4_0000

    struct Mapping: Equatable {
        let address: UInt64
        let length: UInt64
        let protection: GuestProtection
    }

    struct ProtectionRequest: Equatable {
        let address: UInt64
        let length: UInt64
        let protection: GuestProtection
    }

    private let storage: UnsafeMutableRawPointer
    private(set) var console: [UInt8] = []
    private(set) var guestMappings: [Mapping] = []
    private(set) var protectionRequests: [ProtectionRequest] = []
    private(set) var unmapRequests: [(address: UInt64, length: UInt64)] = []

    var writableProgramBreak: UInt64 = 0
    private(set) var programBreak: UInt64 = 0

    init() {
        storage = UnsafeMutableRawPointer.allocate(byteCount: FakeGuestHost.size, alignment: 16384)
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: FakeGuestHost.size)
    }

    deinit {
        storage.deallocate()
    }

    /// Writes a string into guest memory and returns its guest address.
    @discardableResult
    func store(_ text: String, at offset: Int) -> UInt64 {
        let bytes = Array(text.utf8)
        storage.advanced(by: offset).copyMemory(from: bytes, byteCount: bytes.count)
        return FakeGuestHost.base + UInt64(offset)
    }

    func load(offset: Int, count: Int) -> [UInt8] {
        let raw = UnsafeRawBufferPointer(start: storage.advanced(by: offset), count: count)
        return [UInt8](raw)
    }

    func loadLE(offset: Int) -> UInt64 {
        let bytes = load(offset: offset, count: 8)
        var value: UInt64 = 0
        for index in 0..<8 { value |= UInt64(bytes[index]) << (8 * UInt64(index)) }
        return value
    }

    var consoleText: String { String(decoding: console, as: UTF8.self) }

    // MARK: - GuestSyscallHost

    func isMapped(address: UInt64, length: UInt64) -> Bool {
        guard address >= FakeGuestHost.base else { return false }
        let end = address.addingReportingOverflow(length)
        guard !end.overflow else { return false }
        return end.partialValue <= FakeGuestHost.base + UInt64(FakeGuestHost.size)
    }

    func guestBuffer(address: UInt64, length: Int) -> UnsafeRawBufferPointer? {
        guard isMapped(address: address, length: UInt64(length)) else { return nil }
        let offset = Int(address - FakeGuestHost.base)
        return UnsafeRawBufferPointer(start: storage.advanced(by: offset), count: length)
    }

    func readGuest(address: UInt64, length: Int) -> [UInt8]? {
        guestBuffer(address: address, length: length).map { [UInt8]($0) }
    }

    func writeGuest(address: UInt64, bytes: [UInt8]) -> Bool {
        guard isMapped(address: address, length: UInt64(bytes.count)) else { return false }
        let offset = Int(address - FakeGuestHost.base)
        storage.advanced(by: offset).copyMemory(from: bytes, byteCount: bytes.count)
        return true
    }

    func writeConsole(fd: Int32, buffer: UnsafeRawBufferPointer) -> Int {
        console.append(contentsOf: buffer)
        return buffer.count
    }

    func mapGuest(address: UInt64, length: UInt64, protection: GuestProtection) -> UInt64? {
        // The fake host hands out addresses from its own window, so a caller that ignores the
        // returned address (instead of using it) fails a test rather than silently working.
        let mapped = 0x70_0000 + UInt64(guestMappings.count) * 0x10000
        guestMappings.append(Mapping(address: mapped, length: length, protection: protection))
        return mapped
    }

    func unmapGuest(address: UInt64, length: UInt64) -> Bool {
        unmapRequests.append((address, length))
        return true
    }

    func protectGuest(address: UInt64, length: UInt64, protection: GuestProtection) -> Bool {
        protectionRequests.append(ProtectionRequest(address: address, length: length, protection: protection))
        return true
    }

    func setProgramBreak(_ address: UInt64) -> UInt64 {
        programBreak = min(address, writableProgramBreak)
        return programBreak
    }

    var processIdentifier: Int32 { 4242 }
    var parentProcessIdentifier: Int32 { 0 }
    var threadIdentifier: Int32 { 4242 }
    var userIdentifier: UInt32 { 0 }
    var groupIdentifier: UInt32 { 0 }
    var systemName: String { "Linux" }
    var nodeName: String { "ubuntupad" }
    var release: String { "6.6.0-ubuntupad" }
    var version: String { "#1 UbuntuPad" }
    var machine: String { "aarch64" }
    var domainName: String { "(none)" }
    var wallClockNanoseconds: UInt64 { 1_700_000_000 * 1_000_000_000 }
    var monotonicNanoseconds: UInt64 { 123_456_789 }

    func randomBytes(count: Int) -> [UInt8] {
        (0..<count).map { UInt8($0 & 0xff) }
    }
}
