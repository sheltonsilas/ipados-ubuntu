# Roadmap

Phases are **never deleted**, only updated. A phase is finished only when its exit criteria pass
in CI (device-only criteria are marked and stay open until the owner reports on a real iPad).

Track B's detailed plan — the design problems, the order of work and the milestone exit criteria that
sit behind Phases 2-5 below — is [TRACK-B-PLAN.md](TRACK-B-PLAN.md). This file stays the checklist.

## Phase 0 — Foundation

- [x] Public repository, GPL-2.0-or-later license, docs skeleton
- [x] `AGENTS.md` so any future agent can continue in minutes
- [x] Platform-independent Swift core package with unit tests in CI (ubuntu-latest)
- [x] CI builds a trivial iOS app into an **unsigned IPA** on macos-15
- [x] CI publishes the IPA as an artifact and to a rolling `nightly` release
- [x] Repository layout check (`tools/check-layout.sh`) in CI

**Exit criteria:** `build-ipa` and `tests` workflows are green on `main`; the `nightly` release
contains a downloadable `.ipa`; the app's bundle contents are inspected and reported by CI.

**Met on 2026-10-14** (commit `8feff5c`): `tests.yml` run 38598756785 and `build-ipa.yml` run
38598756914 both succeeded; the `nightly` release asset was downloaded from its public URL and its
SHA-256 matched the published checksum. The app itself is still **unverified on device**.

## Phase 1 — Track A baseline (usable app first)

- [x] Fork UTM into the owner's account (<https://github.com/sheltonsilas/UTM>) and record the
      pinned upstream commit in `track-a-utm/upstream.txt`; the build definition lives here and is
      pushed to the fork by `track-a-utm/tools/push-fork-ci.sh` (decision 0017). UTM is *not*
      vendored into this repository (decision 0001).
- [ ] CI builds UTM's iOS target as an unsigned IPA (no Apple account, signing disabled) — the
      trimmed iOS-only workflow exists and has run; **not yet a downloadable IPA** (see STATUS.md)
- [ ] Preconfigured Ubuntu arm64 guest: XFCE or LXQt, not stock GNOME
- [ ] First-run guest image download from Ubuntu's official servers
- [ ] Optional pre-booted snapshot so the first launch takes seconds, not minutes
- [ ] iPad polish: window sizing, keyboard, trackpad, external display
- [ ] Record measured boot time and responsiveness (owner-reported, real device)

**Exit criteria:** CI produces `UTM-unsigned.ipa`; the owner sideloads it, boots the Ubuntu
desktop and reports back; boot time is written into STATUS.md.

## Phase 2 — Track B core (native arm64 execution)

- [x] arm64 ELF loader: header/program-header parsing, `PT_LOAD` mapping with `.bss` zeroing, and a
      patch planner that finds every `svc` in the executable segments.
- [x] Image placement and relocation: decide identity vs bias from the image (decision 0019 — the low
      4 GiB is a kernel reservation on Apple silicon and cannot be mapped into), apply
      `R_AARCH64_RELATIVE` relocations for the chosen base, and refuse a fixed-address image below the
      floor with a message that says what would work instead.
- [x] Guest address-space model: 4 KiB guest pages over 16 KiB host pages, region bookkeeping,
      buffer validation (a guest bug becomes `EFAULT`, not a host crash) and a host-page protection
      plan that reports merges (decision 0018)
- [x] Syscall dispatch for `write`, `read`, `exit`/`exit_group`, `mmap`, `munmap`, `mprotect`, `brk`,
      `madvise`, `uname`, `clock_gettime`, `getrandom`, `getcwd`, `prctl`, `rt_sig*`, pid/uid/gid/tid;
      everything else answers `ENOSYS` *and is recorded*, so the work list for Phases 3-4 comes from
      running real programs
- [x] Linux initial stack (argc/argv/envp/auxv, `AT_PHDR` derived from the containing segment,
      `AT_PAGESZ` = 4096 on a 16 KiB host) built in the portable core and parsed back by tests
- [x] Decide and document the capture mechanism: rewrite `svc` to a breakpoint and handle SIGTRAP
      (decision 0012) — no generated code, no writable+executable pages
- [x] A static position-independent arm64 "hello" runs end to end in CI and its stdout is asserted —
      green on `macos-15`, with a control run (`--skip-relocations`) proving the relocation pass is
      load-bearing and a refusal test for a fixed-address image (run 38745174715)
- [ ] The same binary runs inside the iOS app. **Implemented** — the run pipeline is a library
      (`UbuntuPadRunner`) the app links, the app bundle carries a cross-compiled guest that
      `build-ipa` verifies inside the IPA, and the screen has a Run button and a memory probe — but
      **unverified on device** until the owner installs it and reports back
- [ ] `fork`/`clone`/exec of a second process — designed in decision 0021 and
      [TRACK-B-PLAN.md](TRACK-B-PLAN.md) §1.2 (one guest task per host thread, modelled `clone` flags,
      eager address-space copy because guest writes cannot be trapped under native execution)

**Exit criteria:** CI runs a static arm64 ELF end to end and asserts its stdout. **Met on 2026-10-15**
(commit `25eb56e`, `runtime-e2e` run 38745174715).

## Phase 3 — Shell and userland

- [ ] Busybox running, then bash
- [ ] Processes, pipes, signals, pseudo-terminals
- [ ] `fork`/`clone` strategy implemented and documented (decision 0021 is the strategy; the
      implementation is milestone B3 in [TRACK-B-PLAN.md](TRACK-B-PLAN.md))
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
