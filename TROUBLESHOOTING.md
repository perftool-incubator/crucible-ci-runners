# AWS GitHub Runners Troubleshooting Guide

## Date: 2026-03-19

This document details all issues encountered during the initial deployment and testing of AWS Lambda-based GitHub Actions runners for crucible-ci.

---

## Issue 1: Wrong AMI - Amazon Linux Instead of Fedora 43

### Symptoms
- Instances launching but runners failing to register
- Console output showing `chown: invalid user: 'fedora'` error
- User-data script failing with exit code 1

### Root Cause
The SSM parameter `/github-action-runners/crucible-ci/fedora-k3s/runners/config/ami_id` was pointing to Amazon Linux 2023 AMI (`ami-02dfbd4ff395f2a1b`) instead of our custom Fedora 43 AMI (`ami-09c00469859f3ef6d`).

**Why this happened:**
- Terraform module creates the SSM parameter during initial deployment
- If not explicitly set in terraform, it defaults to the latest Amazon Linux AMI
- Subsequent `terraform apply` operations **reset** the SSM parameter value to the terraform-managed value
- Even though we manually updated it, terraform kept reverting it

### Diagnosis Steps
1. Check which AMI instances are using:
   ```bash
   aws ec2 describe-instances --region us-east-1 \
     --filters "Name=instance-state-name,Values=running" \
               "Name=tag:ghr:Application,Values=github-action-runner" \
     --query 'Reservations[0].Instances[0].ImageId' --output text
   ```

2. Check what AMI the SSM parameter specifies:
   ```bash
   aws ssm get-parameter \
     --name "/github-action-runners/crucible-ci/fedora-k3s/runners/config/ami_id" \
     --region us-east-1 --query 'Parameter.Value' --output text
   ```

3. Check console output for user errors:
   ```bash
   aws ec2 get-console-output --instance-id <instance-id> --region us-east-1 \
     --output text | grep -E "error|fail|chown"
   ```

### Solution
1. **Immediate fix** - Update SSM parameter manually:
   ```bash
   aws ssm put-parameter \
     --name "/github-action-runners/crucible-ci/fedora-k3s/runners/config/ami_id" \
     --value "ami-09c00469859f3ef6d" \
     --type String \
     --overwrite \
     --region us-east-1
   ```

2. **Terminate all instances** with wrong AMI:
   ```bash
   aws ec2 describe-instances --region us-east-1 \
     --filters "Name=instance-state-name,Values=running" \
               "Name=tag:ghr:Application,Values=github-action-runner" \
     --query 'Reservations[*].Instances[*].InstanceId' --output text | \
     tr '\t' ' ' | xargs aws ec2 terminate-instances --region us-east-1 --instance-ids
   ```

3. **Long-term fix** - Configure AMI in terraform (NOT IMPLEMENTED YET):
   - The terraform module doesn't directly expose AMI configuration
   - It uses `ami_filter` and `ami_owners` to find AMIs dynamically
   - Our custom Fedora AMI matches the filter pattern `crucible-ci-fedora-43-runner-*`
   - But terraform still manages the SSM parameter and can reset it

### Prevention
- After any `terraform apply`, verify SSM parameter still points to correct AMI
- Monitor instance AMI IDs in launch template
- Consider adding validation in CI/CD pipeline

---

## Issue 2: JIT Configuration IAM Permission Errors

### Symptoms
- Instances launching with correct AMI
- User-data script reaching runner setup
- Error: `AccessDeniedException: User is not authorized to perform: ssm:GetParameter on resource: /github-action-runners/crucible-ci/fedora-k3s/runners/tokens/<instance-id>`
- Runners failing to register

### Root Cause
With JIT (Just-In-Time) config enabled, the scale-up Lambda creates ephemeral registration tokens stored in SSM parameters. The instance IAM role needs permission to read these tokens, but there was a mismatch in the permission condition.

The IAM policy required an `InstanceId` tag, but the instances didn't have that tag (or there was a timing issue with tag propagation).

