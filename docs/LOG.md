# Session log

Newest first. Never delete an entry; correct it with a new one if it turns out to be wrong. Date,
what was done, what was learned, what was left unfinished.

---

## 2026-10-15 — Session 4: Track B planned end to end, and the runtime moved into the app

**Done**

- Wrote [TRACK-B-PLAN.md](TRACK-B-PLAN.md): the six design problems the mission names, what is
  decided about each, the milestones B1-B8 with their exit criteria, the order they have to happen in
  and what could kill the work. Researched the three unknowns first rather than guessing: the process
  model ([process-model-without-fork.md](RESEARCH/process-model-without-fork.md)), the device's
  executable-memory and memory-limit reality (added a second pass to
  [jit-and-entitlements-on-ios.md](RESEARCH/jit-and-entitlements-on-ios.md)) and the display path
  ([desktop-graphics-path.md](RESEARCH/desktop-graphics-path.md)).
- Recorded decision **0020** (the run pipeline is a library the CLI and the app both link, and the app
  carries a guest program CI has verified) and **0021** (the guest process model: one guest task per
  host thread, modelled `clone` flags, and an eager address-space copy because guest writes cannot be
  trapped when the code runs natively).
- Made it real: `GuestRunner` and the syscall session moved into a new `UbuntuPadRunner` library,
  `ubuntupad-run` became a thin CLI over it, and `HostProbe` (the host facts, measured) moved in there
  too so the CLI and the app report the same lines in the same words. The iPad app links that product,
  bundles two guest programs, and shows a Run button, the guest's output and the probe result.
- One place builds the guests: `tools/build-guest-binaries.sh`, called by `runtime-e2e.yml` (which
  executes them), `tests.yml` (which tests the loader against them) and `build-ipa.yml` (which bundles
  two of them), so the guest the owner runs cannot drift from the guest CI proved.
- `tools/verify-ipa.sh` now opens the published artifact and parses the guest's ELF header inside the
  app bundle: AArch64, ET_DYN, no `PT_INTERP`. A packaging or toolchain mistake fails the build instead
  of reaching the iPad.
- Green on `3f2d878`: `tests` 38758466445, `runtime-e2e` 38758466379, `build-ipa` 38758466487, and the
  `nightly` release refreshed with `UbuntuPad-unsigned.ipa` (226,966 bytes).

**Learned**

- **The evidence chain can be checked byte for byte.** The two guest programs in the IPA have the same
  BuildIDs (`7717885b…`, `d7f2ccc6…`) as the ones `runtime-e2e` executed on Apple silicon minutes
  earlier, so "the app carries a program CI has run" is a fact about the artifact, not a hope.
- **`os_proc_available_memory()` does not exist on macOS.** The macOS 15 SDK marks it unavailable and the
  build failed on it — the research note's claim that it is model- and platform-dependent was right, and
  the runtime now answers "will not say" (printed as `available_memory_bytes=unknown`) instead of a
  number nobody measured.
- **SwiftPM assumes iOS 12 for a package that does not declare `platforms:`.** `build-ipa`'s log showed
  the C shim compiled with `-target arm64-apple-ios12.0` while the app targets iOS 16: every availability
  check in the shim was being measured against the wrong minimum. Declared iOS 16 / macOS 13 explicitly.
- The macOS probe *signed nothing*: `rx_mapping=ok` on the runner without entitlements, so the
  write-then-execute strategy still needs no JIT there. On the iPad that remains open, which is exactly
  what the app's probe is for.

**Unfinished / next**

- Nothing has run on a physical iPad. The owner's checklist (install, enable JIT, press Run, paste the
  diagnostics block) is the next task in STATUS.md, and the probe's `rx_mapping=` is the line that
  matters most in the paste.
- Track A is parked by the owner's instruction; fork run 38746321359 was never read, so the GStreamer
  pre-fetch fix is still unproven.
- Phase 3 begins with the guest process table (decision 0021): tasks on host threads, `clone` flags
  classified, `fork`/`wait4`/pipes next, then a shell.

---
## 2026-10-15 — Session 3: the low 4 GiB is a kernel rule, so guest images are placed and relocated

**Done**

- Found *why* the end-to-end run was dying: XNU's Mach-O loader requires a 4 GiB `__PAGEZERO` on arm64,
  so the low 4 GiB cannot be mapped at all. Both mechanisms from decision 0015 were removed — the
  `-pagezero_size` link flag (which links, then produces a binary the kernel SIGKILLs at startup) and the
  `MAP_FIXED` fallback (`up_reserve` now has one mode, a hint that must be honoured).
