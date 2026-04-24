#!/bin/bash
# Check for Lambda errors and redeliver failed webhook events
# Handles both failure modes:
#   1. Webhook delivery failed (HTTP 500) — redeliver via failed delivery scan
#   2. Webhook delivered (201) but dispatcher rejected due to SSM rate limit — redeliver by job ID
# Usage:
#   ./fix-webhooks.sh              # default: last 10 minutes
#   ./fix-webhooks.sh 30m          # last 30 minutes
#   ./fix-webhooks.sh 2h           # last 2 hours
#   ./fix-webhooks.sh 10m dry-run  # preview only

SINCE="${1:-10m}"
DRY_RUN=""
DRY_RUN_FLAG=""
if [ "$2" = "dry-run" ]; then
  DRY_RUN="yes"
  DRY_RUN_FLAG="--dry-run"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGION="us-east-1"

# Parse since value to seconds
parse_seconds() {
  local val="$1"
  if [[ "$val" =~ ^([0-9]+)m$ ]]; then
    echo $(( ${BASH_REMATCH[1]} * 60 ))
  elif [[ "$val" =~ ^([0-9]+)h$ ]]; then
    echo $(( ${BASH_REMATCH[1]} * 3600 ))
  elif [[ "$val" =~ ^([0-9]+)d$ ]]; then
    echo $(( ${BASH_REMATCH[1]} * 86400 ))
  else
    echo 600
  fi
}

SECONDS_AGO=$(parse_seconds "$SINCE")
START_TIME=$(($(date +%s) - SECONDS_AGO))000

echo "=== Checking errors (last $SINCE) ==="
echo ""

webhook_errors=$(aws logs filter-log-events --log-group-name /aws/lambda/crucible-ci-webhook \
  --start-time $START_TIME --region $REGION 2>/dev/null | \
  jq -r '.events[] | .message' | grep -i "ERROR\|Rate exceeded" | wc -l)
echo "Webhook Lambda errors: $webhook_errors"

dispatcher_errors=$(aws logs filter-log-events --log-group-name /aws/lambda/crucible-ci-dispatch-to-runner \
  --start-time $START_TIME --region $REGION 2>/dev/null | \
  jq -r '.events[] | .message' | grep -i "ERROR\|Rate exceeded" | wc -l)
echo "Dispatcher Lambda errors: $dispatcher_errors"

scaleup_errors=$(aws logs filter-log-events --log-group-name /aws/lambda/crucible-ci-fedora-k3s-scale-up \
  --start-time $START_TIME --region $REGION 2>/dev/null | \
  jq -r '.events[] | .message' | grep -i "ERROR" | wc -l)
echo "Scale-up Lambda errors: $scaleup_errors"

# Check for dispatcher rejections of aws-cloud-1 events (silent event loss)
rejected_jobs=$(aws logs filter-log-events --log-group-name /aws/lambda/crucible-ci-dispatch-to-runner \
  --start-time $START_TIME --region $REGION 2>/dev/null | \
  jq -r '.events[] | .message' | grep "not accepted" | grep "aws-cloud-1" | \
  jq -r '.message | capture("Job ID: (?<id>[0-9]+)") | .id' 2>/dev/null | sort -u)
rejected_count=$(echo "$rejected_jobs" | grep -c . 2>/dev/null || echo 0)
if [ -z "$rejected_jobs" ]; then rejected_count=0; fi
echo "Dispatcher silent rejections (aws-cloud-1): $rejected_count"

echo ""
echo "=== Phase 1: Redelivering failed webhook deliveries (last $SINCE) ==="
echo ""
"$SCRIPT_DIR/redeliver-webhooks.sh" --since "$SINCE" $DRY_RUN_FLAG

if [ "$rejected_count" -gt 0 ]; then
  echo ""
  echo "=== Phase 2: Redelivering dispatcher-rejected events ($rejected_count jobs) ==="
  echo ""

  python3 - "$DRY_RUN" <<PYEOF
import subprocess, base64, json, time, urllib.request, sys
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding

dry_run = sys.argv[1] == "yes" if len(sys.argv) > 1 else False

