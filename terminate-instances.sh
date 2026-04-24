#!/bin/bash
# Terminate all runner EC2 instances and purge SQS queue

REGION="us-east-1"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

ids=$(aws ec2 describe-instances --region $REGION \
  --filters 'Name=instance-state-name,Values=running,pending' \
            'Name=tag:ghr:Application,Values=github-action-runner' \
  --query 'Reservations[*].Instances[*].InstanceId' --output text | tr '\t' '\n')
count=$(echo "$ids" | grep -c . 2>/dev/null || echo 0)

if [ "$count" -eq 0 ]; then
  echo "No runner instances to terminate."
else
  echo "Terminating $count instances..."
  echo "$ids" | xargs aws ec2 terminate-instances --region $REGION --instance-ids > /dev/null 2>&1
  echo "Terminated: $count"
fi

echo ""
echo "Purging SQS queue..."
aws sqs purge-queue \
  --queue-url "https://sqs.$REGION.amazonaws.com/$ACCOUNT/crucible-ci-fedora-k3s-queued-builds" \
  --region $REGION 2>/dev/null
echo "SQS queue purged"
