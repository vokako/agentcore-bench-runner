"""Recover usage the in-sandbox summarizer missed, from the event stream already in S3.

Usage: python scripts/recompute_usage.py runs/<run> [...] [--dry-run]

Only kiro-cli trials whose summary has no credits are looked at: their agent.jsonl is re-read and the
meteringUsage credits summed. This finds trials whose stream does hold credits but whose summary was
never written (the old summarizer ran after kiro-cli exited, so a timeout killed it too). A trial whose
stream has no credit at all stays empty: kiro-cli reports credits only when a turn ends, so a run cut
off by the timeout never reports any, and nothing else records them (checked against kiro-cli's session
files and logs).

The original file is kept as results.pre-usage.jsonl. Recovered trials get usage_source "recovered".
"""
import json, os, shutil, sys
import boto3

s3 = boto3.client("s3", region_name="us-east-2")


def credits_of(uri):
    b, k = uri[5:].split("/", 1)
    try:
        text = s3.get_object(Bucket=b, Key=k + "agent.jsonl")["Body"].read().decode("utf-8", "replace")
    except s3.exceptions.NoSuchKey:
        return None, 0
    total, n = 0.0, 0
    for line in text.splitlines():
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if e.get("type") != "metadata":
            continue
        for m in (e.get("data") or {}).get("meteringUsage") or []:
            if m.get("unit") == "credit":
                total += m["value"]
                n += 1
    return (round(total, 4) if n else None), n


def main(argv):
    dry = "--dry-run" in argv
    for run in [a for a in argv if not a.startswith("--")]:
        path = os.path.join(run, "results.jsonl")
        rows = [json.loads(l) for l in open(path) if l.strip()]
        fixed = 0
        for r in rows:
            s = r.get("summary")
            if r.get("harness") != "kiro-cli" or not isinstance(s, dict):
                continue
            u = s.get("usage") or {}
            if u.get("credits") is not None:
                continue
            c, n = credits_of(r["results"])
            if c is None:
                continue
            u.update(credits=c, turns=n, usage_source="recovered")
            s["usage"] = u
            fixed += 1
            print(f"{run}: {r['task']} -> {c} credits")
        if fixed and not dry:
            backup = os.path.join(run, "results.pre-usage.jsonl")
            if not os.path.exists(backup):
                shutil.copy(path, backup)
            with open(path, "w") as f:
                for r in rows:
                    f.write(json.dumps(r) + "\n")
        print(f"{run}: recovered {fixed}")


if __name__ == "__main__":
    main(sys.argv[1:])
