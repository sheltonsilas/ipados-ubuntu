import Foundation
import UbuntuPadCore
import UbuntuPadHost

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The real `GuestSyscallHost`: guest memory is host memory, so reading a guest buffer is a pointer
/// cast after an address-space check.
///
/// The hot path (`guestBuffer`, `writeConsole`) deliberately allocates nothing, because these calls
/// arrive from inside a signal handler.
final class RealGuestHost: GuestSyscallHost {
    private var space: GuestAddressSpace
    private let heapStart: UInt64
    private let heapLimit: UInt64
    private var currentBreak: UInt64

    init(space: GuestAddressSpace, heapStart: UInt64, heapLimit: UInt64) {
        self.space = space
        self.heapStart = heapStart
        self.heapLimit = heapLimit
        self.currentBreak = heapStart
    }

    var addressSpace: GuestAddressSpace { space }

    func isMapped(address: UInt64, length: UInt64) -> Bool {
        space.validateBuffer(address: address, length: length)
    }

    func guestBuffer(address: UInt64, length: Int) -> UnsafeRawBufferPointer? {
        guard length >= 0, space.validateBuffer(address: address, length: UInt64(length)) else {
            return nil
        }
        guard let pointer = UnsafeRawPointer(bitPattern: UInt(address)) else { return nil }
        return UnsafeRawBufferPointer(start: pointer, count: length)
    }

    func readGuest(address: UInt64, length: Int) -> [UInt8]? {
        guestBuffer(address: address, length: length).map { [UInt8]($0) }
    }

    func writeGuest(address: UInt64, bytes: [UInt8]) -> Bool {
        guard space.validateBuffer(address: address, length: UInt64(bytes.count)) else { return false }
        guard let pointer = UnsafeMutableRawPointer(bitPattern: UInt(address)) else { return false }
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            pointer.copyMemory(from: base, byteCount: bytes.count)
        }
        return true
    }

    /// Straight to the host's file descriptor: no buffering, so the guest's output keeps its order
    /// relative to the runner's own markers on the same descriptor.
    func writeConsole(fd: Int32, buffer: UnsafeRawBufferPointer) -> Int {
        guard let base = buffer.baseAddress, buffer.count > 0 else { return 0 }
        return write(fd, base, buffer.count)
    }

    func mapGuest(address: UInt64, length: UInt64, protection: GuestProtection) -> UInt64? {
        let geometry = space.geometry
        let hostLength = Int(geometry.roundUpToHostPage(length))
        var landed: UInt64 = 0
        guard up_reserve(address, hostLength, Int32(UP_RESERVE_HINT), &landed) != nil else { return nil }
        // A guest mmap without a hint can land anywhere; with a hint, the guest expects that address.
        // A different address is still correct as long as the guest uses the return value, which Linux
        // requires it to do, so it is accepted but reported through the address space.
        if up_protect(landed, hostLength, protection.hostProtBits) != 0 {
            _ = up_release(landed, hostLength)
            return nil
        }
        do {
            try space.map(
                name: "guest-mmap", guestRange: landed..<(landed + length), protection: protection)
        } catch {
            _ = up_release(landed, hostLength)
            return nil
        }
        return landed
    }

    func unmapGuest(address: UInt64, length: UInt64) -> Bool {
        guard space.unmap(guestRange: address..<(address + length)) else { return false }
        return up_release(address, Int(length)) == 0
    }

    func protectGuest(address: UInt64, length: UInt64, protection: GuestProtection) -> Bool {
        for change in space.protectionChanges(for: address..<(address + length), to: protection) {
            if up_protect(
                change.hostRange.lowerBound, Int(change.hostRange.count),
                change.protection.hostProtBits) != 0
            {
                return false
            }
        }
        return true
    }

    func setProgramBreak(_ address: UInt64) -> UInt64 {
        guard address >= heapStart, address <= heapLimit else { return currentBreak }
        currentBreak = address
        return currentBreak
    }

    var programBreak: UInt64 { currentBreak }

    var processIdentifier: Int32 { Int32(getpid()) }
    var parentProcessIdentifier: Int32 { 0 }
    var threadIdentifier: Int32 { Int32(getpid()) }
    var userIdentifier: UInt32 { UInt32(getuid()) }
    var groupIdentifier: UInt32 { UInt32(getgid()) }
    var systemName: String { "Linux" }
    var nodeName: String { "ubuntupad" }
    var release: String { "6.6.0-ubuntupad" }
    var version: String { "#1 UbuntuPad (Track B)" }
    var machine: String { "aarch64" }
    var domainName: String { "(none)" }
    var wallClockNanoseconds: UInt64 { up_wall_clock_nanoseconds() }
    var monotonicNanoseconds: UInt64 { up_monotonic_nanoseconds() }

    func randomBytes(count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        bytes.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress { _ = up_random_bytes(base, count) }
        }
        return bytes
    }
}

/// One guest run: the dispatcher, the host, and the preallocated register file that the trap handler
/// fills in.
///
/// The register file is a stored property on purpose. Writing into an array that the struct owns
/// uniquely does not copy, so servicing a syscall allocates nothing on the syscall path — which is the
/// constraint imposed by running inside a signal handler. (The trace ring does allocate one small array
/// per recorded event; that is a documented Phase 2 compromise, see `SyscallTrace`.)
final class GuestSession {
    private let dispatcher: SyscallDispatcher
    private let host: RealGuestHost
    private var registers = GuestRegisterFile()

    init(dispatcher: SyscallDispatcher, host: RealGuestHost) {
        self.dispatcher = dispatcher
        self.host = host
    }

    /// Passed to `up_set_syscall_handler`. Non-capturing, so it is a valid C function pointer.
    static let syscallTrampoline:
        @convention(c) (UnsafeMutablePointer<up_registers_t>?, UnsafeMutableRawPointer?) -> Void = {
            registersPointer, context in
            guard let registersPointer, let context else { return }
            let session = Unmanaged<GuestSession>.fromOpaque(context).takeUnretainedValue()
            session.serviceSyscall(registers: registersPointer)
        }

    private func serviceSyscall(registers registersPointer: UnsafeMutablePointer<up_registers_t>) {
        for index in 0..<31 {
            registers.general[index] = up_guest_register(registersPointer, Int32(index))
        }
        let outcome = dispatcher.handle(registers: &registers, host: host)
        if case let .exit(status) = outcome {
            // Does not return: longjmps out of the signal handler back to `up_guest_run`.
            up_exit_guest(status)
        }
        up_set_guest_register(registersPointer, 0, registers[0])
    }
}