### Diagnosis Steps
1. Check console output for permission errors:
   ```bash
   aws ec2 get-console-output --instance-id <instance-id> --region us-east-1 \
     --output text | grep -i "accessdenied\|permission\|ssm:GetParameter"
   ```

2. Check if JIT token parameter exists:
   ```bash
   aws ssm get-parameter \
     --name "/github-action-runners/crucible-ci/fedora-k3s/runners/tokens/<instance-id>" \
     --region us-east-1
   ```

3. Check instance IAM role permissions:
   ```bash
   aws iam get-role-policy \
     --role-name crucible-ci-fedora-k3s-runner-<hash> \
     --policy-name runner-ssm-parameters
   ```

### Solution
**Disable JIT config** and use traditional runner registration:

```bash
aws ssm put-parameter \
  --name "/github-action-runners/crucible-ci/fedora-k3s/runners/config/enable_jit_config" \
  --value "false" \
  --type String \
  --overwrite \
  --region us-east-1
```

This is more reliable because:
- Traditional registration creates a long-lived registration token
- No complex IAM permission requirements
- Works with ephemeral runners (they still auto-deregister after job completion)

### Prevention
- Monitor Lambda logs for JIT token creation errors
- Test IAM permissions in dev environment before production
- Consider keeping JIT disabled unless absolutely needed

---

## Issue 3: Scale-Down Lambda Terminating Instances Too Quickly

### Symptoms
- Instances launching successfully
- Instance count would grow (25→46) then rapidly shrink back down (46→20)
- Runners never appearing as "online" in GitHub
- Scale-down Lambda logs showing instances being terminated

### Root Cause
The scale-down Lambda runs every minute (`cron(* * * * ? *)`). It looks for EC2 instances that don't have corresponding GitHub runner registrations and terminates them as "orphaned."

Our Fedora 43 AMI takes **~3-4 minutes** to fully boot and register the runner:
1. Cloud-init (30 sec)
2. Install Docker/dependencies (90 sec)
3. Download/setup GitHub runner (60 sec)
4. Register runner (30 sec)

The scale-down Lambda was terminating instances before they finished step 4.

### Diagnosis Steps
1. Check scale-down Lambda logs:
   ```bash
   aws logs tail /aws/lambda/crucible-ci-fedora-k3s-scale-down \
     --region us-east-1 --since 10m --format short | grep "Terminate"
   ```

2. Monitor instance lifecycle:
   ```bash
   # Watch instances appear and disappear
   watch -n 5 'aws ec2 describe-instances --region us-east-1 \
     --filters "Name=instance-state-name,Values=running" \
               "Name=tag:ghr:Application,Values=github-action-runner" \
     --query "length(Reservations[*].Instances[])"'
   ```

3. Check instance ages when terminated:
   ```bash
   aws ec2 describe-instances --region us-east-1 \
     --filters "Name=instance-state-name,Values=terminated" \
               "Name=tag:ghr:Application,Values=github-action-runner" \
     --query 'Reservations[*].Instances[*].[InstanceId,LaunchTime,StateTransitionReason]'
   ```

### Solution
Add `minimum_running_time_in_minutes` to terraform configuration:

```hcl
runner_config = {
  # ... other config ...

  # Grace period: instances must run at least 5 minutes before scale-down can terminate them
  # This prevents termination during boot/registration (Fedora boot + runner setup takes ~3-4 min)
  minimum_running_time_in_minutes = 5
}
```

Then apply terraform:
```bash
terraform apply
```

Verify the Lambda has the setting:
```bash
aws lambda get-function-configuration \
  --function-name crucible-ci-fedora-k3s-scale-down \
  --region us-east-1 \
  --query 'Environment.Variables.MINIMUM_RUNNING_TIME_IN_MINUTES'
```

### Prevention
- Always set grace period >= boot time + registration time
- Monitor scale-down logs for premature terminations
- Test with a few instances before scaling to max

---

## Issue 4: Webhook Not Accepting workflow_job Events

