# Runs Kimi Code CLI once, headless (-p, which auto-approves tool calls), against Amazon Bedrock.
# Provider: type "openai" (Chat Completions) on bedrock-runtime's OpenAI-compatible endpoint, with a
# short-term Bedrock API key minted from the AgentCore execution role. Model: $BENCH_MODEL
# (e.g. global.moonshotai.kimi-k3). Effort: $BENCH_EFFORT, sent as reasoning_effort (kimi's default
# is medium). Token usage is extracted afterwards by usage.sh from kimi's own session files.
. /bench/env
export PATH=/opt/bench-node/bin:$PATH
export TAR_OPTIONS=--no-same-owner
export KIMI_CODE_HOME=/opt/bench/kimi-home
mkdir -p "$KIMI_CODE_HOME"
MODEL_REGION="${BENCH_MODEL_REGION:-$BENCH_REGION}"
AWS_BEARER_TOKEN_BEDROCK=$(node /opt/bench/aws.mjs bedrock-token "$MODEL_REGION") || { echo "cannot mint a Bedrock API key" >&2; exit 2; }
export AWS_BEARER_TOKEN_BEDROCK
EFFORT_LINE=""
[ -n "$BENCH_EFFORT" ] && EFFORT_LINE="effort = \"$BENCH_EFFORT\""
cat > "$KIMI_CODE_HOME/config.toml" <<TOML
default_model = "bench"
default_permission_mode = "auto"
telemetry = false
auto_session_title = false

[thinking]
enabled = true
$EFFORT_LINE

[providers.bedrock]
type = "openai"
base_url = "https://bedrock-runtime.$MODEL_REGION.amazonaws.com/openai/v1"
api_key_env = "AWS_BEARER_TOKEN_BEDROCK"

[models.bench]
provider = "bedrock"
model = "$BENCH_MODEL"
max_context_size = 262144
capabilities = ["thinking", "always_thinking", "tool_use"]
support_efforts = ["low", "medium", "high"]
TOML
# No self-upgrade: the version is the pinned bundle.
printf '[upgrade]\nauto_install = false\n' > "$KIMI_CODE_HOME/tui.toml"

node /opt/bench-kimi/kimi-code/node_modules/@moonshot-ai/kimi-code/dist/main.mjs \
  -p "$(cat /bench/instruction.md)" --output-format stream-json < /dev/null > /bench/agent.jsonl
CODE=$?
exit $CODE
