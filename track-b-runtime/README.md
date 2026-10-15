# Track B — the native arm64 syscall-translation runtime

**Status: Phase 2.** A static, position-independent AArch64 **Linux** program is loaded, placed at a
base this host allows, relocated, patched so every `svc #0` reaches our code, and executed **natively
on an Apple-silicon host**, with the Linux syscalls serviced by our own Swift. The iPad app links the
same code and carries the same guest program, so the pipeline CI asserts is the one the owner can run
by pressing a button. What is not done: a dynamically linked program, more than one process, threads,
signals and a filesystem.

The plan for all of it — the six design problems, the milestones and what could kill them — is
[docs/TRACK-B-PLAN.md](../docs/TRACK-B-PLAN.md).

## Layout

```
core/                          SwiftPM package: builds and tests on Linux AND macOS
  Sources/UbuntuPadCore/       the platform-independent library (no Darwin, no Glibc — CI enforces it)
    ELF.swift                  ELF64/AArch64 header + program header parsing, PT_INTERP
    ImagePlacement.swift       where an image can live on this host: identity, a bias, or a refusal
    Relocations.swift          PT_DYNAMIC / .rela.dyn: the relative relocations a biased PIE needs
    CodePatch.swift            finds every `svc` in executable segments and plans the patch
    GuestAddressSpace.swift    4 KiB guest pages over 16 KiB host pages; regions; host-page plan
    InitialStack.swift         the Linux process stack: argc/argv/envp/auxv, AT_PHDR, AT_PAGESZ
    SyscallTable.swift         curated arm64 syscall numbers (the trace and tests keep it honest)
    SyscallDispatch.swift      the syscall *policy*: registers, errno, outcomes, trace, dispatcher
    Diagnostics.swift          the report an owner pastes into a GitHub issue
  Sources/UbuntuPadHost/       the C shim: mmap primitives, the guest entry trampoline, the SIGTRAP
                               handler, the host probe (host.c). The only place machine-level code lives.
  Sources/UbuntuPadRunner/     the run pipeline as a **library**: GuestRunner (the seven steps below),
                               the syscall session, and HostProbe. Linked by both the CLI and the app,
                               so there is exactly one implementation (decision 0020).
  Sources/ubuntupad-run/       the command-line tool: argument parsing and machine-readable output on
                               top of UbuntuPadRunner, which is what CI asserts
  Tests/UbuntuPadCoreTests/    unit tests, including real cross-compiled arm64 binaries
ios/                           the iPad app (SwiftUI + XcodeGen spec): it links UbuntuPadRunner, bundles
                               a guest program in ios/Guest/ and runs it behind a button
testdata/                      the guest programs: freestanding (raw syscalls) and libc-linked
runner-entitlements.plist      used ONLY if the kernel refuses an executable mapping (decision 0015)
```

## The design in six steps

1. **Parse** the image; refuse anything that is not a static ELF64/AArch64 image.
2. **Place** it: on Apple silicon the low 4 GiB is `__PAGEZERO`, reserved by the kernel for every arm64
   process, so a normal Linux executable linked at 0x400000 cannot be mapped at its link-time address
   — not by hinting, and not by forcing (decision 0019). A position-independent image is therefore
   moved above the floor at a bias that keeps its alignment, and a fixed-address image that would fall
   inside the reservation is refused with a message saying why and what would work instead.
3. **Relocate**: the image's own `R_AARCH64_RELATIVE` relocations are applied to the image bytes for
   that base, which is what makes a biased PIE's data pointers valid. Unsupported types are collected
   and refused rather than half-applied.
4. **Map** the image at `bias + link-time address` and **patch** every `svc #0` into `brk #0x123`,
   planned from the executable `PT_LOAD` contents. A guest virtual address *is* a host virtual
   address, so the guest's pointers need no translation (decision 0011) — and the mapping must land on
   the address that was asked for, or the run stops.
5. **Protect**: each host page gets the union of the protections of the guest regions inside it, and
   the run reports how many pages had to merge (decision 0018).
6. **Run**: install a SIGTRAP handler on its own stack and branch to the entry point. Each trap is a
   syscall: the handler reads x8/x0-x5 out of the signal context, lets Swift decide, writes x0, steps
   the program counter past the breakpoint and resumes the guest (decision 0012).

