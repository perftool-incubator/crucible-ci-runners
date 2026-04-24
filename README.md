# Crucible CI - AWS GitHub Actions Runners

This Terraform configuration sets up self-hosted GitHub Actions runners on AWS for the crucible-ci project.

## Architecture

- **VPC**: New VPC with public and private subnets across 2 availability zones
- **Runners**: EC2 instances launched on-demand in private subnets
- **Scaling**: Automatic scale-up when jobs are queued, scale-down when idle
- **Instance Types**: m5.large, m5a.large, m6i.large (cost-effective options)
- **Maximum Runners**: 5 concurrent runners

## Prerequisites

1. **AWS Credentials**: Configure AWS CLI with credentials that have permissions to create VPCs, EC2 instances, Lambda functions, IAM roles, etc.
   ```bash
   aws configure
   ```

2. **GitHub App**: Already created (App ID: 2942511)
   - Private key file (.pem) downloaded

3. **Tools**:
   - Terraform >= 1.3.0
   - AWS CLI

## Setup Instructions

### Step 1: Download Lambda Functions

```bash
cd lambdas
terraform init
terraform apply
cd ..
```

This downloads the pre-built Lambda functions from GitHub releases.

### Step 2: Prepare Configuration

1. Create your `terraform.tfvars` file from the example:
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```

2. Base64 encode your GitHub App private key:
   ```bash
   base64 -w 0 path/to/your-github-app.private-key.pem
   ```

3. Edit `terraform.tfvars` and fill in:
   - `github_app_key_base64`: The base64-encoded private key
   - `github_organization`: Your GitHub organization or username
   - `aws_region`: AWS region (default: us-east-1)

### Step 3: Deploy Infrastructure

```bash
terraform init
terraform plan
terraform apply
```

After deployment, Terraform will output:
- `webhook_endpoint`: URL for GitHub webhook
- `webhook_secret`: Secret for GitHub webhook (use `terraform output -raw webhook_secret`)

### Step 4: Configure GitHub App Webhook

1. Go to your GitHub App settings: https://github.com/settings/apps
2. Click on your app (crucible-ci-aws-runners or similar)
3. Enable the webhook:
   - Check "Active"
   - **Webhook URL**: Use the `webhook_endpoint` output from Terraform
   - **Webhook secret**: Use the `webhook_secret` output (run `terraform output -raw webhook_secret`)
   - **Content type**: application/json
4. In "Permissions & events" → "Subscribe to events":
   - Check **"Workflow job"** (choose ONLY this one, not "Check run")
5. Save changes

### Step 5: Install GitHub App

1. In your GitHub App settings, go to "Install App"
2. Install the app to your organization
3. Choose "All repositories" or select specific repositories (including crucible-ci)

## Using the Runners

In your crucible-ci repository's GitHub Actions workflows, specify the custom labels:

```yaml
name: CI

on: [push, pull_request]

jobs:
  test:
    runs-on: [self-hosted, crucible-ci, aws]
    steps:
      - uses: actions/checkout@v4
      - name: Run tests
        run: |
          # Your test commands here
```

The `runs-on` labels should match the `runner_extra_labels` configured in the Terraform (crucible-ci, aws).

## How It Works

1. GitHub sends webhook events when workflow jobs are queued
2. AWS Lambda receives the webhook and creates EC2 instances
3. Runners register with GitHub and execute jobs
4. After job completion, runners are terminated automatically
5. Scale-down runs every minute to clean up idle runners

## Debugging

- **CloudWatch Logs**: Check Lambda function logs in CloudWatch
  - `/aws/lambda/crucible-ci-webhook`
  - `/aws/lambda/crucible-ci-runners`
  - `/aws/lambda/crucible-ci-runner-binaries-syncer`

- **SSM Access**: Connect to running instances via AWS Systems Manager Session Manager

- **Runner Logs**: Check GitHub Actions settings in your organization/repository to see registered runners

## Cost Optimization

- Runners are ephemeral and terminate after each job
- Single NAT Gateway for cost savings
- Automatic scale-down every minute
- Spot instances can be enabled for further cost reduction

## Cleanup

To destroy all resources:

```bash
terraform destroy
```

## Troubleshooting

If runners aren't starting:
1. Check CloudWatch logs for webhook and runners lambdas
2. Verify GitHub App webhook is receiving events (check "Advanced" tab in GitHub App settings)
3. Ensure GitHub App has correct permissions and is installed
4. Check AWS SQS queues for messages
5. Verify EC2 instances are launching in AWS Console
