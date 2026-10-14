# Syscall translation prior art (for Track B)

_Learned 2026-10-14. Sources cited inline. This is the design space for running Ubuntu arm64 ELF
binaries natively inside an iOS app with Linux syscalls handled in our own code._

## The projects are not the same kind of thing

- **In-process Linux compatibility runtimes:** [iSH](https://github.com/ish-app/ish) (x86
  interpreter + syscall translation), [ios-linuxkit](https://github.com/rcarmo/ios-linuxkit)
  (documented AArch64 guest, in-process userspace Linux kernel/syscall table,
  [architecture](https://github.com/rcarmo/ios-linuxkit/blob/master/docs/ARCHITECTURE.md)).
- **User-mode CPU emulators/translators that also translate syscalls:** QEMU linux-user,
  [FEX-Emu](https://github.com/FEX-Emu/FEX).
- **Kernel-interface implementations:** [gVisor](https://gvisor.dev/docs/architecture_guide/intro/)
  (Sentry, an application kernel in userspace), WSL1
  ([`lxcore.sys`/`lxss.sys`](https://learn.microsoft.com/en-us/previous-versions/windows/desktop/cmdline/wsl-architectural-overview)).
- **Not a syscall translator:** PlatformLab Arachne is a cooperative user-level thread system
  ([repo](https://github.com/PlatformLab/Arachne)). Note this because the prior-art list mixes it in.

## How each one catches syscalls

| Project | Mechanism | Portability to iOS |
| --- | --- | --- |
| iSH | Emulated instructions; the emulator recognises the syscall and calls its Linux-compat code | The pattern works; upstream is x86 |
| ios-linuxkit | ARM64 decoder + precompiled gadgets; syscall numbers dispatch to a userspace Linux syscall table; optional AOT translations | Closest documented precedent for **arm64** on iOS |
| QEMU linux-user | Generic syscall translator adjusting ABI details (endianness, argument widths) and forwarding to equivalent host calls; also translates `ioctl` and signals | Reference for the **translation table**; its host support is Linux/BSD |
| gVisor | `systrap` uses Linux `seccomp` `SECCOMP_RET_TRAP` → `SIGSYS`; `ptrace` platform uses `PTRACE_SYSEMU`; KVM uses virtualization ([platforms](https://gvisor.dev/docs/architecture_guide/platforms/)) | **Linux-only capture mechanisms** |
| WSL1 | Windows kernel forwards a Pico process's syscall to the subsystem driver | Requires Windows kernel support |

**Critical point:** Linux's `seccomp`/`SIGSYS` interception contract does not exist on Darwin.
[Linux seccomp docs](https://docs.kernel.org/userspace-api/seccomp_filter.html). Linux's Syscall
User Dispatch is likewise Linux-only ([docs](https://docs.kernel.org/admin-guide/syscall-user-dispatch.html)).
A Darwin `SIGSYS` name existing in headers does not imply seccomp trap semantics.

## Mach exception ports: investigate, do not assume

XNU defines `EXC_SYSCALL` and `EXC_MACH_SYSCALL` exception classes and
`task_set_exception_ports` ([XNU headers](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/mach/exception_types.h),
[Mach reference](https://web.mit.edu/darwin/src/modules/xnu/osfmk/man/task_set_exception_ports.html)).
**No source found shows that every ordinary BSD/POSIX syscall of an app is delivered to an app
handler**, or that a sandboxed App-Store-style iOS app may rely on this. Treat it as something to
probe in a Phase 2 spike, not as a substitute for seccomp.

Consequence: the guest's `svc` instruction, executed natively on an Apple CPU, enters **Darwin's**
syscall machinery, not Linux's. Guest and host syscall numbers and ABIs are not interchangeable.

## Three viable capture strategies for us

1. **Interpret/translate and dispatch `svc` in the runtime.** Best-supported precedent, no W^X
   problems, but slow unless combined with AOT translation.
2. **Rewrite `svc` sites at load time** (or interpose trampolines) so guest syscalls call our
   handler. Keeps native speed for the rest of the code; must handle static binaries, JIT-generated
   and self-modifying code, and memory-protection constraints.
3. **Ship a patched libc** whose syscall wrappers call our handler directly. Simplest for
   dynamically linked programs; cannot cover static binaries or hand-written `svc`.

These map to decision 0008 in `docs/DECISIONS.md`, which stays *proposed* until Phase 2 measures
option 2.

## Processes, fork/exec, threads, signals, futexes

- **iOS apps may not spawn child processes** ([Apple DTS](https://developer.apple.com/forums/thread/747499)),
  so a guest process cannot be a host process. Guest processes must be modelled inside our process
  (registers, mappings, descriptors, metadata).
- QEMU documents creating a real host thread per emulated thread for supported `clone` cases on
  Linux ([QEMU user-mode docs](https://www.qemu.org/docs/master/user/main.html)) — no evidence that
  the same is available on iOS.
- WSL1 handles Linux `fork` with internal Windows kernel APIs and state copying — a precedent for
  *design*, not a technique we can use.
- Signals: QEMU forwards/synthesises signals; gVisor reimplements signal handling; ios-linuxkit warns
  that Darwin and Linux signal frames differ
  ([limitations](https://github.com/rcarmo/ios-linuxkit/blob/master/docs/LIMITATIONS.md)).
- `/proc`: ios-linuxkit synthesises `/proc` and warns it is incomplete. That is the natural approach
  when PIDs are virtual.
- Futexes: no source found documenting the guest-futex implementation of iSH/ios-linuxkit. gVisor's
  own Go runtime using host futexes is **not** evidence of guest futex support. Assume we implement
  guest wait/wake semantics ourselves.

## Page size (4 KiB guest vs 16 KiB host)

- Asahi documents that AArch64 ELF load segments aligned only to 4 KiB can fail on 16 KiB systems,
  and recommends 16 KiB-aligned `PT_LOAD`
  ([Asahi broken software](https://asahilinux.org/docs/sw/broken-software/)).
- ios-linuxkit models a **software 4 KiB guest page table**, which is the key idea: guest page
  granularity does not have to equal host page granularity. It does not by itself prove correct
  behaviour for every `mmap`/`mprotect`/partial-unmap/SHM case.
- FEX has a 4 KiB host-page requirement in practice and Fedora proposes a 4 KiB microVM (`muvm`) to
  host it ([Fedora FEX change](https://fedoraproject.org/wiki/Changes/FEX)).
- A patched libc does not solve ELF alignment or `mmap` semantics.

## Performance evidence (not directly comparable)

- iSH: its gadget/threaded interpreter is reported as roughly **3-5× faster** than its simpler
  switch dispatcher — an internal comparison, not native speed
  ([iSH README](https://github.com/ish-app/ish)).
- ios-linuxkit: an **AOT prototype** measured roughly **12-13% faster** on shell/zlib workloads but
  about **15% slower on Python**, with peak RSS rising from **18.3 MiB to 54.1 MiB**; the note warns
  these are dated measurements, not device guarantees
  ([limitations](https://github.com/rcarmo/ios-linuxkit/blob/master/docs/LIMITATIONS.md)).
- gVisor's Systrap release explains that syscall-site jump patching (its biggest optimisation) was
  **not available on ARM** at the time of writing
  ([Systrap announcement](https://gvisor.dev/blog/2023/04/28/systrap-release/)).
- No comparable numeric syscall benchmark was found for QEMU, FEX or WSL1.

## Open questions for the Phase 2 spike

1. Can a sandboxed app receive `EXC_SYSCALL`-class exceptions for guest `svc` instructions, and at
   what cost? (Probe it; expect no.)
2. What is the real cost of rewriting `svc` sites at load time on a large binary, and what happens
   with JIT-generated guest code?
3. How do we keep a 4 KiB guest view correct over 16 KiB host mappings for `mprotect`, partial
   `munmap` and shared memory?
4. Which of the three capture strategies can survive a statically linked binary?
