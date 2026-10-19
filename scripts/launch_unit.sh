#!/usr/bin/env bash
# Start one run_suite.sh batch as a systemd user unit that survives the calling session.
#   scripts/launch_unit.sh <out-name> <harness> <model> <effort> [jobs] [task-list]
# Environment (BENCH_STEERING, BENCH_KIRO_VERSION, BENCH_KIRO_SECRET, PYTHON) is passed through.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${1:?out-name}; shift
[ -e "runs/$OUT" ] && { echo "runs/$OUT exists" >&2; exit 1; }
CMD=$(DRY_RUN=1 scripts/run_suite.sh "$OUT" "$@")
mkdir -p "runs/$OUT"
ENVS=()
for v in BENCH_STEERING BENCH_KIRO_VERSION BENCH_KIRO_SECRET BENCH_KIMI_VERSION BENCH_QODER_VERSION BENCH_CODEBUDDY_VERSION BENCH_CLAUDE_VERSION BENCH_CODEX_VERSION; do [ -n "${!v:-}" ] && ENVS+=(--setenv="$v=${!v}"); done
systemd-run --user --quiet --unit="bench-$OUT" --working-directory="$PWD" "${ENVS[@]}" \
  bash -c "$CMD > runs/$OUT/batch.log 2>&1 < /dev/null"
echo "started bench-$OUT"
