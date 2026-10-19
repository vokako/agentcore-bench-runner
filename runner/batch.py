#!/usr/bin/env python3
"""Run many Harbor tasks in one go, --jobs trials at a time, and collect results from S3.

    python runner/batch.py --mode microvm \\
        --image '123456789012.dkr.ecr.us-east-2.amazonaws.com/bench/{task}:arm64' \\
        --jobs 8 --out batch-microvm  <task-dir>...

{task} in --image is replaced by the task directory name. Nothing is task-specific: a
task whose image is missing, that fails to start, or that never finishes is recorded
with the reason and the batch goes on. Output in --out:
    results.jsonl   one line per task as it settles (submit record + summary.json, or the failure)
    summary.md      table of reward, timings and errors
"""
import argparse
import calendar
import concurrent.futures as cf
import json
import os
import sys
import threading
import time

import boto3
from botocore.exceptions import ClientError

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bench  # noqa: E402

LOST_S = 900  # trial.sh refreshes status.json every 300 s; 3 missed beats = sandbox gone


def submit_one(cfg, mode, task_dir, image):
    name = os.path.basename(os.path.normpath(task_dir))
    row = {"task": name, "mode": mode, "image": image}
    size = bench.ecr_image_bytes(image)
    if size is None:
        return {**row, "status": "no-image", "error": "image not found in ECR"}
    try:
        rec = bench.submit(cfg, mode, task_dir, image, cfg.get("harness", "claude-code"), cfg.get("model"), cfg.get("model_region"), cfg.get("effort"))
        return {**row, **rec, "status": "submitted"}
    except SystemExit as exc:  # bench.submit reports expected failures this way
        return {**row, "image_bytes": size, "status": "submit-failed", "error": str(exc)[-600:]}
    except Exception as exc:  # noqa: BLE001 -- record and keep going
        return {**row, "image_bytes": size, "status": "submit-failed", "error": f"{type(exc).__name__}: {exc}"[-600:]}


def read_json(s3, bucket, key):
    try:
        body = s3.get_object(Bucket=bucket, Key=key)["Body"].read()
    except ClientError:
        return None
    try:
        return json.loads(body)
    except ValueError:
        return {"error": f"unreadable {key.rsplit('/', 1)[-1]} ({len(body)} bytes)"}


def wait_one(cfg, row, deadline_s, margin):
    """Wait for this trial's summary.json, up to its own timeouts + margin."""
    s3 = boto3.client("s3", region_name=cfg["results_region"])
    bucket = cfg["results_bucket"]
    prefix = row["results"].split(f"s3://{bucket}/", 1)[1].rstrip("/")
    start = time.time()
    while True:
        summary = read_json(s3, bucket, f"{prefix}/summary.json")
        if summary is not None:
            return {**row, "status": "done", "summary": summary}
        status = read_json(s3, bucket, f"{prefix}/status.json") or {}
        updated = status.get("updated")
        if updated and time.time() - calendar.timegm(time.strptime(updated, "%Y-%m-%dT%H:%M:%SZ")) > LOST_S:
            return {**row, "status": "lost",
                    "error": f"sandbox gone: no heartbeat since {updated}, last phase {status.get('phase')}"}
        if time.time() - start > deadline_s + margin:
            return {**row, "status": "timeout",
                    "error": f"no summary.json; last phase {status.get('phase', 'none')}"}
        time.sleep(30)


def run_one(cfg, mode, task_dir, image, margin, log):
    """Submit one trial and wait for it. Never raises: every outcome becomes a row."""
    row = submit_one(cfg, mode, task_dir, image)
    log(f"[submit] {row['task']}: {row['status']} {row.get('error', '')[:200]}")
    if row["status"] == "submitted":
        task = bench.load_task(task_dir)
        row = wait_one(cfg, row, task["agent_timeout"] + task["verifier_timeout"], margin)
    s = row.get("summary") or {}
    log(f"[done]   {row['task']}: {row['status']} reward={s.get('reward')}")
    return row


def table(rows):
    lines = ["| task | mode | image MB | reward | agent s | verifier s | total s | free MB start->end | note |",
             "|---|---|---|---|---|---|---|---|---|"]
    for r in sorted(rows, key=lambda r: r["task"]):
        s = r.get("summary") or {}
        t = s.get("timings_s") or {}
        d = s.get("disk_free_mb") or {}
        disk = f"{d.get('start')}->{d.get('end')}" if d else "-"
        mb = f"{r['image_bytes'] / 1e6:.0f}" if r.get("image_bytes") else "-"
        reward = s.get("reward")
        note = (s.get("error") or r.get("error") or "").replace("\n", " ").replace("|", "/")[:120]
        if r["status"] != "done":
            note = f"{r['status']}: {note}"
        lines.append(f"| {r['task']} | {r['mode']} | {mb} | {'-' if reward is None else reward} | "
                     f"{t.get('agent', '-')} | {t.get('verifier', '-')} | {t.get('total', '-')} | {disk} | {note} |")
    done = [r for r in rows if r["status"] == "done"]
    passed = sum(1 for r in done if (r["summary"].get("reward") or 0) >= 1)
    lines.append("")
    lines.append(f"tasks {len(rows)}, finished {len(done)}, reward 1: {passed}, "
                 f"not finished: {len(rows) - len(done)}")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--config", default="config.json")
    ap.add_argument("--mode", choices=["microvm", "instances"], required=True)
    ap.add_argument("--image", required=True, help="image URI template with {task}")
    ap.add_argument("--jobs", type=int, default=8, help="trials in flight at a time")
    ap.add_argument("--margin", type=int, default=1800, help="seconds added to each task's timeouts")
    ap.add_argument("--out", required=True)
    ap.add_argument("--harness", default="claude-code", help="runner/harnesses/<name>")
    ap.add_argument("--model", help="model / inference profile for the harness")
    ap.add_argument("--effort", help="reasoning effort passed to the harness (e.g. high)")
    ap.add_argument("--model-region", help="region the harness calls the model in")
    ap.add_argument("tasks", nargs="+", help="Harbor task directories")
    args = ap.parse_args()
    cfg = json.load(open(args.config))
    cfg.setdefault("results_region", cfg["region"])
    cfg["harness"], cfg["model"], cfg["model_region"], cfg["effort"] = args.harness, args.model, args.model_region, args.effort
    bench.harness_dir(args.harness)  # fail fast on an unknown harness
    os.makedirs(args.out, exist_ok=True)

    lock = threading.Lock()
    out = open(os.path.join(args.out, "results.jsonl"), "w")

    def log(msg):
        with lock:
            print(time.strftime("%H:%M:%S"), msg, flush=True)

    # --jobs trials are in flight at a time; each worker submits, waits, then takes the next.
    rows = []
    with cf.ThreadPoolExecutor(args.jobs) as pool:
        futs = [pool.submit(run_one, cfg, args.mode, d,
                            args.image.format(task=os.path.basename(os.path.normpath(d))),
                            args.margin, log)
                for d in args.tasks]
        for f in cf.as_completed(futs):
            row = f.result()
            rows.append(row)
            with lock:
                out.write(json.dumps(row) + "\n"); out.flush()
    out.close()
    md = table(rows)
    open(os.path.join(args.out, "summary.md"), "w").write(md + "\n")
    print(md)


if __name__ == "__main__":
    main()
