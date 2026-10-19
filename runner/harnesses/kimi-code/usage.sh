# Runs after the agent however it ended. Writes /bench/usage.json and prints the final message.
# Source: the usage.record events kimi writes to $KIMI_CODE_HOME/sessions/**/agents/<agent>/wire.jsonl
# as each model request completes, one file per agent (main plus every sub-agent), so a timeout kill
# loses only the request that was still streaming. Checked against Bedrock's own usage through a
# logging proxy: input, cache-read and output match exactly, including sub-agents.
#   inputOther = uncached input, inputCacheRead = cached input, output = completion (reasoning included).
export PATH=/opt/bench-node/bin:$PATH
node -e '
const fs = require("fs"), path = require("path");
const home = "/opt/bench/kimi-home/sessions";
function walk(d, out) {
  let ents = []; try { ents = fs.readdirSync(d, {withFileTypes: true}); } catch {}
  for (const x of ents) { const p = path.join(d, x.name); x.isDirectory() ? walk(p, out) : x.name === "wire.jsonl" && out.push(p); }
  return out;
}
const u = {input: 0, cache_read: 0, cache_write: 0, output: 0}, agents = {};
let records = 0, effort = null;
for (const f of walk(home, [])) {
  const agent = f.split("/agents/")[1].split("/")[0];
  for (const l of fs.readFileSync(f, "utf8").split("\n")) {
    if (!l) continue;
    let e; try { e = JSON.parse(l); } catch { continue; }
    if (e.type === "profile.bind" && agent === "main" && e.thinkingEffort) effort = e.thinkingEffort;
    if (e.type !== "usage.record" || !e.usage) continue;
    records++; agents[agent] = (agents[agent] || 0) + 1;
    u.input += e.usage.inputOther || 0; u.cache_read += e.usage.inputCacheRead || 0;
    u.cache_write += e.usage.inputCacheCreation || 0; u.output += e.usage.output || 0;
  }
}
let last = "";
try {
  for (const l of fs.readFileSync("/bench/agent.jsonl", "utf8").split("\n")) {
    let e; try { e = JSON.parse(l); } catch { continue; }
    if (e.role === "assistant" && typeof e.content === "string" && e.content) last = e.content;
  }
} catch {}
const none = records === 0;
fs.writeFileSync("/bench/usage.json", JSON.stringify({
  usage_source: none ? "none" : "wire", requests: records, agents,
  input_tokens: none ? null : u.input, output_tokens: none ? null : u.output,
  cache_read_tokens: none ? null : u.cache_read, cache_write_tokens: none ? null : u.cache_write,
  cost_usd: null, effort: process.env.BENCH_EFFORT || effort || "default" }));
console.log(last);
'
