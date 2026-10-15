# Design decisions

Numbered, newest last. Each entry: context, options considered, choice, consequences. **Do not
re-litigate a decision that is recorded here** — if new evidence appears, add a new decision that
supersedes the old one and say so in the entry.

---

## 0001 — Project license: GPL-2.0-or-later

**Date:** 2026-10-14 · **Status:** accepted

**Context.** The project ships two things: our own code, and a Track A app that links QEMU through
UTM. UTM's own code is Apache-2.0; QEMU is GPL-2.0 (mostly "version 2 only", with some files
"version 2 or later"). Husk (GPL-2.0-or-later), Madeira (GPL-3.0-or-later) and iSH (GPL-3.0) are
read-only references — we never copy their code.

**Options.**

1. *Apache-2.0* (matching UTM). Wrong direction: Apache-2.0 code cannot be combined into a
   GPL-2.0-only work, and we intend to distribute a binary that links GPL-2.0 QEMU.
2. *GPL-3.0-or-later*. Attractive, but GPL-2.0-only components (parts of QEMU) cannot be combined
   into a GPL-3.0 work, so the Track A IPA could not be distributed under our license.
3. *GPL-2.0-or-later*. Compatible with GPL-2.0-only third-party code (distribute the combination
   under GPL-2.0 terms), compatible with GPL-2.0-or-later code, and its "or later" option lets a
   downstream recipient combine it into a GPL-3.0 work if they need to (which is what makes
   Apache-2.0 upstream code usable at all, since Apache-2.0 is GPLv3-compatible only).

**Choice:** option 3, **GPL-2.0-or-later**, for every file we write.

**Consequences.**

- We may link QEMU and fork UTM, and we must ship license texts and corresponding-source pointers
  with any IPA containing them (see LICENSES.md).
- Upstream files keep their own headers; we never relicense them.
- If we ever include Apache-2.0 code (e.g. UTM sources) in a distributed binary, the combination
  must be resolved by taking the "or later" option for our own files. This is a known gray area in
  practice (UTM itself distributes Apache-2.0 + QEMU GPL-2.0); we keep our own code GPL-compatible
  so the safest reading stays available, and we do not vendor QEMU source into this repository.

---

## 0002 — Credentials: GitHub CLI OAuth token in the OS keyring, not a PAT in a file

**Date:** 2026-10-14 · **Status:** accepted

**Context.** The project brief asked for a fine-grained personal access token created in the
browser, kept out of every file, log and chat message. Reading a token out of a web page and
pasting it anywhere would put it into the agent transcript, which is exactly a log.

**Options.**

1. Fine-grained PAT created in the browser UI, then set as `GH_TOKEN` in the shell. Narrowest
   permission set, but the value has to pass through the agent's tool output — i.e. into a log.
2. Fine-grained PAT created in the browser, set by the owner outside the agent session. Needs the
   owner to paste a secret into their own terminal; they are not a programmer.
3. **GitHub CLI device-flow login** approved in the browser the agent already controls. The token
   never appears in any tool output; it is written straight into the OS credential store.

**Choice:** option 3. `gh auth login --web` with `--scopes public_repo,workflow`, approved by the
owner in the browser via the device code.

**Consequences.**

- The stored token carries the scopes the GitHub CLI OAuth app already had: `repo`, `workflow`,
  `gist`, `read:org`. That is **wider than we wanted** (we asked for public-repo-only). Recorded
  as a known limitation; the owner can tighten it later by revoking the GitHub CLI app grant at
  <https://github.com/settings/applications> and using a fine-grained PAT instead.
- No fixed expiry: it stays valid until revoked. Renewal is `gh auth login` again (see SETUP.md).
- CI never uses this token: workflows use the built-in `GITHUB_TOKEN`.
- Nothing about the token is committed; only its scopes and renewal steps are documented.
- Related deviation, recorded for honesty: the repository was created with `gh repo create
  ipados-ubuntu --public` rather than through the GitHub web interface as the brief suggested.
  The result is identical (public repo, same name and owner) and it avoids a brittle sequence of
  browser form interactions. GitHub's own LICENSE API was used to fetch the GPL-2.0 text so the
  license file is byte-identical to the canonical text.
