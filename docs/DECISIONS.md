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