Two things this design deliberately avoids: generated code, and pages that are writable and
executable at the same time. Text is written while it is writable and made executable afterwards. That
is what keeps it viable on a non-jailbroken iOS device, and `ubuntupad-run probe` reports the kernel's
answer rather than assuming it.

## How to run it

```bash
# 1. cross-compile the guest programs (Linux/macOS with the aarch64 toolchain, or use CI's artifact).
#    -static-pie is not a preference: a fixed-address image cannot be mapped on Apple silicon at all,
#    so this is the only shape that runs there (decision 0019).
aarch64-linux-gnu-gcc -static -nostdlib -static-pie -fPIE -ffreestanding -fno-builtin -O1 \
  -o /tmp/hello-pie-nostdlib track-b-runtime/testdata/hello-pie-nostdlib.c

# 2. build and probe
cd track-b-runtime/core
swift build -c release --product ubuntupad-run
.build/release/ubuntupad-run probe

# 3. run a guest
.build/release/ubuntupad-run run /tmp/hello-pie-nostdlib
```

### The same program, on the iPad

`ios/project.yml` links the `UbuntuPadRunner` product and bundles two of the guest programs from
`ios/Guest/` — the same files `tools/build-guest-binaries.sh` produces for CI, fetched as an artifact by
`build-ipa.yml`, which also verifies they are really inside the `.ipa` before publishing it (decision
0020). The app's screen has a Run button per program and prints the run's facts.

**Unverified on device.** Nothing in this repository has been executed on a physical iPad. The first
line worth reading when it is, is the probe's `rx_mapping=`: it is the device's answer to whether an app
may execute pages it wrote, and it decides how much of Phase 5 is possible.

`probe` prints the host page size, whether executable memory is available, and the size of the host's
reserved low region. `run` prints one fact per line — including `image_placement=`, `bias=` and how
many relocations it applied — and brackets the guest's own output with
`guest-stdout-begin` / `guest-stdout-end`, which is what CI asserts
(`tools/assert-guest-run.sh`). `run` is **only meaningful on arm64**; on other architectures it
reports `exit=unsupported-on-this-host` and exits non-zero rather than pretending.

The unit tests, including the checks against real binaries:

```bash
cd track-b-runtime/core
swift test                     # on Linux or macOS
UBUNTUPAD_TEST_BINARY=/path/to/static-libc-arm64-binary \
UBUNTUPAD_TEST_NOSTDLIB_BINARY=/path/to/hello-nostdlib \
UBUNTUPAD_TEST_PIE_BINARY=/path/to/hello-pie-nostdlib \
swift test
```

Without those variables the real-binary tests report **skipped**, never passed — read the test output,
not just the exit code. `runtime-e2e.yml` sets them and runs the whole thing on `macos-15`.

## What is not implemented (and is therefore refused, loudly)

| Missing | What happens today |
| --- | --- |
| Dynamic linking / `PT_INTERP` | the loader refuses the image and says which interpreter it asked for |
| Symbol-based relocations (`R_AARCH64_ABS64`, ...) | reported by number and refused; only `R_AARCH64_RELATIVE` is applied |
| Relocations into `.bss` | refused: the runtime relocates the image *before* mapping it, so zero-filled bytes cannot be patched |
| `fork`/`clone`/`execve` | `ENOSYS`, recorded in the trace's `unimplemented=` line |
| Threads, futexes, signals to the guest | `ENOSYS`; `rt_sigaction` is accepted as a no-op and documented as such |
| Filesystem (`openat`, `fstat`, `ioctl`, ...) | `ENOSYS` / `ENOTTY`; only a virtual `/` exists for `getcwd` |
| Guest TLS (`TPIDR_EL0`) | untouched: the guest's thread pointer is the host's, so a program that sets one (glibc does) is not supported yet |
| Code the guest generates at runtime | not patched; the first dynamic `svc` becomes a Darwin syscall and the run ends with `exit=breakpoint` |

The `unimplemented=` line in a run's output is the intended work list for the next session: run a
program, see what it asks for, implement that.