- The token's OAuth *app* grant is per-account, not per-repository, so a future session on another
  machine needs the owner to approve a login again — that is expected, not a leak.

---

## 0003 — Deliverable packaging: unsigned IPA assembled in CI

**Date:** 2026-10-14 · **Status:** accepted

**Context.** Sideloading tools (AltStore, SideStore, Sideloadly, TrollStore) re-sign the app with
the owner's own certificate. The build must not need an Apple Developer account.

**Options.**

1. Sign with a real certificate. Needs an Apple account, a provisioning profile and secrets in CI —
   forbidden by the project constraints.
2. `xcodebuild ... CODE_SIGNING_ALLOWED=NO`, then zip the produced `Payload/*.app` into a `.ipa`.
3. Build with `xcodebuild -archivePath`/`-exportArchive`. Requires signing identities to export.

**Choice:** option 2, implemented in `.github/workflows/build-ipa.yml`.

**Consequences.** The IPA contains no signature and no entitlements are enforced by the OS as
built — the sideloading tool signs it. App extensions and entitlement survival depend on the tool
(that table is maintained in SETUP.md). Because we do not sign, we cannot validate entitlements in
CI; CI instead asserts the bundle structure, the arm64 slice, the presence of our entitlements
file in the source, and that no provisioning profile or secret was packaged.

---

## 0004 — Two-track strategy with Track A as a permanent fallback

**Date:** 2026-10-14 · **Status:** accepted

**Context.** iOS forbids loading a kernel and forbids a hypervisor from an app, so a real Linux
kernel can only be emulated (slow, needs JIT). Running Ubuntu arm64 binaries natively on the iPad
CPU with Linux syscalls translated in our own code is far faster but is a multi-month runtime
project.

**Options.**

1. Track B only. Highest performance ceiling, but nothing usable for a long time — bad for a
   long-running project owned by a non-programmer.
2. Track A only (a UTM fork). Usable quickly, but permanently slow and capped by emulation.
3. **Both**, with Track A always kept working and Track B developed behind the same app UI.

**Choice:** option 3.

**Consequences.** Two build pipelines, two sets of risks, more documentation. The app UI must not
assume either backend; Track A ships first and always remains the fallback.

---

## 0005 — Xcode project generated from `project.yml` (XcodeGen) instead of a committed `.xcodeproj`

**Date:** 2026-10-14 · **Status:** accepted

**Context.** The iOS app needs an Xcode project. Agents edit text files and cannot open Xcode; a
hand-written `project.pbxproj` is error-prone and produces unreadable diffs.

**Options.**

1. Commit a hand-written `.xcodeproj`. No CI dependency, but painful for future agents and easy to
   corrupt.
2. Generate it from a small YAML spec with XcodeGen (MIT, installed by Homebrew on the runner).
3. Use Tuist or a Swift script. Heavier, or more bespoke, for no benefit at this size.

**Choice:** option 2. `track-b-runtime/ios/project.yml` is the source of truth; CI runs
`xcodegen generate`.

**Consequences.** One extra CI tool (`brew install xcodegen`). Local iOS builds require XcodeGen
too. Generated projects are git-ignored, so a stale generated project can never be committed.

---

## 0006 — Track B is a platform-independent Swift package with a thin iOS shell

**Date:** 2026-10-14 · **Status:** accepted

**Context.** iOS restrictions make iterating on a device slow and expensive; GitHub's ubuntu-latest
runners are fast and free. Syscall semantics, ELF loading and the memory model do not need an iPad
to be correct.

**Options.**

1. One iOS-only target. Simplest layout, but every test needs a macOS runner and a device.
2. Platform-independent core in a SwiftPM package (`track-b-runtime/core`), tested on ubuntu-latest,
   plus a SwiftUI shell that links it.
3. Write the runtime in C/C++. Portable, but loses Swift's memory-safety tooling and the existing
   Swift toolchain on Linux CI; revisit only if performance demands it.