### Symptoms
- Workflow jobs queued in GitHub
- No instances launching
- SQS queue empty (0 messages)
- Webhook Lambda logs show events being received but not processed

### Root Cause
The webhook Lambda has an environment variable `ACCEPT_EVENTS` that filters which GitHub event types to process. This was set to an empty array `[]` instead of `["workflow_job"]`.

**Why this happened:**
- Terraform module doesn't manage the `ACCEPT_EVENTS` parameter directly
- When we ran `terraform apply`, it reset the Lambda environment variables
- The module likely set `ACCEPT_EVENTS` correctly during initial creation
- But subsequent terraform applies overwrote it with the wrong value

### Diagnosis Steps
1. Check if webhook is receiving events:
   ```bash
   aws logs tail /aws/lambda/crucible-ci-webhook \
     --region us-east-1 --since 5m --format short
   ```

2. Check ACCEPT_EVENTS configuration:
   ```bash
   aws lambda get-function-configuration \
     --function-name crucible-ci-webhook \
     --region us-east-1 \
     --query 'Environment.Variables.ACCEPT_EVENTS'
   ```

3. Check SQS queue depth:
   ```bash
   aws sqs get-queue-attributes \
     --queue-url https://sqs.us-east-1.amazonaws.com/<account>/crucible-ci-fedora-k3s-queued-builds \
     --attribute-names ApproximateNumberOfMessages \
     --region us-east-1
   ```

### Solution
**Manual fix after each terraform apply:**

```bash
# Get current environment variables
current_env=$(aws lambda get-function-configuration \
  --function-name crucible-ci-webhook \
  --region us-east-1 \
  --query 'Environment.Variables' \
  --output json)

# Update with ACCEPT_EVENTS fixed
aws lambda update-function-configuration \
  --function-name crucible-ci-webhook \
  --region us-east-1 \
  --environment "Variables={
    POWERTOOLS_LOGGER_LOG_EVENT=false,
    POWERTOOLS_SERVICE_NAME=crucible-ci-webhook,
    POWERTOOLS_TRACER_CAPTURE_ERROR=false,
    EVENT_BUS_NAME=crucible-ci-runners,
    ACCEPT_EVENTS='[\"workflow_job\"]',
    PARAMETER_GITHUB_APP_WEBHOOK_SECRET=/github-action-runners/crucible-ci/app/github_app_webhook_secret,
    POWERTOOLS_TRACER_CAPTURE_HTTPS_REQUESTS=false,
    LOG_LEVEL=info,
    PARAMETER_RUNNER_MATCHER_CONFIG_PATH=/github-action-runners/crucible-ci/webhook/runner-matcher-config,
    POWERTOOLS_TRACE_ENABLED=false
  }"
```

**Important:** This must be done after EVERY `terraform apply`

### Prevention
- Create a script to verify/fix ACCEPT_EVENTS after terraform apply
- Add this to deployment checklist
- Consider contributing a fix to the terraform module upstream

---

## Issue 5: 601 Stale Offline Runners Blocking Jobs

### Symptoms
- 1200+ jobs queued but not running
- EC2 instances launching and registering successfully
- GitHub shows hundreds of runners but almost all "offline"
- Jobs assigned to offline runners and stuck forever

### Root Cause
With ephemeral runners, each instance registers a unique runner when it starts. When the job completes, the instance terminates but the runner registration sometimes doesn't clean up properly.

Over time, this accumulated **601 offline runner registrations**:
- 420 with prefix `crucible-ci-fedora_` (from our configuration)
- 181 with prefix `crucible-ci_` (from an older/different configuration)

GitHub assigns queued jobs to **any** runner that matches the labels, including offline ones. These jobs then sit waiting forever for an offline runner that will never come online.

### Diagnosis Steps
1. Count total runners in organization:
   ```bash
   gh api /orgs/perftool-incubator/actions/runners --paginate | jq -s 'map(.runners[]) | length'
   ```

