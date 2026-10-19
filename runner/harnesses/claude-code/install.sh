# Claude Code CLI (npm), pinned: $BENCH_CLAUDE_VERSION, default 2.1.296 (the version the published results used).
# Runs after runner/install.sh, with /opt/bench-node on PATH.
quiet npm install -g --silent "@anthropic-ai/claude-code@${BENCH_CLAUDE_VERSION:-2.1.296}"
echo "claude=$(claude --version 2>/dev/null | head -1)"
