import Foundation

/// The guest's general-purpose register file.
///
/// This is a plain value type on purpose: the trap handler fills it from the host's signal context,
/// hands it to the dispatcher, and writes the result back. Keeping it independent of `ucontext_t`
/// is what allows the syscall policy to be tested on Linux with no signals involved.
public struct GuestRegisterFile: Equatable, Sendable {
    /// x0...x30, in order.
    public var general: [UInt64]
    public var stackPointer: UInt64
    public var programCounter: UInt64

    public init(
        general: [UInt64] = Array(repeating: 0, count: 31),
        stackPointer: UInt64 = 0,
        programCounter: UInt64 = 0
    ) {
        precondition(general.count == 31, "the AArch64 register file has exactly x0...x30")
        self.general = general
        self.stackPointer = stackPointer
        self.programCounter = programCounter
    }

    public subscript(index: Int) -> UInt64 {
        get { general[index] }
        set { general[index] = newValue }
    }

    /// Linux aarch64 passes the syscall number in x8 and arguments in x0...x5.
    public var syscallNumber: Int64 { Int64(bitPattern: general[8]) }

    public func syscallArgument(_ index: Int) -> UInt64 {
        precondition((0..<6).contains(index), "a Linux syscall has at most six arguments")
        return general[index]
    }

    public mutating func setSyscallResult(_ value: Int64) {
        general[0] = UInt64(bitPattern: value)
    }
}

/// The Linux `errno` values Phase 2 can produce. Only the ones the runtime actually returns are
/// listed; a missing case would be a compile error rather than a guessed number.
public enum LinuxErrno: Int32, Sendable, CaseIterable {
    case EPERM = 1
    case ENOENT = 2
    case EINTR = 4
    case EIO = 5
    case EBADF = 9
    case EAGAIN = 11
    case ENOMEM = 12
    case EACCES = 13
    case EFAULT = 14
    case EEXIST = 17
    case EISDIR = 21
    case EINVAL = 22
    case EMFILE = 24
    case ENOTTY = 25
    case ENOSPC = 28
    case ESPIPE = 29
    case EPIPE = 32
    case ERANGE = 34
    case ENAMETOOLONG = 36
    case ENOSYS = 38
    case ENOTEMPTY = 39
    case ENOTSOCK = 88
    case EAFNOSUPPORT = 97
    case EADDRINUSE = 98
    case ENETUNREACH = 101
    case ENOTCONN = 107
    case ETIMEDOUT = 110
    case ECONNREFUSED = 111
    case EOVERFLOW = 75
    case ENOTSUP = 95

    public var name: String {
        switch self {
        case .EPERM: return "EPERM"
        case .ENOENT: return "ENOENT"
        case .EINTR: return "EINTR"
        case .EIO: return "EIO"
        case .EBADF: return "EBADF"
        case .EAGAIN: return "EAGAIN"
        case .ENOMEM: return "ENOMEM"
        case .EACCES: return "EACCES"
        case .EFAULT: return "EFAULT"
        case .EEXIST: return "EEXIST"
        case .EISDIR: return "EISDIR"
        case .EINVAL: return "EINVAL"
        case .EMFILE: return "EMFILE"
        case .ENOTTY: return "ENOTTY"
        case .ENOSPC: return "ENOSPC"
        case .ESPIPE: return "ESPIPE"
        case .EPIPE: return "EPIPE"
        case .ERANGE: return "ERANGE"
        case .ENAMETOOLONG: return "ENAMETOOLONG"
        case .ENOSYS: return "ENOSYS"
        case .ENOTEMPTY: return "ENOTEMPTY"
        case .ENOTSOCK: return "ENOTSOCK"
        case .EAFNOSUPPORT: return "EAFNOSUPPORT"
        case .EADDRINUSE: return "EADDRINUSE"
        case .ENETUNREACH: return "ENETUNREACH"
        case .ENOTCONN: return "ENOTCONN"
        case .ETIMEDOUT: return "ETIMEDOUT"
        case .ECONNREFUSED: return "ECONNREFUSED"
        case .EOVERFLOW: return "EOVERFLOW"
        case .ENOTSUP: return "ENOTSUP"
        }
    }
}

/// What a syscall service decided.
public enum SyscallOutcome: Equatable, Sendable {
    /// Success with a non-negative return value.
    case result(Int64)
    /// Failure with a Linux errno; the guest sees `-errno` in x0.
    case failure(LinuxErrno)
    /// The guest program is finishing. Handled by the host, not returned to the guest.
    case exit(status: Int32)

