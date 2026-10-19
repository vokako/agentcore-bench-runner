#!/usr/bin/env bash
# Fetch Terminal-Bench 2.0 (Harbor task format) at the commit the published results used.
#
#   scripts/fetch_tb2.sh [dest]        # default vendor/terminal-bench-2
set -euo pipefail
cd "$(dirname "$0")/.."
DEST=${1:-vendor/terminal-bench-2}
REPO=https://github.com/laude-institute/terminal-bench-2
COMMIT=${TB2_COMMIT:-2fd12b8}
if [ ! -d "$DEST/.git" ]; then
  git clone --quiet "$REPO" "$DEST"
fi
git -C "$DEST" fetch --quiet origin
git -C "$DEST" checkout --quiet "$COMMIT"
echo "$DEST at $(git -C "$DEST" rev-parse --short HEAD): $(ls -d "$DEST"/*/ | wc -l) tasks"
