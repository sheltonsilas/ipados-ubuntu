# Roadmap

Phases are **never deleted**, only updated. A phase is finished only when its exit criteria pass
in CI (device-only criteria are marked and stay open until the owner reports on a real iPad).

## Phase 0 — Foundation

- [x] Public repository, GPL-2.0-or-later license, docs skeleton
- [x] `AGENTS.md` so any future agent can continue in minutes
- [x] Platform-independent Swift core package with unit tests in CI (ubuntu-latest)
- [x] CI builds a trivial iOS app into an **unsigned IPA** on macos-15
- [x] CI publishes the IPA as an artifact and to a rolling `nightly` release
- [x] Repository layout check (`tools/check-layout.sh`) in CI

**Exit criteria:** `build-ipa` and `tests` workflows are green on `main`; the `nightly` release
contains a downloadable `.ipa`; the app's bundle contents are inspected and reported by CI.

## Phase 1 — Track A baseline (usable app first)

- [ ] Fork UTM into the owner's account and vendor it under `track-a-utm/`
- [ ] CI builds UTM's iOS target as an unsigned IPA (no Apple account, signing disabled)
- [ ] Preconfigured Ubuntu arm64 guest: XFCE or LXQt, not stock GNOME
- [ ] First-run guest image download from Ubuntu's official servers
- [ ] Optional pre-booted snapshot so the first launch takes seconds, not minutes
- [ ] iPad polish: window sizing, keyboard, trackpad, external display
- [ ] Record measured boot time and responsiveness (owner-reported, real device)

**Exit criteria:** CI produces `UTM-unsigned.ipa`; the owner sideloads it, boots the Ubuntu
desktop and reports back; boot time is written into STATUS.md.

## Phase 2 — Track B core (native arm64 execution)

- [ ] arm64 ELF loader (headers, program headers, relocations) with unit tests
- [ ] Guest address-space model (independent of host page size)
- [ ] Syscall dispatch table for the minimal set: `write`, `exit`, `mmap`, `brk`, `read`
- [ ] Static arm64 "hello world" runs in tests on the ubuntu-latest runner
- [ ] The same binary runs inside the iOS app (unverified on device until tested)
- [ ] Decide and document the syscall-capture mechanism (see DECISIONS: svc rewriting vs patched libc)

**Exit criteria:** CI runs a static arm64 ELF end to end and asserts its stdout.

## Phase 3 — Shell and userland

- [ ] Busybox running, then bash
- [ ] Processes, pipes, signals, pseudo-terminals
- [ ] `fork`/`clone` strategy implemented and documented
- [ ] Terminal view in the iOS app with keyboard input

**Exit criteria:** CI runs a shell script (pipes, redirection, exit codes) inside the runtime.

## Phase 4 — Real Ubuntu userland

- [ ] Dynamically linked glibc programs
- [ ] Ubuntu arm64 rootfs, `apt` working
- [ ] `/proc`, `/dev`, minimal `/sys` emulation
- [ ] Linux Test Project subset running; pass rate tracked in STATUS.md

**Exit criteria:** LTP subset pass rate published and rising between sessions.

## Phase 5 — Graphics and desktop

- [ ] Framebuffer X server (or small Wayland compositor) rendering into a Metal view
- [ ] XFCE/LXQt desktop session launched from a custom init (systemd is out of scope)
- [ ] Touch, keyboard, trackpad input mapping
- [ ] GPU acceleration (virgl / Mesa over MoltenVK) — last, only if feasible

**Exit criteria:** the owner sees and interacts with a desktop on the iPad.

## Phase 6 — Polish and distribution

- [ ] Stability and memory management (swap-like offload to storage)
- [ ] Onboarding flow for a non-technical owner
- [ ] Project website on GitHub Pages
- [ ] Documented release process for tagged milestones
