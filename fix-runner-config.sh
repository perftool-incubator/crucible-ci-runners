#!/bin/bash
# fix-runner-config.sh - Run after every terraform apply
# This script fixes SSM parameters and Lambda config that terraform resets

set -e

REGION="us-east-1"
FEDORA_AMI="ami-09c00469859f3ef6d"

echo "==================================="
echo "Fixing Runner Configuration"
echo "==================================="
echo

# Get AWS account ID for webhook fix
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Fix AMI ID
echo "1. Fixing AMI ID parameter..."
aws ssm put-parameter \
  --name "/github-action-runners/crucible-ci/fedora-k3s/runners/config/ami_id" \
  --value "$FEDORA_AMI" \
  --type String \
  --overwrite \
  --region $REGION \
  --description "Fedora 43 custom AMI with K3s" > /dev/null
echo "   ✓ Set AMI to $FEDORA_AMI"

# Fix JIT config (keep it disabled for reliability)
echo "2. Disabling JIT config..."
aws ssm put-parameter \
  --name "/github-action-runners/crucible-ci/fedora-k3s/runners/config/enable_jit_config" \
  --value "false" \
  --type String \
  --overwrite \
  --region $REGION > /dev/null
echo "   ✓ JIT config disabled (using traditional registration)"

# Fix webhook ACCEPT_EVENTS
echo "3. Fixing webhook ACCEPT_EVENTS..."

# Get current environment variables
current_env=$(aws lambda get-function-configuration \
  --function-name crucible-ci-webhook \
  --region $REGION \
  --query 'Environment.Variables' \
  --output json)

# Extract individual values
POWERTOOLS_LOGGER_LOG_EVENT=$(echo "$current_env" | jq -r '.POWERTOOLS_LOGGER_LOG_EVENT // "false"')
POWERTOOLS_SERVICE_NAME=$(echo "$current_env" | jq -r '.POWERTOOLS_SERVICE_NAME // "crucible-ci-webhook"')
POWERTOOLS_TRACER_CAPTURE_ERROR=$(echo "$current_env" | jq -r '.POWERTOOLS_TRACER_CAPTURE_ERROR // "false"')
EVENT_BUS_NAME=$(echo "$current_env" | jq -r '.EVENT_BUS_NAME // "crucible-ci-runners"')
PARAMETER_GITHUB_APP_WEBHOOK_SECRET=$(echo "$current_env" | jq -r '.PARAMETER_GITHUB_APP_WEBHOOK_SECRET')
POWERTOOLS_TRACER_CAPTURE_HTTPS_REQUESTS=$(echo "$current_env" | jq -r '.POWERTOOLS_TRACER_CAPTURE_HTTPS_REQUESTS // "false"')
LOG_LEVEL=$(echo "$current_env" | jq -r '.LOG_LEVEL // "info"')
PARAMETER_RUNNER_MATCHER_CONFIG_PATH=$(echo "$current_env" | jq -r '.PARAMETER_RUNNER_MATCHER_CONFIG_PATH')
POWERTOOLS_TRACE_ENABLED=$(echo "$current_env" | jq -r '.POWERTOOLS_TRACE_ENABLED // "false"')

# Update with ACCEPT_EVENTS fixed
aws lambda update-function-configuration \
  --function-name crucible-ci-webhook \
  --region $REGION \
  --environment "Variables={
    POWERTOOLS_LOGGER_LOG_EVENT=$POWERTOOLS_LOGGER_LOG_EVENT,
    POWERTOOLS_SERVICE_NAME=$POWERTOOLS_SERVICE_NAME,
    POWERTOOLS_TRACER_CAPTURE_ERROR=$POWERTOOLS_TRACER_CAPTURE_ERROR,
    EVENT_BUS_NAME=$EVENT_BUS_NAME,
    ACCEPT_EVENTS='[\"workflow_job\"]',
    PARAMETER_GITHUB_APP_WEBHOOK_SECRET=$PARAMETER_GITHUB_APP_WEBHOOK_SECRET,
    POWERTOOLS_TRACER_CAPTURE_HTTPS_REQUESTS=$POWERTOOLS_TRACER_CAPTURE_HTTPS_REQUESTS,
    LOG_LEVEL=$LOG_LEVEL,
    PARAMETER_RUNNER_MATCHER_CONFIG_PATH=$PARAMETER_RUNNER_MATCHER_CONFIG_PATH,
    POWERTOOLS_TRACE_ENABLED=$POWERTOOLS_TRACE_ENABLED
  }" > /dev/null 2>&1
