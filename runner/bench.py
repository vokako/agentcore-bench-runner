#!/usr/bin/env python3
"""Submit Harbor-format tasks to Amazon Bedrock AgentCore and fetch their results.

The client does two things only:
    submit   start a trial; returns as soon as the trial is running in the sandbox
    results  read reward and logs from S3

Everything in between -- running the agent, waiting for it to exit, grading with the
task's tests/test.sh, uploading results, releasing the sandbox -- runs inside the
AgentCore runtime session (runner/trial.sh). The client is not involved.

    python runner/bench.py submit --mode microvm   --task tasks/fix-git --image <arm64-uri>
    python runner/bench.py submit --mode instances --task tasks/fix-git --image <uri> \\
        --config config.instances.json
    python runner/bench.py results <run-id>
    python runner/bench.py cleanup
"""
import argparse
import base64
import hashlib
import io
import json
import os
import re
import sys
import tarfile
import time
import tomllib
import uuid

import boto3
import botocore.config
from botocore.exceptions import ClientError

HERE = os.path.dirname(os.path.abspath(__file__))
PREFIX = "bench_"  # name prefix of sandboxes created by this tool
LONG = botocore.config.Config(read_timeout=3600, connect_timeout=30, retries={"max_attempts": 0})
# Control-plane list/create calls are rate limited per account; batches submit in parallel.
CTRL = botocore.config.Config(retries={"mode": "adaptive", "max_attempts": 12})
MAX_LIFETIME = 28800  # AgentCore maximum (8 h)


def code_of(exc):
    return exc.response["Error"]["Code"] if isinstance(exc, ClientError) else type(exc).__name__


# --------------------------------------------------------------------------- task

def load_task(task_dir):
    """Read a Harbor task: instruction.md, task.toml, tests/."""
    cfg = tomllib.load(open(os.path.join(task_dir, "task.toml"), "rb"))
    instruction = open(os.path.join(task_dir, "instruction.md")).read()
    workdir = cfg.get("environment", {}).get("workdir")
    if not workdir:  # fall back to the last WORKDIR of environment/Dockerfile
        dockerfile = os.path.join(task_dir, "environment", "Dockerfile")
        if os.path.exists(dockerfile):
            found = re.findall(r"^\s*WORKDIR\s+(\S+)", open(dockerfile).read(), re.M)
            workdir = found[-1] if found else None
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        tests = os.path.join(task_dir, "tests")
        for name in sorted(os.listdir(tests)):
            tar.add(os.path.join(tests, name), arcname=name)
    return {
        "name": os.path.basename(os.path.normpath(task_dir)),
        "instruction": instruction,
        "tests_tgz": buf.getvalue(),
        "workdir": workdir or "/",
        "agent_timeout": int(cfg.get("agent", {}).get("timeout_sec", 3600)),
        "verifier_timeout": int(cfg.get("verifier", {}).get("timeout_sec", 900)),
    }


# --------------------------------------------------------------------------- sandbox