    /// The value the guest would read from x0. Exit is signalled to the host separately, so this
    /// returns the exit status only for tracing purposes.
    public var encodedValue: Int64 {
        switch self {
        case let .result(value): return value
        case let .failure(errno): return -Int64(errno.rawValue)
        case let .exit(status): return Int64(status)
        }
    }

    public var isExit: Bool {
        if case .exit = self { return true }
        return false
    }
}

/// One decoded syscall: which one, and its six raw arguments.
public struct SyscallRequest: Equatable, Sendable {
    public static let argumentCount = 6
    public let rawNumber: Int64
    public let arguments: [UInt64]

    public init(rawNumber: Int64, arguments: [UInt64]) {
        precondition(arguments.count == SyscallRequest.argumentCount)
        self.rawNumber = rawNumber
        self.arguments = arguments
    }

    public init(registers: GuestRegisterFile) {
        self.init(
            rawNumber: registers.syscallNumber,
            arguments: (0..<SyscallRequest.argumentCount).map { registers.syscallArgument($0) })
    }

    public var number: Int32 { Int32(truncatingIfNeeded: rawNumber) }
    public func argument(_ index: Int) -> UInt64 { arguments[index] }
    public func signedArgument(_ index: Int) -> Int64 { Int64(bitPattern: arguments[index]) }

    /// "write" when the number is in the curated table, otherwise "syscall N".
    public var name: String { SyscallTable.name(for: number) ?? "syscall \(rawNumber)" }
}

/// A fixed-capacity trace of syscall activity.
///
/// Capacity is fixed and everything is preallocated because the trace is written from inside a signal
/// handler, where allocating is not async-signal-safe. That constraint drives the whole design: counts
/// in a flat array indexed by syscall number, and events in a ring buffer.
public final class SyscallTrace {
    public static let maximumTrackedNumber = 512
    public static let ringCapacity = 64

    public struct Event: Equatable, Sendable {
        public let sequence: Int
        public let number: Int64
        public let name: String
        public let arguments: [UInt64]
        public let outcome: String
    }

    private var counts: [Int32]
    private var ring: [Event?]
    private var ringCursor = 0
    public private(set) var total = 0
    public private(set) var unknownNumbers: Set<Int32> = []

    public init() {
        counts = Array(repeating: 0, count: SyscallTrace.maximumTrackedNumber)
        ring = Array(repeating: nil, count: SyscallTrace.ringCapacity)
    }

    public func count(of number: Int32) -> Int {
        guard number >= 0, Int(number) < SyscallTrace.maximumTrackedNumber else { return 0 }
        return Int(counts[Int(number)])
    }

    public func record(_ request: SyscallRequest, outcome: SyscallOutcome) {
        total += 1
        if request.rawNumber >= 0, Int(request.rawNumber) < SyscallTrace.maximumTrackedNumber {
            counts[Int(request.rawNumber)] += 1
        }
        if !outcome.isExit, case .failure(.ENOSYS) = outcome {
            unknownNumbers.insert(request.number)
        }
        let event = Event(
            sequence: total,
            number: request.rawNumber,
            name: request.name,
            arguments: request.arguments,
            outcome: describe(outcome))
        ring[ringCursor] = event
        ringCursor = (ringCursor + 1) % SyscallTrace.ringCapacity
    }

    /// Events in chronological order, oldest first.
    public var events: [Event] {
        ring.compactMap { $0 }.sorted { $0.sequence < $1.sequence }
    }

