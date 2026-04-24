#!/bin/bash
# Check infrastructure health: instances, config, Lambda, SQS

REGION="us-east-1"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

echo "=== EC2 Instances ==="
instance_data=$(aws ec2 describe-instances --region $REGION \
  --filters 'Name=instance-state-name,Values=running,pending' \
            'Name=tag:ghr:Application,Values=github-action-runner' \
  --query 'Reservations[*].Instances[*].[InstanceId,ImageId,LaunchTime]' --output text)

instances=$(echo "$instance_data" | grep -c . 2>/dev/null || echo 0)
if [ -z "$instance_data" ]; then
  instances=0
fi
echo "Running: $instances"

if [ "$instances" -gt 0 ]; then
  echo "AMI:"
  echo "$instance_data" | awk '{print $2}' | sort | uniq -c

  # Instance age distribution
  echo "Age distribution:"
  now=$(date +%s)
  echo "$instance_data" | while read id ami launch; do
    launch_epoch=$(date -d "$launch" +%s 2>/dev/null || echo $now)
    age=$(( (now - launch_epoch) / 60 ))
    echo "$age"
  done | sort -n | awk '
    BEGIN { b0=0; b5=0; b15=0; b60=0; old=0 }
    { if ($1 < 5) b0++; else if ($1 < 15) b5++; else if ($1 < 60) b15++; else if ($1 < 240) b60++; else old++ }
    END { printf "  <5min: %d | 5-15min: %d | 15-60min: %d | 1-4hr: %d | >4hr: %d\n", b0, b5, b15, b60, old }
  '
fi

vcpus=$((instances * 8))
echo "vCPUs: $vcpus / 1388 on-demand quota ($(( vcpus * 100 / 1388 ))%)"

echo ""
echo "=== Configuration ==="
echo "SSM AMI: $(aws ssm get-parameter --name '/github-action-runners/crucible-ci/fedora-k3s/runners/config/ami_id' --region $REGION --query 'Parameter.Value' --output text)"
echo "SSM JIT: $(aws ssm get-parameter --name '/github-action-runners/crucible-ci/fedora-k3s/runners/config/enable_jit_config' --region $REGION --query 'Parameter.Value' --output text)"
echo "ACCEPT_EVENTS: $(aws lambda get-function-configuration --function-name crucible-ci-webhook --region $REGION --query 'Environment.Variables.ACCEPT_EVENTS' --output text)"
echo "MAX_RUNNERS: $(aws lambda get-function-configuration --function-name crucible-ci-fedora-k3s-scale-up --region $REGION --query 'Environment.Variables.RUNNERS_MAXIMUM_COUNT' --output text)"
echo "GRACE_PERIOD: $(aws lambda get-function-configuration --function-name crucible-ci-fedora-k3s-scale-up --region $REGION --query 'Environment.Variables.MINIMUM_RUNNING_TIME_IN_MINUTES' --output text) min"
echo "CAPACITY_TYPE: $(aws lambda get-function-configuration --function-name crucible-ci-fedora-k3s-scale-up --region $REGION --query 'Environment.Variables.INSTANCE_TARGET_CAPACITY_TYPE' --output text)"
webhook_concurrency=$(aws lambda get-function-concurrency --function-name crucible-ci-webhook --region $REGION --query 'ReservedConcurrentExecutions' --output text 2>/dev/null || echo "unrestricted")
dispatcher_concurrency=$(aws lambda get-function-concurrency --function-name crucible-ci-dispatch-to-runner --region $REGION --query 'ReservedConcurrentExecutions' --output text 2>/dev/null || echo "unrestricted")
echo "WEBHOOK_CONCURRENCY: $webhook_concurrency"
echo "DISPATCHER_CONCURRENCY: $dispatcher_concurrency"

echo ""
echo "=== SQS Queue ==="
sqs_attrs=$(aws sqs get-queue-attributes \
  --queue-url "https://sqs.$REGION.amazonaws.com/$ACCOUNT/crucible-ci-fedora-k3s-queued-builds" \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
  --region $REGION --query 'Attributes' --output json)