2. Check runners by status:
   ```bash
   gh api /orgs/perftool-incubator/actions/runners --paginate | \
     jq -s 'map(.runners[]) | group_by(.status) | map({status: .[0].status, count: length})'
   ```

3. Check crucible-ci runners specifically:
   ```bash
   gh api /orgs/perftool-incubator/actions/runners --paginate | \
     jq -s 'map(.runners[]) | map(select(.name | startswith("crucible-ci"))) |
     group_by(.status) | map({status: .[0].status, count: length})'
   ```

4. Check if jobs are assigned to offline runners:
   ```bash
   gh api "/repos/perftool-incubator/crucible-ci/actions/runs/<run-id>/jobs" --paginate | \
     jq -s 'map(.jobs[]) | map(select(.status == "queued")) | .[0:5] | .[] | .runner_name'
   ```

### Solution
**Remove all offline runners** (requires `admin:org` scope):

1. Grant GitHub CLI admin:org permission:
   ```bash
   gh auth refresh -h github.com -s admin:org
   ```

2. Remove offline runners with `crucible-ci-fedora_` prefix:
   ```bash
   gh api /orgs/perftool-incubator/actions/runners --paginate \
     -q '.runners[] | select(.name | startswith("crucible-ci-fedora_")) | select(.status == "offline") | .id' \
     > /tmp/offline_runners.txt

   while read id; do
     gh api -X DELETE /orgs/perftool-incubator/actions/runners/$id 2>/dev/null && \
       echo "Removed runner $id"
   done < /tmp/offline_runners.txt
   ```

3. Remove offline runners with `crucible-ci_` prefix (different naming pattern):
   ```bash
   gh api /orgs/perftool-incubator/actions/runners --paginate \
     -q '.runners[] | select(.name | startswith("crucible-ci_")) | select(.status == "offline") | .id' \
     > /tmp/offline_crucible.txt

   while read id; do
     gh api -X DELETE /orgs/perftool-incubator/actions/runners/$id 2>/dev/null && \
       echo "Removed runner $id"
   done < /tmp/offline_crucible.txt
   ```

4. **Cancel stuck workflows and re-trigger:**
   ```bash
   # Cancel workflows that have jobs assigned to deleted runners
   gh run cancel <run-id> --repo perftool-incubator/crucible-ci

   # Trigger new workflow
   cd /path/to/crucible-ci
   git commit --allow-empty -m "Re-trigger after runner cleanup"
   git push
   ```

### Prevention
**This will keep happening** until we fix the root cause. Options:

1. **Monitor and clean up regularly:**
   ```bash
   # Add to cron or CI/CD pipeline
   gh api /orgs/perftool-incubator/actions/runners --paginate \
     -q '.runners[] | select(.name | startswith("crucible-ci")) | select(.status == "offline") | .id' | \
     xargs -I {} gh api -X DELETE /orgs/perftool-incubator/actions/runners/{}
   ```

2. **Investigate why ephemeral runners aren't auto-deregistering:**
   - Check if instances are being force-terminated before runner cleanup
   - Verify runner has time to deregister gracefully
   - Check runner logs for deregistration errors

3. **Use runner groups with shorter retention:**
   - Potentially configure in GitHub organization settings
   - May not be available in all GitHub plans

---

## Issue 6: Terraform Keeps Resetting SSM Parameters

### Symptoms
- Manually update SSM parameter (e.g., AMI ID, JIT config)
- Run `terraform apply`
- Parameter gets reset to wrong/default value
- Instances launch with wrong configuration again

### Root Cause
The terraform module manages SSM parameters as resources. When you run `terraform apply`, it enforces the state defined in terraform code, which may not reflect manual changes.

Specifically:
- `ami_id` parameter: Module sets it based on AMI filters, might default to latest Amazon Linux
- `enable_jit_config`: Module might have a default value different from what we manually set
- `ACCEPT_EVENTS` in Lambda: Not fully managed by module, gets overwritten

