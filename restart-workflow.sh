#!/bin/bash
# Cancel, clean up, and re-trigger a crucible-ci workflow run
# Usage: ./restart-workflow.sh [run_id]
#   If no run_id provided, uses the most recent active or last run

REPO="perftool-incubator/crucible-ci"
REGION="us-east-1"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

run_id=$1
if [ -z "$run_id" ]; then
  run_id=$(gh run list --repo $REPO --limit 1 --json databaseId --jq '.[0].databaseId')
  echo "No run_id provided, using most recent: $run_id"
fi

echo "=== Step 1: Cancel workflow run $run_id ==="
gh run cancel $run_id --repo $REPO 2>&1
sleep 15
status=$(gh api /repos/$REPO/actions/runs/$run_id --jq '.status' 2>/dev/null)
echo "Run status: $status"

echo ""
echo "=== Step 2: Terminate instances ==="
ids=$(aws ec2 describe-instances --region $REGION \
  --filters 'Name=instance-state-name,Values=running,pending' \
            'Name=tag:ghr:Application,Values=github-action-runner' \
  --query 'Reservations[*].Instances[*].InstanceId' --output text | tr '\t' '\n')
count=$(echo "$ids" | grep -c . 2>/dev/null || echo 0)
if [ "$count" -gt 0 ]; then
  echo "$ids" | xargs aws ec2 terminate-instances --region $REGION --instance-ids > /dev/null 2>&1
  echo "Terminated: $count instances"
else
  echo "No instances to terminate"
fi

echo ""
echo "=== Step 3: Purge SQS queue ==="
aws sqs purge-queue \
  --queue-url "https://sqs.$REGION.amazonaws.com/$ACCOUNT/crucible-ci-fedora-k3s-queued-builds" \
  --region $REGION 2>/dev/null
echo "Queue purged"

echo ""
echo "=== Step 4: Clean up offline runners ==="
./cleanup-runners.sh

echo ""
echo "=== Step 5: Re-trigger workflow ==="
sleep 5
gh api /repos/$REPO/actions/runs/$run_id/rerun --method POST 2>&1
sleep 5
status=$(gh api /repos/$REPO/actions/runs/$run_id --jq '{status: .status, attempt: .run_attempt}' 2>/dev/null)
echo "Run status: $status"
