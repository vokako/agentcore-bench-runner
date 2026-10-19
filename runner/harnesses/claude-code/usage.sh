# Runs after the agent however it ended (exit, error, timeout kill). Reads /bench/agent.jsonl (the
# stream-json event stream), writes /bench/usage.json and prints the final text for agent.log.
# usage_source: "result" = Claude Code's own totals; "stream+transcript" = summed per message from the event stream and Claude Code's
# session transcript (the run was cut off before the result event). stream_sum is always recorded, to cross-check.
export PATH=/opt/bench-node/bin:$PATH
node -e '
const fs = require("fs");
let lines = []; try { lines = fs.readFileSync("/bench/agent.jsonl", "utf8").split("\n").filter(Boolean); } catch {}
let result = null, last = "";
const msgs = new Map();   // message id -> field-wise max (a message repeats once per content block)
const F = ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"];
function add(e) {
  if (!(e.type === "assistant" && e.message && e.message.usage)) return;
  const id = e.message.id || ("anon" + msgs.size), u = e.message.usage, m = msgs.get(id) || {model: e.message.model};
  for (const k of F) m[k] = Math.max(m[k] || 0, u[k] || 0);
  msgs.set(id, m);
  for (const c of e.message.content || []) if (c.type === "text" && c.text) last = c.text;
}
for (const l of lines) {
  let e; try { e = JSON.parse(l); } catch { continue; }
  if (e.type === "result") result = e; else add(e);
}
// The stream reports output_tokens as the count at the START of a message (2-8), so it is useless. Claude
// Code'"'"'s own session transcript holds the final count; both sources are merged by message id with a max.
const path = require("path");
function walk(d, out) {
  let ents = []; try { ents = fs.readdirSync(d, {withFileTypes: true}); } catch {}
  for (const x of ents) { const p = path.join(d, x.name); x.isDirectory() ? walk(p, out) : x.name.endsWith(".jsonl") && out.push(p); }
  return out;
}
for (const f of walk("/root/.claude/projects", [])) {
  for (const l of fs.readFileSync(f, "utf8").split("\n")) {
    if (!l.includes("\"usage\"")) continue;
    let e; try { e = JSON.parse(l); } catch { continue; }
    add(e);
  }
}
const sum = {input_tokens: 0, output_tokens: 0, cache_read_tokens: 0, cache_write_tokens: 0};
for (const m of msgs.values()) {
  sum.input_tokens += m.input_tokens; sum.output_tokens += m.output_tokens;
  sum.cache_read_tokens += m.cache_read_input_tokens; sum.cache_write_tokens += m.cache_creation_input_tokens;
}
sum.messages = msgs.size;
const u = result && result.usage;
const out = {
  usage_source: u ? "result" : (msgs.size ? "stream+transcript" : "none"), stream_sum: sum,
  input_tokens: u ? u.input_tokens ?? null : (msgs.size ? sum.input_tokens : null),
  output_tokens: u ? u.output_tokens ?? null : (msgs.size ? sum.output_tokens : null),
  cache_read_tokens: u ? u.cache_read_input_tokens ?? null : (msgs.size ? sum.cache_read_tokens : null),
  cache_write_tokens: u ? u.cache_creation_input_tokens ?? null : (msgs.size ? sum.cache_write_tokens : null),
  cost_usd: result ? result.total_cost_usd ?? null : null,
  turns: result ? result.num_turns ?? null : null, effort: process.env.BENCH_EFFORT || "default",
  model_usage: result ? result.modelUsage ?? null : null };
console.log(result ? (result.result || "") : last);
fs.writeFileSync("/bench/usage.json", JSON.stringify(out));
'