- Added `UbuntuPadCore.ImagePlacement` (identity vs bias vs refusal, with the reasoning in the refusal
  message) and `UbuntuPadCore.Relocations` (parse `PT_DYNAMIC`, apply `R_AARCH64_RELATIVE`, refuse
  symbol-based and `.bss` relocations rather than half-applying them). Both are pure and portable, so
  every branch is unit-tested on Linux: 12 new tests, including one that parses and applies a real
  `-static-pie` binary's relocations.
- Rebuilt the guest programs as `-static-pie`. `hello-pie-nostdlib.c` prints through a `volatile` global
  pointer precisely so that the relocation pass has real work to do, and `tools/assert-guest-run.sh`
  asserts the trio that cannot all pass by accident: the relocated guest prints its message, the same
  guest with `--skip-relocations` does not (it faults, exit 11), and the fixed-address build is refused
  with a reason. The workflow fails the build if `readelf` ever stops finding that relocation, so the
  test cannot quietly become vacuous.
- **First green Phase 2 end-to-end run**: `runtime-e2e` 38745174715 on commit `25eb56e` (with `tests`
  38745174521 and `build-ipa` 38745174900). The guest printed its message byte for byte at a 448 GiB
  bias, with one relative relocation applied, and the stack probe saw `pagesz=4096` and a biased
  `AT_ENTRY`.
- Track A: pushed the resumable, verified GStreamer pre-fetch (fork run 38746321359) after the previous
  attempt died mid-download.

**Learned**

- A platform rule is worth more than a workaround. Shrinking `__PAGEZERO` at link time *builds*
  successfully and then fails only at exec time, silently (`Killed: 9`, exit 137) — the kind of
  "unrelated" failure that would have consumed a whole session had it not been measured against a
  controlled binary.
- **A hint is not a reservation.** On `macos-15` a hint at 8 GiB was refused, twelve candidates between
  64 GiB and 240 GiB were refused, and 448 GiB was accepted — that is where XNU puts hinted mappings.
  The runtime now adapts: it walks a candidate list from the planner and also converts the address a
  refused hint returns into a candidate through the same alignment rule. The first green run was placed
  by the *adaptive* candidate (attempt 13), so the fallback is not theoretical.
- Two CI checks caught their own author: `readelf -r` truncates `R_AARCH64_RELATIVE` to
  `R_AARCH64_RELATIV` (its narrow output) so a real relocation looked like a missing one, and the
  real-binary patch test asserted every site was `svc #0` when a `-static -O0` guest contains one
  `svc`-shaped word with a non-zero immediate. Both were fixed by asserting the real invariant.
- `runtime-e2e` reports `rx_mapping=ok` **unsigned**: on the runner the write-then-execute strategy needs
  no JIT entitlement. On the iPad that is still unverified.
- `gstreamer.freedesktop.org` is still unhealthy from a third network (503 on a plain `HEAD`), so Track
  A's blocker is the host, not the runner. Truncated transfers (curl 18) are resumable, which is now
  what the pre-fetch does.

**Unfinished / next**

- Phase 1 still has no IPA: fork run 38746321359 was dispatched and is the thing to read next.
- The runtime is not wired into the iOS app; no device test of anything.
- `fork`/`clone`/`execve`, threads, signals, guest TLS and a filesystem remain Phase 3-4 work, and a real
  Ubuntu binary is dynamically linked, which is Phase 4.

---

## 2026-10-15 — Session 2: Track A's CI definition and Track B's runtime, from skeleton to executing guest

**Done**

- Track A: forked UTM to `sheltonsilas/UTM`, kept the iOS-only workflow definition in this repository
  (`track-a-utm/ci/ubuntupad-ios.yml`) and added `track-a-utm/tools/push-fork-ci.sh` to push and dispatch
  it, so the fork's CI matches this repository exactly (decision 0017). Vendoring or running upstream's
  nine-platform matrix were both rejected.
- Track B: built the Phase 2 runtime end to end — ELF parsing and the `svc` → `brk` patch planner, the
  guest address-space model (4 KiB guest pages over 16 KiB host pages, with protected-page merging), the
  Linux initial stack, the syscall table and dispatcher, the C shim with the SIGTRAP handler and the
  guest entry trampoline, and `ubuntupad-run` as the signed-able test bed (decisions 0011-0018).
- CI: `tests.yml` grew a cross-compile step and real-binary test variables; `runtime-e2e.yml` was added
  to run a cross-compiled Linux guest on `macos-15` and assert its stdout; `tools/assert-guest-run.sh`
  asserts on stdout *between the runner's markers* because a passing exit code proves nothing.

**Learned**

