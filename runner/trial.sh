#!/bin/bash
# Runs one trial inside the sandbox, start to finish, with no client involvement:
#   agent (foreground, waits for it to exit) -> fetch tests -> tests/test.sh
#   -> upload reward + logs to S3 -> stop this session.
# Started in the background by `bench.py submit`; configuration comes from /bench/env.
set -u
exec >> /bench/trial.log 2>&1
. /bench/env
export PATH=/opt/bench-node/bin:$PATH
# GNU tar cannot restore archive owners without CAP_CHOWN (Runtime Instances).
export TAR_OPTIONS=--no-same-owner
cd /bench

s3put() { [ -f "$2" ] && node /opt/bench/aws.mjs put "$BENCH_PREFIX/$1" "$2"; }
now() { date +%s; }
json_str() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# Keep 64 MiB in reserve. If the task fills the disk, finish() frees it first so the
# summary and logs can still be written and uploaded and the session still stops.
RESERVE=/bench/.reserve
dd if=/dev/zero of=$RESERVE bs=1M count=64 status=none 2>/dev/null || true

free_mb() { df -Pm / 2>/dev/null | awk 'NR==2 {print $4}'; }
DISK_START=$(free_mb)
T0=$(now); AGENT_EXIT=""; VERIFIER_EXIT=""; REWARD=""; ERROR=""

# Status and summary go to $OUT. It is /bench, or /dev/shm when the root filesystem has
# become read-only: on microVM a task that fills the disk turns / read-only (EROFS).
OUT=/bench
writable_out() {
  if [ "$OUT" = /bench ] && ! : > /bench/.wtest 2>/dev/null; then
    OUT=/dev/shm/bench; mkdir -p "$OUT"
    ERROR="${ERROR:+$ERROR; }root filesystem became read-only (disk full)"
  fi
}

write_status() {  # write_status <phase>
  writable_out
  printf '{"run_id":"%s","phase":"%s","updated":"%s"}\n' \
    "$BENCH_RUN_ID" "$1" "$(date -u +%FT%TZ)" > "$OUT/status.json"
  s3put status.json "$OUT/status.json"
}

finish() {
  kill "${HEARTBEAT:-}" 2>/dev/null
  DISK_END=$(free_mb)   # before the reserve is freed, so a full disk reads as ~0
  rm -f "$RESERVE"
  writable_out
  T_END=$(now)
  [ -f /logs/verifier/reward.json ] && REWARD_JSON=$(cat /logs/verifier/reward.json) || REWARD_JSON=null
  USAGE=null
  [ -s /bench/usage.json ] && node -e 'JSON.parse(require("fs").readFileSync("/bench/usage.json","utf8"))' 2>/dev/null && USAGE=$(cat /bench/usage.json)
  [ -f /logs/verifier/reward.txt ] && REWARD=$(tr -d ' \n' < /logs/verifier/reward.txt)
  cat > "$OUT/summary.json" <<EOF
{
  "run_id": "$BENCH_RUN_ID",
  "task": "$BENCH_TASK",
  "mode": "$BENCH_MODE",
  "harness": "${BENCH_HARNESS:-}",
  "harness_version": "${BENCH_HARNESS_VERSION:-}",
  "model": "$BENCH_MODEL",
  "usage": $USAGE,
  "reward": ${REWARD:-null},
  "reward_json": $REWARD_JSON,
  "agent_exit": ${AGENT_EXIT:-null},
  "verifier_exit": ${VERIFIER_EXIT:-null},
  "error": "$(json_str "$ERROR")",
  "disk_free_mb": {"start": ${DISK_START:-null}, "end": ${DISK_END:-null}},
  "timings_s": {"restore": ${T_RESTORE:-null}, "agent": ${T_AGENT:-null}, "verifier": ${T_VERIFIER:-null}, "total": $((T_END - T0))},
  "finished": "$(date -u +%FT%TZ)"
}
EOF
  s3put agent.log /bench/agent.log
  s3put agent.json /bench/agent.json
  s3put agent.jsonl /bench/agent.jsonl
  s3put session-logs.tgz /bench/session-logs.tgz
  s3put usage.json /bench/usage.json
  s3put kiro-metering.log /bench/kiro-metering.log
  s3put verifier.log /bench/verifier.log
  s3put reward.txt /logs/verifier/reward.txt
  s3put reward.json /logs/verifier/reward.json
  s3put ctrf.json /logs/verifier/ctrf.json
  s3put trial.log /bench/trial.log
  s3put summary.json "$OUT/summary.json"   # written last: its presence means "done"
  # Release this sandbox. On success the session ends here; a failure is uploaded.
  if ! node /opt/bench/aws.mjs stop > "$OUT/stop.log" 2>&1; then
    s3put stop-error.log "$OUT/stop.log"
  fi
}
trap finish EXIT

