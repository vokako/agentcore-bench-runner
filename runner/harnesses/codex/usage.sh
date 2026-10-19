# Runs after the agent however it ended. Writes /bench/usage.json and prints the final message.
# usage_source: "events" = the turn.completed events in /bench/agent.jsonl (emitted when the turn ends);
# "rollout" = the last cumulative token_count in Codex's own session file, which is written as the run
# goes and so survives a timeout kill. Both totals are recorded when available, to cross-check them.
export PATH=/opt/bench-node/bin:$PATH
export CODEX_HOME=/opt/bench/codex-home
node -e '
const fs = require("fs"), path = require("path");
const K = ["input_tokens", "cached_input_tokens", "output_tokens", "reasoning_output_tokens"];
let lines = []; try { lines = fs.readFileSync("/bench/agent.jsonl", "utf8").split("\n").filter(Boolean); } catch {}
const ev = {input_tokens: 0, cached_input_tokens: 0, output_tokens: 0, reasoning_output_tokens: 0};
let turns = 0, last = "";
for (const l of lines) {
  let e; try { e = JSON.parse(l); } catch { continue; }
  if (e.type === "turn.completed" && e.usage) { turns++; for (const k of K) ev[k] += e.usage[k] || 0; }
  if (e.type === "item.completed" && e.item && e.item.type === "agent_message") last = e.item.text || last;
}
function walk(d, out) {
  let ents = []; try { ents = fs.readdirSync(d, {withFileTypes: true}); } catch {}
  for (const x of ents) { const p = path.join(d, x.name); x.isDirectory() ? walk(p, out) : /rollout-.*\.jsonl$/.test(x.name) && out.push(p); }
  return out;
}
let ro = null;   // last cumulative total across the session files
for (const f of walk(path.join(process.env.CODEX_HOME, "sessions"), [])) {
  for (const l of fs.readFileSync(f, "utf8").split("\n")) {
    if (!l.includes("token_count")) continue;
    let e; try { e = JSON.parse(l); } catch { continue; }
    const t = e.payload && e.payload.type === "token_count" && e.payload.info && e.payload.info.total_token_usage;
    if (t) ro = t;
  }
}
const src = turns ? "events" : (ro ? "rollout" : "none");
const u = turns ? ev : (ro || ev), none = src === "none";
fs.writeFileSync("/bench/usage.json", JSON.stringify({
  usage_source: src, rollout_total: ro, event_sum: turns ? ev : null,
  input_tokens: none ? null : u.input_tokens, output_tokens: none ? null : u.output_tokens,
  cache_read_tokens: none ? null : u.cached_input_tokens, cache_write_tokens: null,
  reasoning_tokens: none ? null : u.reasoning_output_tokens, cost_usd: null, turns,
  effort: process.env.BENCH_EFFORT || "default" }));
console.log(last);
'