class Sandbox:
    """One AgentCore resource per (mode, image), reused across trials.

    microVM:   Harness (the harness keeps the session alive; the image is unchanged)
    instances: Agent runtime on a capacity provider (image wrapped by adapter/)
    """

    def __init__(self, cfg, mode, image):
        self.cfg, self.mode, self.image = cfg, mode, image
        self.cp = boto3.client("bedrock-agentcore-control", region_name=cfg["region"], config=CTRL)
        # An Instances runtime is bound to its capacity provider, so that is part of its identity.
        key = f"{mode}|{image}" + (f"|{cfg['capacity_provider_arn']}" if mode == "instances" else "")
        digest = hashlib.sha1(key.encode()).hexdigest()[:10]
        self.name = f"{PREFIX}{mode}_{digest}"
        self.id = self.arn = None

    def lifecycle(self):
        # No client calls reach the session while the agent runs, so the idle timer must
        # cover the whole trial. trial.sh stops the session itself when it is done.
        return {"idleRuntimeSessionTimeout": MAX_LIFETIME, "maxLifetime": MAX_LIFETIME}

    def ensure(self):
        found = self._find()
        if not found:
            self._create()
        state = self._wait()
        if state != "READY":
            raise RuntimeError(f"sandbox {self.name} is {state}")
        return self

    def _wait(self, budget=1200):
        deadline = time.time() + budget
        while time.time() < deadline:
            state = self._status()
            if state == "READY" or (state or "").endswith("FAILED"):
                return state
            time.sleep(10)
        return self._status()

    def _find(self):
        for item in self._list():
            name = item.get("harnessName") or item.get("agentRuntimeName")
            if name == self.name:
                if self.mode == "microvm":
                    self.id, self.arn = item["harnessId"], item["arn"]
                else:
                    self.id, self.arn = item["agentRuntimeId"], item["agentRuntimeArn"]
                return True
        return False

    def _list(self):
        return list_all(self.cp, self.mode)

    def _create(self):
        if self.mode == "microvm":
            h = self.cp.create_harness(
                harnessName=self.name,
                executionRoleArn=self.cfg["execution_role_arn"],
                environmentArtifact={"containerConfiguration": {"containerUri": self.image}},
                model={"bedrockModelConfig": {"modelId": self.cfg["model_id"]}},
                environment={"agentCoreRuntimeEnvironment": {"lifecycleConfiguration": self.lifecycle()}},
            )["harness"]
            self.id, self.arn = h["harnessId"], h["arn"]
        else:
            r = self.cp.create_agent_runtime(
                agentRuntimeName=self.name,
                agentRuntimeArtifact={"containerConfiguration": {"containerUri": self.image}},
                roleArn=self.cfg["execution_role_arn"],
                protocolConfiguration={"serverProtocol": "HTTP"},
                capacityProviderConfiguration={"capacityProviderArn": self.cfg["capacity_provider_arn"]},
                lifecycleConfiguration=self.lifecycle(),
            )
            self.id, self.arn = r["agentRuntimeId"], r["agentRuntimeArn"]

    def _status(self):
        if self.mode == "microvm":
            return self.cp.get_harness(harnessId=self.id)["harness"].get("status")
        return self.cp.get_agent_runtime(agentRuntimeId=self.id).get("status")


def list_all(cp, mode):
    """All harnesses (microvm) or agent runtimes (instances), across pages."""
    op, key = (cp.list_harnesses, "harnesses") if mode == "microvm" else (cp.list_agent_runtimes, "agentRuntimes")
    items, token = [], None
    while True:
        page = op(**({"nextToken": token} if token else {}))
        items += page.get(key, [])
        token = page.get("nextToken")
        if not token:
            return items


def run_command(data, arn, session_id, script, timeout=1500, tries=10):
    """Run a bash script in the session (shipped base64 so nothing needs quoting)."""
    b64 = base64.b64encode(script.encode()).decode()
    cmd = "/bin/sh -c 'echo %s | base64 -d > /tmp/.bench-step.sh && bash /tmp/.bench-step.sh'" % b64
    if len(cmd) > 64000:
        raise ValueError("command exceeds 64 KB")
    return _invoke(data, arn, session_id, cmd, timeout, tries)


def _invoke(data, arn, session_id, cmd, timeout, tries):
    for attempt in range(tries):
        try:
            resp = data.invoke_agent_runtime_command(
                agentRuntimeArn=arn, runtimeSessionId=session_id, qualifier="DEFAULT",
                contentType="application/json", accept="application/vnd.amazon.eventstream",
                body={"command": cmd, "timeout": timeout})
            break
        except ClientError as exc:
            # 409 while the session provisions; capacity errors while an instance starts.
            if code_of(exc) in ("RetryableConflictException", "ThrottlingException",
                                "RuntimeClientError") and attempt < tries - 1:
                time.sleep(20)
                continue
            raise
    out, code = [], None
    for event in resp.get("stream", []):
        chunk = event.get("chunk") or {}
        if isinstance(chunk, dict):
            delta = chunk.get("contentDelta") or {}
            out.append(delta.get("stdout", "") + delta.get("stderr", ""))
            if chunk.get("contentStop"):
                code = chunk["contentStop"].get("exitCode")
    return code, "".join(out)


# --------------------------------------------------------------------------- commands

def ecr_image_bytes(image):
    """Compressed size of an ECR image as ECR reports it, or None if it cannot be read."""
    m = re.match(r"(\d+)\.dkr\.ecr\.([a-z0-9-]+)\.amazonaws\.com/([^:@]+)[:@](.+)$", image)
    if not m:
        return None
    account, region, repo, ref = m.groups()
    ref_id = {"imageDigest": ref} if ref.startswith("sha256:") else {"imageTag": ref}
    try:
        detail = boto3.client("ecr", region_name=region).describe_images(
            registryId=account, repositoryName=repo, imageIds=[ref_id])["imageDetails"][0]
        return detail["imageSizeInBytes"]
    except (ClientError, IndexError, KeyError):
        return None



