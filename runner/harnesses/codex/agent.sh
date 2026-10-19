# Runs Codex CLI once, headless, against Amazon Bedrock (built-in amazon-bedrock provider).
# Credentials come from the AgentCore execution role; no profile is set, so the AWS
# default chain is used. Token usage is extracted afterwards by usage.sh.
. /bench/env
export PATH=/opt/bench-node/bin:$PATH
export TAR_OPTIONS=--no-same-owner
export CODEX_HOME=/opt/bench/codex-home
mkdir -p "$CODEX_HOME"
EFFORT_LINE=""
[ -n "$BENCH_EFFORT" ] && EFFORT_LINE="model_reasoning_effort = \"$BENCH_EFFORT\""
MODEL_REGION="${BENCH_MODEL_REGION:-$BENCH_REGION}"
case "$BENCH_MODEL" in
  global.*|us.*|eu.*|apac.*|jp.*)
    # Cross-region inference profiles exist only on bedrock-runtime, whose OpenAI-compatible
    # Responses endpoint takes bearer auth: mint a short-term Bedrock API key from the role.
    AWS_BEARER_TOKEN_BEDROCK=$(node /opt/bench/aws.mjs bedrock-token "$MODEL_REGION") || { echo "cannot mint a Bedrock API key" >&2; exit 2; }
    export AWS_BEARER_TOKEN_BEDROCK
    PROVIDER="bedrock-runtime"
    PROVIDER_BLOCK="[model_providers.bedrock-runtime]
name = \"Amazon Bedrock Runtime\"
base_url = \"https://bedrock-runtime.$MODEL_REGION.amazonaws.com/openai/v1\"
env_key = \"AWS_BEARER_TOKEN_BEDROCK\"
wire_api = \"responses\"" ;;
  *)
    # In-region model IDs go through the built-in provider (Bedrock Mantle, SigV4 from the role).
    PROVIDER="amazon-bedrock"
    PROVIDER_BLOCK="[model_providers.amazon-bedrock.aws]
region = \"$MODEL_REGION\"" ;;
esac
cat > "$CODEX_HOME/config.toml" <<TOML
model = "$BENCH_MODEL"
model_provider = "$PROVIDER"
approval_policy = "never"
sandbox_mode = "danger-full-access"
$EFFORT_LINE

$PROVIDER_BLOCK
TOML

# The task sandbox is already the isolation boundary, so Codex's own sandbox is off.
codex exec --json --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox \
  "$(cat /bench/instruction.md)" < /dev/null > /bench/agent.jsonl
CODE=$?
exit $CODE
