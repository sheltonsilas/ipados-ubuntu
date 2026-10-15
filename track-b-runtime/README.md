# Track B — the native arm64 syscall-translation runtime

**Status: Phase 2.** A static AArch64 **Linux** program is loaded, mapped at its own addresses,
patched so every `svc #0` reaches our code, and executed **natively on an Apple-silicon host**, with
the Linux syscalls serviced by our own Swift. What is not done: a dynamically linked program, more
than one process, threads, signals and a filesystem.

## Layout

```
core/                          SwiftPM package: builds and tests on Linux AND macOS
  Sources/UbuntuPadCore/       the platform-independent library (no Darwin, no Glibc — CI enforces it)
    ELF.swift                  ELF64/AArch64 header + program header parsing, PT_INTERP
    CodePatch.swift            finds every `svc` in executable segments and plans the patch
    GuestAddressSpace.swift    4 KiB guest pages over 16 KiB host pages; regions; host-page plan
    InitialStack.swift         the Linux process stack: argc/argv/envp/auxv, AT_PHDR, AT_PAGESZ
    SyscallTable.swift         curated arm64 syscall numbers (the trace and tests keep it honest)
    SyscallDispatch.swift      the syscall *policy*: registers, errno, outcomes, trace, dispatcher
    Diagnostics.swift          the report an owner pastes into a GitHub issue
  Sources/UbuntuPadHost/       the C shim: mmap primitives, the guest entry trampoline, the SIGTRAP
                               handler (host.c). This is the only place machine-level code lives.
  Sources/ubuntupad-run/       the executable that actually runs a guest (see below)
  Tests/UbuntuPadCoreTests/    unit tests, including real cross-compiled arm64 binaries
ios/                           the iOS shell (SwiftUI + XcodeGen spec) — not wired to the runtime yet
testdata/                      the guest programs: freestanding (raw syscalls) and libc-linked
runner-entitlements.plist      used ONLY if the kernel refuses an executable mapping (decision 0015)
```

## The design in five steps

1. **Parse** the image; refuse anything that is not static ELF64/AArch64 at a fixed address.
2. **Map** the image at exactly its link-time addresses. A guest virtual address *is* a host virtual
   address, so the guest's pointers need no translation (decision 0011).
3. **Patch**: every `svc #0` becomes `brk #0x123`, planned from the executable `PT_LOAD` contents.
4. **Protect**: each host page gets the union of the protections of the guest regions inside it, and
   the run reports how many pages had to merge (decision 0018).
5. **Run**: install a SIGTRAP handler on its own stack and branch to the entry point. Each trap is a
   syscall: the handler reads x8/x0-x5 out of the signal context, lets Swift decide, writes x0, steps
   the program counter past the breakpoint and resumes the guest (decision 0012).

Two things this design deliberately avoids: generated code, and pages that are writable and
executable at the same time. Text is written while it is writable and made executable afterwards. That
is what keeps it viable on a non-jailbroken iOS device, and `ubuntupad-run probe` reports the kernel's
answer rather than assuming it.

## How to run it

```bash
# 1. cross-compile the guest programs (Linux/macOS with the aarch64 toolchain, or use CI's artifact)
aarch64-linux-gnu-gcc -static -nostdlib -no-pie -ffreestanding -fno-builtin -O1 \
  -o /tmp/hello-nostdlib track-b-runtime/testdata/hello-nostdlib.c

# 2. build and probe
cd track-b-runtime/core
swift build -c release --product ubuntupad-run
.build/release/ubuntupad-run probe

# 3. run a guest
.build/release/ubuntupad-run run /tmp/hello-nostdlib
```

`probe` prints the host page size, whether executable memory is available, and the size of the host's
reserved low region. `run` prints one fact per line and brackets the guest's own output with
`guest-stdout-begin` / `guest-stdout-end`, which is what CI asserts
(`tools/assert-guest-run.sh`). `run` is **only meaningful on arm64**; on other architectures it
reports `exit=unsupported-on-this-host` and exits non-zero rather than pretending.

The unit tests, including the checks against real binaries:

```bash
cd track-b-runtime/core
swift test                     # on Linux or macOS
UBUNTUPAD_TEST_BINARY=/path/to/static-libc-arm64-binary \
UBUNTUPAD_TEST_NOSTDLIB_BINARY=/path/to/hello-nostdlib \
swift test
```

Without those variables the real-binary tests report **skipped**, never passed — read the test output,
not just the exit code. `runtime-e2e.yml` sets them and runs the whole thing on `macos-15`.

## What is not implemented (and is therefore refused, loudly)

| Missing | What happens today |
| --- | --- |
| Dynamic linking / `PT_INTERP` | the loader refuses the image and says which interpreter it asked for |
| ET_DYN (PIE) images | refused; `loadBias` exists in the stack builder but nothing relocates yet |
| `fork`/`clone`/`execve` | `ENOSYS`, recorded in the trace's `unimplemented=` line |
| Threads, futexes, signals to the guest | `ENOSYS`; `rt_sigaction` is accepted as a no-op and documented as such |
| Filesystem (`openat`, `fstat`, `ioctl`, ...) | `ENOSYS` / `ENOTTY`; only a virtual `/` exists for `getcwd` |
| Guest TLS (`TPIDR_EL0`) | untouched: the guest's thread pointer is the host's, so a program that sets one (glibc does) is not supported yet |
| Code the guest generates at runtime | not patched; the first dynamic `svc` becomes a Darwin syscall and the run ends with `exit=breakpoint` |

The `unimplemented=` line in a run's output is the intended work list for the next session: run a
program, see what it asks for, implement that.