**Choice:** option 2. `ubuntu-latest` runs `swift test` on the core; the iOS app links the same
sources.

**Consequences.** The core must stay free of Apple-only APIs (`Mach`, `Metal`, `darwin`-specific
calls); those live behind a small platform layer in the iOS shell. Some behaviour (16 KB pages, JIT
permissions, entitlements) can only be verified on a device and is marked as such.

---

## 0007 — No systemd in the guest or the runtime

**Date:** 2026-10-14 · **Status:** accepted

**Context.** systemd expects a real kernel: cgroups v1/v2, `mount`, `kmod`, `udev`, PID 1 semantics
with privileged operations. Neither the emulated guest (Track A) nor a translated runtime
(Track B) can honour that faithfully, and chasing it would burn entire sessions.

**Options.** (1) Fight to run systemd; (2) run a minimal init; (3) run the desktop session directly.

**Choice:** a custom minimal init that mounts what it can and execs the desktop session. In Track A
the kernel is real QEMU-emulated Linux, so systemd *can* run there, but the guest image is
configured to avoid it by default for boot speed; in Track B it is out of scope entirely.

**Consequences.** Documented here so no future session re-researches it. Guest images define services
explicitly instead of relying on systemd units.

---

## 0008 — Syscall capture: decide after the Phase 2 spike, with a documented default

**Date:** 2026-10-14 · **Status:** proposed (to be resolved in Phase 2)

**Context.** Darwin has no Linux `seccomp`/`SIGSYS` contract, so guest `svc` instructions cannot be
trapped the way `gVisor` traps them on Linux (see `docs/RESEARCH/syscall-translation-prior-art.md`).
Mach exception ports exist, but there is no evidence that an ordinary sandboxed iOS app can use them
to intercept all normal syscalls.

**Options.**

1. **Interpret/translate guest instructions** and dispatch `svc` inside the runtime. The
   best-supported precedent (iSH, ios-linuxkit), but slow unless combined with ahead-of-time
   translation, and native-speed execution is the whole point of Track B.
2. **Rewrite `svc` instructions at load time** to call our handler (patched trampolines). Keeps
   native execution for the bulk of the code, needs W^X handling, and must cope with static
   binaries, JIT-generated code and self-modifying code.
3. **Ship a patched libc** (musl/glibc) whose syscall wrappers call our handler directly. Simplest
   for dynamically linked programs, cannot cover static binaries or hand-written `svc`.

**Provisional choice:** 3 for dynamically linked Ubuntu userland, plus 2 for everything else, with 1
kept as the correctness fallback for hard cases. Phase 2 must measure whether 2 is fast enough
before this is accepted; until then this entry stays **proposed**.

**Consequences.** Phase 2 starts with the loader and the dispatch table (useful under every option)
and defers the capture mechanism. Any change here must update this entry, not replace it.

---

## 0009 — Runner images are pinned, not floating labels

**Date:** 2026-10-14 · **Status:** accepted

**Context.** The brief suggested `ubuntu-latest`, and CI does need to stay free and GitHub-hosted.
The first successful run's log carried a warning that **the `ubuntu-latest` label migrates to
Ubuntu 26 beginning 2026-10-19**. The core tests depend on a Swift toolchain being present on the
image, and CI cannot test Swift on any other platform we have (the agent machine has no Swift,
and macOS runners are slower and metered). A silent image change could therefore turn every green
build red for reasons unrelated to this project.

**Options.**

1. Keep `ubuntu-latest` and react if it breaks. Fewest keystrokes, but the failure would appear
   unattributed in whatever future session happens to push next.
2. Pin `ubuntu-24.04` and upgrade deliberately. Slightly more maintenance, but a runner image
   change becomes a decision instead of an accident.
3. Pin by digest/self-hosted. Not possible or not allowed here.

**Choice:** option 2 — `ubuntu-24.04` for both jobs in `tests.yml`; `macos-15` is already pinned in
`build-ipa.yml`.

