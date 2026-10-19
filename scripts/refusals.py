"""List failed trials whose agent.log shows a model safety refusal.
Usage: python scripts/refusals.py runs/<run> [...]   (reads agent.log from S3 via the aws CLI)"""
import json, subprocess, sys
PAT = ("safeguards flagged", "refused to respond", "cannot continue this conversation")
for run in sys.argv[1:]:
    hits = []
    for l in open(f"{run}/results.jsonl"):
        r = json.loads(l); s = r.get("summary") or {}
        if s.get("reward") == 1:
            continue
        log = subprocess.run(["aws", "s3", "cp", r["results"] + "agent.log", "-", "--region", "us-east-2"],
                             capture_output=True, text=True, stdin=subprocess.DEVNULL).stdout
        if any(p in log for p in PAT):
            hits.append(r["task"])
    print(f"{run.split('/')[-1]}\trefused={len(hits)}\t{' '.join(hits)}")