_CP_IDLE = {}


def check_capacity_provider(cfg, trial_s):
    """An instance counts as idle while no client calls reach it -- which is the whole trial
    here -- and is terminated after idleInstanceTimeout (default 900 s), taking the running
    trial with it. Refuse to start a trial the capacity provider would cut off."""
    arn = cfg["capacity_provider_arn"]
    if arn not in _CP_IDLE:
        cp = boto3.client("bedrock-agentcore-control", region_name=cfg["region"], config=CTRL)
        got = cp.get_capacity_provider(capacityProviderId=arn.rsplit("/", 1)[1])
        life = got["computeConfiguration"]["ec2Configuration"].get("lifecycleConfiguration") or {}
        _CP_IDLE[arn] = life.get("idleInstanceTimeout", 900)
    if _CP_IDLE[arn] < trial_s:
        raise SystemExit(f"capacity provider idleInstanceTimeout={_CP_IDLE[arn]}s is shorter than this "
                         f"trial's agent+verifier timeouts ({trial_s}s): the instance would be terminated "
                         "mid-trial. Set idleInstanceTimeout >= the longest trial; see docs/limitations.md")


def harness_dir(harness):
    d = os.path.join(HERE, "harnesses", harness)
    if not os.path.isfile(os.path.join(d, "agent.sh")):
        names = sorted(os.listdir(os.path.join(HERE, "harnesses")))
        raise SystemExit(f"unknown harness {harness!r}; available: {', '.join(names)}")
    return d


def harness_version_from(install_out):
    """Version line printed by harnesses/<h>/install.sh, e.g. 'claude=2.3.1 (Claude Code)' -> '2.3.1'."""
    for line in reversed(install_out.splitlines()):
        m = re.match(r"\s*(?:claude|codex|kiro|kimi|qoder|codebuddy)=(\S*(?:\s+\S+)*)", line)
        if m:
            v = re.search(r"\d+\.\d+[\w.\-+]*", m.group(1))
            return v.group(0) if v else m.group(1).strip()
    return ""


def install_script(harness, cfg=None):
    """Common install (Node + AWS helper) followed by the harness's own install.sh."""
    common = open(os.path.join(HERE, "install.sh")).read()
    # Optional harness version pins, e.g. BENCH_KIRO_VERSION=2.29.0. Each install.sh has a pinned default
    # (the version the published results used); these override it.
    pin = "".join(f"export {k}={json.dumps(os.environ[k])}\n"
                  for k in ("BENCH_KIRO_VERSION", "BENCH_KIMI_VERSION", "BENCH_QODER_VERSION", "BENCH_CODEBUDDY_VERSION",
                            "BENCH_CLAUDE_VERSION", "BENCH_CODEX_VERSION") if os.environ.get(k))
    # Harnesses installed from a pinned bundle in the results bucket (s3://<bucket>/<prefix>/artifacts/...)
    # read it with aws.mjs during install, before /bench/env exists, so the bucket is exported here.
    if cfg:
        pin += (f"export BENCH_BUCKET={json.dumps(cfg['results_bucket'])}\n"
                f"export BENCH_S3_REGION={json.dumps(cfg['results_region'])}\n"
                f"export BENCH_ARTIFACTS={json.dumps(cfg.get('results_prefix', 'bench-runner') + '/artifacts')}\n")
        # aws.mjs is normally shipped at trial launch; install needs it earlier for bundle downloads.
        helper = base64.b64encode(open(os.path.join(HERE, "aws.mjs"), "rb").read()).decode()
        pin += f"mkdir -p /opt/bench && echo {helper} | base64 -d > /opt/bench/aws.mjs\n"
    return pin + common + "\n" + open(os.path.join(harness_dir(harness), "install.sh")).read()