**Consequences.** When a new image is worth adopting (for example an Xcode or Swift version we
want), that is an explicit commit. If `ubuntu-24.04` is ever retired, the fix is a one-line change
plus a note here and in `docs/STATUS.md`.

---

## 0010 — Track B executes guest code on an Apple-silicon runner, not in an emulator on Linux

**Date:** 2026-10-15 · **Status:** accepted, phase 2

**Context.** Track B's reason to exist is running a Linux arm64 binary *natively on the iPad's CPU*.
A test that runs that binary inside an emulator on an x86_64 Linux runner would prove nothing about
the design that actually ships.

**Options.**

1. Test only on the iPad. Slowest possible loop, and nothing is verifiable in CI at all.
2. Run the guest under QEMU user-mode on the Linux runner. Cheap, but it tests QEMU, not our trap
   handler, our page-size bridging or our entitlements story.
3. **Run the guest natively on a `macos-15` GitHub runner.** Same architecture (arm64), same 16 KiB
   pages, same code-signing rules and the same kernel as the iPad. The only difference is that the
   runner is not sandboxed like an iOS app.

**Choice:** option 3. Guest binaries are cross-compiled cheaply on `ubuntu-24.04` (no toolchain
bloat in the macOS job) and handed over as a build artifact; `runtime-e2e.yml` runs them and asserts
stdout between explicit markers.

**Consequences.**

- The 16 KiB page size is exercised for real, not simulated: the CI job fails if the host does not
  report 16384-byte pages, because that condition is the point of the test.
- macOS runners are slower and metered, so the heavy cross-compilation stays on Linux.
- What this still does **not** prove: iOS sandbox behaviour (JIT, entitlements, memory limits). Those
  stay marked *unverified on device* until the owner reports from the iPad, as AGENTS.md requires.

---

## 0011 — Identity mapping: a guest virtual address *is* a host virtual address

**Date:** 2026-10-15 · **Status:** accepted, phase 2

**Context.** A Linux executable is linked for specific virtual addresses (0x400000 for a classic
ET_EXEC). The guest dereferences raw pointers: `write(1, 0x400123, 13)` passes an address, and the
address has to mean the same thing to guest and runtime, or every pointer the guest computes has to
be translated.

**Options.**

1. **Identity mapping**: map the image at exactly its link-time addresses. Guest pointers are host
   pointers; the syscall services can validate and use them directly. Requires the addresses to be
   free in the host process.
2. A separate guest address space with translation on every access. Correct for arbitrary guest
   addresses, but every guest memory access inside the runtime needs a translation step, and guest
   code that computes pointers (all of it) still needs link-time addresses to be valid *somewhere*.
3. Relocate the image to a free base. An ET_EXEC has no relocation information, so this means
   rewriting absolute addresses — not possible in general.

**Choice:** option 1, with the address-space model still recording regions and protections so that
option 2 can be layered underneath later without redesigning the callers.

**Consequences.**

- The loader must *verify* that the mapping landed at the requested address and refuse to run
  otherwise; a silently relocated image would take wild pointers (see decision 0015 for the one
  case where the fix is a link-time flag rather than a relocation).
- Guest `mmap` returns real host addresses, so guest and host views stay identical.
- ET_DYN (PIE) images need a load bias before they can be mapped this way; `InitialStackBuilder`
  already takes `loadBias` so the change is localised, and the loader refuses a PIE image today with
  a message that says so.

---

## 0012 — Syscall capture: rewrite `svc #0` to a breakpoint and handle SIGTRAP

**Date:** 2026-10-15 · **Status:** accepted, phase 2 — resolves the mechanism half of decision 0008

**Context.** On Darwin a guest `svc #0` is not a Linux syscall: it enters the Darwin kernel, which
interprets it with Darwin's own numbering (taken from x16). Every one of them must be intercepted
before the guest runs. Decision 0008 left the mechanism open and listed three families
(interpretation, load-time rewriting, a patched libc).

**Options, within load-time rewriting.**

