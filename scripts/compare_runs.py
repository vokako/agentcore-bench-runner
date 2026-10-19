"""Compare harness runs: pass rate, agent time, tokens and cost.

Usage: python scripts/compare_runs.py runs/<run-a> runs/<run-b> ... [--pricing benchmarks/pricing.json]

Each run directory holds batch.py's results.jsonl. Cost is recomputed from token counts
and benchmarks/pricing.json (USD per 1M tokens), not taken from what a harness reports.
For kiro-cli, cost = credits x kiro-credit.usd_per_credit ($0.02, the plan-included rate).
Prints a Markdown table.
"""
import argparse
import json
import os
import statistics


def load(run_dir):
    return [json.loads(l) for l in open(os.path.join(run_dir, "results.jsonl")) if l.strip()]


def token_cost(u, price):
    if not price or price.get("input") is None:
        return None
    # input_tokens semantics differ: Claude Code reports uncached input only; Codex reports
    # all input including the cached part (cached_input_tokens is a subset of it).
    cache_read = u.get("cache_read_tokens") or 0
    cache_write = u.get("cache_write_tokens") or 0
    inp = u.get("input_tokens") or 0
    if u.get("_input_includes_cache"):
        inp = max(inp - cache_read, 0)
    return (inp * price["input"] + (u.get("output_tokens") or 0) * price["output"]
            + cache_read * price["cache_read"] + cache_write * price["cache_write"]) / 1e6


def summarize(run_dir, pricing):
    rows = load(run_dir)
    done = [r for r in rows if isinstance(r.get("summary"), dict)]
    first = done[0] if done else rows[0]
    harness, model, effort = first.get("harness"), first.get("model"), first.get("effort") or "default"
    passed = sum(1 for r in done if r["summary"].get("reward") == 1)
    agent_s = [r["summary"]["timings_s"]["agent"] for r in done if r["summary"].get("timings_s", {}).get("agent") is not None]
    tok = {"in": 0, "out": 0, "cache_read": 0, "cache_write": 0}
    cost, credits, with_usage = 0.0, 0.0, 0
    for r in done:
        u = dict(r["summary"].get("usage") or {})
        if not u:
            continue
        with_usage += 1
        if harness == "codex":
            u["_input_includes_cache"] = True
        tok["in"] += u.get("input_tokens") or 0
        tok["out"] += u.get("output_tokens") or 0
        tok["cache_read"] += u.get("cache_read_tokens") or 0
        tok["cache_write"] += u.get("cache_write_tokens") or 0
        if u.get("credits") is not None:
            credits += u["credits"]
        c = token_cost(u, pricing.get(model))
        if c is not None:
            cost += c
    if harness == "kiro-cli":
        per = pricing.get("kiro-credit", {}).get("usd_per_credit", 0.02)
        cost_txt = f"${credits * per:.2f} ({credits:.1f} credits)"
    else:
        cost_txt = f"${cost:.2f}" if pricing.get(model, {}).get("input") is not None else "no price"
    return {
        "run": os.path.basename(os.path.normpath(run_dir)), "harness": harness, "model": model, "effort": effort,
        "tasks": len(rows), "finished": len(done), "passed": passed,
        "agent_median_s": round(statistics.median(agent_s)) if agent_s else None,
        "agent_total_min": round(sum(agent_s) / 60, 1),
        "tokens": tok, "usage_rows": with_usage, "cost": cost_txt,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("runs", nargs="+")
    ap.add_argument("--pricing", default=os.path.join(os.path.dirname(__file__), "..", "benchmarks", "pricing.json"))
    a = ap.parse_args()
    pricing = json.load(open(a.pricing))
    print("| run | harness | model | effort | pass | agent median s | agent total min | input tok | output tok | cache read | cache write | cost |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|")
    for d in a.runs:
        s = summarize(d, pricing)
        t = s["tokens"]
        print(f'| {s["run"]} | {s["harness"]} | `{s["model"]}` | {s["effort"]} | {s["passed"]}/{s["tasks"]} '
              f'| {s["agent_median_s"]} | {s["agent_total_min"]} | {t["in"]:,} | {t["out"]:,} | {t["cache_read"]:,} '
              f'| {t["cache_write"]:,} | {s["cost"]} |')


if __name__ == "__main__":
    main()