def submit(cfg, mode, task_dir, image, harness="claude-code", model=None, model_region=None, effort=None):
    task = load_task(task_dir)
    run_id = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + "-" + uuid.uuid4().hex[:6]
    base = cfg.get("results_prefix", "bench").strip("/")
    run_prefix = f"{base}/runs/{task['name']}/{run_id}"
    input_prefix = f"{base}/inputs/{task['name']}/{run_id}"
    s3 = boto3.client("s3", region_name=cfg["results_region"])
    s3.put_object(Bucket=cfg["results_bucket"], Key=f"{input_prefix}/tests.tgz", Body=task["tests_tgz"])

    # An image over the account's size limit is refused by CreateAgentRuntime (Instances),
    # but a Harness (microVM) accepts it and every session then returns no output.
    # max_image_mb is in decimal MB, like ECR's imageSizeInBytes / 1e6.
    image_bytes = ecr_image_bytes(image)
    limit_mb = cfg.get("max_image_mb")
    if image_bytes and limit_mb and image_bytes > limit_mb * 1_000_000:
        raise SystemExit(f"image is {image_bytes / 1e6:.0f} MB compressed, over max_image_mb={limit_mb}; "
                         "see docs/large-images.md")

    t0 = time.time()
    if mode == "instances":
        check_capacity_provider(cfg, task["agent_timeout"] + task["verifier_timeout"])
    sandbox = Sandbox(cfg, mode, image)
    reused = sandbox._find()
    sandbox.ensure()
    t_sandbox = time.time() - t0
    session_id = "trial-" + uuid.uuid4().hex + uuid.uuid4().hex[:8]  # never reused
    data = boto3.client("bedrock-agentcore", region_name=cfg["region"], config=LONG)

    # 1. install the agent (synchronous, so an install failure is reported right here)
    t0 = time.time()
    code, out = run_command(data, sandbox.arn, session_id, install_script(harness, cfg))
    t_install = time.time() - t0
    if code is None and not out:
        raise SystemExit("the session returned no output. On microVM this is what an image looks like "
                         "when it is over the compressed size limit or does not fit the ~8.8 GiB disk "
                         "uncompressed; see docs/large-images.md")
    if code != 0:
        raise SystemExit(f"agent install failed (exit {code}):\n{out[-2000:]}")
    harness_version = harness_version_from(out)

    # 2. hand the trial to the sandbox and return
    env = {
        "BENCH_RUN_ID": run_id, "BENCH_TASK": task["name"], "BENCH_MODE": mode,
        "BENCH_HARNESS": harness, "BENCH_MODEL": model or cfg["model_id"], "BENCH_REGION": cfg["region"],
        "BENCH_MODEL_REGION": model_region or cfg["region"],
        "BENCH_EFFORT": effort or "",
        "BENCH_HARNESS_VERSION": harness_version,
        "BENCH_BUCKET": cfg["results_bucket"], "BENCH_S3_REGION": cfg["results_region"],
        "BENCH_PREFIX": run_prefix, "BENCH_INPUT_PREFIX": input_prefix,
        "BENCH_RUNTIME_ARN": sandbox.arn, "BENCH_SESSION_ID": session_id,
        "BENCH_WORKDIR": task["workdir"],
        # BENCH_AGENT_TIMEOUT_OVERRIDE shortens the agent timeout (e.g. to test timeout handling).
        "BENCH_AGENT_TIMEOUT": os.environ.get("BENCH_AGENT_TIMEOUT_OVERRIDE") or str(task["agent_timeout"]),
        "BENCH_VERIFIER_TIMEOUT": str(task["verifier_timeout"]),
    }
    if os.environ.get("BENCH_KIRO_SECRET"):  # secret name, optionally "<id>:<STAGE>" (kiro-cli only)
        env["BENCH_KIRO_SECRET"] = os.environ["BENCH_KIRO_SECRET"]
    # Optional steering / system-prompt file for the harness (kiro-cli: installed as global steering).
    steering_path = os.environ.get("BENCH_STEERING") or ""
    steering = os.path.splitext(os.path.basename(steering_path))[0] if steering_path else ""
    if steering:
        env["BENCH_STEERING"] = steering
    files = {
        "/bench/env": "".join(f"export {k}={json.dumps(v)}\n" for k, v in env.items()),
        "/bench/instruction.md": task["instruction"],
        "/bench/trial.sh": open(os.path.join(HERE, "trial.sh")).read(),
        "/bench/agent.sh": open(os.path.join(harness_dir(harness), "agent.sh")).read(),
        "/opt/bench/aws.mjs": open(os.path.join(HERE, "aws.mjs")).read(),
    }
    if steering:
        files["/bench/steering.md"] = open(steering_path).read()
    usage_sh = os.path.join(harness_dir(harness), "usage.sh")
    if os.path.isfile(usage_sh):
        files["/bench/usage.sh"] = open(usage_sh).read()
    lines = ["set -e", "mkdir -p /bench /opt/bench"]
    for path, body in files.items():
        lines.append(f"echo {base64.b64encode(body.encode()).decode()} | base64 -d > {path}")
    lines += ["chmod +x /bench/trial.sh",
              "setsid nohup bash /bench/trial.sh >/dev/null 2>&1 < /dev/null &",
              "echo started"]
    code, out = run_command(data, sandbox.arn, session_id, "\n".join(lines), timeout=120)
    if code != 0 or "started" not in out:
        raise SystemExit(f"trial launch failed (exit {code}):\n{out[-2000:]}")

    record = {"run_id": run_id, "task": task["name"], "mode": mode, "image": image,
              "harness": harness, "harness_version": harness_version,
              "model": env["BENCH_MODEL"], "effort": env["BENCH_EFFORT"], "steering": steering,
              "image_bytes": image_bytes, "sandbox": sandbox.name, "sandbox_reused": reused, "session_id": session_id,
              "timings_s": {"sandbox": round(t_sandbox, 1), "install": round(t_install, 1)},
              "results": f"s3://{cfg['results_bucket']}/{run_prefix}/",
              "submitted": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    s3.put_object(Bucket=cfg["results_bucket"], Key=f"{run_prefix}/submitted.json",
                  Body=json.dumps(record, indent=2).encode())
    print(json.dumps(record))
    return record


def results(cfg, run_id, wait=0):
    s3 = boto3.client("s3", region_name=cfg["results_region"])
    base = cfg.get("results_prefix", "bench").strip("/")
    keys = []
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=cfg["results_bucket"], Prefix=f"{base}/runs/"):
        keys += [o["Key"] for o in page.get("Contents", []) if f"/{run_id}/" in o["Key"]]
        if keys:
            break
    if not keys:
        raise SystemExit(f"run {run_id} not found")
    prefix = keys[0].rsplit("/", 1)[0]
    deadline = time.time() + wait
    while True:
        try:
            body = s3.get_object(Bucket=cfg["results_bucket"], Key=f"{prefix}/summary.json")["Body"].read()
            try:
                summary = json.loads(body)
            except ValueError:  # e.g. written on a full disk
                summary = {"run_id": run_id, "reward": None, "error": f"unreadable summary.json ({len(body)} bytes)"}
            summary["results"] = f"s3://{cfg['results_bucket']}/{prefix}/"
            print(json.dumps(summary, indent=2))
            return summary
        except ClientError as exc:
            if code_of(exc) not in ("NoSuchKey", "404"):
                raise
        if time.time() >= deadline:
            try:
                status = s3.get_object(Bucket=cfg["results_bucket"], Key=f"{prefix}/status.json")["Body"].read().decode()
            except ClientError:
                status = '{"phase": "starting"}'
            print(status.strip())
            return None
        time.sleep(30)


