# Track A — the UTM-based baseline

**Status: not started (Phase 1).** This directory is a placeholder so the layout in `AGENTS.md`
does not lie about what exists.

## What Track A is

A fork of [UTM](https://github.com/utmapp/UTM) built into an unsigned IPA by CI, preconfigured with
an arm64 Ubuntu VM running a lightweight desktop (XFCE or LXQt, **not** stock GNOME) and a first-run
image download. It is the fallback: the owner always has a usable app, and the emulated VM gives us
the performance benchmark that Track B must beat.

## Rules for this directory

1. **Fork, do not rewrite.** UTM's own code stays Apache-2.0 and its headers stay intact. Our
   changes are additive: build configuration, CI, VM presets, onboarding, input polish.
2. **QEMU is GPL-2.0.** It is built from upstream sources at build time, never vendored into this
   repository. See [../LICENSES.md](../LICENSES.md) and decision 0001.
3. **No Apple credentials, ever.** The iOS target is built with `CODE_SIGNING_ALLOWED=NO` into an
   unsigned IPA; the owner's sideloading tool re-signs it.
4. **Do not copy code from Husk or Madeira** into this tree — they are references only.

## Plan (Phase 1)

- [ ] Fork UTM into `sheltonsilas/utm` and record the exact upstream commit in `upstream.txt`.
- [ ] Add the fork here as a git subtree/submodule (decide which, and write it in DECISIONS.md).
- [ ] Build the iOS target in CI as an unsigned IPA; keep the workflow in
      `../.github/workflows/` and publish it as a separate artifact from the Track B app.
- [ ] Define the Ubuntu arm64 + XFCE/LXQt guest (preset, first-run download URL, checksum).
- [ ] Investigate a pre-booted snapshot so the first launch takes seconds instead of minutes.
- [ ] Measure and record cold boot time, warm boot time and UI responsiveness (owner-reported).

## Known constraints to design around

- The normal UTM IPA expects a JIT enabler to attach (see
  [../docs/RESEARCH/jit-and-entitlements-on-ios.md](../docs/RESEARCH/jit-and-entitlements-on-ios.md)).
  UTM SE is the non-JIT interpreter fallback and is much slower.
- `dynamic-codesigning` and the increased-memory-limit entitlement do not survive a
  free-Apple-ID sideload; the entitlement table in [../docs/SETUP.md](../docs/SETUP.md) is the
  reference for what to promise the owner.
- Emulation is only an acceptable interim answer: it is the reason Track B exists.
