# The process model: Linux processes without a process API

_Learned 2026-10-15 (research session, Track B planning). Sources cited inline; "documented" means the
source says it, "inferred" means it follows from the sources plus our own design._

## The constraint

An iOS app cannot create processes. iSH's own engineering write-up says iOS apps cannot spawn multiple
processes and that iSH therefore maps Linux processes to iOS **threads**. There is no `fork`, no
arbitrary `posix_spawn` target, no seccomp for trapping: the guest's process semantics have to be built
inside our own address space. [iSH: JIT and the EU](https://ish.app/blog/ish-jit-and-eu)

That single sentence decides the architecture: **a guest process table inside the app, guest tasks on
host threads.**

## What the prior art actually does

| Project | Model | What it proves for us |
| --- | --- | --- |
| **iSH** | `sys_fork()` routes through the guest `clone` path; a child without `CLONE_VM` gets a **copied guest `mm`**; the new task starts on a host `pthread`. Guest signal masks and pending sets live with the task; dispositions are process-wide. | The closest precedent, and the source of our model. Note: iSH **interprets** x86, so it can trap every guest write — see "the COW consequence" below. [iSH `fork.c`](https://raw.githubusercontent.com/ish-app/ish/master/kernel/fork.c), [iSH `task.c`](https://raw.githubusercontent.com/ish-app/ish/master/kernel/task.c), [iSH `signal.c`](https://raw.githubusercontent.com/ish-app/ish/master/kernel/signal.c) |
| **QEMU linux-user** | Guest `clone` can create a real host thread with its own virtual CPU, but QEMU's source says it cannot forward arbitrary flags to the host `clone` because that confuses libc; it classifies flag combinations into pthread-like, fork-like, internal and unsupported. | Do not forward flags. Classify, implement the classes that matter, and return `EINVAL` for the rest — a documented, deliberate refusal. [QEMU user-mode docs](https://www.qemu.org/docs/master/user/main.html), [QEMU `syscall.c`](https://raw.githubusercontent.com/qemu/qemu/master/linux-user/syscall.c) |
| **gVisor** | A user-space kernel with its own process and memory model; its `systrap` platform depends on seccomp's `SECCOMP_RET_TRAP`. | Reinforces separating the guest kernel model from host execution — and that its own platforms are unavailable to us (no KVM, no seccomp). [gVisor platforms](https://gvisor.dev/docs/architecture_guide/platforms/) |
| **WSL 1** | A syscall translation layer, but with Windows *kernel* pico-process infrastructure behind it. | Conceptually the target, but no infrastructure to copy: our "kernel" is a table in the app. [Microsoft: WSL comparison](https://learn.microsoft.com/en-us/windows/wsl/compare-versions) |
| **FEX-Emu** | Linux-host user-mode emulator for arm64; a release note documents a `clone3` stack-pointer bug that broke applications until fixed. | Evidence that clone stack handling is subtle enough to need its own tests. [FEX releases](https://fex-emu.com/FEX-2206/) |

## Mechanisms that work, and the traps

- **One guest task = one host pthread.** Keep the guest's PC/SP/registers *in the thread* by executing
  natively; only the guest-visible metadata (PID/TID, address space, fd table, mask, pending set) is in
  our tables. This avoids inventing native stack switching per context.
- **`setjmp`/`longjmp` is not a forked process image.** A `jmp_buf` saves host execution state, is only
  valid while the saving frame is alive, and must not be restored on a different thread. We already use
  `sigsetjmp` for exactly one thing: returning from the trap handler to `up_guest_run`. Extending that
  into a process model would be undefined behaviour. [Linux `longjmp(3)`](https://man7.org/linux/man-pages/man3/longjmp.3.html)
- **`pthread_create` failure unwind:** POSIX returns a positive error number, not `-1`/`errno`. A task
  record must not stay visible if the thread could not be created. [iSH-AOK notes](https://github.com/emkey1/ish-AOK/blob/working/docs/book/ch10-processes-and-threads.md)
- **`fork` semantics:** only the calling thread exists in the child, pending signals start empty, and
  until `execve` the child may only call async-signal-safe functions (a copied mutex can look locked by
  a thread that no longer exists — the guest's problem, but it explains why fork-then-exec is the
  common real-world pattern we must support). [Linux `fork(2)`](https://man7.org/linux/man-pages/man2/fork.2.html)
- **`execve` semantics:** the program image is replaced, sibling threads are destroyed, caught
  dispositions reset, the PID is kept. [Linux `execve(2)`](https://man7.org/linux/man-pages/man2/execve.2.html)
- **`wait` semantics:** child state (running/stopped/continued/zombie) must be modelled by us; a
  blocking `waitpid` sleeps on guest state. [Linux `wait(2)`](https://man7.org/linux/man-pages/man2/wait.2.html)
- **Descriptors:** fork duplicates the fd *table*; both entries refer to the same open-file description.
  Pipe endpoints therefore need reference counts, or the guest never sees EOF. [Linux `fork(2)`](https://man7.org/linux/man-pages/man2/fork.2.html)
- **Signals:** dispositions per process, masks and pending per task, delivery by constructing a guest
  signal frame. A host signal may wake a blocked pthread; it is never the guest's signal semantics.
  [Linux `signal(7)`](https://man7.org/linux/man-pages/man7/signal.7.html)
- **Guest TLS.** The AArch64 thread pointer is `TPIDR_EL0` and each thread owns its TLS block. Because
  each guest task *is* a host thread, `CLONE_SETTLS` maps onto the host thread's own thread pointer and
  per-thread TLS works without emulating the register at all. This is a place where native execution is
  **easier** than interpreting, and it means glibc's TLS setup is not a blocker by itself.
  [Fuchsia TLS docs](https://fuchsia.googlesource.com/fuchsia/+/HEAD/docs/development/kernel/threads/tls.md),
  [Linux `clone(2)`](https://man7.org/linux/man-pages/man2/clone.2.html)

## The COW consequence (our design, inferred)

A software page table can implement copy-on-write only if it sees every guest write. iSH interprets
instructions, so it can. **We execute guest code natively, so guest writes go straight to host memory
through ordinary pointers — a software page table cannot intercept them.**

Therefore:

- `fork` copies the child's private, present regions **eagerly** (`mmap` + copy of the live bytes).
  Read-only and shared mappings are re-mapped or re-shared rather than copied.
- A hardware write barrier (mprotect a page read-only, catch the fault, copy, resume) is the only way to
  recover laziness. It is available on Apple silicon in principle, but a fault per page is expensive and
  adds a whole new failure mode to the trap handler, so it stays a *measured* option, not the design.
- Cost is real and must be measured: a shell that runs `grep` in a pipeline forks twice, and each fork
  copies the shell's private pages. This is the main reason B3's exit criterion is a *fork-and-pipe*
  guest rather than a benchmark.

Also from the same fact: two guest processes cannot have different host memory at the same guest
virtual address (threads share one host address space), so address-space isolation is a property of our
tables, not of the hardware. A guest that expects isolation from a buggy sibling gets it only in the
sense that we validate buffers against the *calling* task's mappings.

## What iOS forces, summarised

1. No host process tree for the guest: model PIDs, zombies, fds, pipes, signals, waits ourselves.
2. Syscalls are translated in the runtime (decision 0012), never allowed to reach Darwin.
3. No assumption of permission to execute unsigned code; the device answer is measured (see
   [jit-and-entitlements-on-ios.md](jit-and-entitlements-on-ios.md)).
4. All guest memory counts against one app's jetsam limit — the app reports
   `os_proc_available_memory()` instead of assuming a budget. [Apple: jetsam](https://developer.apple.com/documentation/xcode/identifying-high-memory-use-with-jetsam-event-reports), [increased-memory-limit entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.kernel.increased-memory-limit)
5. No Linux kernel primitives for free: no host `fork`, no host COW, no host `waitpid` for guest tasks.
