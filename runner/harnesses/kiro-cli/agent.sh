# Runs Kiro CLI once, headless.
# Auth: a Kiro API key read at run time, with the execution role, from the Secrets Manager
# secret named in $BENCH_KIRO_SECRET (default bench/kiro-api-key). The key never passes
# through the client. Model: $BENCH_MODEL (Kiro model id). Effort: $BENCH_EFFORT.
. /bench/env
export PATH=/opt/bench-kiro/bin:/opt/bench-node/bin:$PATH
export TAR_OPTIONS=--no-same-owner
KEY=$(node /opt/bench/aws.mjs secret "${BENCH_KIRO_SECRET:-bench/kiro-api-key}") || { echo "cannot read the Kiro API key secret" >&2; exit 2; }
export KIRO_API_KEY="$KEY"; unset KEY
kiro-cli settings app.disableAutoupdates true >/dev/null 2>&1
# Optional steering ($BENCH_STEERING, uploaded as /bench/steering.md): installed as global steering and
# also listed in the benchmark agent's resources, so it loads whichever agent config kiro-cli uses.
if [ -f /bench/steering.md ]; then
  mkdir -p /root/.kiro/steering && cp /bench/steering.md "/root/.kiro/steering/${BENCH_STEERING:-bench}.md"
  node -e 'const f="/root/.kiro/agents/benchmark.json",fs=require("fs");const a=JSON.parse(fs.readFileSync(f));
    a.resources=["file:///root/.kiro/steering/**/*.md"];fs.writeFileSync(f,JSON.stringify(a))'
fi
ARGS="--trust-all-tools --agent benchmark"
[ -n "$BENCH_MODEL" ] && [ "$BENCH_MODEL" != default ] && ARGS="$ARGS --model $BENCH_MODEL"
[ -n "$BENCH_EFFORT" ] && [ "$BENCH_EFFORT" != default ] && ARGS="$ARGS --effort $BENCH_EFFORT"
# Per-request credits: kiro-cli receives a MeteringEvent at the end of every model request, but only
# writes it to its trace log; stream-json reports credits once per turn (metadata.meteringUsage), and a
# headless task is one turn, so a timeout kill loses all of them there. The trace log is several MB per
# request (each request dumps the conversation), so it goes into a FIFO and only the metering lines are
# kept, in /bench/kiro-metering.log. --line-buffered: lines are on disk as they arrive, kill or not.
METER_FIFO=/bench/.kiro-trace.fifo
rm -f "$METER_FIFO"; mkfifo "$METER_FIFO"
grep --line-buffered -a -E 'MeteringEvent \{ usage|model selected' < "$METER_FIFO" > /bench/kiro-metering.log &
METER_PID=$!
export KIRO_LOG_LEVEL=trace KIRO_CHAT_LOG_FILE="$METER_FIFO"
# stream-json: ACP events as JSON Lines; per-turn credits (metadata.meteringUsage) are kept as a cross-check.
kiro-cli chat --output-format stream-json $ARGS "$(cat /bench/instruction.md)" < /dev/null > /bench/agent.jsonl
CODE=$?
# kiro closing the FIFO ends grep; bounded wait in case a child still holds it open.
for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 $METER_PID 2>/dev/null || break; sleep 0.5; done
kill $METER_PID 2>/dev/null
exit $CODE
