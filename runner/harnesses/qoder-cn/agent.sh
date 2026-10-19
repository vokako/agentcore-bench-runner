# Runs Qoder CN CLI once, headless (-p), against the Qoder CN service.
# Auth: a personal access token read at run time, with the execution role, from the Secrets Manager
# secret $BENCH_QODER_SECRET (default bench/qoder-api-key); it never passes through the client.
# Model: $BENCH_MODEL (a name from `qoderclicn --list-models`, e.g. Auto, Kimi-K3; "default" = account
# default). Effort: $BENCH_EFFORT -> --reasoning-effort. Usage is extracted afterwards by usage.sh.
. /bench/env
export PATH=/opt/bench-node/bin:$PATH
export TAR_OPTIONS=--no-same-owner
TOKEN=$(node /opt/bench/aws.mjs secret "${BENCH_QODER_SECRET:-bench/qoder-api-key}") || { echo "cannot read the Qoder token secret" >&2; exit 2; }
export QODERCN_PERSONAL_ACCESS_TOKEN="$TOKEN"; unset TOKEN
# No self-update: the version is the pinned bundle.
printf '{"autoUpdates": false}\n' > /root/.qoder-cn.json
ARGS=(-p "$(cat /bench/instruction.md)" --output-format stream-json --dangerously-skip-permissions)
[ -n "$BENCH_MODEL" ] && [ "$BENCH_MODEL" != default ] && ARGS+=(--model "$BENCH_MODEL")
[ -n "$BENCH_EFFORT" ] && [ "$BENCH_EFFORT" != default ] && ARGS+=(--reasoning-effort "$BENCH_EFFORT")
node /opt/bench-qoder/qoderclicn/node_modules/@qodercn-ai/qoderclicn/bundle/qoderclicn.js "${ARGS[@]}" \
  < /dev/null > /bench/agent.jsonl
CODE=$?
exit $CODE