echo "   ✓ Webhook configured to accept workflow_job events"

echo
echo "==================================="
echo "Verification"
echo "==================================="

# Verify AMI
actual_ami=$(aws ssm get-parameter \
  --name "/github-action-runners/crucible-ci/fedora-k3s/runners/config/ami_id" \
  --region $REGION \
  --query 'Parameter.Value' \
  --output text)
if [ "$actual_ami" == "$FEDORA_AMI" ]; then
  echo "✓ AMI: $actual_ami (correct)"
else
  echo "✗ AMI: $actual_ami (WRONG! Should be $FEDORA_AMI)"
  exit 1
fi

# Verify JIT config
jit_config=$(aws ssm get-parameter \
  --name "/github-action-runners/crucible-ci/fedora-k3s/runners/config/enable_jit_config" \
  --region $REGION \
  --query 'Parameter.Value' \
  --output text)
if [ "$jit_config" == "false" ]; then
  echo "✓ JIT config: disabled (correct)"
else
  echo "⚠ JIT config: $jit_config (may cause issues)"
fi

# Verify ACCEPT_EVENTS (wait a moment for Lambda update to complete)
sleep 2
accept_events=$(aws lambda get-function-configuration \
  --function-name crucible-ci-webhook \
  --region $REGION \
  --query 'Environment.Variables.ACCEPT_EVENTS' \
  --output text 2>/dev/null || echo "error")

if [ "$accept_events" == '["workflow_job"]' ]; then
  echo "✓ ACCEPT_EVENTS: [\"workflow_job\"] (correct)"
elif [ "$accept_events" == "error" ]; then
  echo "⚠ Could not verify ACCEPT_EVENTS (Lambda may be updating)"
else
  echo "✗ ACCEPT_EVENTS: $accept_events (WRONG!)"
  exit 1
fi

# Check for running instances with wrong AMI
echo
echo "Checking running instances..."
instance_count=$(aws ec2 describe-instances --region $REGION \
  --filters "Name=instance-state-name,Values=running" \
            "Name=tag:ghr:Application,Values=github-action-runner" \
  --query 'length(Reservations[*].Instances[])' \
  --output text)

if [ "$instance_count" == "0" ]; then
  echo "✓ No instances running (new instances will use correct AMI)"
else
  instance_ami=$(aws ec2 describe-instances --region $REGION \
    --filters "Name=instance-state-name,Values=running" \
              "Name=tag:ghr:Application,Values=github-action-runner" \
    --query 'Reservations[0].Instances[0].ImageId' \
    --output text)

  if [ "$instance_ami" == "$FEDORA_AMI" ]; then
    echo "✓ $instance_count instances running with correct AMI"
  else
    echo "⚠ $instance_count instances running with WRONG AMI: $instance_ami"
    echo
    echo "ACTION REQUIRED: Terminate these instances so new ones launch with correct AMI:"
    echo "  aws ec2 describe-instances --region $REGION \\"
    echo "    --filters \"Name=instance-state-name,Values=running\" \\"
    echo "              \"Name=tag:ghr:Application,Values=github-action-runner\" \\"
    echo "    --query 'Reservations[*].Instances[*].InstanceId' --output text | \\"
    echo "    tr '\\t' ' ' | xargs aws ec2 terminate-instances --region $REGION --instance-ids"
  fi
fi

echo
echo "==================================="
echo "Configuration fixed successfully!"
echo "==================================="
