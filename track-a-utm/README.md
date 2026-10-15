# Track A — the UTM-based baseline

**Status: Phase 1 in progress.** The fork exists, the trimmed iOS build workflow is in place and has
run, and the dependency (sysroot) build is the expensive step being shaken out. **There is no
downloadable Track A IPA yet** — see [../docs/STATUS.md](../docs/STATUS.md) for the current result.
Track A is not usable until there is.

## What Track A is

A fork of [UTM](https://github.com/utmapp/UTM) built into an unsigned IPA by CI, preconfigured with an
arm64 Ubuntu VM running a lightweight desktop (XFCE or LXQt, **not** stock GNOME) and a first-run
image download. It is the fallback: the owner always has a usable app, and the emulated VM is the
performance benchmark Track B must beat.

## Where everything is

```
track-a-utm/
  upstream.txt        the fork URL and the exact pinned upstream commit (corresponding source)
  ci/ubuntupad-ios.yml  SOURCE OF TRUTH for the fork's CI — pushed to the fork, never edited there
  tools/push-fork-ci.sh pushes ci/ubuntupad-ios.yml into the fork; --dispatch also starts a build
```

The fork is <https://github.com/sheltonsilas/UTM>. UTM source is **not** vendored into this
repository (decision 0001: vendoring QEMU is a licensing and maintenance liability), so the only thing
this directory owns is the build definition, the pin, and the documentation.

## How the build works

`ci/ubuntupad-ios.yml` is upstream's own recipe (`scripts/build_dependencies.sh`, `scripts/build_utm.sh`,
`scripts/package.sh`) with the matrix removed:

1. **sysroot job** — `brew install bison pkg-config gettext glib-utils libgpg-error nasm make meson
   cmake llvm spirv-llvm-translator libxcb libxrandr`, the Python packages UTM's build needs, then
   `./scripts/build_dependencies.sh -p ios -a arm64`, which cross-compiles QEMU and its dependencies
   for `iphoneos`/arm64. The result is cached (`actions/cache`) **and** uploaded as an artifact, because
   this is the step that takes the longest and fails for environmental reasons.
2. **build-ipa job** — restores the sysroot, runs `./scripts/build_utm.sh -k iphoneos -s iOS -a arm64`
   (which passes `CODE_SIGNING_ALLOWED=NO`), then `./scripts/package.sh ipa UTM.xcarchive dist`.
3. Verification, inside the job: the archive must contain `Payload/*.app`, the executable must be
   arm64, there must be **no** `embedded.mobileprovision`, and the app must not carry an Apple
   authority. A SHA-256 is published next to the IPA.
4. Publication: a rolling `ios-nightly` release in the fork, using the fork's own `GITHUB_TOKEN`.
   No personal access token is involved anywhere — which is also why this repository's CI cannot
   *trigger* the fork (that would need a cross-repository token, forbidden by the project rules).

Everything is triggered by hand or by a push to the fork's `ubuntupad-ci` branch:

```bash
track-a-utm/tools/push-fork-ci.sh            # sync the workflow into the fork
track-a-utm/tools/push-fork-ci.sh --dispatch # sync, then start a build
gh run watch --repo sheltonsilas/UTM
```

## Known constraints to design around

- **The sysroot build is the risk.** It compiles QEMU for iOS from source on a 3-vCPU/7 GiB runner.
  The first attempt died on a network problem (curl error 92 downloading GStreamer; fixed with an
  HTTP/1.1 `~/.curlrc`, decision 0014). Disk is not the constraint (the runner reports ~38 GiB free).
- **JIT.** The normal UTM IPA expects a JIT enabler to attach; UTM SE is the non-JIT interpreter
  fallback and is much slower. The workflow can build either (`package_mode: ipa`, `ipa-hv`, `ipa-se`),
  and the choice belongs to a decision entry once there is a measured boot time to argue with.
- `dynamic-codesigning` and the increased-memory-limit entitlement do not survive a free-Apple-ID
  sideload; the entitlement table in [../docs/SETUP.md](../docs/SETUP.md) is what to promise the owner.

## Still to do in Phase 1

- [ ] Get the sysroot + IPA job green and a downloadable `UTM-unsigned.ipa` published (in progress).
- [ ] Add a workflow **here** that consumes the fork's public `ios-nightly` asset, re-verifies it and
      republishes it as this project's own `UTM-unsigned.ipa` release asset, so one place lists the
      artifacts this project ships.
- [ ] Define the Ubuntu arm64 + XFCE/LXQt guest preset (CPU/RAM/disk, image URL + SHA-256) as a
      generated `.utm` bundle plus an import checklist the owner can follow without a terminal.
- [ ] Investigate a pre-booted snapshot so the first launch takes seconds, not minutes.
- [ ] Measure and record cold boot, warm boot and UI responsiveness (owner-reported, on the iPad).
