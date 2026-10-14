# Status

_Last updated: 2026-10-14 (Phase 0, session 1)._

## One-line summary

**Phase 0 is complete.** The whole delivery pipeline is proven: CI builds an unsigned IPA on a
macos-15 runner, verifies its structure, publishes it to a public release, and the core test suite
passes on ubuntu-latest. There is **no Linux runtime in the app yet** — it opens a diagnostics
screen. Nothing has been run on a real iPad, so every on-device claim is unverified.

## Verified evidence (2026-10-14, commit `8feff5c`)

| Item | State | Evidence |
| --- | --- | --- |
| Public repository | Works | <https://github.com/sheltonsilas/ipados-ubuntu> |
| Agent authentication (git push + API) | Works | `gh auth status` → logged in as `sheltonsilas`, token in the OS keyring |
| Core unit tests on Linux | **Passing** | `tests.yml` run 38598756785, success on `8feff5c` |
| Unsigned IPA built by CI | **Passing** | `build-ipa.yml` run 38598756914, success on `8feff5c` |
| IPA structure verified in CI | **Passing** | `tools/verify-ipa.sh`: arm64 slice present, unsigned, no provisioning profile, no secrets, bundle 328 KB |
| Public release with a downloadable IPA | Works | <https://github.com/sheltonsilas/ipados-ubuntu/releases/tag/nightly> — `UbuntuPad-unsigned.ipa` (81,780 bytes) + `.sha256` |
| Release asset integrity | Verified independently | Downloaded from the public URL, SHA-256 matched the published value exactly (`290b1e68…6a51`), archive contains `Payload/UbuntuPad.app/UbuntuPad` (arm64) |
| ELF64/AArch64 parsing | Passing (synthetic + real binary) | 8 tests in `ELFTests`, including a real `-static` aarch64 binary cross-compiled in CI |
| Syscall table consistency | Passing | 4 tests in `SyscallTableTests` |
| Diagnostics report model | Passing | 3 tests in `DiagnosticsTests` |
| iOS app launches and shows diagnostics | **Unverified on device** | Built in CI only; never run on an iPad |
| Track A (UTM fork) | Not started | Phase 1 |
| Track B (native arm64 syscall runtime) | Skeleton only | Phases 2-5 |

Known CI limitation: the real-binary ELF test reports **skipped** when `UBUNTUPAD_TEST_BINARY` is
unset (local runs without a cross-compiler). In CI the workflow compiles the binary first, so the
test runs; check the test output rather than only the exit code.

## What is broken / not started

- No UTM fork in `track-a-utm/` yet, so there is no usable Linux desktop at all.
- No real-device testing of any kind: everything iOS-side is **unverified on device**.
- JIT is not implemented and is not even probed; `JITStatus` is deliberately `notProbed`.
- The app has no VM, no guest image download, no terminal, no graphics.
- The credential is wider than ideal (see below).

## CI environment risks to watch

- The tests workflow is **pinned to `ubuntu-24.04`** because the `ubuntu-latest` label migrates to
  Ubuntu 26 on 2026-10-19 and the Swift toolchain on a new image is not something we want to
  inherit silently (decision 0009). If a pin retires, change it deliberately and re-run.
- A GitHub-runner warning on the first runs said the `ubuntu-latest` label would migrate; the
  workflow prints `swift --version` and fails loudly if no toolchain is present, so a surprise
  shows up as an attributed error rather than a mysterious test failure.

## Environment facts (agent machine, 2026-10-14)

- Windows 11 + Git Bash tools; `git` and `gh` work, and a browser is available for GitHub web work.
- No local `xcodebuild` / `swift`: iOS and Swift results are verified **only in CI**.
- The owner is signed in to GitHub in the agent browser as `sheltonsilas`.
- Git checks out files with CRLF locally while storing LF, which is why `.gitattributes` pins
  `eol=lf` for text files — a CRLF shell script would fail on the Linux runners.

## Credentials

- **Authentication in use:** the GitHub CLI OAuth token in the operating system credential store.
  It is never written to this repository, to CI, or to a log.
- **Scopes:** `repo`, `workflow`, `read:org`, `gist` — wider than the "public repo only" ideal
  (decision 0002 explains why and how to tighten it).
- **Expiry:** none; valid until revoked. Renewal: [docs/SETUP.md](SETUP.md#agent-credentials).
- **If a token ever leaks:** tell the owner immediately, have them revoke it at
  <https://github.com/settings/applications>, then re-authenticate.

## Next tasks (in order)

1. **Phase 1 start:** fork UTM into the owner's account, vendor it under `track-a-utm/`, record the
   upstream commit, and get its iOS target building as an unsigned IPA in CI.
2. Define the preconfigured Ubuntu arm64 guest (XFCE/LXQt preset, first-run download URL + checksum).
3. Investigate a pre-booted snapshot so the first launch takes seconds, not minutes.
4. **Phase 2 start:** add `PT_LOAD` mapping to the ELF loader with tests, then the minimal syscall
   dispatch (`write`, `exit`, `mmap`, `brk`, `read`) and run `testdata/hello.c` through it on Linux.
5. Give the owner the on-device checklist (install, enable JIT, screenshot diagnostics) and label
   every unverified item honestly until they report back.
