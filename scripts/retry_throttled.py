"""Re-run trials that failed because the harness was throttled, then merge the retries back.

  python scripts/retry_throttled.py launch runs/throttles.json [--jobs 1] [--suffix retry1]
      one background batch per affected run: runs/<run>-<suffix>/ with only the throttled tasks
  python scripts/retry_throttled.py merge runs/throttles.json [--suffix retry1]
      replaces the throttled rows in runs/<run>/results.jsonl with the retry rows
      (original kept as results.pre-<suffix>.jsonl); a retry that is itself throttled is kept
      but reported, so run throttles.py on the retry dirs before merging.
"""
import argparse, collections, json, os, subprocess

ap = argparse.ArgumentParser()
ap.add_argument("cmd", choices=["launch", "merge"])
ap.add_argument("found")
ap.add_argument("--jobs", type=int, default=1)
ap.add_argument("--suffix", default="retry1")
a = ap.parse_args()
os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

groups = collections.defaultdict(list)
for h in json.load(open(a.found)):
    groups[h["run"]].append(h)

for run, hits in sorted(groups.items()):
    retry = f"{run}-{a.suffix}"
    if a.cmd == "launch":
        h = hits[0]
        lst = f"runs/{retry}.txt"
        with open(lst, "w") as f:
            f.write("".join(x["task"] + "\n" for x in hits))
        r = subprocess.run(["scripts/run_suite.sh", retry, h["harness"], h["model"], h["effort"], str(a.jobs), lst],
                           capture_output=True, text=True, stdin=subprocess.DEVNULL)
        print(run, len(hits), (r.stdout or r.stderr).strip())
        continue
    path = f"runs/{retry}/results.jsonl"
    new = {}
    for l in open(path):
        r = json.loads(l)
        new[r["task"]] = r
    want = {x["task"] for x in hits}
    missing = want - new.keys()
    if missing:
        print(f"{run}: retry not finished for {sorted(missing)}; skipped"); continue
    src = f"runs/{run}/results.jsonl"
    rows = [json.loads(l) for l in open(src)]
    os.replace(src, f"runs/{run}/results.pre-{a.suffix}.jsonl")
    with open(src, "w") as f:
        for r in rows:
            if r["task"] in want:
                r = dict(new[r["task"]], retry_of=r["run_id"])
            f.write(json.dumps(r) + "\n")
    before = sum((r.get("summary") or {}).get("reward") == 1 for r in rows)
    after = sum((json.loads(l).get("summary") or {}).get("reward") == 1 for l in open(src))
    print(f"{run}: replaced {len(want)} rows, reward 1: {before} -> {after}")
