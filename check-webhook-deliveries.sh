#!/bin/bash
# Query GitHub App webhook delivery history to verify if webhooks were sent
# Usage:
#   ./check-webhook-deliveries.sh                         # show recent deliveries
#   ./check-webhook-deliveries.sh --failures              # scan for failed deliveries and check if retried
#   ./check-webhook-deliveries.sh --failures --since 30m  # only deliveries from last 30 minutes
#   ./check-webhook-deliveries.sh --failures --since 2h   # only deliveries from last 2 hours
#   ./check-webhook-deliveries.sh --failures --pages 50   # scan more pages (default: 20)
#   ./check-webhook-deliveries.sh <job_id> [job_id..]     # search for specific job IDs (uses rate limit)

REGION="us-east-1"

python3 - "$@" <<'PYEOF'
import sys
import json
import time
import base64
import urllib.request
import urllib.error
import subprocess

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
    payload = {
        "iat": now - 60,
        "exp": now + (10 * 60),
        "iss": int(app_id)
    }
    segments = [
        base64url_encode(json.dumps(header)),
        base64url_encode(json.dumps(payload))
    ]
    signing_input = '.'.join(segments).encode('utf-8')
    key = serialization.load_pem_private_key(private_key_pem, password=None)
    signature = key.sign(signing_input, padding.PKCS1v15(), hashes.SHA256())
    segments.append(base64url_encode(signature))
    return '.'.join(segments)

jwt_token = create_jwt(app_id, private_key_pem)

def github_api(path, jwt_token):
    url = f"https://api.github.com{path}"
    req = urllib.request.Request(url)
    req.add_header("Authorization", f"Bearer {jwt_token}")
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        if e.code == 403:
            print(f"Rate limited (HTTP 403)")
            return None
        print(f"ERROR: {e.code} {e.reason}")
        print(e.read().decode())
        sys.exit(1)

# Parse arguments
from datetime import datetime, timezone, timedelta

args = sys.argv[1:]
mode = "recent"
max_pages = 20
job_ids = []
since_cutoff = None

def parse_since(val):
    """Parse duration like '30m', '2h', '1d' into a UTC datetime cutoff"""
    val = val.strip()
    if val.endswith('m'):
        return datetime.now(timezone.utc) - timedelta(minutes=int(val[:-1]))
    elif val.endswith('h'):
        return datetime.now(timezone.utc) - timedelta(hours=int(val[:-1]))
    elif val.endswith('d'):
        return datetime.now(timezone.utc) - timedelta(days=int(val[:-1]))
    else:
        raise ValueError(f"Invalid --since format '{val}'. Use e.g. 30m, 2h, 1d")

i = 0
while i < len(args):
    if args[i] == "--failures":
        mode = "failures"
    elif args[i] == "--pages" and i + 1 < len(args):
        i += 1
        max_pages = int(args[i])
    elif args[i] == "--since" and i + 1 < len(args):
        i += 1
        since_cutoff = parse_since(args[i])
    elif args[i].isdigit():
        mode = "search"
        job_ids.append(args[i])
    else:
        job_ids.append(args[i])
        if job_ids:
            mode = "search"
    i += 1

def fetch_all_deliveries(max_pages, cutoff=None):
    """Fetch delivery metadata only (no individual detail calls, no rate limit concern)"""
    all_deliveries = []
    cursor = None
    for _ in range(max_pages):
        url = "/app/hook/deliveries?per_page=100"
        if cursor:
            url += f"&cursor={cursor}"
        deliveries = github_api(url, jwt_token)
        if not deliveries:
            break
        for d in deliveries:
            if cutoff:
                ts = datetime.fromisoformat(d['delivered_at'].replace('Z', '+00:00'))
                if ts < cutoff:
                    return all_deliveries
            all_deliveries.append(d)
        if len(deliveries) < 100:
            break
        cursor = deliveries[-1]['id']
    return all_deliveries

