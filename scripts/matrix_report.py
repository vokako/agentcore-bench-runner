"""Merge the sweep's runs into one table: one row per agent + model + effort over all task lists.

    python scripts/matrix_report.py [--matrix benchmarks/matrix.txt] [--runs runs] [--out FILE]

For each matrix row and effort it reads runs/<subset>-<name>-<effort>/results.jsonl for every
subset (default fast30, hard20) and reports passed / total, passes per subset, cost and mean
agent time per task. A trial with no reward (lost, or no reward written) counts as a fail.
Cost uses the same rules as compare_runs.py: tokens x benchmarks/pricing.json for Claude Code
and Codex, credits x kiro-credit.usd_per_credit for kiro-cli.
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from compare_runs import token_cost  # noqa: E402

EFFORTS = ("low", "medium", "high")


def read_matrix(path):
    rows = []
    for line in open(path):
        parts = line.split()
        if parts and not parts[0].startswith("#"):
            rows.append((parts[0], parts[1], parts[2]))
    return rows


def trial_cost(r, pricing):
    s = r.get("summary") or {}
    u = dict(s.get("usage") or {})
    if r.get("harness") == "kiro-cli":
        return (u.get("credits") or 0) * pricing.get("kiro-credit", {}).get("usd_per_credit", 0.02)
    if r.get("harness") == "codex":
        u["_input_includes_cache"] = True
    return token_cost(u, pricing.get(r.get("model"))) or 0.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--matrix", default="benchmarks/matrix.txt")
    ap.add_argument("--runs", default="runs")
    ap.add_argument("--subsets", default="fast30,hard20")
    ap.add_argument("--pricing", default="benchmarks/pricing.json")
    ap.add_argument("--out")
    a = ap.parse_args()
    pricing = json.load(open(a.pricing))
    subsets = a.subsets.split(",")

    table, missing = [], []
    for name, harness, model in read_matrix(a.matrix):
        for effort in EFFORTS:
            row = dict(name=name, harness=harness, model=model, effort=effort, n=0, passed=0,
                       cost=0.0, agent_s=0.0, timed=0, by_subset={})
            for sub in subsets:
                path = os.path.join(a.runs, f"{sub}-{name}-{effort}", "results.jsonl")
                if not os.path.exists(path):
                    missing.append(f"{sub}-{name}-{effort}")
                    continue
                ok = 0
                for line in open(path):
                    if not line.strip():
                        continue
                    r = json.loads(line)
                    s = r.get("summary") or {}
                    row["n"] += 1
                    ok += s.get("reward") == 1
                    agent = (s.get("timings_s") or {}).get("agent")
                    if agent is not None:
                        row["agent_s"] += agent
                        row["timed"] += 1
                    row["cost"] += trial_cost(r, pricing)
                row["by_subset"][sub] = ok
                row["passed"] += ok
            if row["n"]:
                table.append(row)

    table.sort(key=lambda r: (-r["passed"], r["cost"]))
    head = ["#", "Agent + model", "effort", "passed", *subsets, "cost (USD)", "agent min / task"]
    out = ["| " + " | ".join(head) + " |", "|" + "---|" * len(head)]
    for i, r in enumerate(table, 1):
        mins = r["agent_s"] / r["timed"] / 60 if r["timed"] else 0
        out.append("| " + " | ".join([
            str(i), f"{r['name']} ({r['model']})", r["effort"], f"{r['passed']}/{r['n']}",
            *[str(r["by_subset"].get(s, "-")) for s in subsets], f"{r['cost']:.2f}", f"{mins:.1f}",
        ]) + " |")
    text = "\n".join(out) + "\n"
    if missing:
        text += "\nMissing runs: " + ", ".join(missing) + "\n"
    if a.out:
        open(a.out, "w").write(text)
    sys.stdout.write(text)


if __name__ == "__main__":
    main()
