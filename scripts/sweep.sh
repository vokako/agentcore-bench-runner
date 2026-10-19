#!/usr/bin/env bash
# Launch the whole harness x model x effort sweep defined in a matrix file.
#
#   scripts/sweep.sh [matrix] [jobs-per-run]
#
#   matrix        default benchmarks/matrix.txt
#   jobs-per-run  trials in flight per run (default 5)
#   EFFORTS       efforts to run (default "low medium high")
#   SUITES        task lists to run (default "fast30 hard20" -> benchmarks/tb2-<suite>.txt)
#   ONLY          run only matrix rows whose name matches this regex
#
# Every (row, effort, suite) becomes runs/<suite>-<name>-<effort>; runs that already exist are
# skipped, so the script can be re-run to fill gaps. Everything run_suite.sh reads applies here.
set -euo pipefail
cd "$(dirname "$0")/.."
MATRIX=${1:-benchmarks/matrix.txt}
JOBS=${2:-5}
EFFORTS=${EFFORTS:-low medium high}
SUITES=${SUITES:-fast30 hard20}

while read -r name harness model extra; do
  [ -z "${name:-}" ] || [ "${name#\#}" != "$name" ] && continue
  [ -n "${ONLY:-}" ] && ! [[ $name =~ $ONLY ]] && continue
  for effort in $EFFORTS; do
    for suite in $SUITES; do
      out="$suite-$name-$effort"
      if [ -e "runs/$out" ]; then echo "skip   runs/$out (exists)"; continue; fi
      # shellcheck disable=SC2086
      env ${extra:-} scripts/run_suite.sh "$out" "$harness" "$model" "$effort" "$JOBS" "benchmarks/tb2-$suite.txt"
    done
  done
done < "$MATRIX"