echo "Messages: $(echo "$sqs_attrs" | jq -r '.ApproximateNumberOfMessages') queued, $(echo "$sqs_attrs" | jq -r '.ApproximateNumberOfMessagesNotVisible') in-flight"

echo ""
echo "=== Lambda Activity (last 5 min) ==="
echo "Webhook events: $(aws logs filter-log-events --log-group-name /aws/lambda/crucible-ci-webhook --start-time $(($(date +%s) - 300))000 --region $REGION 2>/dev/null | jq -r '.events | length')"
echo "Scale-up instances created: $(aws logs filter-log-events --log-group-name /aws/lambda/crucible-ci-fedora-k3s-scale-up --start-time $(($(date +%s) - 300))000 --region $REGION 2>/dev/null | jq -r '.events[] | .message' | grep 'Created instance' | wc -l)"

scale_up_errors=$(aws logs filter-log-events --log-group-name /aws/lambda/crucible-ci-fedora-k3s-scale-up --start-time $(($(date +%s) - 300))000 --region $REGION 2>/dev/null | jq -r '.events[] | .message' | grep -i 'ERROR')
error_count=$(echo "$scale_up_errors" | grep -c . 2>/dev/null || echo 0)
if [ -z "$scale_up_errors" ]; then error_count=0; fi
echo "Scale-up errors: $error_count"
if [ "$error_count" -gt 0 ]; then
  echo "  Recent errors:"
  echo "$scale_up_errors" | head -3 | while read line; do
    echo "  $(echo "$line" | jq -r '.message // .' 2>/dev/null || echo "$line")" | head -c 200
    echo ""
  done
fi

scale_down_terminations=$(aws logs filter-log-events --log-group-name /aws/lambda/crucible-ci-fedora-k3s-scale-down --start-time $(($(date +%s) - 300))000 --region $REGION 2>/dev/null | jq -r '.events[] | .message' | grep -i 'terminat')
term_count=$(echo "$scale_down_terminations" | grep -c . 2>/dev/null || echo 0)
if [ -z "$scale_down_terminations" ]; then term_count=0; fi
echo "Scale-down terminations: $term_count"

echo ""
echo "=== GitHub Runners ==="
online=$(gh api /orgs/perftool-incubator/actions/runners --paginate \
  -q '.runners[] | select(.name | startswith("crucible-ci")) | select(.status == "online") | .name' 2>/dev/null | wc -l)
offline=$(gh api /orgs/perftool-incubator/actions/runners --paginate \
  -q '.runners[] | select(.name | startswith("crucible-ci")) | select(.status == "offline") | .name' 2>/dev/null | wc -l)
echo "Online: $online"
echo "Offline: $offline"
if [ "$offline" -gt 10 ]; then
  echo "  WARNING: Many offline runners. Run: ./cleanup-runners.sh"
fi

echo ""
echo "=== Recently Terminated (last 10 min) ==="
aws ec2 describe-instances --region $REGION \
  --filters 'Name=instance-state-name,Values=terminated' \
            'Name=tag:ghr:Application,Values=github-action-runner' \
  --query 'Reservations[*].Instances[*].[InstanceId,LaunchTime,StateTransitionReason]' --output text | tr '\t' ' ' | \
  while read id launch reason; do
    term_time=$(echo "$reason" | grep -oP '\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}' || echo "")
    if [ -n "$term_time" ]; then
      term_epoch=$(date -d "$term_time GMT" +%s 2>/dev/null || echo 0)
      now=$(date +%s)
      mins_ago=$(( (now - term_epoch) / 60 ))
      if [ "$mins_ago" -lt 10 ]; then
        launch_epoch=$(date -d "$launch" +%s 2>/dev/null || echo 0)
        runtime=$(( (term_epoch - launch_epoch) / 60 ))
        echo "  $id: ran ${runtime}min, terminated ${mins_ago}min ago"
      fi
    fi
  done