- A test bundle cannot be signed with JIT entitlements, which is why the guest runner is an executable
  target rather than an XCTest bundle (decision 0016).
- The end-to-end job is the only place the platform's real properties (16 KiB pages, executable-memory
  policy, address-space layout) are exercised; unit tests on Linux cover the *policy* instead.
- Runner images move: the `ubuntu-latest` label announced a migration to Ubuntu 26 on 2026-10-19, so both
  jobs were pinned to `ubuntu-24.04` (decision 0009).

**Unfinished / next**

- Track A's first builds died on `gstreamer.freedesktop.org` (curl 92, then HTTP 503), not on UTM's code.
- The guest runner's first real execution attempt failed at the mapping step, which is what session 3
  diagnosed.

---

## 2026-10-14 — Session 1: foundation (Phase 0)

**Done**

- Checked the environment: Windows 11 + Git Bash, `git` and the GitHub CLI work, a browser is
  available, **no local Xcode/Swift** — so all iOS and Swift verification happens in CI.
- Confirmed the owner was already signed in to GitHub in the agent browser as `sheltonsilas`.
- Authenticated the agent with `gh auth login --web` (device flow approved in the browser). The
  token is stored in the Windows credential store and never appeared in a file, log or message.
  See decision 0002 for why this was chosen over a browser-made PAT.
- Created the public repository <https://github.com/sheltonsilas/ipados-ubuntu>.
- Wrote the repository skeleton (`README.md`, `AGENTS.md`, `LICENSES.md`, `LICENSE`, `docs/*`) and
  chose **GPL-2.0-or-later** (decision 0001) for compatibility with QEMU's GPL-2.0 and UTM's
  Apache-2.0.
- Built the Phase 0 deliverables: platform-independent Swift core package with unit tests, a
  SwiftUI diagnostics app, XcodeGen spec, and two CI workflows (unsigned IPA on macos-15; core
  tests + layout checks on ubuntu-latest).

**Learned**

- The GitHub device flow needed **sudo-mode re-authentication** (passkey/authenticator/email code)
  before it would authorize the OAuth app; the email-code path worked and is repeatable.
- The device-flow code box on `github.com/login/device` collapses a pasted 8-character code into
  the first input (which ignores `maxlength` for scripted insertion), which fails validation with
  `reason=not_found`; filling each of the 8 boxes individually works.
- A GitHub CLI OAuth login silently exits without storing anything if its polling fails after a bad
  code entry; re-running the whole flow from scratch is the fix.
- GitHub's OAuth app for the CLI already held `repo`, `gist`, `read:org` grants, so the resulting
  token is wider than `public_repo` — documented as a limitation in STATUS.md and decision 0002.

**CI outcome (same session, later)**

- The first run was red on `tests.yml`: the synthetic `PT_LOAD` fixture declared read+execute flags
  while the test asserted the segment was writable — my own fixture bug, not a parser bug. Fixed by
  using flags `0x7` so all three permission bits are parsed and checked.
- After the fix both workflows passed on `main` (commit `8feff5c`): `tests.yml` run 38598756785 and
  `build-ipa.yml` run 38598756914.
- The IPA pipeline end to end: XcodeGen project generation, unsigned device build, hand-packaged
  `Payload/*.ipa`, CI verification (arm64 slice, unsigned, no provisioning profile or key material,
  no secrets, sane size), artifact upload, and publication to the rolling `nightly` release.
- Independently verified the *public* download path: fetched `UbuntuPad-unsigned.ipa` from the
  release URL with curl, confirmed its SHA-256 matches the published checksum exactly, and listed
  the archive (`Payload/UbuntuPad.app/UbuntuPad`, 328 KB bundle). **Phase 0 is complete.**
- A Windows CRLF checkout risk was caught early and pinned with `.gitattributes` (`eol=lf`), because
  a CRLF shell script would break the Linux runners.
- The tagged-release path (which only runs on `v*` tags and had never executed) was verified by
  publishing `v0.1.0`: the release job published both assets as Latest, and the asset downloaded
  from the public URL matched its published checksum (`4eacbe00…5fd1`).
- Test jobs were pinned to `ubuntu-24.04` after the runner log warned that the `ubuntu-latest`
  label migrates to Ubuntu 26 on 2026-10-19 — a silent toolchain change we do not want to inherit
  (decision 0009).

**Unfinished / next**

- Track A (UTM fork) and Track B (ELF loader, syscall dispatch) not started — that is Phase 1/2.
- Nothing has ever run on a real iPad: every iOS result is **unverified on device**. The next
  device-visible milestone is Phase 1 (a clickable Ubuntu desktop).