### Diagnosis Steps
1. Check terraform state for SSM parameters:
   ```bash
   terraform state list | grep ssm_parameter
   ```

2. Check parameter version history:
   ```bash
   aws ssm get-parameter-history \
     --name "/github-action-runners/crucible-ci/fedora-k3s/runners/config/ami_id" \
     --region us-east-1 \
     --query 'Parameters[*].[Version,LastModifiedDate,Value]'
   ```

3. After terraform apply, immediately check if parameters changed:
   ```bash
   aws ssm get-parameter \
     --name "/github-action-runners/crucible-ci/fedora-k3s/runners/config/ami_id" \
     --region us-east-1
   ```

### Solution
**Create a post-terraform-apply script** to fix parameters:

```bash
#!/bin/bash
# fix-runner-config.sh - Run after every terraform apply

echo "Fixing SSM parameters after terraform apply..."

# Fix AMI ID
aws ssm put-parameter \
  --name "/github-action-runners/crucible-ci/fedora-k3s/runners/config/ami_id" \
  --value "ami-09c00469859f3ef6d" \
  --type String \
  --overwrite \
  --region us-east-1
echo "✓ Fixed AMI ID"

# Fix JIT config (keep it disabled)
aws ssm put-parameter \
  --name "/github-action-runners/crucible-ci/fedora-k3s/runners/config/enable_jit_config" \
  --value "false" \
  --type String \
  --overwrite \
  --region us-east-1
echo "✓ Fixed JIT config"

# Fix webhook ACCEPT_EVENTS
aws lambda update-function-configuration \
  --function-name crucible-ci-webhook \
  --region us-east-1 \
  --environment "Variables={ACCEPT_EVENTS='[\"workflow_job\"]',...}" > /dev/null
echo "✓ Fixed webhook ACCEPT_EVENTS"

echo "Done! Verify configuration:"
echo "  AMI: $(aws ssm get-parameter --name '/github-action-runners/crucible-ci/fedora-k3s/runners/config/ami_id' --query 'Parameter.Value' --output text)"
echo "  JIT: $(aws ssm get-parameter --name '/github-action-runners/crucible-ci/fedora-k3s/runners/config/enable_jit_config' --query 'Parameter.Value' --output text)"
echo "  ACCEPT_EVENTS: $(aws lambda get-function-configuration --function-name crucible-ci-webhook --query 'Environment.Variables.ACCEPT_EVENTS' --output text)"
```

Usage:
```bash
terraform apply && ./fix-runner-config.sh
```

### Prevention
- Always run the fix script after terraform apply
- Add to deployment documentation
- Consider contributing fixes to upstream terraform module

---

## Issue 7: Scale-Down Lambda Ignores Grace Period for "Not Found" Runners

### Symptoms
- Jobs fail mid-execution with logs that abruptly end
- Example: Job log stops during container image pull or other long-running operation
- Job shows as "failure" with runtime of only 10-15 minutes instead of expected 3-4 hours
- Instance terminated after only 4-5 minutes (less than grace period)
- Scale-down logs show: `"Runner 'i-XXX' - GitHub Runner ID 'XXX' - Not found on GitHub, treating as not busy"`

### Root Cause
**Critical bug in scale-down Lambda logic:**

The scale-down Lambda is supposed to check two conditions before terminating an instance:
1. Is the runner "not busy" (not running a job)?
2. Has the instance been running longer than MINIMUM_RUNNING_TIME_IN_MINUTES?

However, when the Lambda queries GitHub's API to check runner status and gets a 404 error ("runner not found"), it:
1. Marks the runner as "not busy" (reasonable assumption)
2. **Immediately terminates the instance WITHOUT checking the grace period** (BUG!)

This causes instances to be terminated while jobs are still running, resulting in job failures.

### Why "Not Found" Happens
1. **JIT (Just-In-Time) configuration enabled**: With `enable_jit_config=true`, runners use ephemeral tokens and may not appear consistently in GitHub's runner API
2. **Race condition**: Newly-launched runners may not have fully registered with GitHub yet
3. **GitHub API latency**: Temporary API delays can make recently-registered runners appear "not found"
4. **Ephemeral runners**: Runners that just completed a job and de-registered might still have running instances

