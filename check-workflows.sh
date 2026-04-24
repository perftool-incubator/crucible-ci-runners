#!/bin/bash
# Check status of active crucible-ci workflow runs
# Usage: ./check-workflows.sh [repo]

REPO="${1:-perftool-incubator/crucible-ci}"
REGION="us-east-1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Workflow Runs ==="
gh run list --repo $REPO --limit 5 --json databaseId,status,conclusion,name,createdAt | \
  jq -r '.[] | "\(.databaseId) \(.status) \(.conclusion // "n/a") \(.name)"'

echo ""

# Get active/recent run IDs
runs=$(gh run list --repo $REPO --limit 5 --json databaseId,status --jq '.[] | select(.status != "completed") | .databaseId')

if [ -z "$runs" ]; then
  echo "No active runs. Showing most recent completed:"
  runs=$(gh run list --repo $REPO --limit 3 --json databaseId --jq '.[].databaseId')
fi

echo "=== Job Details ==="
for run in $runs; do
  name=$(gh api /repos/$REPO/actions/runs/$run --jq '.name' 2>/dev/null)
  attempt=$(gh api /repos/$REPO/actions/runs/$run --jq '.run_attempt' 2>/dev/null)
  echo "$name (run $run, attempt $attempt):"
  counts=$("$SCRIPT_DIR/get-job-counts.sh" "$REPO" "$run" 2>/dev/null)
  echo "  $counts"
  echo ""
done

echo "=== Infrastructure ==="
instances=$(aws ec2 describe-instances --region $REGION \
  --filters 'Name=instance-state-name,Values=running,pending' \
            'Name=tag:ghr:Application,Values=github-action-runner' \
  --query 'Reservations[*].Instances[*].InstanceId' --output text | tr '\t' '\n' | wc -l)
echo "Instances: $instances"

runners_online=$(gh api /orgs/perftool-incubator/actions/runners --paginate \
  -q '.runners[] | select(.name | startswith("crucible-ci")) | select(.status == "online") | .name' 2>/dev/null | wc -l)
echo "Runners online: $runners_online"
