# Runs after the agent however it ended. Writes /bench/usage.json and prints the final text.
# Credits, best source first:
#   "trace"    - one MeteringEvent per completed model request, from /bench/kiro-metering.log (agent.sh
#                keeps them out of kiro-cli's trace log). A timeout kill loses only the request in flight.
#   "metering" - the per-turn metadata.meteringUsage in /bench/agent.jsonl, written when a turn ends.
# Both totals are recorded when present (credits_trace / credits_stream) to cross-check them.
export PATH=/opt/bench-node/bin:$PATH
node -e '
const fs = require("fs");
let stream = 0, turns = 0, effort = null, text = "", requests = 0;
let lines = []; try { lines = fs.readFileSync("/bench/agent.jsonl", "utf8").split("\n"); } catch {}
for (const l of lines) {
  let e; try { e = JSON.parse(l); } catch { continue; }
  const d = e.data || {};
  if (e.type === "metadata") {
    requests++;
    if (d.reasoning && d.reasoning.effort) effort = d.reasoning.effort;
    for (const m of d.meteringUsage || []) if (m.unit === "credit") { stream += m.value; turns++; }
  }
  const u = d.update || d;
  if (e.type === "sessionUpdate" && u.content && u.content.type === "text") text += u.content.text || "";
}
let trace = 0, events = 0;
try {
  for (const l of fs.readFileSync("/bench/kiro-metering.log", "utf8").split("\n")) {
    const m = l.match(/MeteringEvent \{ usage: Some\(([0-9.eE+-]+)\), unit: Some\("credit"\)/);
    if (m) { trace += parseFloat(m[1]); events++; }
  }
} catch {}
const r4 = x => Math.round(x * 10000) / 10000;
const src = events ? "trace" : (turns ? "metering" : "none");
const credits = events ? trace : (turns ? stream : null);
console.log(text);
fs.writeFileSync("/bench/usage.json", JSON.stringify({
  usage_source: src, credits: credits === null ? null : r4(credits),
  credits_trace: events ? r4(trace) : null, metering_events: events,
  credits_stream: turns ? r4(stream) : null, turns, requests, effort,
  input_tokens: null, output_tokens: null, cache_read_tokens: null, cache_write_tokens: null, cost_usd: null }));
'