1. Replace each `svc` with a **branch to a generated trampoline** that saves registers, calls Swift,
   restores them and returns. Documented precedent (`svc-hook`). Needs writable *and* executable
   pages to place the trampolines, and `b` only reaches ±128 MiB, so a trampoline island has to be
   allocated near the guest image.
2. Replace each `svc` with **`brk #0x123`** and handle `SIGTRAP`: the signal context *contains* the
   full register file, so no trampoline, no code generation and no W+X mapping is needed. The
   handler reads x8 and x0-x5 from the context, services the syscall, writes x0, advances the
   program counter past the breakpoint and returns.
3. `ptrace`/debugserver, or a Mach exception port. Either needs a debugger relationship or a
   privileged port; no evidence that an ordinary iOS app can rely on it (see
   `docs/RESEARCH/syscall-translation-prior-art.md`).

**Choice:** option 2.

**Consequences.**

- The text is written while the image is still writable and is made executable afterwards, so the
  process never holds a writable-and-executable page. That is what keeps the design viable on a
  non-jailbroken iOS device (see `docs/RESEARCH/jit-and-entitlements-on-ios.md`), and the runner's
  `probe` mode reports the kernel's answer instead of assuming it.
- Instruments compiled by a future session must not use `brk #0x123`: the handler distinguishes "our"
  syscall trap from a guest breakpoint by the instruction word at the program counter, and a genuine
  `brk` ends the run with `exit=breakpoint`. The sentinel is pinned by a unit test.
- Code the guest generates at runtime is not patched, so a JIT inside the guest (or a self-modifying
  program) would make a Darwin syscall instead. That is a documented Phase 2 non-goal; a guest that
  does it fails at the first dynamic `svc`.
- This does not resolve the *dynamic* half of decision 0008: a dynamically linked Ubuntu program still
  needs a loader (Phase 4), and a patched libc may still be the better answer for it.

---

## 0013 — `macos-15` is pinned for the guest-execution job too

**Date:** 2026-10-15 · **Status:** accepted, phase 2

**Context.** `runtime-e2e.yml` depends on two properties of the runner that must not change silently:
arm64 and **16384-byte pages**. Decision 0009 pinned the Linux image for the same class of reason.

**Choice:** `runs-on: macos-15`, and the job asserts `uname -m` is `arm64` and that the host reports
16384-byte pages. If the runner ever stops being arm64 or stops using 16 KiB pages, the job fails
loudly with a message that names the assumption rather than quietly passing a weaker test.

**Consequences.** A future image upgrade is an explicit commit. `macos-15` is also what UTM's iOS
sysroot is built on (decision 0017), so the two macOS jobs are pinned together on purpose.

---

## 0014 — Build workarounds in the fork are recorded, not left in the workflow

**Date:** 2026-10-15 · **Status:** accepted, phase 1

**Context.** Two UTM fork runs in a row failed for infrastructure reasons, not code reasons, and both
times on the same host. `gstreamer.freedesktop.org` first closed HTTP/2 streams mid-download from
GitHub's macOS runners (curl error 92), then answered **HTTP 503** to every attempt. UTM's dependency
script gives up after five attempts and the whole sysroot build — tens of minutes of QEMU
compilation — is lost. Note that the three GStreamer tarballs are genuinely part of the **iOS**
sysroot (SPICE server), so "skip what iOS does not need" is not available.

**Options.**

1. Skip GStreamer. Not possible: `build_qemu_dependencies` builds it unconditionally, for every
   platform.
2. Mirror the tarballs as assets of our own release and fetch them from there. Works, but it makes a
   third-party source archive part of this project's supply chain, with the checksum/provenance work
   that implies — kept in reserve if the fixes below are not enough.
3. **Make the fetch patient and repeatable, and pre-seed the files the build would re-fetch.**

**Choice:** option 3, in two parts, both written next to the step that does them:

- `~/.curlrc` sets `http1.1`, `retry = 10`, `retry-delay = 15`, `retry-max-time = 900` for every curl
  in the build (curl retries 5xx itself, so a transient outage becomes a slower build, not a failure).
