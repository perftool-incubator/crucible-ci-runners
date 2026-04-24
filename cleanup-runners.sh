#!/bin/bash
# Remove offline crucible-ci runners from GitHub

echo "Finding offline runners..."
offline_ids=$(gh api /orgs/perftool-incubator/actions/runners --paginate \
  -q '.runners[] | select(.name | startswith("crucible-ci")) | select(.status == "offline") | .id')

if [ -z "$offline_ids" ]; then
  echo "No offline runners found."
  exit 0
fi

count=$(echo "$offline_ids" | wc -l)
echo "Found $count offline runners. Removing..."
removed=0
failed=0
for id in $offline_ids; do
  result=$(gh api -X DELETE /orgs/perftool-incubator/actions/runners/$id 2>&1)
  if echo "$result" | grep -q "error\|Error\|422"; then
    failed=$((failed + 1))
  else
    removed=$((removed + 1))
  fi
done

echo "Removed: $removed"
if [ "$failed" -gt 0 ]; then
  echo "Skipped (busy): $failed"
fi

echo ""
echo "Remaining offline:"
gh api /orgs/perftool-incubator/actions/runners --paginate \
  -q '.runners[] | select(.name | startswith("crucible-ci")) | select(.status == "offline") | .name' | wc -l
