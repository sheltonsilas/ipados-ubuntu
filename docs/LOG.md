# Session log

Newest first. Never delete an entry; correct it with a new one if it turns out to be wrong. Date,
what was done, what was learned, what was left unfinished.

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
