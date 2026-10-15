# Track B — the complete plan

Track B is the mission: run real Ubuntu **arm64** programs natively on the iPad's CPU with Linux
system calls handled by our own code. This document is the whole plan in one place — what each design
problem is, what has been decided, what is still open, and the order the work has to happen in.

It exists so that a session with no memory of the previous one can see the shape of the work before
touching code. Concrete decisions live in [DECISIONS.md](DECISIONS.md) (numbered, never deleted);
current state lives in [STATUS.md](STATUS.md); prior art lives in [RESEARCH/](RESEARCH/README.md);
the phase checkboxes live in [ROADMAP.md](ROADMAP.md). When this plan and a decision disagree, the
decision wins and this plan is corrected.

**The rule for every milestone below:** its exit criterion is an automated test in CI, or an explicit
item on the owner's device checklist labelled *unverified on device* until they report back. Nothing
is "done" because it looks right.

---

## 1. The six design problems

The mission names six problems that must be researched and decided. This is the state of each.

### 1.1 Catching syscalls — decided and working

iOS has no `seccomp` and no `SIGSYS`, so a guest `svc #0` must be caught by us.

- **Decision 0012:** rewrite every `svc` in the executable segments into `brk #0x123` when the image is
  loaded, install a `SIGTRAP` handler on its own stack, read x8/x0–x5 out of the signal context, let
  Swift decide, write x0, step the PC past the breakpoint and resume.
- **Why not a patched libc:** a modified libc only helps programs that call libc; static binaries,
  musl programs and hand-written assembly would still issue a raw `svc`. Rewriting the instruction
  works for everything on the same CPU, needs no source patches, and costs one pass over the text at
  load time (measured: 2 sites in each CI guest, ~microseconds).
- **What is implemented:** `UbuntuPadCore.CodePatch` finds the sites; `UbuntuPadHost` traps them.
- **Open:** code the guest generates at runtime (a JIT of its own) is not patched; the first dynamic
  `svc` becomes a Darwin syscall and the run ends with `exit=breakpoint`. That is honest, documented
  behaviour and belongs to the same problem as dynamic linking (milestone B5).

### 1.2 Processes and fork — the next big one

An iOS app cannot create processes, so every Linux process lives **inside** the app.

- **The model (decision 0021, written now, implemented in B3):** a guest process table in the portable
  core. A guest task is one host **pthread**; the guest's CPU state is that thread's own registers
  (we execute natively, so there is no interpreter state to save). Each guest task owns a
  `GuestAddressSpace`; tasks in one `CLONE_VM` group share it.
- **`clone`** is modelled, not forwarded: `CLONE_VM` shares the address space, `CLONE_FILES` shares the
  fd table, `CLONE_FS` shares cwd/root, and `CLONE_SIGHAND` shares dispositions (with Linux's required
  flag dependencies validated); `CLONE_THREAD` joins the thread group. A host pthread starts the child.
  Without `CLONE_VM` the child gets a **copy** of the parent's address space (see 1.3 — with native
  execution there is no lazy copy-on-write to be had).
- **`fork` is `clone` without `CLONE_VM`**, exactly as iSH does it: only the calling thread survives
  into the child, pending signals start empty, and the child's PID differs.
- **`fork` + `execve`** is special-cased: the child builds the new image, stack and auxv *before*
  committing, then adopts them in place — the guest PID and most descriptors stay, so shells that
  `fork`-`exec` every command keep working.
- **`execve`** replaces the program image of the calling task: validate, then remap. Threads of the
  process except the caller are removed, caught dispositions reset (per `execve(2)`).
- **`wait4`/`waitid`** are served from the process table (zombies included); a blocking wait sleeps on
  guest state rather than on a host `waitpid` that would have nothing to wait for.
- **Signals:** dispositions are per process, masks and pending sets are per task; delivery constructs a
  guest signal frame and redirects the guest PC. A host signal is only ever used to wake a blocked
  pthread.
- **Prior art:** iSH (its `fork.c` routes `fork` through `clone`, copies the guest `mm` when
  `CLONE_VM` is absent, and starts tasks with `pthread_create`), QEMU linux-user (warns that raw host
  `clone` breaks libc and maps only thread-like flag combinations to `pthread_create`). See
  [RESEARCH/process-model-without-fork.md](RESEARCH/process-model-without-fork.md).

### 1.3 Memory — mostly decided, one measurement outstanding

- **Decided (0011, 0018, 0019):** a guest address *is* a host address; 4 KiB guest pages are modelled
  over 16 KiB host pages; a host page gets the **union** of the protections of the guest regions inside
  it; the low 4 GiB is a kernel reservation, so images are placed at a bias and their relative
  relocations applied rather than forced to their link address.