    public func summary() -> String {
        var lines = ["syscall_total=\(total)"]
        let interesting = counts.enumerated()
            .filter { $0.element > 0 }
            .map { (number: Int32($0.offset), count: Int($0.element)) }
            .sorted { $0.count > $1.count }
        for entry in interesting {
            let name = SyscallTable.name(for: entry.number) ?? "syscall \(entry.number)"
            lines.append("syscall_count \(name) (\(entry.number)) = \(entry.count)")
        }
        if !unknownNumbers.isEmpty {
            let names = unknownNumbers.sorted().map { number -> String in
                "\(SyscallTable.name(for: number) ?? "syscall \(number)") (\(number))"
            }
            lines.append("unimplemented=\(names.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    private func describe(_ outcome: SyscallOutcome) -> String {
        switch outcome {
        case let .result(value): return "= \(value)"
        case let .failure(errno): return "= -\(errno.name)"
        case let .exit(status): return "exit(\(status))"
        }
    }
}

/// Everything the syscall services need from the outside world.
///
/// The split matters: `UbuntuPadCore` owns the *policy* (what each syscall means, what it returns on a
/// bad argument) and the platform layer owns the *mechanism* (mapping memory, writing to fd 1, reading
/// the clock). That is why the dispatcher can be tested exhaustively on Linux while the memory and
/// trap machinery only exists on Apple silicon.
public protocol GuestSyscallHost: AnyObject {
    /// Whether `address..<address+length` is inside one mapped guest region.
    func isMapped(address: UInt64, length: UInt64) -> Bool
    /// A borrowed view of guest memory. No copy: this is the path `write` takes on the hot path.
    func guestBuffer(address: UInt64, length: Int) -> UnsafeRawBufferPointer?
    func readGuest(address: UInt64, length: Int) -> [UInt8]?
    func writeGuest(address: UInt64, bytes: [UInt8]) -> Bool
    func writeConsole(fd: Int32, buffer: UnsafeRawBufferPointer) -> Int
    /// Reserves host memory for the guest and returns the address the guest may use, or nil.
    func mapGuest(address: UInt64, length: UInt64, protection: GuestProtection) -> UInt64?
    func unmapGuest(address: UInt64, length: UInt64) -> Bool
    func protectGuest(address: UInt64, length: UInt64, protection: GuestProtection) -> Bool
    /// Sets the program break; returns the break actually in effect (Linux returns the new one).
    func setProgramBreak(_ address: UInt64) -> UInt64
    var programBreak: UInt64 { get }
    var processIdentifier: Int32 { get }
    var parentProcessIdentifier: Int32 { get }
    var threadIdentifier: Int32 { get }
    var userIdentifier: UInt32 { get }
    var groupIdentifier: UInt32 { get }
    var systemName: String { get }
    var nodeName: String { get }
    var release: String { get }
    var version: String { get }
    var machine: String { get }
    var domainName: String { get }
    var wallClockNanoseconds: UInt64 { get }
    var monotonicNanoseconds: UInt64 { get }
    func randomBytes(count: Int) -> [UInt8]
}

/// Routes a syscall number to its service.
///
/// Deliberately a normal class rather than a switch statement: the set of implemented syscalls is
/// expected to grow every session, and the tests assert that anything unimplemented fails with ENOSYS
/// and is *recorded* — so the next session's work list is produced by running real programs, not by
/// guessing.
public final class SyscallDispatcher {
    public typealias Handler = (SyscallRequest, GuestSyscallHost) -> SyscallOutcome

    private var handlers: [Int32: Handler] = [:]
    public private(set) var trace = SyscallTrace()
    /// Set by an `exit`/`exit_group` service; the host reads it after leaving the guest.
    public private(set) var exitStatus: Int32?

    public init() {}

    public func register(_ number: Int32, _ handler: @escaping Handler) {
        handlers[number] = handler
    }

    /// Every syscall number with a service, sorted. Used by tests and diagnostics.
    public var implementedNumbers: [Int32] { handlers.keys.sorted() }

    public func isImplemented(_ number: Int32) -> Bool { handlers[number] != nil }

    @discardableResult
    public func dispatch(_ request: SyscallRequest, host: GuestSyscallHost) -> SyscallOutcome {
        let outcome: SyscallOutcome
        if let handler = handlers[request.number] {
            outcome = handler(request, host)
        } else {
            outcome = .failure(.ENOSYS)
        }
        trace.record(request, outcome: outcome)
        if case let .exit(status) = outcome { exitStatus = status }
        return outcome
    }

    /// Convenience for the trap handler: decode from registers, dispatch, write the result back.
    @discardableResult
    public func handle(registers: inout GuestRegisterFile, host: GuestSyscallHost) -> SyscallOutcome {
        let outcome = dispatch(SyscallRequest(registers: registers), host: host)
        registers.setSyscallResult(outcome.encodedValue)
        return outcome
    }
}

// MARK: - the Phase 2 syscall set

extension SyscallDispatcher {
    /// The syscalls a *static, freestanding* arm64 Linux program needs, plus the few a libc's startup
    /// reaches for. Everything else answers ENOSYS and shows up in the trace.
    public static func standardPhase2() -> SyscallDispatcher {
        let dispatcher = SyscallDispatcher()

        dispatcher.register(SyscallNumber.write) { request, host in
            let fd = Int32(truncatingIfNeeded: request.argument(0))
            guard fd == 1 || fd == 2 else { return .failure(.EBADF) }
            let address = request.argument(1)
            // Linux caps a single read/write at 1 GiB (MAX_RW_COUNT); refusing an absurd count keeps
            // the conversion to Int from silently wrapping.
            let count64 = request.argument(2)
            guard count64 <= 1 << 30 else { return .failure(.EINVAL) }
            let count = Int(count64)
            if count == 0 { return .result(0) }
            guard let buffer = host.guestBuffer(address: address, length: count) else {
                return .failure(.EFAULT)
            }
            let written = host.writeConsole(fd: fd, buffer: buffer)
            return written < 0 ? .failure(.EIO) : .result(Int64(written))
        }

        dispatcher.register(SyscallNumber.read) { request, host in
            let fd = Int32(truncatingIfNeeded: request.argument(0))
            guard fd == 0 else { return .failure(.EBADF) }
            let address = request.argument(1)
            let count64 = request.argument(2)
            guard count64 <= 1 << 30 else { return .failure(.EINVAL) }
            guard count64 > 0 else { return .result(0) }
            guard host.isMapped(address: address, length: count64) else { return .failure(.EFAULT) }
            // Phase 2 has no terminal yet: end of file is the honest answer, and it keeps a program
            // that reads stdin from blocking forever.
            return .result(0)
        }

        dispatcher.register(SyscallNumber.exit) { request, _ in
            .exit(status: Int32(truncatingIfNeeded: request.argument(0)))
        }
        dispatcher.register(SyscallNumber.exitGroup) { request, _ in
            .exit(status: Int32(truncatingIfNeeded: request.argument(0)))
        }

        dispatcher.register(SyscallNumber.brk) { request, host in
            .result(host.setProgramBreak(request.argument(0)))
        }

        dispatcher.register(SyscallNumber.mmap) { request, host in
            let address = request.argument(0)
            let length = request.argument(1)
            guard let protection = GuestProtection.fromLinuxProt(UInt32(truncatingIfNeeded: request.argument(2)))
            else { return .failure(.EINVAL) }
            let flags = request.argument(3)
            // MAP_PRIVATE | MAP_ANONYMOUS is what a program's heap and static-BSS growth use. Without a
            // filesystem there is no file-backed mapping, so anything else is refused loudly.
            let mapPrivate: UInt64 = 0x02
            let mapAnonymous: UInt64 = 0x20
            let allowed: UInt64 = mapPrivate | mapAnonymous
            guard flags & mapPrivate != 0, flags & mapAnonymous != 0, flags & ~allowed == 0 else {
                return .failure(.EINVAL)
            }
            guard length > 0 else { return .failure(.EINVAL) }
            guard let mapped = host.mapGuest(address: address, length: length, protection: protection) else {
                return .failure(.ENOMEM)
            }
            return .result(Int64(bitPattern: mapped))
        }

        dispatcher.register(SyscallNumber.munmap) { request, host in
            let address = request.argument(0)
            let length = request.argument(1)
            // Alignment and range checking are the host's job: it is the only side that knows which
            // pages are actually mapped.
            guard length > 0 else { return .failure(.EINVAL) }
            return host.unmapGuest(address: address, length: length) ? .result(0) : .failure(.EINVAL)
        }

        dispatcher.register(SyscallNumber.mprotect) { request, host in
            let address = request.argument(0)
            let length = request.argument(1)
            guard let protection = GuestProtection.fromLinuxProt(UInt32(truncatingIfNeeded: request.argument(2)))
            else { return .failure(.EINVAL) }
            guard length > 0 else { return .failure(.EINVAL) }
            guard host.isMapped(address: address, length: length) else { return .failure(.ENOMEM) }
            return host.protectGuest(address: address, length: length, protection: protection)
                ? .result(0) : .failure(.EACCES)
        }

        // Advisory only: nothing to do, and saying so is better than ENOSYS for a program that asks.
        dispatcher.register(SyscallNumber.madvise) { _, _ in .result(0) }

        dispatcher.register(SyscallNumber.getpid) { _, host in .result(Int64(host.processIdentifier)) }
        dispatcher.register(SyscallNumber.getppid) { _, host in
            .result(Int64(host.parentProcessIdentifier))
        }
        dispatcher.register(SyscallNumber.gettid) { _, host in .result(Int64(host.threadIdentifier)) }
        dispatcher.register(SyscallNumber.getuid) { _, host in .result(Int64(host.userIdentifier)) }
        dispatcher.register(SyscallNumber.geteuid) { _, host in .result(Int64(host.userIdentifier)) }
        dispatcher.register(SyscallNumber.getgid) { _, host in .result(Int64(host.groupIdentifier)) }
        dispatcher.register(SyscallNumber.getegid) { _, host in .result(Int64(host.groupIdentifier)) }

        // `uname` is what libc and many programs call first. The layout is the Linux `struct utsname`:
        // six NUL-terminated char arrays of 65 bytes each.
        dispatcher.register(SyscallNumber.uname) { request, host in
            let address = request.argument(0)
            let fields = [
                host.systemName, host.nodeName, host.release, host.version, host.machine, host.domainName,
            ]
            var bytes = [UInt8]()
            for field in fields {
                var encoded = Array(field.utf8)
                if encoded.count > 64 { encoded = Array(encoded.prefix(64)) }
                bytes.append(contentsOf: encoded)
                bytes.append(contentsOf: Array(repeating: 0, count: 65 - encoded.count))
            }
            guard host.writeGuest(address: address, bytes: bytes) else { return .failure(.EFAULT) }
            return .result(0)
        }

        // No wall clock is available in the host protocol beyond the platform's own, and the guest
        // only needs a monotonic timeline to make progress; both clocks report real host time.
        dispatcher.register(SyscallNumber.clockGetTime) { request, host in
            let clockID = Int32(truncatingIfNeeded: request.argument(0))
            let address = request.argument(1)
            guard clockID >= 0, clockID <= 7 else { return .failure(.EINVAL) }
            let nanoseconds = clockID == 0 || clockID == 5
                ? host.wallClockNanoseconds : host.monotonicNanoseconds
            var bytes = [UInt8]()
            let seconds = UInt64(nanoseconds / 1_000_000_000)
            let remainder = UInt64(nanoseconds % 1_000_000_000)
            for value in [seconds, remainder] {
                for index in 0..<8 { bytes.append(UInt8((value >> (8 * UInt64(index))) & 0xff)) }
            }
            guard host.writeGuest(address: address, bytes: bytes) else { return .failure(.EFAULT) }
            return .result(0)
        }

        dispatcher.register(SyscallNumber.getrandom) { request, host in
            let address = request.argument(0)
            let count = Int(truncatingIfNeeded: request.argument(1))
            guard count >= 0 else { return .failure(.EINVAL) }
            guard count > 0 else { return .result(0) }
            guard host.writeGuest(address: address, bytes: host.randomBytes(count: count)) else {
                return .failure(.EFAULT)
            }
            return .result(Int64(count))
        }

        // Thread bookkeeping: the values are cached by libc and never acted on, so an honest tid is
        // enough. Real threads arrive in Phase 3 with fork/clone.
        dispatcher.register(SyscallNumber.setTidAddress) { _, host in .result(Int64(host.threadIdentifier)) }
        // set_robust_list (99): libc reports the list head and never depends on the answer.
        dispatcher.register(99) { _, _ in .result(0) }

        // Signal plumbing: accepted and ignored, because the runtime does not deliver guest signals yet.
        // Implementing them wrongly would be worse than reporting success for a no-op.
        dispatcher.register(SyscallNumber.rt_sigaction) { _, _ in .result(0) }
        dispatcher.register(SyscallNumber.rt_sigprocmask) { _, _ in .result(0) }
        dispatcher.register(SyscallNumber.prctl) { _, _ in .result(0) }
        dispatcher.register(SyscallNumber.schedYield) { _, _ in .result(0) }

        dispatcher.register(SyscallNumber.getcwd) { request, host in
            let address = request.argument(0)
            let count = Int(truncatingIfNeeded: request.argument(1))
            // There is exactly one directory in the world as far as Phase 2 is concerned.
            let path = Array("/".utf8) + [0]
            guard count >= path.count else { return .failure(.ERANGE) }
            guard host.writeGuest(address: address, bytes: path) else { return .failure(.EFAULT) }
            return .result(Int64(path.count))
        }

        // Explicit non-goals, refused with a reason the trace will show. These are the work items for
        // Phases 3-4, and the trace's `unimplemented=` line is how the next session finds them.
        for number in [
            SyscallNumber.futex, SyscallNumber.clone, SyscallNumber.execve, SyscallNumber.wait4,
            SyscallNumber.openat, SyscallNumber.readlinkat, SyscallNumber.newfstatat,
            SyscallNumber.fstat, SyscallNumber.socket, SyscallNumber.ioctl,
        ] {
            dispatcher.register(number) { _, _ in .failure(.ENOSYS) }
        }

        return dispatcher
    }
}
