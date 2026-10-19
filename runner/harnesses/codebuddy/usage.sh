# Runs after the agent however it ended. Writes /bench/usage.json and prints the final message.
# Source: CodeBuddy's own session files (/root/.codebuddy/projects/**/*.jsonl). Each model request
# leaves one record with providerData.rawUsage (prompt/completion tokens + credit) and
# providerData.usage (inputTokens, outputTokens, cached_tokens, reasoning_tokens); deduplicated on
# providerData.messageId. The stream-json result usage (tokens only) is kept as a cross-check.
export PATH=/opt/bench-node/bin:$PATH
node -e '
const fs = require("fs"), path = require("path");
function walk(d, out) {
  let ents = []; try { ents = fs.readdirSync(d, {withFileTypes: true}); } catch {}
  for (const x of ents) { const p = path.join(d, x.name); x.isDirectory() ? walk(p, out) : x.name.endsWith(".jsonl") && out.push(p); }
  return out;
}
const seen = new Map(), models = {};
for (const f of walk("/root/.codebuddy/projects", [])) {
  for (const l of fs.readFileSync(f, "utf8").split("\n")) {
    if (!l.includes("rawUsage")) continue;
    let e; try { e = JSON.parse(l); } catch { continue; }
    const pd = e.providerData || {};
    if (!pd.rawUsage) continue;
    const id = pd.messageId || pd.traceId || l.slice(0, 200);
    if (!seen.has(id)) { seen.set(id, pd); models[pd.model || "?"] = (models[pd.model || "?"] || 0) + 1; }
  }
}
let credit = 0, inp = 0, out = 0, cached = 0, reasoning = 0, withCredit = 0;
for (const pd of seen.values()) {
  const r = pd.rawUsage || {}, u = pd.usage || {};
  if (typeof r.credit === "number") { credit += r.credit; withCredit++; }
  inp += u.inputTokens ?? r.prompt_tokens ?? 0; out += u.outputTokens ?? r.completion_tokens ?? 0;
  for (const d of u.inputTokensDetails || []) cached += d.cached_tokens || 0;
  for (const d of u.outputTokensDetails || []) reasoning += d.reasoning_tokens || 0;
}
let result = null, last = "";
try {
  for (const l of fs.readFileSync("/bench/agent.jsonl", "utf8").split("\n")) {
    let e; try { e = JSON.parse(l); } catch { continue; }
    if (e.type === "result") { result = e; last = e.result || last; }
  }
} catch {}
const r4 = x => Math.round(x * 10000) / 10000, none = seen.size === 0;
console.log(last);
fs.writeFileSync("/bench/usage.json", JSON.stringify({
  usage_source: none ? "none" : "session", requests: seen.size, requests_with_credit: withCredit, models,
  credits: none ? null : r4(credit),
  // input_tokens includes the cached part (cache_read_tokens is a subset), as with Codex.
  input_tokens: none ? null : inp, output_tokens: none ? null : out,
  cache_read_tokens: none ? null : cached, cache_write_tokens: null, reasoning_tokens: none ? null : reasoning,
  result_usage: result ? result.usage : null, cost_usd: null,
  num_turns: result ? result.num_turns : null, effort: process.env.BENCH_EFFORT || "default" }));
'
