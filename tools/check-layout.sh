#!/usr/bin/env bash
# Repository hygiene checks. Runs on Linux (CI) and on any developer machine with git.
# Deliberately does not use `set -e`: every check runs so one failure does not hide the others.
set -uo pipefail

fail=0
note() { printf '%s\n' "$*"; }
bad() {
  printf 'FAIL: %s\n' "$*"
  fail=1
}

# ---------------------------------------------------------------- required documentation and paths
required_files=(
  README.md
  AGENTS.md
  LICENSES.md
  LICENSE
  docs/STATUS.md
  docs/ROADMAP.md
  docs/DECISIONS.md
  docs/LOG.md
  docs/SETUP.md
  docs/RESEARCH/README.md
  track-a-utm/README.md
  track-b-runtime/README.md
  track-b-runtime/core/Package.swift
  track-b-runtime/ios/project.yml
  .github/workflows/build-ipa.yml
  .github/workflows/tests.yml
)

for file in "${required_files[@]}"; do
  [ -f "$file" ] || bad "missing required file: $file"
done

# ---------------------------------------------------------------------- nothing generated is tracked
if git rev-parse --git-dir >/dev/null 2>&1; then
  tracked_forbidden=$(git ls-files | grep -E '(^|/)(build|dist|DerivedData)/|\.ipa$|\.app/|\.xcodeproj/|\.pbxproj$' || true)
  if [ -n "$tracked_forbidden" ]; then
    bad "build output or generated project is tracked:"
    printf '%s\n' "$tracked_forbidden"
  fi
else
  note "warning: not a git repository, skipping tracked-file checks"
fi

# --------------------------------------------------------------------------- platform portability
# Decision 0006: the core must stay free of Apple-only APIs so it keeps building on Linux CI.
if grep -rnE '^import (Darwin|UIKit|SwiftUI|Metal|MetalKit|CoreGraphics|CoreFoundation|MachO|Security)' \
  track-b-runtime/core/Sources >/dev/null 2>&1; then
  bad "Apple-only import found in the platform-independent core:"
  grep -rnE '^import (Darwin|UIKit|SwiftUI|Metal|MetalKit|CoreGraphics|CoreFoundation|MachO|Security)' \
    track-b-runtime/core/Sources
fi

# ------------------------------------------------------------------------------------- secret scan
# Secrets must never reach this repository (constraint 1 in AGENTS.md). This scan is coarse on
# purpose: it looks for the shapes of high-entropy credentials, not names of variables.
secret_pattern='(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|AKIA[0-9A-Z]{16})'
if git rev-parse --git-dir >/dev/null 2>&1; then
  hits=$(git ls-files | grep -v '^tools/check-layout.sh$' | xargs -r grep -nE "$secret_pattern" 2>/dev/null || true)
  if [ -n "$hits" ]; then
    bad "possible secret committed:"
    printf '%s\n' "$hits"
  fi
fi

# ------------------------------------------------------------------------------ docs sanity checks
# AGENTS.md is the entry point for every future session; it must point at the living documents.
for pointer in STATUS.md ROADMAP.md DECISIONS.md LOG.md; do
  grep -q "$pointer" AGENTS.md || bad "AGENTS.md does not reference $pointer"
done

# The roadmap must keep the phases documented, and never be emptied out.
for phase in 'Phase 0' 'Phase 1' 'Phase 2' 'Phase 3' 'Phase 4' 'Phase 5' 'Phase 6'; do
  grep -q "$phase" docs/ROADMAP.md || bad "docs/ROADMAP.md lost $phase"
done

# ------------------------------------------------------------------------------- workflow yaml lint
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
  for workflow in .github/workflows/*.yml; do
    [ -f "$workflow" ] || continue
    python3 -c "import sys, yaml; yaml.safe_load(open(sys.argv[1]))" "$workflow" ||
      bad "invalid YAML: $workflow"
  done
else
  note "note: python3 + pyyaml unavailable, skipping workflow YAML parse"
fi

if [ "$fail" -eq 0 ]; then
  note "check-layout: OK"
fi
exit "$fail"