### Evidence - Real Example
Instance `i-0d276435299dd2fa6` that ran failed job #67813819901:
- **Launched:** 2026-03-19T20:44:28+00:00
- **Job started:** 2026-03-19T20:46:44+00:00 (2 min after launch)
- **Instance terminated:** 2026-03-19T20:49:07+00:00 (StateTransitionReason: "Service initiated")
- **Runtime before termination:** 4 minutes 39 seconds
- **Job "completed":** 2026-03-19T20:58:45+00:00 (failure - runner already gone)

The instance was terminated **4m39s** after launch, which is **less than the 5-minute grace period** configured in `minimum_running_time_in_minutes = 5`.

Scale-down log for this event:
```
"Runner 'i-0d276435299dd2fa6' - GitHub Runner ID '141992' - Not found on GitHub, treating as not busy"
```

### Diagnosis Steps

1. **Check for recent job failures with abrupt log endings:**
   ```bash
   gh run list --repo perftool-incubator/crucible-ci --limit 20 --json conclusion,name,url | \
     jq -r '.[] | select(.conclusion == "failure") | .url'
   ```

2. **Check scale-down logs for "not found" decisions:**
   ```bash
   aws logs filter-log-events \
     --log-group-name /aws/lambda/crucible-ci-fedora-k3s-scale-down \
     --start-time $(($(date +%s) - 3600))000 \
     --region us-east-1 | \
     jq -r '.events[] | select(.message | contains("Not found on GitHub")) | .message'
   ```

3. **Check instance runtime for recent terminations:**
   ```bash
   aws ec2 describe-instances --region us-east-1 \
     --filters "Name=instance-state-name,Values=terminated" \
               "Name=tag:ghr:Application,Values=github-action-runner" \
     --query 'Reservations[*].Instances[*].[InstanceId,LaunchTime,StateTransitionReason]' \
     --output text | head -10
   ```

4. **Check JIT config status:**
   ```bash
   aws ssm get-parameter \
     --name "/github-action-runners/crucible-ci/fedora-k3s/runners/config/enable_jit_config" \
     --region us-east-1 --query 'Parameter.Value' --output text
   ```
   Should be `false` for reliability.

### Solution

#### Immediate Fix - Increase Grace Period
Since the Lambda bypasses the grace period check for "not found" runners, we need to make the grace period very conservative:

```hcl
# In main.tf
minimum_running_time_in_minutes = 15  # Increased from 5
```

This gives runners time to:
- Boot and register with GitHub (3-4 min)
- Start job and get marked "busy" (1-2 min)
- Buffer for GitHub API latency (5+ min)

#### Critical Fix - Disable JIT Config
```bash
aws ssm put-parameter \
  --name "/github-action-runners/crucible-ci/fedora-k3s/runners/config/enable_jit_config" \
  --value "false" \
  --type String \
  --overwrite \
  --region us-east-1
```

With traditional registration (non-JIT), runners stay registered in GitHub's database and are reliably findable via API.

#### Apply Changes
```bash
# 1. Update main.tf with increased grace period
# 2. Apply terraform changes
terraform apply

# 3. Fix JIT config (gets reset by terraform)
./fix-runner-config.sh

# 4. Monitor for continued failures
```

### Prevention
1. **Always keep JIT config disabled** - Add to fix-runner-config.sh (already done)
2. **Monitor scale-down logs** for "not found" messages
3. **Check job failure rate** - frequent 10-15 minute failures indicate this issue
4. **Consider contributing fix to upstream** - Lambda should respect grace period even for "not found" runners

### Long-Term Fix
The proper fix requires modifying the scale-down Lambda code to always respect the grace period:

