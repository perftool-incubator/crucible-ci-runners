#!/bin/bash
# Get accurate job counts for a workflow run by paginating through all pages
# Usage: ./get-job-counts.sh <repo> <run_id>
# Output: single line of key=value pairs for easy parsing

REPO="${1:?Usage: $0 <repo> <run_id>}"
RUN_ID="${2:?Usage: $0 <repo> <run_id>}"
PER_PAGE=100
MAX_RETRIES=3

# Get total job count
total_count=""
for attempt in $(seq 1 $MAX_RETRIES); do
  total_count=$(gh api "/repos/$REPO/actions/runs/$RUN_ID/jobs?per_page=1" --jq '.total_count' 2>/dev/null)
  if [ -n "$total_count" ] && [ "$total_count" -gt 0 ] 2>/dev/null; then
    break
  fi
  sleep 2
done

if [ -z "$total_count" ] || ! [ "$total_count" -gt 0 ] 2>/dev/null; then
  echo "total=0 success=0 failure=0 in_progress=0 queued=0"
  exit 1
fi

total_pages=$(( (total_count + PER_PAGE - 1) / PER_PAGE ))

success=0; failure=0; cancelled=0; in_progress=0; queued=0; total=0
page=1
while [ $page -le $total_pages ]; do
  result=""
  for attempt in $(seq 1 $MAX_RETRIES); do
    result=$(gh api "/repos/$REPO/actions/runs/$RUN_ID/jobs?per_page=$PER_PAGE&page=$page" --jq '{s: [.jobs[] | select(.conclusion == "success")] | length, f: [.jobs[] | select(.conclusion == "failure")] | length, c: [.jobs[] | select(.conclusion == "cancelled")] | length, ip: [.jobs[] | select(.status == "in_progress")] | length, q: [.jobs[] | select(.status == "queued")] | length, t: .jobs | length}' 2>/dev/null)
    if [ -n "$result" ]; then
      t=$(echo "$result" | jq -r '.t')
      if [ -n "$t" ] && [ "$t" -gt 0 ] 2>/dev/null; then
        break
      fi
    fi
    sleep 2
  done

  if [ -z "$result" ]; then
    # Skip this page after max retries
    page=$((page + 1))
    continue
  fi

  t=$(echo "$result" | jq -r '.t')
  if [ -z "$t" ] || ! [ "$t" -gt 0 ] 2>/dev/null; then
    page=$((page + 1))
    continue
  fi

  success=$((success + $(echo "$result" | jq -r '.s')))
  failure=$((failure + $(echo "$result" | jq -r '.f')))
  cancelled=$((cancelled + $(echo "$result" | jq -r '.c')))
  in_progress=$((in_progress + $(echo "$result" | jq -r '.ip')))
  queued=$((queued + $(echo "$result" | jq -r '.q')))
  total=$((total + t))
  page=$((page + 1))
done

echo "total=$total success=$success failure=$failure in_progress=$in_progress queued=$queued cancelled=$cancelled"
