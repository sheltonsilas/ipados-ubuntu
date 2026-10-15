# The guest programs the app runs

This directory is where the app's runnable Linux program comes from. It is deliberately almost empty:
the binaries are **build output**, not source.

- `tools/build-guest-binaries.sh` cross-compiles them with `aarch64-linux-gnu-gcc` (Linux). They are
  arm64 **Linux** ELFs, not Mach-O: the whole point is that the app loads a foreign binary and runs its
  instructions on the same CPU.
- `build-ipa.yml` has a small `ubuntu-24.04` job that runs that script and uploads `hello-pie-nostdlib`
  and `stack-probe-nostdlib`; the macOS job downloads them **here** before `xcodegen generate`, so they
  end up in the app bundle as resources (see `ios/project.yml`).
- `runtime-e2e.yml` runs the same script and then *executes* those binaries on Apple silicon, asserting
  their output byte for byte. So the program the app carries is a program CI has already run.
- The binaries are git-ignored (they are build output). A local `xcodegen generate` without them still
  works: the project spec marks the resources optional, and the app then honestly reports that no guest
  program is bundled instead of failing to build.

Decision: [docs/DECISIONS.md](../../../docs/DECISIONS.md) 0020.