def cleanup(cfg):
    cp = boto3.client("bedrock-agentcore-control", region_name=cfg["region"], config=CTRL)
    for h in list_all(cp, "microvm"):
        if h.get("harnessName", "").startswith(PREFIX):
            cp.delete_harness(harnessId=h["harnessId"]); print("deleted harness", h["harnessName"])
    for r in list_all(cp, "instances"):
        if r.get("agentRuntimeName", "").startswith(PREFIX):
            cp.delete_agent_runtime(agentRuntimeId=r["agentRuntimeId"]); print("deleted runtime", r["agentRuntimeName"])


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--config", default="config.json")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("submit", help="start a trial and return")
    s.add_argument("--mode", choices=["microvm", "instances"], required=True)
    s.add_argument("--task", required=True, help="Harbor task directory")
    s.add_argument("--image", required=True, help="task image URI in ECR")
    s.add_argument("--harness", default="claude-code", help="runner/harnesses/<name>")
    s.add_argument("--model", help="model / inference profile for the harness (default: config model_id)")
    s.add_argument("--effort", help="reasoning effort passed to the harness (e.g. high); empty = harness default")
    s.add_argument("--model-region", help="region the harness calls the model in (default: config region)")
    r = sub.add_parser("results", help="read a trial's results from S3")
    r.add_argument("run_id")
    r.add_argument("--wait", type=int, default=0, help="seconds to wait for completion")
    sub.add_parser("cleanup", help="delete sandboxes created by this tool")
    args = ap.parse_args()
    cfg = json.load(open(args.config))
    cfg.setdefault("results_region", cfg["region"])
    if args.cmd == "submit":
        submit(cfg, args.mode, args.task, args.image, args.harness, args.model, args.model_region, args.effort)
    elif args.cmd == "results":
        sys.exit(0 if results(cfg, args.run_id, args.wait) else 3)
    else:
        cleanup(cfg)


if __name__ == "__main__":
    main()