- Before the dependency build, the three GStreamer tarballs are fetched into the directory UTM's
  downloader looks in (`build-iOS-arm64/`). UTM's `download()` skips a file that is already present,
  so a successful pre-fetch removes that host from the critical path entirely. The pre-fetch verifies
  each file is a readable archive and only warns if it fails, because the build itself is about to try
  again with the same patience — the error that appears in the log should be the build's own.

**Consequences.** A future session seeing "curl 92" or "503" in this pipeline finds this entry instead
of re-diagnosing it. If upstream switches mirror or fixes the download, both parts can be removed with
a new decision entry. It also explains why a *fork* of UTM can hit this while upstream's CI does not:
upstream builds its sysroots on **self-hosted** runners by default (`IS_SELF_HOSTED_RUNNER` defaults to
true for `utmapp`), while we are on GitHub-hosted machines, whose IP ranges that host treats
differently.

---

## 0015 — The guest runner is linked with a 64 KiB `__PAGEZERO`

**Date:** 2026-10-15 · **Status:** **superseded by 0019** — the technique was measured and it does
not work; kept because the reasoning is what led to the fix, and because a future session will
otherwise propose it again.

**Context.** Every arm64 macOS process reserves a **4 GiB** `__PAGEZERO` at the bottom of its address
space. A Linux executable is linked at 0x400000 — inside that reservation — so with identity mapping
(decision 0011) the image could not be mapped at its own addresses and the runner refused to start.
This is a genuine, load-bearing platform fact, not a detail.

**Options.**

1. Relocate the guest (impossible for ET_EXEC without relocation info).
2. Change the guest's link address (only possible for programs we build; real Ubuntu binaries are
   linked at 0x400000, so this would test something that never ships).
