"""Per-task pass matrix across runs: 1 = reward 1, 0 = reward 0, R = model safety refusal, - = no result.

Usage: python scripts/task_matrix.py [--refusals] runs/<run-a> runs/<run-b> ...
--refusals reads agent.log of failed trials from S3 (aws CLI) to mark refusals as R.
"""
import json
import subprocess
import sys

PAT = ("safeguards flagged", "refused to respond", "cannot continue this conversation")
args = sys.argv[1:]
check = "--refusals" in args
runs = [a for a in args if a != "--refusals"]
cells, tasks = {}, []
for run in runs:
    for line in open(f"{run}/results.jsonl"):
        if not line.strip():
            continue
        r = json.loads(line)
        s = r.get("summary") if isinstance(r.get("summary"), dict) else {}
        t = r["task"]
        if t not in tasks:
            tasks.append(t)
        if s.get("reward") == 1:
            v = "1"
        elif s.get("reward") is None:
            v = "-"
        else:
            v = "0"
            if check:
                log = subprocess.run(["aws", "s3", "cp", r["results"] + "agent.log", "-", "--region", "us-east-2"],
                                     capture_output=True, text=True, stdin=subprocess.DEVNULL).stdout
                if any(p in log for p in PAT):
                    v = "R"
        cells[(t, run)] = v
names = [r.rstrip("/").split("/")[-1] for r in runs]
print("| task | " + " | ".join(names) + " |")
print("|---|" + "---|" * len(runs))
for t in sorted(tasks):
    print(f"| {t} | " + " | ".join(cells.get((t, r), "-") for r in runs) + " |")
print("| **pass** | " + " | ".join(str(sum(cells.get((t, r)) == "1" for t in tasks)) for r in runs) + " |")
