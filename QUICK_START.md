# Quick Start Guide

## What You Have

Your Terraform configuration is ready in `crucible-ci-runners/` with:
- ✓ Lambda functions downloaded (in `lambdas/`)
- ✓ VPC configuration for a new network
- ✓ GitHub Actions runners setup
- ✓ Organization-level runners configured
- ✓ GitHub App ID: 2942511

## Next Steps

### 1. Prepare Your Configuration

Create your `terraform.tfvars` file:

```bash
cd crucible-ci-runners
cp terraform.tfvars.example terraform.tfvars
```

### 2. Encode Your GitHub App Private Key

```bash
base64 -w 0 /path/to/your-github-app-private-key.pem
```

Copy the output.

### 3. Edit terraform.tfvars

Open `terraform.tfvars` and fill in:

```hcl
aws_region = "us-east-1"  # or your preferred region

github_app_id = "2942511"

github_app_key_base64 = "PASTE_YOUR_BASE64_ENCODED_KEY_HERE"

github_organization = "your-github-org-or-username"
```

### 4. Deploy

**Option A - Using the setup script:**
```bash
./setup.sh
# Review the plan, then:
terraform apply tfplan
```

**Option B - Manual:**
```bash
terraform init
terraform plan
terraform apply
```

### 5. Get Webhook Configuration

After deployment completes, get the webhook details:

```bash
# Get webhook URL
terraform output webhook_endpoint

# Get webhook secret
terraform output -raw webhook_secret
```

### 6. Configure GitHub App

1. Go to https://github.com/settings/apps
2. Click on your GitHub App
3. Under "General":
   - Check "Active" under Webhook
   - **Webhook URL**: Paste the `webhook_endpoint` output
   - **Webhook secret**: Paste the `webhook_secret` output
   - **Content type**: Select `application/json`
4. Under "Permissions & events" → "Subscribe to events":
   - ✓ Check **"Workflow job"** ONLY (not Check run)
5. Click "Save changes"

### 7. Install the App

1. Still in your GitHub App settings
2. Go to "Install App" in the left sidebar
3. Click "Install" next to your organization
4. Choose "All repositories" or select repositories (must include crucible-ci)
5. Click "Install"

### 8. Test It!

Create a workflow in your crucible-ci repository:

```yaml
# .github/workflows/test-runner.yml
name: Test AWS Runner

on: [push]

jobs:
  test:
    runs-on: [self-hosted, crucible-ci, aws]
    steps:
      - name: Test runner
        run: |
          echo "Running on AWS self-hosted runner!"
          uname -a
          pwd
```

Push this workflow and watch it run on your new AWS runners!

## Monitoring

- **GitHub**: Settings → Actions → Runners (see registered runners)
- **AWS CloudWatch**: Check Lambda logs
- **AWS EC2**: See running instances when jobs execute

## Troubleshooting

If runners don't start:
1. Check GitHub App webhook deliveries (Settings → GitHub Apps → Advanced tab)
2. Check CloudWatch logs for `/aws/lambda/crucible-ci-webhook`
3. Verify AWS credentials have necessary permissions
4. Ensure GitHub App is installed to your organization

## Cleanup

To remove all AWS resources:

```bash
terraform destroy
```

## Need Help?

See the full README.md for detailed documentation and troubleshooting tips.