```javascript
// Pseudocode for proper logic
if (instanceAge < minimumRunningTime) {
  // NEVER terminate instances within grace period
  return skip;
}

if (runnerNotFoundOnGitHub) {
  // Be conservative - don't terminate if we can't verify status
  return skip;
}

if (runnerFound && !runnerBusy) {
  // Safe to terminate - runner exists and is idle
  return terminate;
}
```

This fix would need to be contributed to the upstream terraform module.

### Impact
- **High severity**: Causes random job failures
- **Affects**: All workflows using crucible-ci runners
- **Frequency**: Depends on GitHub API latency and load - can affect 5-10% of jobs
- **Cost**: Each failed job wastes compute resources and developer time

---

## Complete Deployment Checklist

### Initial Setup
- [ ] Build custom Fedora 43 AMI with K3s
- [ ] Note AMI ID (e.g., `ami-09c00469859f3ef6d`)
- [ ] Configure terraform with correct AMI filter pattern
- [ ] Set `minimum_running_time_in_minutes = 5` in terraform
- [ ] Deploy with `terraform apply`
- [ ] **Immediately run fix script** to set correct SSM parameters

### After Every Terraform Apply
- [ ] Run `./fix-runner-config.sh` to fix SSM parameters
- [ ] Verify AMI ID: `aws ssm get-parameter --name '...' --query 'Parameter.Value'`
- [ ] Verify webhook accepts events: Check ACCEPT_EVENTS in Lambda config
- [ ] Terminate any running instances to force re-launch with correct config

### Daily/Weekly Maintenance
- [ ] Clean up offline runners:
  ```bash
  gh api /orgs/perftool-incubator/actions/runners --paginate \
    -q '.runners[] | select(.name | startswith("crucible-ci")) | select(.status == "offline") | .id' | \
    xargs -I {} gh api -X DELETE /orgs/perftool-incubator/actions/runners/{}
  ```
- [ ] Check for instances with wrong AMI
- [ ] Monitor scale-down Lambda for premature terminations

### When Jobs Get Stuck
1. [ ] Check runner status: `gh api /orgs/perftool-incubator/actions/runners`
2. [ ] Count offline runners - if > 10, clean them up
3. [ ] Check if instances are using correct AMI
4. [ ] Check webhook ACCEPT_EVENTS configuration
5. [ ] Check SQS queue depth
6. [ ] Cancel stuck workflows and re-trigger

---

## Monitoring Commands

### Check System Health
```bash
#!/bin/bash
# health-check.sh - Quick health check for runner system

echo "=== Runner System Health Check ==="
echo

echo "EC2 Instances:"
instances=$(aws ec2 describe-instances --region us-east-1 \
  --filters "Name=instance-state-name,Values=running" \
            "Name=tag:ghr:Application,Values=github-action-runner" \
  --query 'length(Reservations[*].Instances[])' --output text)
echo "  Running: $instances"

if [ "$instances" -gt 0 ]; then
  ami=$(aws ec2 describe-instances --region us-east-1 \
    --filters "Name=instance-state-name,Values=running" \
              "Name=tag:ghr:Application,Values=github-action-runner" \
    --query 'Reservations[0].Instances[0].ImageId' --output text)
  echo "  AMI: $ami"

  if [ "$ami" == "ami-09c00469859f3ef6d" ]; then
    echo "  ✓ Correct Fedora 43 AMI"
  else
    echo "  ✗ WRONG AMI! Should be ami-09c00469859f3ef6d"
  fi
fi

echo
echo "GitHub Runners:"
online=$(gh api /orgs/perftool-incubator/actions/runners --paginate \
  -q '.runners[] | select(.name | startswith("crucible-ci")) | select(.status == "online")' | \
  jq -s 'length')
offline=$(gh api /orgs/perftool-incubator/actions/runners --paginate \
  -q '.runners[] | select(.name | startswith("crucible-ci")) | select(.status == "offline")' | \
  jq -s 'length')
echo "  Online: $online"
echo "  Offline: $offline"

if [ "$offline" -gt 10 ]; then
  echo "  ⚠ Many offline runners - consider cleanup"
fi

echo
echo "Configuration:"
ami_param=$(aws ssm get-parameter \
  --name "/github-action-runners/crucible-ci/fedora-k3s/runners/config/ami_id" \
  --query 'Parameter.Value' --output text)
echo "  SSM AMI: $ami_param"

accept_events=$(aws lambda get-function-configuration \
  --function-name crucible-ci-webhook \
  --region us-east-1 \
  --query 'Environment.Variables.ACCEPT_EVENTS' --output text)
echo "  Webhook ACCEPT_EVENTS: $accept_events"

if [ "$accept_events" == '["workflow_job"]' ]; then
  echo "  ✓ Webhook configured correctly"
else
  echo "  ✗ Webhook misconfigured!"
fi

echo
echo "SQS Queue:"
sqs=$(aws sqs get-queue-attributes \
  --queue-url "https://sqs.us-east-1.amazonaws.com/$(aws sts get-caller-identity --query Account --output text)/crucible-ci-fedora-k3s-queued-builds" \
  --attribute-names ApproximateNumberOfMessages \
  --region us-east-1 \
  --query 'Attributes.ApproximateNumberOfMessages' --output text)
echo "  Messages: $sqs"
```

