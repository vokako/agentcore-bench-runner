#!/usr/bin/env bash
# Run one task list with one harness + model + effort on microVM, in the background.
#
#   scripts/run_suite.sh <out-name> <harness> <model> <effort> [jobs] [task-list]
#
#   out-name   run directory under runs/ (refuses to overwrite an existing one)
#   harness    claude-code | codex | kiro-cli   (runner/harnesses/<name>)
#   model      model / inference profile the harness calls
#   effort     low | medium | high
#   jobs       trials in flight at a time (default 4)
#   task-list  file with one task name per line (default benchmarks/tb2-fast30.txt)
#
# Inputs:
#   config.json         image_template, e.g. "<account>.dkr.ecr.<region>.amazonaws.com/bench/{task}:arm64"
#   TB2_DIR             Terminal-Bench 2.0 checkout (default vendor/terminal-bench-2, see scripts/fetch_tb2.sh)
#   BENCH_CONFIG        config file (default config.json)
#   BENCH_KIRO_SECRET   kiro-cli only: Secrets Manager id[:STAGE] of the Kiro API key (default bench/kiro-api-key)
#   PYTHON              interpreter with boto3 (default python3)
#   DRY_RUN=1           print the batch command instead of starting it
#
# Writes runs/<out-name>/{batch.log,results.jsonl,summary.md}.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${1:?out-name} HARNESS=${2:?harness} MODEL=${3:?model} EFFORT=${4:?effort}
JOBS=${5:-4} LIST=${6:-benchmarks/tb2-fast30.txt}
CONFIG=${BENCH_CONFIG:-config.json}
TB2=${TB2_DIR:-vendor/terminal-bench-2}
PY=${PYTHON:-python3}

[ -f "$CONFIG" ] || { echo "missing $CONFIG (copy config.example.json)" >&2; exit 2; }
[ -d "$TB2" ] || { echo "missing task dir $TB2 (run scripts/fetch_tb2.sh or set TB2_DIR)" >&2; exit 2; }
IMAGE=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("image_template",""))' "$CONFIG")
[ -n "$IMAGE" ] || { echo "$CONFIG has no image_template" >&2; exit 2; }

TASKS=()
while read -r t; do
  [ -z "$t" ] || [ "${t#\#}" != "$t" ] && continue
  [ -d "$TB2/$t" ] || { echo "task $t not found in $TB2" >&2; exit 2; }
  TASKS+=("$TB2/$t")
done < "$LIST"

CMD=($PY runner/batch.py --config "$CONFIG" --mode microvm --image "$IMAGE"
     --harness "$HARNESS" --model "$MODEL" --effort "$EFFORT" --jobs "$JOBS" --out "runs/$OUT" "${TASKS[@]}")
if [ "${DRY_RUN:-}" = 1 ]; then
  printf '%q ' "${CMD[@]}"; echo
  exit 0
fi
[ -e "runs/$OUT" ] && { echo "runs/$OUT exists" >&2; exit 1; }
mkdir -p "runs/$OUT"
nohup "${CMD[@]}" > "runs/$OUT/batch.log" 2>&1 < /dev/null &
echo "started runs/$OUT pid=$! (${#TASKS[@]} tasks)"
