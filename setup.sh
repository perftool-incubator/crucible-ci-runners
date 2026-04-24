#!/bin/bash
set -e

echo "========================================="
echo "Crucible CI AWS Runners Setup"
echo "========================================="
echo ""

# Check if terraform.tfvars exists
if [ ! -f "terraform.tfvars" ]; then
    echo "ERROR: terraform.tfvars not found!"
    echo ""
    echo "Please create terraform.tfvars from the example:"
    echo "  1. cp terraform.tfvars.example terraform.tfvars"
    echo "  2. Edit terraform.tfvars with your values"
    echo ""
    echo "To base64 encode your GitHub App private key:"
    echo "  base64 -w 0 path/to/your-github-app.private-key.pem"
    echo ""
    exit 1
fi

echo "Step 1: Checking AWS credentials..."
if ! aws sts get-caller-identity &>/dev/null; then
    echo "ERROR: AWS credentials not configured!"
    echo "Please run 'aws configure' first"
    exit 1
fi
echo "✓ AWS credentials configured"
echo ""

echo "Step 2: Initializing Terraform..."
terraform init
echo ""

echo "Step 3: Planning deployment..."
terraform plan -out=tfplan
echo ""

echo "========================================="
echo "Review the plan above. If it looks good, run:"
echo "  terraform apply tfplan"
echo "========================================="
