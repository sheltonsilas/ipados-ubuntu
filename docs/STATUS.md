# Status

_Last updated: 2026-10-15 (Track B is inside the app; Track A is parked at the owner's instruction)._

## One-line summary

**The runtime now ships in the app.** A real arm64 **Linux** program is loaded, relocated, patched and
executed by our own code on an Apple-silicon host, and the same program is verified **inside the
unsigned IPA** that the nightly release publishes: the app links the same library CI asserts and carries
the same guest binaries, byte for byte. The screen has a **Run** button and a **memory probe** in front
of the owner. Track B is otherwise at Phase 2's end: what remains is Phase 3 (processes, pipes, a shell).
**Nothing has run on a physical iPad yet**, so every iOS statement below is *unverified on device*.
Track A is parked by the owner's decision (its blocker was `gstreamer.freedesktop.org`, not UTM's code).
The complete Track B plan is [TRACK-B-PLAN.md](TRACK-B-PLAN.md).

## Evidence — commit `3f2d878`, all three workflows green

| Item | State | Evidence |
| --- | --- | --- |
| `tests` (unit tests, layout, hygiene) | **Passing** | run [38758466445](https://github.com/sheltonsilas/ipados-ubuntu/actions/runs/38758466445) — both jobs success |
| `runtime-e2e` (execute a Linux guest on Apple silicon) | **Passing** | run [38758466379](https://github.com/sheltonsilas/ipados-ubuntu/actions/runs/38758466379) — "all guest-run assertions passed" |
| `build-ipa` (unsigned IPA) | **Passing** | run [38758466487](https://github.com/sheltonsilas/ipados-ubuntu/actions/runs/38758466487) — guest-programs, ipa and release jobs all success |
| Guest's stdout from guest code | Verified | `hello from a position-independent aarch64 linux`, between the runner's markers, `exit=normal status=0` |
| Placement and relocation | Verified | `image_mapping=biased attempt=1 bias=0x7000000000`, `relative_relocations=1 applied=1`; with `--skip-relocations` the same guest prints nothing and faults |
| A fixed-address image is refused, with a reason | Verified | the refusal names `0x400000` and says a position-independent build would run |
| Linux initial stack | Verified | `argc=3 … pagesz=4096 … auxv_entries=18`, `AT_ENTRY=0x7000000558` (biased) |
| Executable memory without entitlements (on the runner) | Works | `rx_mapping=ok` unsigned; no re-signing step was needed |
| **A Linux program inside the app bundle** | Verified | `verify-ipa.sh`: `ok: …/Payload/UbuntuPad.app/hello-pie-nostdlib is a static AArch64 Linux PIE (67880 bytes)` and the stack probe (67904 bytes) |
| **The app's guest is the one CI executed** | Verified | identical BuildIDs: `7717885b…` (hello) and `d7f2ccc6…` (stack probe) in both the `runtime-e2e` run and the extracted IPA |
| **The app builds with the runtime linked** | Verified | `build-ipa` compiles `UbuntuPadRunner` and `UbuntuPadHost` for `iphoneos` (target `arm64-apple-ios16.0` after the platform declaration) and produces the app |
| Downloadable artifact refreshed | Verified | `nightly` release asset `UbuntuPad-unsigned.ipa`, 226,966 bytes + `.sha256`, uploaded 2026-10-15T15:15:39Z |
| The runtime running **on a real iPad** | **Unverified on device** | nobody has installed this build yet; the checklist is in [SETUP.md](SETUP.md) |
| Whether the iPad lets the app execute pages it wrote | **Unverified on device** | this is what the app's probe reports; CI cannot answer it |

The one honest limit of the whole table: the app and the CLI link the *same* `UbuntuPadRunner` code, so
the run path is the one CI exercises — but "the same code compiled for iOS" is not "observed running on
iOS". Only the owner's paste of the diagnostics block closes that gap.

## What is broken / not started

- **No device test of anything.** Track B's probe may well answer "refused" on an unentitled iPad; the
  design avoids a writable-and-executable page precisely so that it has a chance, and the app measures
  the answer instead of assuming it.
- Track A is **parked**. Its last fork run (38746321359) was never read; the GStreamer pre-fetch fix is
  in `track-a-utm/ci/ubuntupad-ios.yml` and unproven.
- Phase 3+ is not started: `fork`/`clone`/`execve`, threads, pipes, signals, a filesystem, dynamic
  linking. The design for the process model is decision 0021; the order of work is
  [TRACK-B-PLAN.md](TRACK-B-PLAN.md) §2.
- A dynamically linked binary, `/proc`, `/dev`, pty, sockets, epoll, futex and timers are all still
  `ENOSYS`, and the run's `unimplemented=` line is the list to work from.
- The app has no terminal and no way to feed in an arbitrary binary: it runs the two programs it ships.

## CI environment risks to watch

- `tests`/`runtime-e2e` are pinned to `ubuntu-24.04` and `macos-15` on purpose (decisions 0009, 0013):
  a 16 KiB-page arm64 host is the design's premise.
- `gstreamer.freedesktop.org` remains a single point of failure for Track A whenever it is resumed
  (decision 0014).
- A macOS runner's address-space layout is a moving target; the runtime reports every placement attempt,
  so a layout change shows up as a readable log line (decision 0019).
- **SwiftPM platform defaults.** The package had no `platforms:` declaration, so the app built the C shim
  with `-target arm64-apple-ios12.0` while the app targets iOS 16 — an availability mismatch that would
  silently disable every version check. Fixed this session in `Package.swift`; if a future change drops
  that line, `build-ipa`'s log is where it shows.

## Environment facts (agent machine, 2026-10-15)

- Windows 11 + Git Bash; `git`, `gh`, `curl`, `python3` (with `pyyaml`) work.
- **No local `swift`, `xcodebuild` or `aarch64-linux-gnu-gcc`**: Swift compilation, the iOS build and
  every guest-execution result are verified **only in CI**. Shell scripts are checked with `bash -n`,
  workflows with `yaml.safe_load`, and the ELF check inside `verify-ipa.sh` was exercised locally
  against synthetic ELF files (accept a static PIE; reject ET_EXEC, PT_INTERP, x86_64 and non-ELF).
- The owner is signed in to GitHub in the agent browser as `sheltonsilas`.

## Credentials

- **Authentication in use:** the GitHub CLI OAuth token in the operating system credential store. It is
  never written to this repository, to CI, or to a log.
- **Scopes:** `repo`, `workflow`, `read:org`, `gist` — wider than the "public repo only" ideal
  (decision 0002 explains why and how to tighten it).
- **Expiry:** none; valid until revoked. Renewal: [docs/SETUP.md](SETUP.md#agent-credentials).
- **If a token ever leaks:** tell the owner immediately, have them revoke it at
  <https://github.com/settings/applications>, then re-authenticate.

## Next tasks (in order)

1. **The owner's device report.** Give them the four-step checklist (install the nightly IPA, enable JIT,
   press Run on both programs, paste the diagnostics block into an issue). Every "unverified on device"
   line in this file turns into either evidence or a bug report, and the probe's `rx_mapping=` decides
   how much of Phase 5 is possible.
2. **B3, first slice:** the guest process table in the portable core — one guest task per host thread,
   `clone` flags classified rather than forwarded, `wait` state, per-task signal masks — with unit tests
   for the flag combinations that matter (decision 0021 designs it).
3. **B3, second slice:** `clone`/`fork`/`wait4` services plus pipes, and a fork-and-pipe guest added to
   `tools/build-guest-binaries.sh` and asserted in `runtime-e2e`.
4. **B4:** a static busybox from a pinned, checksummed release, running `sh -c` with pipes and
   redirection in CI — Phase 3's exit criterion.
5. **B5, first slice:** `PT_INTERP` and symbol-based relocations (the dynamic loader), tested against a
   real Ubuntu arm64 binary fetched from Ubuntu's own archive.
