#!/bin/bash
# Find failed webhook deliveries for 'queued' events and redeliver them
# Usage:
#   ./redeliver-webhooks.sh --since 30m          # redeliver failed queued events from last 30 minutes
#   ./redeliver-webhooks.sh --since 2h           # last 2 hours
#   ./redeliver-webhooks.sh --since 1d           # last day
#   ./redeliver-webhooks.sh --since 30m --dry-run  # show what would be redelivered without doing it

REGION="us-east-1"

python3 - "$@" <<'PYEOF'
import sys
import json
import time
import base64
import urllib.request
import urllib.error
import subprocess
from datetime import datetime, timezone, timedelta

app_id = subprocess.run(
    ["aws", "ssm", "get-parameter", "--name", "/github-action-runners/crucible-ci/app/github_app_id",
     "--region", "us-east-1", "--with-decryption", "--query", "Parameter.Value", "--output", "text"],
    capture_output=True, text=True
).stdout.strip()

app_key_b64 = subprocess.run(
    ["aws", "ssm", "get-parameter", "--name", "/github-action-runners/crucible-ci/app/github_app_key_base64",
     "--region", "us-east-1", "--with-decryption", "--query", "Parameter.Value", "--output", "text"],
    capture_output=True, text=True
).stdout.strip()

private_key_pem = base64.b64decode(app_key_b64)

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding

def base64url_encode(data):
    if isinstance(data, str):
        data = data.encode('utf-8')
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode('utf-8')

def create_jwt(app_id, private_key_pem):
    now = int(time.time())
    header = {"alg": "RS256", "typ": "JWT"}
    payload = {"iat": now - 60, "exp": now + 600, "iss": int(app_id)}
    segments = [base64url_encode(json.dumps(header)), base64url_encode(json.dumps(payload))]
    signing_input = '.'.join(segments).encode('utf-8')
    key = serialization.load_pem_private_key(private_key_pem, password=None)
    signature = key.sign(signing_input, padding.PKCS1v15(), hashes.SHA256())
    segments.append(base64url_encode(signature))
    return '.'.join(segments)

jwt_token = create_jwt(app_id, private_key_pem)

def github_api(path, method="GET"):
    url = f"https://api.github.com{path}"
    req = urllib.request.Request(url, method=method)
    req.add_header("Authorization", f"Bearer {jwt_token}")
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    if method == "POST":
        req.data = b""
    try:
        with urllib.request.urlopen(req) as resp:
            body = resp.read()
            return json.loads(body) if body else {}
    except urllib.error.HTTPError as e:
        if e.code == 403:
            print(f"Rate limited (HTTP 403)")
            return None
        print(f"ERROR: {e.code} {e.reason}")
        return None

# Parse arguments
args = sys.argv[1:]
since_cutoff = None
dry_run = False

def parse_since(val):
    val = val.strip()
    if val.endswith('m'):
        return datetime.now(timezone.utc) - timedelta(minutes=int(val[:-1]))
    elif val.endswith('h'):
        return datetime.now(timezone.utc) - timedelta(hours=int(val[:-1]))
    elif val.endswith('d'):
        return datetime.now(timezone.utc) - timedelta(days=int(val[:-1]))
    raise ValueError(f"Invalid --since format '{val}'. Use e.g. 30m, 2h, 1d")

i = 0
while i < len(args):
    if args[i] == "--since" and i + 1 < len(args):
        i += 1
        since_cutoff = parse_since(args[i])
    elif args[i] == "--dry-run":
        dry_run = True
    i += 1

if since_cutoff is None:
    print("Usage: ./redeliver-webhooks.sh --since <duration> [--dry-run]")
    print("  e.g. ./redeliver-webhooks.sh --since 30m")
    sys.exit(1)

print(f"Scanning deliveries since {since_cutoff.strftime('%Y-%m-%d %H:%M:%S UTC')}")
if dry_run:
    print("DRY RUN — will not redeliver")
print()

# Fetch deliveries
all_deliveries = []
cursor = None
for _ in range(50):
    url = "/app/hook/deliveries?per_page=100"
    if cursor:
        url += f"&cursor={cursor}"
    deliveries = github_api(url)
    if not deliveries:
        break
    for d in deliveries:
        ts = datetime.fromisoformat(d['delivered_at'].replace('Z', '+00:00'))
        if ts < since_cutoff:
            deliveries = []
            break
        all_deliveries.append(d)
    if not deliveries or len(deliveries) < 100:
        break
    cursor = deliveries[-1]['id']

print(f"Scanned {len(all_deliveries)} deliveries")

# Find failed 'queued' events
successful_guids = set(d.get('guid', '') for d in all_deliveries if 200 <= d.get('status_code', 0) < 300)
failed_queued = [d for d in all_deliveries
                 if (d.get('status_code', 0) < 200 or d.get('status_code', 0) >= 300)
                 and d.get('action') == 'queued'
                 and d.get('guid', '') not in successful_guids]

if not failed_queued:
    print("No failed 'queued' deliveries found that need redelivery.")
    sys.exit(0)

print(f"Found {len(failed_queued)} failed 'queued' deliveries to redeliver")
print()

redelivered = 0
failed = 0
for d in failed_queued:
    delivery_id = d['id']
    guid = d.get('guid', '?')
    ts = d.get('delivered_at', '?')
    status = d.get('status_code', '?')

    if dry_run:
        print(f"  Would redeliver: {ts} guid={guid} status={status}")
    else:
        result = github_api(f"/app/hook/deliveries/{delivery_id}/attempts", method="POST")
        if result is not None:
            redelivered += 1
            print(f"  Redelivered: {ts} guid={guid} status={status}")
        else:
            failed += 1
            print(f"  Failed to redeliver: {ts} guid={guid}")

print()
if dry_run:
    print(f"Would redeliver {len(failed_queued)} webhooks")
else:
    print(f"Redelivered: {redelivered}, Failed: {failed}")

PYEOF
