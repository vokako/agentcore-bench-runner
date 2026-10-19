# Runs CodeBuddy Code once, headless (-p -y), against the CodeBuddy China service
# (CODEBUDDY_INTERNET_ENVIRONMENT=internal -> copilot.tencent.com; the key returns 401 on www.codebuddy.ai).
# Auth: an API key read at run time from Secrets Manager ($BENCH_CODEBUDDY_SECRET, default
# bench/codebuddy-api-key). Model: $BENCH_MODEL ("default" = account default, hy4-preview at the time of
# writing). Effort: $BENCH_EFFORT -> --effort. Usage is extracted afterwards by usage.sh.
. /bench/env
export PATH=/opt/bench-node/bin:$PATH
export TAR_OPTIONS=--no-same-owner
KEY=$(node /opt/bench/aws.mjs secret "${BENCH_CODEBUDDY_SECRET:-bench/codebuddy-api-key}") || { echo "cannot read the CodeBuddy key secret" >&2; exit 2; }
export CODEBUDDY_API_KEY="$KEY"; unset KEY
export CODEBUDDY_INTERNET_ENVIRONMENT=${BENCH_CODEBUDDY_ENV:-internal}
# The task sandbox is the isolation boundary: no confirmation prompts, no background tasks (a -p run
# exits at its first result), no self-update, no telemetry.
export CODEBUDDY_IS_SANDBOX=1 CODEBUDDY_CODE_DISABLE_BACKGROUND_TASKS=1 DISABLE_AUTOUPDATER=1 DISABLE_TELEMETRY=1
ARGS=(-p "$(cat /bench/instruction.md)" --output-format stream-json --verbose -y)
[ -n "$BENCH_MODEL" ] && [ "$BENCH_MODEL" != default ] && ARGS+=(--model "$BENCH_MODEL")
[ -n "$BENCH_EFFORT" ] && [ "$BENCH_EFFORT" != default ] && ARGS+=(--effort "$BENCH_EFFORT")
node /opt/bench-cbc/codebuddy-code/node_modules/@tencent-ai/codebuddy-code/bin/codebuddy "${ARGS[@]}" \
  < /dev/null > /bench/agent.jsonl
CODE=$?
exit $CODE