if mode == "failures":
    if since_cutoff:
        print(f"=== Scanning for Failed Webhook Deliveries (since {since_cutoff.strftime('%Y-%m-%d %H:%M:%S UTC')}) ===")
    else:
        print(f"=== Scanning for Failed Webhook Deliveries (up to {max_pages} pages) ===")
    print()

    deliveries = fetch_all_deliveries(max_pages, cutoff=since_cutoff)
    print(f"Scanned {len(deliveries)} deliveries")
    print()

    # Categorize by status
    by_status = {}
    for d in deliveries:
        code = d.get('status_code', 0)
        by_status.setdefault(code, []).append(d)

    print("Status code summary:")
    for code in sorted(by_status.keys()):
        print(f"  HTTP {code}: {len(by_status[code])}")
    print()

    # Find failures (non-2xx)
    failures = [d for d in deliveries if d.get('status_code', 0) < 200 or d.get('status_code', 0) >= 300]
    if not failures:
        print("No failed deliveries found!")
        sys.exit(0)

    print(f"Found {len(failures)} failed deliveries")
    print()

    # Build a set of all GUIDs that succeeded (for checking retries)
    successful_guids = set()
    for d in deliveries:
        if 200 <= d.get('status_code', 0) < 300:
            guid = d.get('guid', '')
            if guid:
                successful_guids.add(guid)

    # Check which failures were retried successfully
    retried_ok = []
    not_retried = []
    for d in failures:
        guid = d.get('guid', '')
        if guid in successful_guids:
            retried_ok.append(d)
        else:
            not_retried.append(d)

    if retried_ok:
        print(f"Retried successfully: {len(retried_ok)}")

    if not_retried:
        print(f"NOT retried (potentially lost): {len(not_retried)}")
        print()
        # Group by action type
        queued_lost = [d for d in not_retried if d.get('action') == 'queued']
        other_lost = [d for d in not_retried if d.get('action') != 'queued']
        if queued_lost:
            print(f"  Lost 'queued' events (these cause stuck jobs): {len(queued_lost)}")
            for d in queued_lost[:10]:
                print(f"    {d.get('delivered_at', '?')} guid={d.get('guid', '?')} status={d.get('status_code')} event={d.get('event')}/{d.get('action')}")
            if len(queued_lost) > 10:
                print(f"    ... and {len(queued_lost) - 10} more")
        if other_lost:
            print(f"  Lost non-queued events (less critical): {len(other_lost)}")
            for d in other_lost[:5]:
                print(f"    {d.get('delivered_at', '?')} guid={d.get('guid', '?')} status={d.get('status_code')} event={d.get('event')}/{d.get('action')}")
            if len(other_lost) > 5:
                print(f"    ... and {len(other_lost) - 5} more")
    else:
        print("All failed deliveries were successfully retried!")
    print()

elif mode == "search":
    # Search for specific job IDs (requires fetching individual delivery details — uses rate limit)
    print(f"Searching for job IDs: {', '.join(job_ids)}")
    print("NOTE: This fetches individual delivery details and uses API rate limit")
    print()

    found = {jid: [] for jid in job_ids}
    cursor = None
    checked = 0

    for _ in range(max_pages):
        url = "/app/hook/deliveries?per_page=50"
        if cursor:
            url += f"&cursor={cursor}"
        deliveries = github_api(url, jwt_token)
        if not deliveries:
            break

        for d in deliveries:
            checked += 1
            if d.get('action') in ('queued', None):
                detail = github_api(f"/app/hook/deliveries/{d['id']}", jwt_token)
                if detail is None:
                    print(f"Rate limited after checking {checked} deliveries")
                    break
                if detail.get('request') and detail['request'].get('payload'):
                    payload = detail['request']['payload']
                    if isinstance(payload, str):
                        try:
                            payload = json.loads(payload)
                        except:
                            continue
                    wf_job = payload.get('workflow_job', {})
                    job_id_str = str(wf_job.get('id', ''))
                    action = payload.get('action', '')
                    if job_id_str in job_ids:
                        found[job_id_str].append({
                            'delivery_id': d['id'],
                            'delivered_at': d.get('delivered_at', ''),
                            'status_code': d.get('status_code', ''),
                            'action': action,
                            'redelivery': d.get('redelivery', False)
                        })

        cursor = deliveries[-1]['id']

    print(f"Checked {checked} deliveries")
    print()
    for jid, matches in found.items():
        if matches:
            print(f"Job {jid}: FOUND ({len(matches)} deliveries)")
            for m in matches:
                print(f"  {m['delivered_at']} action={m['action']} status={m['status_code']} redelivery={m['redelivery']}")
        else:
            print(f"Job {jid}: NOT FOUND in last {checked} deliveries")
    print()

else:
    # Show recent deliveries summary
    print("=== Recent Webhook Deliveries ===")
    deliveries = github_api("/app/hook/deliveries?per_page=20", jwt_token)

    for d in deliveries:
        code = d.get('status_code', '?')
        status = "OK" if code in (200, 201) else f"FAIL"
        event = d.get('event', '?')
        action = d.get('action', '?')
        delivered = d.get('delivered_at', '?')
        redelivery = " (redelivery)" if d.get('redelivery') else ""
        print(f"  {delivered} {event}/{action} HTTP {code} {status}{redelivery} guid={d.get('guid','?')}")

    print(f"\nShowing {len(deliveries)} most recent deliveries")
    print()
    print("Usage:")
    print("  ./check-webhook-deliveries.sh                         # show recent")
    print("  ./check-webhook-deliveries.sh --failures              # scan for failed deliveries")
    print("  ./check-webhook-deliveries.sh --failures --pages 50   # scan more pages")
    print("  ./check-webhook-deliveries.sh <job_id> [job_id..]     # search for specific jobs (uses rate limit)")

PYEOF