- **The consequence nobody expects:** because guest code writes through ordinary host pointers, a
  software page table cannot intercept its writes, so **fork cannot be lazy copy-on-write**. A forked
  child's private regions are copied eagerly (`mmap` + `memcpy` of the live bytes). iSH can afford lazy
  COW because its interpreter sees every guest write; we trade that for native speed. This is the
  single most important memory consequence of the native-execution choice and it is why the process
  model in 1.2 is written the way it is.
- **Open:** `com.apple.developer.kernel.increased-memory-limit` and
  `com.apple.developer.kernel.extended-virtual-addressing` — which signing routes actually preserve
  them, and what the app's real ceiling is on the owner's iPad. Apple documents both as
  model/membership-dependent and provides `os_proc_available_memory()` to query the limit at runtime;
  nothing in the documentation promises a number. The app therefore **reports** the number instead of
  claiming one (milestone B2 puts this in the diagnostics screen).

### 1.4 Files and kernel interfaces — designed, not built

- **VFS:** an Ubuntu arm64 rootfs unpacked into the app's Documents directory; `openat`/`read`/`write`/
  `lseek`/`fstat`/`unlink`/`rename`/`statfs` mapped onto host `open`/`read`/… with a path translation
  layer (guest `/` → rootfs, guest `/dev` → emulated). Read-only rootfs plus a writable overlay is the
  target, because the owner will never debug a broken rootfs.
- **Emulated filesystems:** `/proc` (a synthesised tree: `/proc/self`, `/proc/meminfo`, `/proc/cpuinfo`,
  `/proc/self/maps`, `/proc/self/status`), `/dev` (`null`, `zero`, `urandom`, `tty`, `fd/0..2`), a
  minimal `/sys` with the values programs actually read, and a `/tmp`.
- **Objects:** pipes (with real endpoint reference counts, so EOF and `EPIPE` behave), Unix sockets,
  `eventfd`, `epoll`/`poll`/`select`, `futex` (`FUTEX_WAIT`/`WAKE`/`REQUEUE` over a guest-address
  keyed table), `timerfd`, `clock_nanosleep`, and pseudo-terminals (a pty pair backed by a
  ring buffer in the runtime, since iOS has no `/dev/ptmx`).
- **Ordering:** pipes and `wait` belong with B3 (a shell needs them); the rootfs, `/proc` and dynamic
  linking belong to B5; LTP is the judge (milestone B6) with the pass rate published in STATUS.md.

### 1.5 Graphics — planned after userland exists

Research (written into [RESEARCH/desktop-graphics-path.md](RESEARCH/desktop-graphics-path.md)) says:

- **Xvfb is the smallest viable X server** for this job: the manual documents that it needs neither
  display hardware nor physical input devices, and it can expose its framebuffer as a shared-memory
  segment or a memory-mapped file. Xfbdev needs `/dev/fb` and is obsolete; TinyX drops XKB/XInput;
  Xephyr needs a parent display; Xwayland needs an existing compositor.
- **Do not copy whole frames.** At 2360×1640 a 32-bit frame is ~14.8 MiB; a 30 fps full-frame copy is
  ~443 MiB/s of one-way traffic. The bridge watches the X **Damage** extension and publishes changed
  rectangles over a shared mapping into a Metal view, coalescing before it copies.
- **Input:** iOS touch/keyboard/trackpad events become **XTest** events (`XTestFakeKeyEvent`,
  `XTestFakeButtonEvent`, `XTestFakeMotionEvent`) — an X protocol request, so no `/dev/uinput` and no
  evdev, neither of which exists here.
- **Wayland later, if at all:** a headless wlroots/Weston + Pixman compositor still needs its own
  output-capture and input plumbing, so it is strictly more work for the same desktop.
- **systemd is out of scope** (decided long ago): the session is launched from our own init that starts
  the X server, the window manager and the panel in the right order.

### 1.6 Where the pieces live

```
UbuntuPadCore     portable policy: ELF, placement, relocations, patches, address space, stack,
                  syscall table + dispatcher, process table (B3), VFS (B4+)   ← unit-tested on Linux
UbuntuPadHost     C shim: mmap primitives, guest entry trampoline, SIGTRAP handler, probe
UbuntuPadRunner   the run pipeline: GuestRunner (library)
ubuntupad-run     CLI on top of UbuntuPadRunner — machine-readable, asserted by CI
UbuntuPad.app     the iPad shell: links UbuntuPadRunner and runs the same pipeline behind a button
```

The split is deliberate: everything that can be *policy* is in the portable core and is tested on a
free Linux runner; only the machine-level facts live in C/Swift on the Apple side.

---

## 2. Milestones

Each one states its exit criterion the way the mission requires: an automatable test wherever that is
possible, and a labelled device item where it is not.