3. Map over the reservation with `MAP_FIXED` (discards whatever is there; only safe because the
   reservation is the running binary's own, and never holds live data).
4. **Link the runner itself with `-pagezero_size 0x10000`**, shrinking its own reservation to 64 KiB
   so the low 4 GiB is ordinary mappable memory. 64 KiB is still enough to catch a null dereference.

**Choice:** option 4 as the primary mechanism, option 3 kept as an explicit fallback.

**Consequences.**

- The load path is: try a plain hint; if it lands elsewhere, check that the whole image fits inside
  the host's reserved region (read from the loaded Mach-O header, not assumed) and *only then* use
  `MAP_FIXED`. Anything else fails loudly with an error naming the address, the errno and the flag.
- The run output says which mechanism was used (`image_mapping=hint` or
  `image_mapping=replace-reserved-low-region`) and the probe prints the reservation size, so the
  fallback can never be silent.
- `-pagezero_size` reaches the linker through SwiftPM `unsafeFlags`, which is only permitted for a
  root package. This package is therefore not usable as a dependency; acceptable, and reversible.

**Superseded (2026-10-15).** The flag *does* pass the linker, and the binary it produces is killed by
the kernel before `main` runs (`Killed: 9`, exit 137, no output at all). Research into XNU's loader
plus the observed behaviour settled that the 4 GiB reservation is a kernel rule for arm64, not a free
region that happens to be reserved, so `MAP_FIXED` cannot reach below it either. The measurement and
the replacement design are decision 0019.

---

## 0016 — The guest runner is an executable target, not an XCTest bundle

**Date:** 2026-10-15 · **Status:** accepted, phase 2

**Context.** The end-to-end run needs to execute guest code. On macOS that requires the process to have
the JIT/executable-memory entitlements *if* the kernel refuses an executable mapping (decision 0012
expects it not to).

**Options.**

1. Run the guest inside `swift test`. Simple, but on macOS the test bundle is loaded by the `xctest`
   binary, so entitlements would have to be applied to that binary — not something a repository can own.
2. **Build a small executable (`ubuntupad-run`) in the same package and run it from CI**, with the
   entitlements fallback in decision 0015's plist. The executable can be signed (or re-signed) by the
   workflow, and its output format can be asserted byte for byte.
3. An iOS app only. No CI verification at all.

**Choice:** option 2. Every *pure* part of the runtime stays a unit test in `swift test` (ELF parsing,
address-space arithmetic, stack layout, syscall policy); only the part that needs real memory and real
traps moves into the executable.

**Consequences.** Two test entry points to keep in step, and the unit tests must not grow a dependency
on the executable. In exchange, the syscall *policy* is fully tested on a free Linux runner, and the
mechanism is tested once, on the platform that matters.

---

## 0017 — Track A lives in a fork; this repository holds the build definition

**Date:** 2026-10-15 · **Status:** accepted, phase 1

**Context.** Phase 1 needs UTM's iOS target built as an unsigned IPA in CI. UTM's own build workflow
is a large matrix over nine sysroots plus macOS and visionOS apps; running it as-is would burn hours
per attempt on things this project does not ship. QEMU must not be vendored into this repository
(decision 0001), so a git subtree of UTM was never an option either.

**Options.**

1. Vendor UTM into `track-a-utm/`. Hundreds of megabytes, and the QEMU sources would have to be
   committed.
2. Use upstream's workflow unchanged via `workflow_dispatch` in a fork. Runs the nine-sysroot matrix
   for one product.
3. **Fork UTM into the owner's account and add one trimmed iOS-only workflow to the fork**, keeping the
   definition of that workflow in this repository (`track-a-utm/ci/ubuntupad-ios.yml`) and pushing it
   with a script (`track-a-utm/tools/push-fork-ci.sh`).

**Choice:** option 3.

**Consequences.**

- Two repositories, one of which (the fork) is only ever touched by that script; a future session can
  reproduce the fork's CI from this repository alone.
- The fork's CI publishes to a rolling `ios-nightly` release using its own `GITHUB_TOKEN`, and this
  repository's CI can consume that public asset anonymously. A cross-repository `workflow_dispatch`
  would need a personal access token, which the project forbids, so the fork is triggered by hand (or
  by a push to its `ubuntupad-ci` branch) instead.
- The sysroot is cached and uploaded as an artifact in the fork, because rebuilding QEMU for iOS from
  source is the expensive part of the build.

---

## 0018 — On a 16 KiB host, a guest page gets the **union** of its regions' protections

**Date:** 2026-10-15 · **Status:** accepted, phase 2

**Context.** Apple silicon has 16 KiB pages; a Linux guest is linked for 4 KiB pages. Two guest
segments with different protections (read-only `.rodata` and read-write `.data`, or text and data if
the linker packs them tightly) can therefore land in one host page, and the host can only protect whole
pages.

**Options.**

1. Refuse the protection change (EACCES/EINVAL). Breaks legitimate programs for a property they cannot
   see.
2. Narrow: give the page the *intersection* of the rights. Silently un-maps or un-executes something
   the guest needs.
3. **Widen: give the page the union** of the rights, and report that the merge happened.

**Choice:** option 3, in `GuestAddressSpace.hostPageProtectionPlan()`. Widening is what Linux itself
does with a sub-page range, and it is the only option that cannot break a correct guest.

**Consequences.** A read-only guest page can share a host page with a writable one, so the hardware
protection is coarser than the guest believes. That is a documented consequence of 16 KiB pages on Apple
silicon (not of this implementation), and it is visible: the run output reports `merged_pages=N`, and a
unit test asserts both the merge (16 KiB) and the absence of a merge (4 KiB).

---

## 0019 — The low 4 GiB cannot be used at all, so guest images are *placed* at a bias and relocated

**Date:** 2026-10-15 · **Status:** accepted, phase 2 (supersedes 0015)

**Context.** Decision 0015 tried to make the low 4 GiB usable so that a Linux executable linked at its
usual 0x400000 could be mapped at its own addresses. Two mechanisms were tried in CI, and **both
failed**, in ways that are easy to misread as unrelated bugs:

- **Shrinking the runner's own reservation at link time** (`-Xlinker -pagezero_size 0x10000`). The
  build succeeded, `.build/release/ubuntupad-run` was produced, and every invocation of it was killed
  by the kernel before `main`: bash reported `Killed: 9`, exit status 137, with no output at all — not
  even the version line. The same binary with the flag removed ran normally.
- **`MAP_FIXED` over the reservation.** The kernel refuses it, so the mapping never lands where it was
  asked for. (This was the fallback path in the old `mapImage`.)

Research into XNU's Mach-O loader confirmed why: on arm64 the loader *requires* a 4 GiB `__PAGEZERO`
(`LOAD_BADMACHO` otherwise) and refuses to map below it. This is a kernel rule, not an empty region —
which also explains the silent SIGKILL for a shrunken reservation.

**Options.**

1. Keep fighting for the address (patch the guest's link address, patch XNU, use a debugger). Not
   possible for binaries we do not build, and real Ubuntu binaries are the whole point.
2. Refuse every image that is linked below 4 GiB. Honest, but the runtime would run almost nothing on
the platform it exists for.
3. **Place the image where it *can* live and make it correct for that base**: decide identity vs bias
   from the image's own type, and apply the image's relative relocations before mapping, which is what
   a position-independent binary expects the loader to do anyway.

**Choice:** option 3, implemented in the portable core (`ImagePlacement`, `Relocations`) so every branch
is testable on Linux, where the floor does not exist:

- **ET_DYN (PIE)** — any bias works provided it keeps the image's alignment, so the image is moved
  above the floor (default target 8 GiB) and its `R_AARCH64_RELATIVE` relocations are applied. This is
  what Ubuntu ships for arm64, so it is the path real programs take, not an exotic one.
- **ET_EXEC above the floor** — mapped identity: it is already where it can live.
- **ET_EXEC below the floor** — **refused**, with a message that names the linked address, why forcing
  it cannot work, and that a position-independent build would run.
- Symbol-based relocations (`R_AARCH64_ABS64`, `_IRELATIVE`, ...) are collected and *refused* rather
  than partially applied: an image with some of its relocations applied looks alive and reads garbage.
- Relocations that target zero-filled memory (`.bss`) are refused too, because the runtime patches the
  image *before* mapping it and those bytes have nothing in the file to patch.

**Consequences.**

- `MAP_FIXED` is gone from the host layer; there is one mapping rule, a hint that must be honoured, and
  a mismatch ends the run with the address and errno. The plist fallback for executable memory
  (decision 0016) is unaffected.
- The CI guest programs are now built `-static-pie`, and `hello-pie-nostdlib.c` prints through a
  `volatile` global pointer so that the relocation pass has real work to do. `tools/assert-guest-run.sh`
  asserts three things that could not all pass if the pass were decorative: the relocated guest prints
  its message, the *same* guest run with `--skip-relocations` does **not**, and the fixed-address build
  is refused with a reason. `readelf` checks in the workflow fail the build if the toolchain ever stops
  emitting that relocation, so the test cannot quietly become vacuous.
- A bias is a **suggestion**, and the run treats a refused hint as information rather than as a
  failure: on `macos-15` a hint at 8 GiB was refused outright and the kernel offered 12 GiB instead
  (the dyld shared cache and the platform's own mappings live in that neighbourhood). Because a guest
  address must be a host address, the runner cannot accept the address the kernel offers *unless* it is
  a valid base: it asks `ImagePlacementPlanner` for the next candidate (12 attempts, 16 GiB apart,
  every one of them aligned and above the floor) and also converts the offered address into a candidate
  through the same alignment rule. The run reports which attempt was honoured
  (`image_mapping=biased attempt=2`), and if every candidate is refused the error lists every
  "asked for 0x…, the host offered 0x…" pair.
- Cost: the image is no longer at its link-time address, so the run reports
  `image_placement=biased requested_bias=0x…` and `AT_PHDR`/`AT_ENTRY` carry the base that was actually
  used. Anything that assumed "guest address == link-time address" (including the old `.identity`-only
  tests) had to be re-derived from the bias.
- Still open: a real Ubuntu binary is dynamically linked, so `PT_INTERP` and symbol relocations remain
  Phase 4 work. This decision is what makes *static* PIE images — and therefore the whole path to real
  programs — runnable at all.
