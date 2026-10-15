#!/usr/bin/env bash
# Push the vendored workflow into the UTM fork, so the fork's CI always matches this repository.
#
# Why: the fork (github.com/sheltonsilas/UTM) is where UTM's iOS target is actually compiled, but the
# definition of that build lives here, under version control, with the rest of the project. Editing
# the workflow only in the fork would make the pipeline unreproducible.
#
# Usage:
#   track-a-utm/tools/push-fork-ci.sh            # push the workflow to the fork
#   track-a-utm/tools/push-fork-ci.sh --dispatch # push, then start a build
#
# Requires an authenticated `gh` (see docs/SETUP.md). No secret is read or printed here.
set -euo pipefail

FORK="${FORK:-sheltonsilas/UTM}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOCAL_WORKFLOW="$REPO_ROOT/track-a-utm/ci/ubuntupad-ios.yml"
REMOTE_PATH=".github/workflows/ubuntupad-ios.yml"
# Where the workflow is kept in the fork. Deliberately NOT `main`: upstream's own workflow triggers on
# pushes to `main` and would start its nine-platform matrix every time we sync this one file. A
# dedicated branch keeps the fork's main untouched (so it stays a clean record of the pinned upstream
# commit) and workflow_dispatch works fine from a branch.
BRANCH="${BRANCH:-ubuntupad-ci}"

if [ ! -f "$LOCAL_WORKFLOW" ]; then
    echo "error: $LOCAL_WORKFLOW not found" >&2
    exit 1
fi

command -v gh >/dev/null || { echo "error: gh is not installed" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "error: gh is not authenticated" >&2; exit 1; }

# Only a real 40-hex blob SHA means the file already exists; anything else (including the JSON
# error text some gh versions print on a 404) must fall through to the create path.
# Make sure the branch exists, on top of the fork's main (which is the pinned upstream commit).
if ! gh api "repos/$FORK/branches/$BRANCH" >/dev/null 2>&1; then
    base="$(gh api "repos/$FORK" --jq .default_branch)"
    head_sha="$(gh api "repos/$FORK/git/ref/heads/$base" --jq .object.sha)"
    echo "Creating branch $BRANCH on $FORK from $base ($head_sha)"
    gh api --method POST "repos/$FORK/git/refs" -f ref="refs/heads/$BRANCH" -f sha="$head_sha" >/dev/null
fi

sha="$(gh api "repos/$FORK/contents/$REMOTE_PATH?ref=$BRANCH" --jq .sha 2>/dev/null || true)"
if ! printf '%s' "$sha" | grep -Eq '^[0-9a-f]{40}$'; then
    sha=""
fi
content_b64="$(base64 -w0 < "$LOCAL_WORKFLOW")"

if [ -n "$sha" ]; then
    echo "Updating $REMOTE_PATH on $FORK@$BRANCH (blob $sha)"
    gh api --method PUT "repos/$FORK/contents/$REMOTE_PATH" \
        -f message="Sync the UbuntuPad iOS workflow from the ipados-ubuntu repository" \
        -f content="$content_b64" -f sha="$sha" -f branch="$BRANCH" >/dev/null
else
    echo "Creating $REMOTE_PATH on $FORK@$BRANCH"
    gh api --method PUT "repos/$FORK/contents/$REMOTE_PATH" \
        -f message="Add the UbuntuPad iOS workflow (iOS arm64 only, unsigned IPA)" \
        -f content="$content_b64" -f branch="$BRANCH" >/dev/null
fi

echo "Pushed to $FORK@$BRANCH."

if [ "${1:-}" = "--dispatch" ]; then
    echo "Dispatching the iOS build..."
    gh workflow run ubuntupad-ios.yml --repo "$FORK" --ref "$BRANCH"
    sleep 8
    gh run list --repo "$FORK" --workflow ubuntupad-ios.yml --limit 3
fi