| # | Milestone | Exit criterion (CI unless marked) | State |
| --- | --- | --- | --- |
| **B1** | A static PIE arm64 Linux program runs end to end on Apple silicon | the guest's stdout asserted byte for byte, with a control run proving the relocation pass is load-bearing | **done** — run 38745174715 |
| **B2** | The same program runs **inside the iPad app**, and the device answers the executable-memory question | `build-ipa` green with the guest program verified inside the IPA; on-device: the app prints the guest's message and its memory probe result | **in progress** (real-device half is *unverified on device*) |
| **B3** | Two guest processes: `fork`/`clone`, `wait`, pipes, signals between them | a guest that forks, writes a message down a pipe and has the parent wait for it, asserted in `runtime-e2e` | not started |
| **B4** | A shell: static busybox `sh`, then bash | CI runs a **shell script** (pipes, redirection, exit codes) inside the runtime — Phase 3's exit criterion | not started |
| **B5** | Dynamic linking and a real rootfs | a dynamically linked glibc program (with `ld-linux-aarch64.so.1` as a guest) runs; then an Ubuntu arm64 rootfs where `apt` can install a package | not started |
| **B6** | Kernel interfaces at scale | a Linux Test Project subset runs; the pass rate is published in STATUS.md and rises between sessions | not started |
| **B7** | A desktop on the iPad | XFCE/LXQt over Xvfb rendered into a Metal view with damage rectangles; touch and keyboard via XTest | not started |
| **B8** | Polish | stability, swap-like offload, onboarding, website | not started |

**Dependency order, and why it is this order:** B2 exists because nothing is proven until the runtime
runs on a real device, and its probe result decides how much of B5–B7 is even possible. B3 comes before
B4 because a shell without processes, pipes and `wait` is not a shell. B5 comes before B6 because LTP
binaries are dynamically linked. B7 comes last among the hard work because a desktop on top of a
userland that cannot `fork` or `open` a file is a screenshot, not a system.

---

## 3. The next five tasks (kept in step with STATUS.md)

1. **B2, device half:** the app has the run button and memory probe; the owner still needs the
   four-step checklist (install, enable JIT, tap Run on both programs, paste the diagnostics block into
   an issue). The probe is permission-only: only a successful guest run proves execution on device.
2. **B3, continue:** connect the portable task table to clone syscall validation, then add host pthread
   creation and address-space-copy plumbing. `GuestProcessTable` is the first tested slice: it models
   resource sharing and zombies, but does not claim to create threads or copy mapped pages yet.
3. **B3, second slice:** `clone`/`fork`/`wait4` services plus pipes, and the fork-and-pipe guest in
   `runtime-e2e`.
4. **B4:** static busybox from a pinned, checksummed release, run `sh -c` in CI.
5. **B5, first slice:** `PT_INTERP` and symbol-based relocations — the dynamic loader — with the
   hello-world from Ubuntu's own archive as the test.

---

## 4. What could kill this, and what we do about it

| Risk | Why it is a risk | Mitigation |
| --- | --- | --- |
| **Executable memory on device** | Apple spends a lot of engineering on stopping unsigned code from executing: pages that are both writable and executable are allowed only under an Apple-only entitlement, and the debugger-attach route (`get-task-allow` + StikDebug/StikJIT) is the only documented way in. Our design never asks for W+X, so it should work — but "should" is not evidence. | The app **measures** it (probe) and reports it in the diagnostics block. If the answer is no, Track A (UTM, which uses the same JIT route) remains the fallback and B7 is unaffected because it renders guest *data*, not guest *code*. |
| **Memory ceiling** | Every guest process, rootfs cache and framebuffer lives inside one app's memory limit; the increased-memory-limit entitlement is model-and-signing dependent. | Report `os_proc_available_memory()`; keep the framebuffer small (scaled, not native); offload to storage later (B8). |
| **No lazy COW** | Eager copy on `fork` makes a shell that forks a lot heavy (see 1.3). | Copy only private, present regions; share read-only mappings; revisit with a mprotect-based write barrier only if measurement demands it. |
| **Dynamically linked programs assume a lot** | Symbol relocations, `PT_INTERP`, TLS, `dlopen`, `getauxval`. | B5 is a milestone in its own right, with a real Ubuntu binary as its test, not a synthetic one. |
| **Software rendering cost** | ~14.8 MiB per frame at iPad resolution. | Damage rectangles, scaled framebuffer, compositor off, measure before optimising. |

---

## 5. Standing rules for Track B work

1. Portable policy goes in `UbuntuPadCore` and is unit-tested on Linux; only the unavoidable machine
   facts go into the host layer.
2. A new syscall arrives with (a) an entry in the syscall table, (b) a dispatcher case, (c) a test in
   `SyscallDispatchTests` that asserts the *policy* (arguments, errno, return value), and (d) a line in
   the README's "not implemented" table removed. `ENOSYS` is recorded, never silent.
3. Every claim in STATUS.md names the run id or the test that proves it, or says *unverified on device*.
4. When a platform rule blocks a design, the rule goes into DECISIONS.md with the measurement that
   revealed it, so no future session tries the same thing again.
