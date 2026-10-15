# Status

_Last updated: 2026-10-15 (Phase 2's exit criterion met in CI; Phase 1 in progress)._

## One-line summary

**Phase 2's exit criterion is met in CI:** a static AArch64 **Linux** program is cross-compiled, executed
**natively on an Apple-silicon runner**, and the guest's own stdout is asserted byte for byte — with a
control run that proves the relocation pass is load-bearing and a refusal test for an image that cannot
be mapped on this platform at all. **Phase 1 is in progress:** the fork's iOS build runs, but has not yet
produced a downloadable IPA — its last two attempts died on `gstreamer.freedesktop.org` (curl 92, then
curl 18 / HTTP 503), and the resumable pre-fetch fix is dispatched as run
[38746321359](https://github.com/sheltonsilas/UTM/actions/runs/38746321359). **Nothing has run on a real
iPad**: every iOS result is *unverified on device*.

## Phase 2 evidence (commit `25eb56e`, all three workflows green)

| Item | State | Evidence |
| --- | --- | --- |
| `tests` (unit tests + layout + hygiene) | **Passing** | run [38745174521](https://github.com/sheltonsilas/ipados-ubuntu/actions/runs/38745174521) |
| `runtime-e2e` (execute a Linux guest on Apple silicon) | **Passing** | run [38745174715](https://github.com/sheltonsilas/ipados-ubuntu/actions/runs/38745174715) — "all guest-run assertions passed" |
| `build-ipa` (Phase 0 pipeline still green) | **Passing** | run [38745174900](https://github.com/sheltonsilas/ipados-ubuntu/actions/runs/38745174900) |
| Guest's stdout, produced by guest code on the guest's stack | Verified | `hello from a position-independent aarch64 linux`, between the runner's markers, `exit=normal status=0` |
| Image placement on a 16 KiB host | Verified | `reserved_low_region_bytes=4294967296`, `image_placement=biased requested_bias=0x7000000000`, `image_mapping=biased attempt=1 bias=0x7000000000` |
| Relative relocations applied for that base | Verified | `relative_relocations=1 applied=1`; the same guest run with `--skip-relocations` faults (`exit=fault status=11`) and prints nothing, so the pass is what makes it work |
| A fixed-address (ET_EXEC) image is refused, with a reason | Verified | `this is a fixed-address (ET_EXEC) executable linked at 0x400000, which is inside the 4 GiB … A position-independent build … can be loaded at a bias instead` |
| Linux initial stack seen by the guest | Verified | `argc=3 argv0=…/stack-probe-nostdlib envp_entries=4 pagesz=4096 phnum=7 auxv_entries=18 entry=0x7000000558` (the entry carries the bias) |
| Executable memory **without** JIT entitlements | Works on the runner | `probe` reports `rx_mapping=ok` unsigned, so the write-then-execute strategy needs no entitlement there; **unverified on device** |
| Syscall capture (rewrite `svc` to `brk`, handle SIGTRAP) | Verified | `patched_syscall_sites=2` on both freestanding guests, and each guest's syscalls were serviced by Swift |
| Relocation/placement unit coverage, including a real PIE binary | Passing | `ImagePlacementTests`, `RelocationTests` (the latter parses and applies a real `-static-pie` binary's `.rela.dyn`) |

Known limitation of the evidence: the guest is a **freestanding** program (no libc) — a real Ubuntu
binary is dynamically linked, which is Phase 4 work, not proof this is not.

## Phase 1 evidence

| Item | State | Evidence |
| --- | --- | --- |
| UTM fork + CI definition owned by this repository | Works | `sheltonsilas/UTM@ubuntupad-ci`, pushed by `track-a-utm/tools/push-fork-ci.sh` (decision 0017) |
| Fork's iOS build produces an unsigned IPA | **Not yet** | runs 38732453357 and 38735794962 both failed on the *same third-party host* (`gstreamer.freedesktop.org`): first curl 92, then curl 18 (truncated transfer) after five retries. Fix dispatched: [38746321359](https://github.com/sheltonsilas/UTM/actions/runs/38746321359) |
| Preconfigured Ubuntu arm64 guest preset | Not started | Phase 1 |
| Boot time on a real iPad | Not measured | needs the owner |

## What is broken / not started

- **Phase 1 has no usable app yet**: no IPA, no guest image, no VM configuration.
- The Phase 2 runtime is **not wired into the iOS app**: the app still opens a diagnostics screen only.
- No real-device testing of any kind.
- Phase 2's leftovers: `fork`/`clone`/`execve`, threads and signals, guest TLS, a filesystem.
- The iOS shell has no terminal and no way to feed the runtime a binary.

## CI environment risks to watch

- `tests` and the cross-compile job are **pinned to `ubuntu-24.04`** because the `ubuntu-latest` label
  migrates to Ubuntu 26 on 2026-10-19 (decision 0009). The end-to-end job is pinned to `macos-15` for the
  same reason (decision 0013): a 16 KiB-page arm64 host is the design's premise.
- `gstreamer.freedesktop.org` is a single point of failure for Track A (decision 0014). It has been
  intermittently 503 for hours at a time; the fork's build cannot proceed without those three tarballs.
- A macOS runner's **address-space layout is a moving target**: the first green run needed the adaptive
  candidate because twelve planned biases were refused (decision 0019). The runtime reports every
  attempt, so a future layout change shows up as a readable log line instead of a mysterious refusal.

## Environment facts (agent machine, 2026-10-15)

- Windows 11 + Git Bash; `git`, `gh`, `curl`, `python3` (with `pyyaml`) work.
- **No local `swift`, `xcodebuild` or `aarch64-linux-gnu-gcc`**: Swift compilation, the iOS build and
  every guest-execution result are verified **only in CI**. Workflow YAML and shell scripts can be
  syntax-checked locally (`bash -n`, `yaml.safe_load`), and that is done before every push.
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

1. **Phase 1:** watch fork run 38746321359. If `gstreamer.freedesktop.org` is still refusing, decide
   between (a) caching the three tarballs as a release asset in this repository and pointing the workflow
   at it, (b) building the sysroot without GStreamer if the iOS target can link without it, or (c)
   waiting — and record the choice in DECISIONS.md. The IPA is the gate for everything the owner can see.
2. **Wire the runtime into the iOS shell**: bundle a PIE guest binary, keep the diagnostics screen, and
   add a button that runs it through `UbuntuPadCore`/`UbuntuPadHost` on the device. This is the first
   *device-visible* Phase 2 result and the first real test of the entitlement story.
3. **Phase 3 start:** a static busybox, then a shell script with pipes and redirection (the phase's exit
   criterion). Decide `fork`/`clone` strategy first, since pipes need it.
4. Give the owner the on-device checklist (install, enable JIT, screenshot diagnostics) and keep every
   unverified item labelled honestly until they report back.
