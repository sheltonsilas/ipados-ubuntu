import Foundation

/// The Linux `clone(2)` flags that affect which resources a new guest task shares with its parent.
/// Values match the arm64 Linux UAPI. `CLONE_VM` is bit 8; `CLONE_FS` bit 9; `CLONE_FILES` bit 10;
/// `CLONE_SIGHAND` bit 12; `CLONE_THREAD` bit 16; `CLONE_SETTLS` bit 19.
public struct GuestCloneFlags: OptionSet, Equatable, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let vm = GuestCloneFlags(rawValue: 0x0000_0100)
    public static let filesystem = GuestCloneFlags(rawValue: 0x0000_0200)
    public static let files = GuestCloneFlags(rawValue: 0x0000_0400)
    public static let sighand = GuestCloneFlags(rawValue: 0x0000_0800)
    public static let thread = GuestCloneFlags(rawValue: 0x0001_0000)
    public static let setTLS = GuestCloneFlags(rawValue: 0x0008_0000)

    /// Linux requires these implications; reject malformed requests rather than quietly changing the
    /// guest's process semantics.
    public var isValid: Bool {
        (!contains(.thread) || (contains(.vm) && contains(.sighand)))
            && (!contains(.sighand) || contains(.vm))
    }
}

/// A guest task is a Linux-visible thread. In Track B, native guest execution uses the host thread's
/// real registers, so this table owns identity and resource-sharing relationships, not a saved CPU
/// context. See DECISIONS.md 0021 and docs/RESEARCH/process-model-without-fork.md.
public struct GuestTask: Equatable, Sendable {
    public let pid: Int32
    public let threadGroupID: Int32
    public let parentID: Int32
    public let addressSpaceID: UInt64
    public let fileTableID: UInt64
    public let filesystemID: UInt64
    public let signalHandlersID: UInt64
    public let pendingSignals: Set<Int32>
    public let signalMask: Set<Int32>
    public let tlsAddress: UInt64?
    public let exitStatus: Int32?

    fileprivate init(
        pid: Int32,
        threadGroupID: Int32,
        parentID: Int32,
        addressSpaceID: UInt64,
        fileTableID: UInt64,
        filesystemID: UInt64,
        signalHandlersID: UInt64,
        pendingSignals: Set<Int32> = [],
        signalMask: Set<Int32> = [],
        tlsAddress: UInt64? = nil,
        exitStatus: Int32? = nil
    ) {
        self.pid = pid
        self.threadGroupID = threadGroupID
        self.parentID = parentID
        self.addressSpaceID = addressSpaceID
        self.fileTableID = fileTableID
        self.filesystemID = filesystemID
        self.signalHandlersID = signalHandlersID
        self.pendingSignals = pendingSignals
        self.signalMask = signalMask
        self.tlsAddress = tlsAddress
        self.exitStatus = exitStatus
    }

    public var isExited: Bool { exitStatus != nil }
}

public enum GuestProcessError: Error, Equatable, CustomStringConvertible {
    case invalidCloneFlags(UInt64)
    case unknownTask(Int32)
    case pidExhausted
    case taskAlreadyExited(Int32)

    public var description: String {
        switch self {
        case let .invalidCloneFlags(flags): return "invalid Linux clone flag combination 0x\(String(flags, radix: 16))"
        case let .unknownTask(pid): return "no guest task with ID \(pid)"
        case .pidExhausted: return "the guest PID space is exhausted"
        case let .taskAlreadyExited(pid): return "guest task \(pid) has already exited"
        }
    }
}

/// Portable, deterministic bookkeeping for guest process/thread identity and clone resource sharing.
/// It never creates a host thread: the runner does that at the platform boundary after this table has
/// produced a valid task. Linux CI can therefore prove the policy without starting a native thread.
public struct GuestProcessTable: Equatable, Sendable {
    public private(set) var tasks: [Int32: GuestTask]
    private var nextID: Int32

    public init(rootPID: Int32 = 1) {
        precondition(rootPID > 0)
        nextID = rootPID + 1
        tasks = [rootPID: GuestTask(
            pid: rootPID,
            threadGroupID: rootPID,
            parentID: 0,
            addressSpaceID: UInt64(rootPID),
            fileTableID: UInt64(rootPID),
            filesystemID: UInt64(rootPID),
            signalHandlersID: UInt64(rootPID))]
    }

    public var liveTaskCount: Int { tasks.values.filter { !$0.isExited }.count }

    public func task(_ pid: Int32) -> GuestTask? { tasks[pid] }

    /// Models Linux `clone` resource sharing. A non-`CLONE_VM` child receives a new address-space
    /// identity; the caller (platform layer) must eagerly copy its private mappings because native
    /// guest writes cannot be intercepted for software COW. This method does not fake that copy—it
    /// states which address-space instance the host must prepare before starting the child thread.
    @discardableResult
    public mutating func clone(
        parent pid: Int32,
        flags: GuestCloneFlags,
        tlsAddress: UInt64? = nil
    ) throws -> GuestTask {
        guard flags.isValid else { throw GuestProcessError.invalidCloneFlags(flags.rawValue) }
        guard let parent = tasks[pid] else { throw GuestProcessError.unknownTask(pid) }
        guard !parent.isExited else { throw GuestProcessError.taskAlreadyExited(pid) }
        guard nextID > 0, !tasks.keys.contains(nextID) else { throw GuestProcessError.pidExhausted }

        let childID = nextID
        let increment = nextID.addingReportingOverflow(1)
        nextID = increment.overflow ? Int32.min : increment.partialValue
        let threadGroup = flags.contains(.thread) ? parent.threadGroupID : childID
        let child = GuestTask(
            pid: childID,
            threadGroupID: threadGroup,
            parentID: parent.threadGroupID,
            addressSpaceID: flags.contains(.vm) ? parent.addressSpaceID : UInt64(childID),
            fileTableID: flags.contains(.files) ? parent.fileTableID : UInt64(childID),
            filesystemID: flags.contains(.filesystem) ? parent.filesystemID : UInt64(childID),
            signalHandlersID: flags.contains(.sighand) ? parent.signalHandlersID : UInt64(childID),
            // A fork-like task does not inherit the parent's pending set; masks are copied. CLONE_THREAD
            // threads start with no pending signals as Linux specifies.
            pendingSignals: [],
            signalMask: parent.signalMask,
            tlsAddress: flags.contains(.setTLS) ? tlsAddress : nil)
        tasks[childID] = child
        return child
    }

    /// Marks a task's exit. Its record remains as a zombie until `reap` so the parent can wait on it.
    public mutating func exit(_ pid: Int32, status: Int32) throws {
        guard let task = tasks[pid] else { throw GuestProcessError.unknownTask(pid) }
        guard !task.isExited else { throw GuestProcessError.taskAlreadyExited(pid) }
        tasks[pid] = GuestTask(
            pid: task.pid,
            threadGroupID: task.threadGroupID,
            parentID: task.parentID,
            addressSpaceID: task.addressSpaceID,
            fileTableID: task.fileTableID,
            filesystemID: task.filesystemID,
            signalHandlersID: task.signalHandlersID,
            pendingSignals: task.pendingSignals,
            signalMask: task.signalMask,
            tlsAddress: task.tlsAddress,
            exitStatus: status & 0xff)
    }

    /// Reaps one exited direct child. Nil means the child is not a zombie (or is not this parent's child).
    @discardableResult
    public mutating func reap(parent pid: Int32, child childID: Int32) -> GuestTask? {
        guard let child = tasks[childID], child.parentID == pid, child.isExited else { return nil }
        tasks.removeValue(forKey: childID)
        return child
    }
}
