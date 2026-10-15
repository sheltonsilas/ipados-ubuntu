#!/usr/bin/env bash
# Cross-compiles the *guest* programs: the arm64 Linux binaries this runtime loads and executes.
#
# One script, because three workflows need them and they must be the same bytes in all three (decision
# 0020):
#
#   tests.yml        the ELF parser, patch planner and stack builder are tested against real toolchain
#                    output rather than hand-made fixtures
#   runtime-e2e.yml  the guests are executed on Apple silicon and their stdout is asserted byte for byte
#   build-ipa.yml    two of them are bundled into the iPad app, so the app runs what CI ran
#
# Usage: tools/build-guest-binaries.sh [output-directory]     (default: build)
#
# Requires the aarch64 cross toolchain (`gcc-aarch64-linux-gnu` on Debian/Ubuntu; the workflows install
# it, because this script deliberately does not touch the package manager or use sudo).
set -euo pipefail

output="${1:-build}"
compiler="${AARCH64_CC:-aarch64-linux-gnu-gcc}"

if ! command -v "$compiler" >/dev/null 2>&1; then
  echo "build-guest-binaries: $compiler not found." >&2
  echo "Install it first, e.g.: sudo apt-get install -y gcc-aarch64-linux-gnu" >&2
  exit 2
fi

mkdir -p "$output"
"$compiler" --version | head -n1

# -nostdlib: no libc, so every syscall is written out by hand and nothing can hide a mistake.
# -static-pie: position-independent — how Ubuntu ships its own arm64 binaries, and the only shape that
#              can be placed at a bias. A fixed-address image cannot be mapped on Apple silicon at all
#              (decision 0019), so this is not a preference.
common="-static -nostdlib -ffreestanding -fno-builtin -O1"

# The guest the end-to-end run executes, and the one the iPad app bundles. It prints through a
# `volatile` global pointer on purpose: that is what gives the relocation pass real work to do.
"$compiler" $common -static-pie -fPIE \
  -o "$output/hello-pie-nostdlib" track-b-runtime/testdata/hello-pie-nostdlib.c

# The initial-stack probe: argc/argv/envp/auxv, AT_PHDR and AT_PAGESZ, printed by guest code.
"$compiler" $common -static-pie -fPIE \
  -o "$output/stack-probe-nostdlib" track-b-runtime/testdata/stack-probe-nostdlib.c

# A real ET_EXEC image linked at the usual 0x400000. No test runs it: the runtime must *refuse* it, and
# the refusal has to be tested against genuine toolchain output rather than a fixture.
"$compiler" $common -no-pie \
  -o "$output/hello-fixed-nostdlib" track-b-runtime/testdata/hello-nostdlib.c

# A libc-linked static program: the "real Ubuntu binary" the ELF parser and patch planner are tested
# against. It is not executed (it has far more than two syscall sites and expects libc's runtime).
"$compiler" -static -O0 -o "$output/hello-arm64" track-b-runtime/testdata/hello.c

for binary in "$output/hello-pie-nostdlib" "$output/stack-probe-nostdlib" "$output/hello-fixed-nostdlib" "$output/hello-arm64"; do
  if [ ! -f "$binary" ]; then
    echo "build-guest-binaries: $binary was not produced" >&2
    exit 1
  fi
done

file "$output"/hello-* "$output"/stack-probe-*
ls -l "$output"
sha256sum "$output"/hello-* "$output"/stack-probe-* >"$output/SHA256SUMS"
cat "$output/SHA256SUMS"
