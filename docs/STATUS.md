# Status

_Last updated: 2026-10-14 (Phase 0, session 1)._

## One-line summary

Phase 0 (foundation): the repository, docs skeleton, CI workflows and a trivial iOS app are in
place. **Nothing is verified working until CI reports a green build and a downloadable IPA
exists** — check the badge and the [Releases page](https://github.com/sheltonsilas/ipados-ubuntu/releases)
before trusting any claim below.

## What works

| Item | State | Evidence |
| --- | --- | --- |
| Public repository | Works | <https://github.com/sheltonsilas/ipados-ubuntu> |
| Agent authentication (git push + API) | Works | `gh auth status` → logged in as `sheltonsilas`, token stored in the OS keyring |
| Platform-independent Swift core builds and unit tests | Works | `swift test` in CI (`tests.yml`, ubuntu-latest) |
| Unsigned IPA built by CI | Works | `build-ipa.yml` on macos-15 → artifact + rolling `nightly` release |
| Trivial iOS app launches and shows diagnostics | **Unverified on device** | Only built in CI; never run on an iPad yet |
| Track A (UTM fork) | Not started | Phase 1 |
| Track B (native arm64 syscall runtime) | Not started | Phases 2-5 |

## What is broken / not started

- No UTM fork in `track-a-utm/` yet; there is no usable Linux desktop at all yet.
- No real device testing of any kind. Everything iOS-side is **unverified on device**.
- JIT is not implemented; the app cannot execute generated code yet.
- The app has no VM, no guest image download, no terminal, no graphics.

## Environment facts (agent machine, 2026-10-14)

- Windows 11 + Git Bash tools; `git` and `gh` work, and a browser is available for GitHub web work.
- No local `xcodebuild` / `swift`: every iOS and Swift build is verified **only in CI**.
- The owner is signed in to GitHub in the agent browser as `sheltonsilas`.

## Credentials

- **Authentication in use:** the GitHub CLI OAuth token, stored in the operating system credential
  store (Windows Credential Manager). It is never written to this repository, to CI, or to a log.
- **Scopes:** `repo`, `workflow`, `read:org`, `gist` (the scopes the GitHub CLI app was already
  granted). This is wider than the "public repo only" ideal — a limitation, see decision 0002.
- **Expiry:** no fixed expiry; it stays valid until revoked or until the CLI session is reset.
  Renewal steps for a future agent: [docs/SETUP.md](docs/SETUP.md#agent-credentials).
- **If a token ever leaks:** tell the owner immediately and have them revoke it at
  <https://github.com/settings/applications> (OAuth apps) or
  <https://github.com/settings/tokens> (fine-grained tokens), then re-authenticate.

## Next tasks (in order)

1. Confirm the first CI runs are green and that an IPA is downloadable from Releases. If red, read
   the log with `gh run view --log-failed`, fix, push. (Phase 0 exit criterion.)
2. Fork UTM into the owner's account, vendor it under `track-a-utm/` as a fork/subtree, and get its
   iOS target building as an unsigned IPA in CI. (Phase 1 start.)
3. Add the preconfigured Ubuntu arm64 guest definition (XFCE/LXQt) and first-run image download.
4. Track B: implement the arm64 ELF loader in `track-b-runtime/core` with tests that run on
   ubuntu-latest (Phase 2 start).
5. Add a on-device diagnostics page a non-technical owner can screenshot into an issue.
