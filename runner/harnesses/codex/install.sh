# Codex CLI (npm), pinned: $BENCH_CODEX_VERSION, default 0.162.1 (the version the published results used).
# Runs after runner/install.sh, with /opt/bench-node on PATH.
quiet npm install -g --silent "@openai/codex@${BENCH_CODEX_VERSION:-0.162.1}"
# Short-term Bedrock API keys for the bedrock-runtime route (runner/aws.mjs bedrock-token).
cd /opt/bench && quiet npm install --silent @aws/bedrock-token-generator && cd /
echo "codex=$(codex --version 2>/dev/null | head -1)"
