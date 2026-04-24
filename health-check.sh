#!/bin/bash
# health-check.sh - Quick health check for runner system

REGION="us-east-1"
FEDORA_AMI="ami-09c00469859f3ef6d"

echo "========================================="
echo "Runner System Health Check"
echo "========================================="
echo "Time: $(date)"
echo

# EC2 Instances
echo "EC2 Instances:"
instances=$(aws ec2 describe-instances --region $REGION \
  --filters "Name=instance-state-name,Values=running" \
            "Name=tag:ghr:Application,Values=github-action-runner" \
  --query 'length(Reservations[*].Instances[])' --output text)
echo "  Running: $instances"

if [ "$instances" -gt 0 ]; then
  ami=$(aws ec2 describe-instances --region $REGION \
    --filters "Name=instance-state-name,Values=running" \
              "Name=tag:ghr:Application,Values=github-action-runner" \
    --query 'Reservations[0].Instances[0].ImageId' --output text)
  echo "  AMI: $ami"

  if [ "$ami" == "$FEDORA_AMI" ]; then
    echo "  ✓ Correct Fedora 43 AMI"
  else
    echo "  ✗ WRONG AMI! Should be $FEDORA_AMI"
    echo "  ACTION: Run ./fix-runner-config.sh and terminate instances"
  fi

  # Instance age distribution
  echo "  Age distribution:"
  aws ec2 describe-instances --region $REGION \
    --filters "Name=instance-state-name,Values=running" \
              "Name=tag:ghr:Application,Values=github-action-runner" \
    --query 'Reservations[*].Instances[].LaunchTime' --output text | \
    tr '\t' '\n' | sort | uniq -c | tail -5
fi

echo

# GitHub Runners
echo "GitHub Runners:"
if ! gh auth status &>/dev/null; then
  echo "  ⚠ Not authenticated with GitHub CLI"
  echo "  Run: gh auth login"
else
  online=$(gh api /orgs/perftool-incubator/actions/runners --paginate \
    -q '.runners[] | select(.name | startswith("crucible-ci")) | select(.status == "online")' 2>/dev/null | \
    jq -s 'length' 2>/dev/null || echo "0")
  offline=$(gh api /orgs/perftool-incubator/actions/runners --paginate \
    -q '.runners[] | select(.name | startswith("crucible-ci")) | select(.status == "offline")' 2>/dev/null | \
    jq -s 'length' 2>/dev/null || echo "0")

  echo "  Online: $online"
  echo "  Offline: $offline"

  if [ "$offline" -gt 10 ]; then
    echo "  ⚠ Many offline runners - cleanup recommended"
    echo "  ACTION: Run cleanup script:"
    echo "    gh api /orgs/perftool-incubator/actions/runners --paginate \\"
    echo "      -q '.runners[] | select(.name | startswith(\"crucible-ci\")) | select(.status == \"offline\") | .id' | \\"
    echo "      xargs -I {} gh api -X DELETE /orgs/perftool-incubator/actions/runners/{}"
  fi

  # Check for runners that might be running on terminated instances
  if [ "$instances" -gt 0 ] && [ "$online" -gt 0 ]; then
    ratio=$(echo "scale=2; $online / $instances" | bc)
    echo "  Online/Running ratio: $ratio"
    if (( $(echo "$ratio < 0.5" | bc -l) )); then
      echo "  ⚠ Low ratio - instances may not be registering properly"
    fi
  fi
fi

echo

# Configuration
echo "Configuration:"
ami_param=$(aws ssm get-parameter \
  --name "/github-action-runners/crucible-ci/fedora-k3s/runners/config/ami_id" \
  --region $REGION \
  --query 'Parameter.Value' --output text)
echo "  SSM AMI: $ami_param"

if [ "$ami_param" == "$FEDORA_AMI" ]; then
  echo "  ✓ Correct AMI in SSM"
else
  echo "  ✗ Wrong AMI in SSM!"
  echo "  ACTION: Run ./fix-runner-config.sh"
fi

