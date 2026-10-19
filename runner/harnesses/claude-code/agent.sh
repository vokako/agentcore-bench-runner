# Runs Claude Code once, headless, in the foreground; returns the agent's exit code.
# Harness contract: read /bench/instruction.md; optionally write /bench/usage.json
# ({input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, cost_usd, turns}),
# which trial.sh copies into summary.json.
. /bench/env
export PATH=/opt/bench-node/bin:$PATH

# Bedrock via the AgentCore execution role (IMDSv2); no keys are injected.
export CLAUDE_CODE_USE_BEDROCK=1
export ANTHROPIC_MODEL="$BENCH_MODEL"
export AWS_REGION="$BENCH_REGION"
export DISABLE_TELEMETRY=1 DISABLE_AUTOUPDATER=1 DISABLE_ERROR_REPORTING=1
# Claude Code refuses bypassPermissions as root unless it is told it is sandboxed.
export IS_SANDBOX=1
export TAR_OPTIONS=--no-same-owner

EFFORT_ARG=""; [ -n "$BENCH_EFFORT" ] && EFFORT_ARG="--effort $BENCH_EFFORT"
# stream-json emits one event per message as it happens, so token usage survives a timeout kill;
# `--output-format json` prints a single result object only when the run ends.
# usage.sh (run by trial.sh however the agent ended) turns /bench/agent.jsonl into /bench/usage.json.
claude -p "$(cat /bench/instruction.md)" --permission-mode bypassPermissions $EFFORT_ARG \
  --output-format stream-json --verbose < /dev/null > /bench/agent.jsonl
exit $?
