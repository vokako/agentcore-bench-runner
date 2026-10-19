"""Re-run kiro-cli trials that timed out with no credits recorded, to recover their cost only.

Before the trace-log harness (agent.sh keeps kiro-cli's per-request MeteringEvent lines), a timed-out
kiro trial lost all of its credits: stream-json reports them once per turn and a headless task is one
turn. This re-runs exactly those trials under the trace harness and copies the measured credits back.

  python scripts/backfill_credits.py plan  [--out runs/trace_backfill.json]
      list every kiro-cli trial with agent_exit 124 and no credits, grouped by run
  python scripts/backfill_credits.py launch runs/trace_backfill.json [--suffix trace1] [--jobs 1]
      one systemd unit per run: runs/<run>-<suffix>/ with only those tasks, same model / effort /
      steering / kiro-cli version (2.29.0); kimi-k3 runs use the Kiro key stage KEY1
  python scripts/backfill_credits.py merge runs/trace_backfill.json [--suffix trace1]
      for each listed trial, copy the re-run's credits into the ORIGINAL row's usage
      (usage_source "trace-rerun", credits_rerun_from = re-run run_id). The original reward, timings
      and error stay: the re-run measures cost, it does not replace the outcome. Original file kept as
      results.pre-<suffix>.jsonl. A re-run that also has no credits is reported and left alone.
"""
import argparse, json, os, re, subprocess, sys

ap = argparse.ArgumentParser()
ap.add_argument("cmd", choices=["plan", "launch", "merge"])
ap.add_argument("found", nargs="?", default="runs/trace_backfill.json")
ap.add_argument("--suffix", default="trace1")
ap.add_argument("--jobs", type=int, default=1)
a = ap.parse_args()
os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
SKIP = re.compile(r"-(retry|lost|resume|trace|rerun)\d+$")


def rows(run):
    return [json.loads(l) for l in open(f"runs/{run}/results.jsonl") if l.strip()]


def summary(r):
    return r.get("summary") or r


if a.cmd == "plan":
    plan = {}
    for run in sorted(os.listdir("runs")):
        if run.startswith((".", "smoke", "t-")) or SKIP.search(run) or not os.path.isfile(f"runs/{run}/results.jsonl"):
            continue
        for r in rows(run):
            s = summary(r)
            if s.get("harness") != "kiro-cli":
                break
            if s.get("agent_exit") == 124 and (s.get("usage") or {}).get("credits") is None:
                eff = run.rsplit("-", 1)[1]
                p = plan.setdefault(run, {"model": s.get("model"), "effort": "default" if eff == "default" else eff,
                                          "steering": "steer-v2" if "-steerv2-" in run else "", "tasks": []})
                p["tasks"].append(s["task"])
    json.dump(plan, open(a.found, "w"), indent=1)
    print(sum(len(p["tasks"]) for p in plan.values()), "trials in", len(plan), "runs ->", a.found)
    sys.exit()

plan = json.load(open(a.found))
for run, p in plan.items():
    sub = f"{run}-{a.suffix}"
    if a.cmd == "launch":
        lst = f"runs/{sub}.txt"
        open(lst, "w").write("".join(t + "\n" for t in p["tasks"]))
        env = dict(os.environ, BENCH_KIRO_VERSION="2.29.0")
        if p["model"] == "kimi-k3":  # the default Kiro key (KEY2) has no kimi-k3 access
            env["BENCH_KIRO_SECRET"] = "bench/kiro-api-key:KEY1"
        if p["steering"]:
            env["BENCH_STEERING"] = f"benchmarks/steering/{p['steering']}.md"
        r = subprocess.run(["scripts/launch_unit.sh", sub, "kiro-cli", p["model"], p["effort"], str(a.jobs), lst],
                           env=env, capture_output=True, text=True, stdin=subprocess.DEVNULL)
        print(run, len(p["tasks"]), (r.stdout or r.stderr).strip())
        continue
    got = {summary(r)["task"]: summary(r) for r in rows(sub)} if os.path.isfile(f"runs/{sub}/results.jsonl") else {}
    orig = rows(run)
    os.replace(f"runs/{run}/results.jsonl", f"runs/{run}/results.pre-{a.suffix}.jsonl")
    filled = []
    with open(f"runs/{run}/results.jsonl", "w") as out:
        for r in orig:
            s = summary(r)
            g = got.get(s["task"])
            gu = (g or {}).get("usage") or {}
            if s["task"] in p["tasks"] and gu.get("credits") is not None and (s.get("usage") or {}).get("credits") is None:
                u = dict(s.get("usage") or {})
                u.update({k: gu.get(k) for k in ("credits", "credits_trace", "metering_events", "credits_stream", "requests", "effort")})
                u["usage_source"] = "trace-rerun"
                u["credits_rerun_from"] = g.get("run_id")
                u["credits_rerun_agent_exit"] = g.get("agent_exit")
                s["usage"] = u
                filled.append(s["task"])
            out.write(json.dumps(r) + "\n")
    missing = [t for t in p["tasks"] if t not in filled]
    print(f"{run}: filled {len(filled)}/{len(p['tasks'])}" + (f"  NOT filled: {missing}" if missing else ""))
