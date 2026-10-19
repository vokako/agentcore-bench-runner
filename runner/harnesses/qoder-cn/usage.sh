# Runs after the agent however it ended. Writes /bench/usage.json and prints the final message.
# Source: the assistant records in Qoder's own session files (/root/.qoder-cn/projects/**/*.jsonl),
# one per model request, each with message.usage.credits (+ billable, original_credits, request_id);
# deduplicated on request_id. Qoder reports token counts as 0, so credits are the cost unit.
# The stream-json result (total_credits) is recorded too, to cross-check; it only exists if the run ended.
export PATH=/opt/bench-node/bin:$PATH
node -e '
const fs = require("fs"), path = require("path");
function walk(d, out) {
  let ents = []; try { ents = fs.readdirSync(d, {withFileTypes: true}); } catch {}
  for (const x of ents) { const p = path.join(d, x.name); x.isDirectory() ? walk(p, out) : x.name.endsWith(".jsonl") && out.push(p); }
  return out;
}
const seen = new Map(), models = {};
for (const f of walk("/root/.qoder-cn/projects", [])) {
  for (const l of fs.readFileSync(f, "utf8").split("\n")) {
    if (!l.includes("\"credits\"")) continue;
    let e; try { e = JSON.parse(l); } catch { continue; }
    const m = e.message || {}, u = m.usage || {};
    if (u.credits === undefined) continue;
    const id = u.request_id || m.id || l.slice(0, 200);
    if (!seen.has(id)) { seen.set(id, u); models[m.model || "?"] = (models[m.model || "?"] || 0) + 1; }
  }
}
let credits = 0, original = 0, inp = 0, out = 0, cr = 0, cw = 0, billable = 0;
for (const u of seen.values()) {
  credits += u.credits || 0; original += u.original_credits || 0; if (u.billable) billable++;
  inp += u.input_tokens || 0; out += u.output_tokens || 0;
  cr += u.cache_read_input_tokens || 0; cw += u.cache_creation_input_tokens || 0;
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
  usage_source: none ? "none" : "session", requests: seen.size, billable_requests: billable, models,
  credits: none ? null : r4(credits), original_credits: none ? null : r4(original),
  credits_result: result && result.total_credits !== undefined ? r4(result.total_credits) : null,
  input_tokens: none ? null : inp, output_tokens: none ? null : out,
  cache_read_tokens: none ? null : cr, cache_write_tokens: none ? null : cw, cost_usd: null,
  num_turns: result ? result.num_turns : null, effort: process.env.BENCH_EFFORT || "default" }));
'
