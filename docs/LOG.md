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

**Unfinished / next**

- First CI runs had not been observed at the time of writing; if either workflow is red, fix it
  before starting Phase 1.
- Track A (UTM fork) and Track B (ELF loader) not started.
- Nothing has ever run on a real iPad: every iOS result is **unverified on device**.
