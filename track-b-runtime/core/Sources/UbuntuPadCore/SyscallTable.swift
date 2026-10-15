import Foundation

/// Linux arm64 (AArch64) syscall numbers.
///
/// Scope note: this is the **curated subset** Phase 2/3 needs, not the full table. It was written
/// from the generic arm64 syscall table. Every number added here must be cross-checked against the
/// kernel's `arch/arm64/include/uapi/asm/unistd.h` (or QEMU's `linux-user/aarch64/syscall_nr.h`)
/// before it is relied upon — the CI test only proves the table is self-consistent, not that these
/// numbers match the kernel.
public enum SyscallNumber {
    // Filesystem
    public static let getcwd: Int32 = 17
    public static let dup: Int32 = 23
    public static let dup3: Int32 = 24
    public static let fcntl: Int32 = 25
    public static let ioctl: Int32 = 29
    public static let mkdirat: Int32 = 34
    public static let unlinkat: Int32 = 35
    public static let renameat: Int32 = 38
    public static let faccessat: Int32 = 48
    public static let chdir: Int32 = 49
    public static let fchmod: Int32 = 52
    public static let fchmodat: Int32 = 53
    public static let openat: Int32 = 56
    public static let close: Int32 = 57
    public static let pipe2: Int32 = 59
    public static let getdents64: Int32 = 61
    public static let lseek: Int32 = 62
    public static let read: Int32 = 63
    public static let write: Int32 = 64
    public static let readv: Int32 = 65
    public static let writev: Int32 = 66
    public static let pread64: Int32 = 67
    public static let pwrite64: Int32 = 68
    public static let readlinkat: Int32 = 78
    public static let newfstatat: Int32 = 79
    public static let fstat: Int32 = 80
    public static let fsync: Int32 = 82

    // Process and signals
    public static let exit: Int32 = 93
    public static let exitGroup: Int32 = 94
    public static let setTidAddress: Int32 = 96
    public static let setRobustList: Int32 = 99
    public static let futex: Int32 = 98
    public static let nanosleep: Int32 = 101
    public static let clockGetTime: Int32 = 113
    public static let schedYield: Int32 = 124
    public static let kill: Int32 = 129
    public static let tkill: Int32 = 130
    public static let tgkill: Int32 = 131
    public static let rt_sigaction: Int32 = 134
    public static let rt_sigprocmask: Int32 = 135
    public static let rt_sigreturn: Int32 = 139
    public static let uname: Int32 = 160
    public static let prctl: Int32 = 167
    public static let getpid: Int32 = 172
    public static let getppid: Int32 = 173
    public static let getuid: Int32 = 174
    public static let geteuid: Int32 = 175
    public static let getgid: Int32 = 176
    public static let getegid: Int32 = 177
    public static let gettid: Int32 = 178

    // Memory
    public static let brk: Int32 = 214
    public static let munmap: Int32 = 215
    public static let mremap: Int32 = 216
    public static let clone: Int32 = 220
    public static let execve: Int32 = 221
    public static let mmap: Int32 = 222
    public static let mprotect: Int32 = 226
    public static let madvise: Int32 = 233
    public static let mlock: Int32 = 228

    // Event loop and waits
    public static let epoll_create1: Int32 = 20
    public static let epoll_ctl: Int32 = 21
    public static let epoll_pwait: Int32 = 22
    public static let ppoll: Int32 = 73
    public static let wait4: Int32 = 260
    public static let getrandom: Int32 = 278

    // Sockets
    public static let socket: Int32 = 198
    public static let connect: Int32 = 203
    public static let sendto: Int32 = 206
    public static let recvfrom: Int32 = 207
    public static let setsockopt: Int32 = 208
    public static let getsockopt: Int32 = 209
    public static let shutdown: Int32 = 210
    public static let sendmsg: Int32 = 211
    public static let recvmsg: Int32 = 212
}

public struct SyscallEntry: Equatable {
    public let number: Int32
    public let name: String
}

