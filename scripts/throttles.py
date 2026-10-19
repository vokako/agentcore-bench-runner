"""Find failed trials whose agent logs show rate limiting (HTTP 429 / throttling).
Usage: python scripts/throttles.py runs/<run> [...] [--json out.json]
Reads agent.log and agent.jsonl from S3 for every trial with reward != 1."""
import json, re, sys
from concurrent.futures import ThreadPoolExecutor
import boto3

# Harness-level throttling only. A broad "429|throttl|rate limit" match hits task content
# (numbers, HTTP headers, third-party APIs the agent calls), so match the service messages.
PAT = re.compile(r"request was throttled by the service|ThrottlingException|TooManyRequestsException"
                 r"|Too many requests, please wait", re.I)
s3 = boto3.client("s3", region_name="us-east-2")


def fetch(uri, name):
    b, k = uri[5:].split("/", 1)
    try:
        return s3.get_object(Bucket=b, Key=k + name)["Body"].read().decode("utf-8", "replace")
    except s3.exceptions.NoSuchKey:
        return ""


def check(r):
    text = fetch(r["results"], "agent.log") + "\n" + fetch(r["results"], "agent.jsonl")
    m = PAT.search(text)
    return r, (text[max(0, m.start() - 80): m.end() + 80].replace("\n", " ") if m else None)


args = sys.argv[1:]
out = None
if "--json" in args:
    i = args.index("--json"); out = args[i + 1]; del args[i:i + 2]
found = []
for run in args:
    rows = [json.loads(l) for l in open(f"{run}/results.jsonl")]
    bad = [r for r in rows if (r.get("summary") or {}).get("reward") != 1]
    with ThreadPoolExecutor(16) as ex:
        hits = [(r, snip) for r, snip in ex.map(check, bad) if snip]
    name = run.rstrip("/").split("/")[-1]
    print(f"{name}\tfailed={len(bad)}\tthrottled={len(hits)}\t{' '.join(r['task'] for r, _ in hits)}")
    for r, snip in hits:
        found.append({"run": name, "task": r["task"], "run_id": r["run_id"], "harness": r.get("harness"),
                      "model": r.get("model"), "effort": r.get("effort"), "snippet": snip})
if out:
    json.dump(found, open(out, "w"), indent=1)