app_id = subprocess.run(['aws', 'ssm', 'get-parameter', '--name', '/github-action-runners/crucible-ci/app/github_app_id', '--region', 'us-east-1', '--with-decryption', '--query', 'Parameter.Value', '--output', 'text'], capture_output=True, text=True).stdout.strip()
app_key_b64 = subprocess.run(['aws', 'ssm', 'get-parameter', '--name', '/github-action-runners/crucible-ci/app/github_app_key_base64', '--region', 'us-east-1', '--with-decryption', '--query', 'Parameter.Value', '--output', 'text'], capture_output=True, text=True).stdout.strip()
private_key_pem = base64.b64decode(app_key_b64)

def base64url_encode(data):
    if isinstance(data, str): data = data.encode('utf-8')
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode('utf-8')

now = int(time.time())
header = json.dumps({"alg": "RS256", "typ": "JWT"})
payload = json.dumps({"iat": now - 60, "exp": now + 600, "iss": int(app_id)})
signing_input = (base64url_encode(header) + '.' + base64url_encode(payload)).encode('utf-8')
key = serialization.load_pem_private_key(private_key_pem, password=None)
sig = key.sign(signing_input, padding.PKCS1v15(), hashes.SHA256())
jwt_token = base64url_encode(header) + '.' + base64url_encode(payload) + '.' + base64url_encode(sig)

def github_api(path, method="GET"):
    url = f"https://api.github.com{path}"
    req = urllib.request.Request(url, method=method)
    req.add_header("Authorization", f"Bearer {jwt_token}")
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    if method == "POST": req.data = b""
    try:
        with urllib.request.urlopen(req) as resp:
            body = resp.read()
            return json.loads(body) if body else {}
    except urllib.error.HTTPError as e:
        if e.code == 403:
            print(f"Rate limited (HTTP 403)")
            return None
        return None

job_ids = """$rejected_jobs""".strip().split('\n')
job_ids = [j.strip() for j in job_ids if j.strip()]

if not job_ids:
    print("No rejected jobs to process")
    sys.exit(0)

print(f"Searching for {len(job_ids)} dispatcher-rejected job IDs...")

# Scan recent deliveries for queued events with matching job IDs
found = {}
cursor = None
for _ in range(20):
    url = "/app/hook/deliveries?per_page=100"
    if cursor: url += f"&cursor={cursor}"
    deliveries = github_api(url)
    if not deliveries: break
    for d in deliveries:
        if d.get('action') == 'queued' and d.get('status_code') in (200, 201):
            detail = github_api(f"/app/hook/deliveries/{d['id']}")
            if detail is None:
                print("Rate limited, stopping search")
                break
            if detail and detail.get('request', {}).get('payload'):
                p = detail['request']['payload']
                if isinstance(p, str):
                    try: p = json.loads(p)
                    except: continue
                jid = str(p.get('workflow_job', {}).get('id', ''))
                if jid in job_ids and jid not in found:
                    found[jid] = d['id']
        if len(found) == len(job_ids):
            break
    if not deliveries or len(deliveries) < 100 or len(found) == len(job_ids):
        break
    cursor = deliveries[-1]['id']

print(f"Found {len(found)} of {len(job_ids)} jobs")

redelivered = 0
failed = 0
for jid, did in found.items():
    if dry_run:
        print(f"  Would redeliver job {jid} (delivery {did})")
    else:
        result = github_api(f"/app/hook/deliveries/{did}/attempts", method="POST")
        if result is not None:
            redelivered += 1
            print(f"  Redelivered job {jid}")
        else:
            failed += 1
            print(f"  Failed job {jid}")

missing = set(job_ids) - set(found.keys())
if missing:
    print(f"\nCould not find deliveries for {len(missing)} jobs (may be outside scan window)")

if dry_run:
    print(f"\nWould redeliver {len(found)} dispatcher-rejected webhooks")
else:
    print(f"\nRedelivered: {redelivered}, Failed: {failed}")
PYEOF
else
  echo ""
  echo "=== Phase 2: No dispatcher-rejected events found ==="
fi