# Heartbeat: refresh status.json every 5 minutes. A status.json that stops updating while
# summary.json is missing means the sandbox itself went away (see docs/limitations.md).
( while sleep 300; do write_status "$(sed -n 's/.*"phase":"\([^"]*\)".*/\1/p' "$OUT/status.json" /dev/shm/bench/status.json 2>/dev/null | tail -1)"; done ) &
HEARTBEAT=$!

# Split-build images (scripts/build_split.sh) list archives to put back before the agent starts.
if [ -f /etc/bench/restore.list ]; then
  write_status restore
  R0=$(now)
  while read -r uri; do
    [ -n "$uri" ] || continue
    echo "restore $uri"
    set -o pipefail
    if ! node /opt/bench/aws.mjs get "$uri" - | tar -xzf - -C /; then
      ERROR="restore failed: $uri"; exit 1
    fi
    set +o pipefail
  done < /etc/bench/restore.list
  T_RESTORE=$(( $(now) - R0 ))
fi

write_status agent
mkdir -p /logs/agent /logs/verifier
cd "$BENCH_WORKDIR" 2>/dev/null || cd /
A0=$(now)
# On timeout: TERM, then KILL 30 s later.
timeout -k 30 "$BENCH_AGENT_TIMEOUT" bash /bench/agent.sh > /bench/agent.log 2>&1
AGENT_EXIT=$?; T_AGENT=$(( $(now) - A0 ))
[ "$AGENT_EXIT" = 124 ] && ERROR="agent timed out after ${BENCH_AGENT_TIMEOUT}s"

# Usage is extracted here, not inside agent.sh, so a timed-out or killed agent still gets counted.
# The agent's own session files (tokens / credits as the agent wrote them) are kept for re-checking.
if [ -f /bench/usage.sh ]; then
  timeout 120 bash /bench/usage.sh >> /bench/agent.log 2>> /bench/trial.log
fi
find /root/.kiro /root/.claude /opt/bench/codex-home/sessions /opt/bench/kimi-home/sessions /root/.qoder-cn/projects /root/.codebuddy/projects -type f -newer /bench/env -size -50M \
     \( -name '*.jsonl' -o -name '*.json' \) 2>/dev/null | head -200 > /bench/session-files.txt
find /tmp /root/.local/share /root/.cache -type f -newer /bench/env -size -20M -name '*.log' 2>/dev/null \
     | grep -i kiro | head -20 >> /bench/session-files.txt
[ -s /bench/session-files.txt ] && tar -czf /bench/session-logs.tgz -T /bench/session-files.txt 2>/dev/null

# Tests are fetched only now, after the agent has exited.
write_status verifier
if node /opt/bench/aws.mjs get "$BENCH_INPUT_PREFIX/tests.tgz" /bench/tests.tgz; then
  mkdir -p /tests && tar -xzf /bench/tests.tgz -C /tests
  cd "$BENCH_WORKDIR" 2>/dev/null || cd /
  V0=$(now)
  timeout "$BENCH_VERIFIER_TIMEOUT" bash /tests/test.sh > /bench/verifier.log 2>&1
  VERIFIER_EXIT=$?; T_VERIFIER=$(( $(now) - V0 ))
else
  ERROR="${ERROR:+$ERROR; }could not fetch tests"
fi
write_status uploading