### Watch Job Progress
```bash
#!/bin/bash
# watch-jobs.sh <run-id>

RUN_ID=$1
echo "Watching workflow run $RUN_ID"

while true; do
  clear
  echo "=== $(date) ==="
  gh run view $RUN_ID --repo perftool-incubator/crucible-ci --json jobs | \
    jq '{
      total: (.jobs | length),
      completed: ([.jobs[] | select(.status == "completed")] | length),
      in_progress: ([.jobs[] | select(.status == "in_progress")] | length),
      queued: ([.jobs[] | select(.status == "queued")] | length)
    }'
  sleep 10
done
```

---

## Lessons Learned

### 1. Terraform Module Limitations
The `github-aws-runners/github-runner/aws` module doesn't provide full control over all configurations. Some settings require manual intervention after each terraform apply.

### 2. SSM Parameter Management
Using SSM parameter resolution in launch templates is powerful but can be tricky when terraform also manages those parameters. Consider lifecycle rules to prevent unwanted updates.

### 3. Grace Periods Are Critical
Always set grace periods longer than your actual boot time. Instance boot times vary by:
- AMI size and complexity
- Instance type
- Availability zone capacity
- Network conditions

### 4. Ephemeral Runners Need Cleanup
GitHub's ephemeral runner cleanup doesn't always work perfectly. Budget for regular maintenance to remove stale registrations.

### 5. Event-Driven Architecture Debugging
With webhook → EventBridge → SQS → Lambda chains, issues can be hard to trace. Always:
- Check webhook logs first
- Then EventBridge
- Then SQS queue depth
- Finally Lambda logs

### 6. AMI Testing Is Essential
Always test custom AMIs thoroughly:
- Boot time
- User-data script execution
- Runner registration
- Job execution
- Graceful shutdown

---

## Future Improvements

### Short Term
1. Create automated post-terraform-apply script
2. Set up monitoring/alerting for offline runners
3. Document AMI build process completely

### Medium Term
1. Implement dual-pool strategy (80 × 8-vCPU + 135 × 4-vCPU)
2. Request vCPU quota increase if needed
3. Add CloudWatch dashboards for runner metrics

### Long Term
1. Contribute fixes to upstream terraform module
2. Build custom AMI update pipeline
3. Implement automated cleanup of stale runners
4. Consider multi-region deployment

---

## Contact & Support

**Repository:** https://github.com/philips-labs/terraform-aws-github-runner
**Our Configuration:** `/home/atheurer/swdev/repos/terraform-aws-github-runner/crucible-ci-runners/`
**Custom AMI Build:** `packer/packer-build/fedora-43-runner-cpu-partitioning.pkr.hcl`

For issues specific to our deployment, refer to `DUAL-POOL-SETUP.md` and this troubleshooting guide.
