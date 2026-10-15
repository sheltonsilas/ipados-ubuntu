#!/usr/bin/env bash
# Verifies the structure of the unsigned IPA that CI produced.
# macOS only (uses unzip, plutil, lipo, codesign). Run from the repository root:
#   bash tools/verify-ipa.sh track-b-runtime/dist/UbuntuPad-unsigned.ipa
set -euo pipefail

IPA="${1:-}"
if [ -z "$IPA" ]; then
  echo "usage: verify-ipa.sh path/to/app.ipa" >&2
  exit 2
fi

fail() {
  echo "FAIL: $*" >&2
  exit 1
}
ok() { echo "ok: $*"; }

[ -f "$IPA" ] || fail "no such file: $IPA"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

unzip -q "$IPA" -d "$work"
[ -d "$work/Payload" ] || fail "IPA has no Payload/ directory"

app="$(find "$work/Payload" -maxdepth 1 -name '*.app' -print -quit)"
[ -n "$app" ] || fail "Payload/ contains no .app bundle"
name="$(basename "$app" .app)"
binary="$app/$name"

[ -f "$app/Info.plist" ] || fail "Info.plist missing from the app bundle"
[ -f "$binary" ] || fail "executable missing from the app bundle: $binary"
ok "bundle: $(basename "$app")"

# The app must contain an arm64 slice only: this is a device build, not a simulator build.
arch_info="$(lipo -info "$binary")"
echo "$arch_info"
case "$arch_info" in
*arm64*) ok "arm64 slice present" ;;
*) fail "no arm64 slice in the app binary" ;;
esac
case "$arch_info" in
*arm64e*|*x86_64*|*i386*)
  fail "unexpected extra architecture in a device build: $arch_info"
  ;;
esac

# The whole point of the pipeline is an *unsigned* artifact that a sideloading tool can re-sign.
# When signing is disabled there is no embedded signature at all, so `codesign -dv` fails.
if codesign -dv "$binary" >/dev/null 2>&1; then
  signature="$(codesign -dv "$binary" 2>&1 | tr '\n' ' ')"
  case "$signature" in
  *"Signature=adhoc"*) ok "ad-hoc signature only (acceptable for re-signing)" ;;
  *) fail "app appears to carry a real signature, which CI must not create: $signature" ;;
  esac
else
  ok "app is unsigned, as intended"
fi

# ------------------------------------------------- the arm64 *Linux* guest programs the app carries
#
# The app's run button is only meaningful if a real Linux program is inside the bundle, so this checks
# the properties the runtime refuses to run without (decision 0020): a 64-bit little-endian **AArch64**
# ELF, **ET_DYN** (position-independent — a fixed-address image cannot be mapped on Apple silicon at
# all, decision 0019) and with **no PT_INTERP** (a dynamically linked image is Phase 4 work). A
# packaging mistake or a wrong-toolchain binary fails the build here instead of reaching the owner.
for guest in hello-pie-nostdlib stack-probe-nostdlib; do
  guest_path="$app/$guest"
  [ -f "$guest_path" ] || fail "guest program missing from the app bundle: $guest (the app would have nothing to run)"
  file -b "$guest_path"
  if ! command -v python3 >/dev/null 2>&1; then
    fail "python3 is required to inspect the guest ELF header (it is present on GitHub's macOS runners; install it or run this script where it exists)"
  fi
  python3 - "$guest_path" <<'PY'
import struct
import sys

path = sys.argv[1]
data = open(path, "rb").read()
if data[:4] != b"\x7fELF":
    sys.exit(f"FAIL: not an ELF file: {path}")
if data[4] != 2 or data[5] != 1:
    sys.exit(f"FAIL: not a 64-bit little-endian ELF: {path}")
elf_type, machine = struct.unpack_from("<HH", data, 16)
if machine != 183:
    sys.exit(f"FAIL: not AArch64 (e_machine={machine}): {path}")
if elf_type != 3:
    sys.exit(
        f"FAIL: not ET_DYN (e_type={elf_type}); a fixed-address image cannot be mapped on this platform: {path}"
    )
program_header_offset, = struct.unpack_from("<Q", data, 32)
entry_size, count = struct.unpack_from("<HH", data, 54)
for index in range(count):
    (segment_type,) = struct.unpack_from("<I", data, program_header_offset + index * entry_size)
    if segment_type == 3:
        sys.exit(f"FAIL: has PT_INTERP, so it needs a dynamic loader, which is Phase 4 work: {path}")
print(f"  ok: {path} is a static AArch64 Linux PIE ({len(data)} bytes)")
PY
  ok "guest program present and runnable-shaped: $guest"
done

# Nothing from a developer machine or a signing setup may end up in a public artifact.
for pattern in '*.mobileprovision' '*.p12' '*.pfx' '*.pem' '*.key' '.env' '*.mobileprovision*'; do
  found="$(find "$work" -name "$pattern" -print -quit)"
  [ -z "$found" ] || fail "unexpected file in the IPA: $found"
done
ok "no provisioning profiles or key material packaged"

# Coarse secret scan over anything text-like inside the bundle.
if grep -rlEI '(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----)' \
  "$work" 2>/dev/null | grep -q .; then
  fail "possible secret inside the IPA"
fi
ok "no obvious secrets packaged"

# Key Info.plist values the sideload/launch path depends on.
plist_key() { /usr/libexec/PlistBuddy -c "Print :$1" "$app/Info.plist" 2>/dev/null || echo "(absent)"; }
echo "CFBundleIdentifier: $(plist_key CFBundleIdentifier)"
echo "CFBundleShortVersionString: $(plist_key CFBundleShortVersionString)"
echo "MinimumOSVersion: $(plist_key MinimumOSVersion)"
echo "UIDeviceFamily: $(plist_key UIDeviceFamily)"
plutil -p "$app/Info.plist" | head -40

bundle_size="$(du -sh "$app" | cut -f1)"
ipa_bytes="$(stat -f%z "$IPA")"
echo "app size: $bundle_size"
echo "ipa bytes: $ipa_bytes"

# A Phase 0 app is tiny; anything large means something unintended was packaged.
if [ "$ipa_bytes" -gt 52428800 ]; then
  fail "IPA is larger than 50 MiB, which is unexpected at this stage"
fi
ok "IPA size is sane"

echo "verify-ipa: OK"
