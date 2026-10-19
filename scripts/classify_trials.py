"""Classify every trial of the given runs by why it ended abnormally: model refusal or service throttling.

Usage: python scripts/classify_trials.py runs/<run> [...] [--json found.json]

Reads agent.log / agent.jsonl / agent.json from S3 for every trial (passed ones too: a trial can be
throttled after the task is already solved) and writes runs/<run>/outcomes.json:

    {"<run_id>": {"task": ..., "class": "refused" | "throttled" | "not_run", "snippet": ...}}

not_run = the account's quota was exhausted before any model request was made.

Only service-level messages are matched, never the task's own content: agent.log is checked in its
last 3 KB, and the event streams only in their error / result events.
--json writes the throttled trials in the format scripts/retry_throttled.py takes.
"""
import json, re, sys
from concurrent.futures import ThreadPoolExecutor
import boto3

REFUSED = re.compile(
    r"refused to respond|cannot continue this conversation|safeguards flagged|CONTENT_FILTERED"
    r"|flagged for potentially high-risk cyber activity|\"stop_reason\":\s*\"refusal\"", re.I)
THROTTLED = re.compile(
    r"request was throttled by the service|ThrottlingException|TooManyRequestsException|Too many requests"
    r"|rate limit(?:ed| exceeded)|high traffic|overloaded_error|experiencing high demand"
    r"|ServiceUnavailableException|model is (?:currently )?overloaded", re.I)
# Account quota ran out before the model was called: the trial says nothing about the model and is
# shown as "not run" (excluded from the score). Qoder CN: error_code 118; CodeBuddy: 14001.
QUOTA = re.compile(
    r"Credits have been exhausted|quota_balance_exhausted|\"error_code\":\s*(?:118|14001)\b"
    r"|insufficient (?:balance|credits|quota)", re.I)
ERROR_EVENTS = {"runError", "error", "turn.failed", "result", "system"}
s3 = boto3.client("s3", region_name="us-east-2")


def fetch(uri, name):
    b, k = uri[5:].split("/", 1)
    try:
        return s3.get_object(Bucket=b, Key=k + name)["Body"].read().decode("utf-8", "replace")
    except s3.exceptions.NoSuchKey:
        return ""


def service_text(r):
    """The parts of a trial's logs where service errors show up."""
    parts = [fetch(r["results"], "agent.log")[-3000:]]
    for name in ("agent.jsonl", "agent.json"):
        for line in fetch(r["results"], name).splitlines():
            try:
                e = json.loads(line)
            except ValueError:
                continue
            if not isinstance(e, dict):
                continue
            t = e.get("type")
            if t in ERROR_EVENTS or (t == "metadata" and (e.get("data") or {}).get("stopReason")):
                parts.append(line[:4000])
            elif e.get("is_error"):
                parts.append(line[:4000])
    return "\n".join(parts)


def classify(r):
    if not isinstance(r.get("summary"), dict):
        return r, None, None
    text = service_text(r)
    for cls, pat in (("not_run", QUOTA), ("refused", REFUSED), ("throttled", THROTTLED)):
        m = pat.search(text)
        if m and cls == "not_run" and (r["summary"].get("usage") or {}).get("requests"):
            continue  # quota ran out mid-trial after real model calls: a normal (failed) trial
        if m:
            return r, cls, text[max(0, m.start() - 100): m.end() + 100].replace("\n", " ")
    return r, None, None


args = sys.argv[1:]
out = None
if "--json" in args:
    i = args.index("--json"); out = args[i + 1]; del args[i:i + 2]
throttled = []
for run in args:
    run = run.rstrip("/")
    rows = [json.loads(l) for l in open(f"{run}/results.jsonl") if l.strip()]
    with ThreadPoolExecutor(32) as ex:
        res = [(r, c, s) for r, c, s in ex.map(classify, rows) if c]
    outcomes = {r["run_id"]: {"task": r["task"], "class": c, "snippet": s} for r, c, s in res}
    json.dump(outcomes, open(f"{run}/outcomes.json", "w"), indent=1)
    name = run.split("/")[-1]
    n = {c: sum(1 for _, x, _ in res if x == c) for c in ("refused", "throttled", "not_run")}
    print(f"{name}\ttrials={len(rows)}\trefused={n['refused']}\tthrottled={n['throttled']}\tnot_run={n['not_run']}")
    for r, c, s in res:
        if c == "throttled":
            throttled.append({"run": name, "task": r["task"], "run_id": r["run_id"], "harness": r.get("harness"),
                              "model": r.get("model"), "effort": r.get("effort"),
                              "reward": (r.get("summary") or {}).get("reward"), "snippet": s})
if out:
    json.dump(throttled, open(out, "w"), indent=1)