/// Lookup helpers over the curated table. Phase 2's dispatcher is built on this, and the CI test
/// keeps it consistent.
public struct SyscallTable {
    public static let entries: [SyscallEntry] = [
        SyscallEntry(number: SyscallNumber.getcwd, name: "getcwd"),
        SyscallEntry(number: SyscallNumber.dup, name: "dup"),
        SyscallEntry(number: SyscallNumber.dup3, name: "dup3"),
        SyscallEntry(number: SyscallNumber.fcntl, name: "fcntl"),
        SyscallEntry(number: SyscallNumber.ioctl, name: "ioctl"),
        SyscallEntry(number: SyscallNumber.mkdirat, name: "mkdirat"),
        SyscallEntry(number: SyscallNumber.unlinkat, name: "unlinkat"),
        SyscallEntry(number: SyscallNumber.renameat, name: "renameat"),
        SyscallEntry(number: SyscallNumber.faccessat, name: "faccessat"),
        SyscallEntry(number: SyscallNumber.chdir, name: "chdir"),
        SyscallEntry(number: SyscallNumber.fchmod, name: "fchmod"),
        SyscallEntry(number: SyscallNumber.fchmodat, name: "fchmodat"),
        SyscallEntry(number: SyscallNumber.openat, name: "openat"),
        SyscallEntry(number: SyscallNumber.close, name: "close"),
        SyscallEntry(number: SyscallNumber.pipe2, name: "pipe2"),
        SyscallEntry(number: SyscallNumber.getdents64, name: "getdents64"),
        SyscallEntry(number: SyscallNumber.lseek, name: "lseek"),
        SyscallEntry(number: SyscallNumber.read, name: "read"),
        SyscallEntry(number: SyscallNumber.write, name: "write"),
        SyscallEntry(number: SyscallNumber.readv, name: "readv"),
        SyscallEntry(number: SyscallNumber.writev, name: "writev"),
        SyscallEntry(number: SyscallNumber.pread64, name: "pread64"),
        SyscallEntry(number: SyscallNumber.pwrite64, name: "pwrite64"),
        SyscallEntry(number: SyscallNumber.readlinkat, name: "readlinkat"),
        SyscallEntry(number: SyscallNumber.newfstatat, name: "newfstatat"),
        SyscallEntry(number: SyscallNumber.fstat, name: "fstat"),
        SyscallEntry(number: SyscallNumber.fsync, name: "fsync"),
        SyscallEntry(number: SyscallNumber.exit, name: "exit"),
        SyscallEntry(number: SyscallNumber.exitGroup, name: "exit_group"),
        SyscallEntry(number: SyscallNumber.setTidAddress, name: "set_tid_address"),
        SyscallEntry(number: SyscallNumber.setRobustList, name: "set_robust_list"),
        SyscallEntry(number: SyscallNumber.futex, name: "futex"),
        SyscallEntry(number: SyscallNumber.nanosleep, name: "nanosleep"),
        SyscallEntry(number: SyscallNumber.clockGetTime, name: "clock_gettime"),
        SyscallEntry(number: SyscallNumber.schedYield, name: "sched_yield"),
        SyscallEntry(number: SyscallNumber.kill, name: "kill"),
        SyscallEntry(number: SyscallNumber.tkill, name: "tkill"),
        SyscallEntry(number: SyscallNumber.tgkill, name: "tgkill"),
        SyscallEntry(number: SyscallNumber.rt_sigaction, name: "rt_sigaction"),
        SyscallEntry(number: SyscallNumber.rt_sigprocmask, name: "rt_sigprocmask"),
        SyscallEntry(number: SyscallNumber.rt_sigreturn, name: "rt_sigreturn"),
        SyscallEntry(number: SyscallNumber.uname, name: "uname"),
        SyscallEntry(number: SyscallNumber.prctl, name: "prctl"),
        SyscallEntry(number: SyscallNumber.getpid, name: "getpid"),
        SyscallEntry(number: SyscallNumber.getppid, name: "getppid"),
        SyscallEntry(number: SyscallNumber.getuid, name: "getuid"),
        SyscallEntry(number: SyscallNumber.geteuid, name: "geteuid"),
        SyscallEntry(number: SyscallNumber.getgid, name: "getgid"),
        SyscallEntry(number: SyscallNumber.getegid, name: "getegid"),
        SyscallEntry(number: SyscallNumber.gettid, name: "gettid"),
        SyscallEntry(number: SyscallNumber.brk, name: "brk"),
        SyscallEntry(number: SyscallNumber.munmap, name: "munmap"),
        SyscallEntry(number: SyscallNumber.mremap, name: "mremap"),
        SyscallEntry(number: SyscallNumber.clone, name: "clone"),
        SyscallEntry(number: SyscallNumber.execve, name: "execve"),
        SyscallEntry(number: SyscallNumber.mmap, name: "mmap"),
        SyscallEntry(number: SyscallNumber.mprotect, name: "mprotect"),
        SyscallEntry(number: SyscallNumber.madvise, name: "madvise"),
        SyscallEntry(number: SyscallNumber.mlock, name: "mlock"),
        SyscallEntry(number: SyscallNumber.epoll_create1, name: "epoll_create1"),
        SyscallEntry(number: SyscallNumber.epoll_ctl, name: "epoll_ctl"),
        SyscallEntry(number: SyscallNumber.epoll_pwait, name: "epoll_pwait"),
        SyscallEntry(number: SyscallNumber.ppoll, name: "ppoll"),
        SyscallEntry(number: SyscallNumber.wait4, name: "wait4"),
        SyscallEntry(number: SyscallNumber.getrandom, name: "getrandom"),
        SyscallEntry(number: SyscallNumber.socket, name: "socket"),
        SyscallEntry(number: SyscallNumber.connect, name: "connect"),
        SyscallEntry(number: SyscallNumber.sendto, name: "sendto"),
        SyscallEntry(number: SyscallNumber.recvfrom, name: "recvfrom"),
        SyscallEntry(number: SyscallNumber.setsockopt, name: "setsockopt"),
        SyscallEntry(number: SyscallNumber.getsockopt, name: "getsockopt"),
        SyscallEntry(number: SyscallNumber.shutdown, name: "shutdown"),
        SyscallEntry(number: SyscallNumber.sendmsg, name: "sendmsg"),
        SyscallEntry(number: SyscallNumber.recvmsg, name: "recvmsg"),
    ]

    private static let byNumber: [Int32: String] = Dictionary(
        uniqueKeysWithValues: entries.map { ($0.number, $0.name) })

    private static let byName: [String: Int32] = Dictionary(
        uniqueKeysWithValues: entries.map { ($0.name, $0.number) })

    public static func name(for number: Int32) -> String? { byNumber[number] }

    public static func number(forName name: String) -> Int32? { byName[name] }
}