jit_config=$(aws ssm get-parameter \
  --name "/github-action-runners/crucible-ci/fedora-k3s/runners/config/enable_jit_config" \
  --region $REGION \
  --query 'Parameter.Value' --output text)
echo "  JIT config: $jit_config"

accept_events=$(aws lambda get-function-configuration \
  --function-name crucible-ci-webhook \
  --region $REGION \
  --query 'Environment.Variables.ACCEPT_EVENTS' --output text 2>/dev/null)
echo "  Webhook ACCEPT_EVENTS: $accept_events"

if [ "$accept_events" == '["workflow_job"]' ]; then
  echo "  ✓ Webhook configured correctly"
else
  echo "  ✗ Webhook misconfigured!"
  echo "  ACTION: Run ./fix-runner-config.sh"
fi

min_running_time=$(aws lambda get-function-configuration \
  --function-name crucible-ci-fedora-k3s-scale-down \
  --region $REGION \
  --query 'Environment.Variables.MINIMUM_RUNNING_TIME_IN_MINUTES' --output text 2>/dev/null)
echo "  Grace period: $min_running_time minutes"

if [ "$min_running_time" -lt 5 ]; then
  echo "  ⚠ Grace period too short - increase to 5+ minutes"
fi

echo

# SQS Queue
echo "SQS Queue:"
sqs=$(aws sqs get-queue-attributes \
  --queue-url "https://sqs.us-east-1.amazonaws.com/$(aws sts get-caller-identity --query Account --output text)/crucible-ci-fedora-k3s-queued-builds" \
  --attribute-names ApproximateNumberOfMessages,ApproximateNumberOfMessagesNotVisible \
  --region $REGION 2>/dev/null | \
  jq -r '.Attributes | "Visible: \(.ApproximateNumberOfMessages), In-flight: \(.ApproximateNumberOfMessagesNotVisible)"' 2>/dev/null || echo "Error accessing queue")
echo "  $sqs"

echo

# Recent Lambda Activity
echo "Recent Lambda Activity (last 5 min):"
scale_up_count=$(aws logs filter-log-events \
  --log-group-name /aws/lambda/crucible-ci-fedora-k3s-scale-up \
  --start-time $(($(date +%s) - 300))000 \
  --region $REGION \
  --filter-pattern "Creating runner" 2>/dev/null | \
  jq '.events | length' 2>/dev/null || echo "0")
echo "  Scale-up events: $scale_up_count"

scale_down_count=$(aws logs filter-log-events \
  --log-group-name /aws/lambda/crucible-ci-fedora-k3s-scale-down \
  --start-time $(($(date +%s) - 300))000 \
  --region $REGION \
  --filter-pattern "Terminate" 2>/dev/null | \
  jq '.events | length' 2>/dev/null || echo "0")
echo "  Scale-down events: $scale_down_count"

if [ "$scale_down_count" -gt "$scale_up_count" ] && [ "$scale_down_count" -gt 5 ]; then
  echo "  ⚠ Scale-down > scale-up - may indicate premature termination"
  echo "  Check grace period configuration"
fi

echo

# vCPU Usage
if [ "$instances" -gt 0 ]; then
  echo "Resource Usage:"
  vcpus=$((instances * 8))
  quota=1181
  usage_pct=$(echo "scale=1; $vcpus * 100 / $quota" | bc)
  echo "  vCPUs used: $vcpus / $quota ($usage_pct%)"

  if [ "$instances" -ge 80 ]; then
    echo "  ⚠ At or near maximum capacity (80 instances)"
  fi
fi

echo

# Overall Health Status
echo "========================================="
echo "Overall Status:"
if [ "$ami_param" == "$FEDORA_AMI" ] && \
   [ "$accept_events" == '["workflow_job"]' ] && \
   [ "$instances" -gt 0 ] && \
   [ "$online" -gt 0 ] && \
   [ "$offline" -lt 20 ]; then
  echo "✓ System is healthy"
else
  echo "⚠ Issues detected - review warnings above"
fi
echo "========================================="
