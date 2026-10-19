"""Probe which model IDs the Bedrock Mantle Responses endpoint accepts.

Usage: python scripts/mantle_models.py <region> <model-id> [<model-id> ...]
Sends one tiny /openai/v1/responses request per ID (default AWS credential chain,
SigV4 service bedrock-mantle) and prints the HTTP status plus a short body.
"""
import json
import sys
import urllib.error
import urllib.request

import boto3
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest

region, models = sys.argv[1], sys.argv[2:]
url = f"https://bedrock-mantle.{region}.api.aws/openai/v1/responses"
creds = boto3.Session().get_credentials()
for model in models:
    body = json.dumps({"model": model, "input": "Reply with OK.", "max_output_tokens": 16}).encode()
    req = AWSRequest(method="POST", url=url, data=body, headers={"Content-Type": "application/json"})
    SigV4Auth(creds, "bedrock-mantle", region).add_auth(req)
    try:
        with urllib.request.urlopen(urllib.request.Request(url, data=body, headers=dict(req.headers))) as r:
            print(model, r.status, r.read()[:200].decode(errors="replace"))
    except urllib.error.HTTPError as e:
        print(model, e.code, e.read()[:200].decode(errors="replace"))
