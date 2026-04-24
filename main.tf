locals {
  environment = "crucible-ci"
  aws_region  = var.aws_region
}

# VPC Configuration
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.0.0"

  name = "${local.environment}-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["${local.aws_region}a", "${local.aws_region}b", "${local.aws_region}c", "${local.aws_region}d", "${local.aws_region}f"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24", "10.0.4.0/24", "10.0.5.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24", "10.0.104.0/24", "10.0.105.0/24"]

  enable_dns_hostnames    = true
  enable_nat_gateway      = false
  map_public_ip_on_launch = true

  tags = {
    Project     = "crucible-ci"
    Environment = local.environment
  }
}

# Random webhook secret
resource "random_id" "random" {
  byte_length = 20
}

# GitHub Actions Runners Module (Multi-Runner)
module "runners" {
  source  = "github-aws-runners/github-runner/aws//modules/multi-runner"
  version = "7.6.0"

  aws_region = local.aws_region
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.public_subnets

  prefix = local.environment
  tags = {
    Project     = "crucible-ci"
    Environment = local.environment
  }

  github_app = {
    key_base64     = var.github_app_key_base64
    id             = var.github_app_id
    webhook_secret = random_id.random.hex
  }

  # Lambda zip files from downloaded lambdas
  webhook_lambda_zip                = "./lambdas/webhook.zip"
  runner_binaries_syncer_lambda_zip = "./lambdas/runner-binaries-syncer.zip"
  runners_lambda_zip                = "./lambdas/runners.zip"

  # Multi-runner configuration
  multi_runner_config = {
    # Fedora 43 pool for k8s/kube workloads with K3s
    "fedora-k3s" = {
      matcherConfig = {
        labelMatchers = [["aws-cloud-1"]]
        exactMatch    = false
      }
      job_retry = {
        enable           = true
        delay_in_seconds = 300
        max_attempts     = 3
      }
      runner_config = {
        runner_os           = "linux"
        runner_architecture = "x64"
        runner_name_prefix  = "${local.environment}-fedora_"

        # Use custom Fedora 43 AMI with K3s pre-installed
        ami = {
          filter = {
            name  = ["crucible-ci-fedora-43-runner-cpu-partitioning-nohz1-3-*"]
            state = ["available"]
          }
          owners = ["self"]
        }

        # Enable organization-level runners
        enable_organization_runners = true

        # Runner labels
        runner_extra_labels = ["aws-cloud-1", "cpu-partitioning", "remotehosts", "k8s", "kube"]

        # Enable SSM for debugging
        enable_ssm_on_runners = true

        # Instance configuration (matching AMI build size for CPU partitioning)
        instance_types                        = ["c7a.xlarge"]
        instance_target_capacity_type        = "on-demand"
        enable_ephemeral_runners              = false
        enable_jit_config                     = false
        enable_runner_binaries_syncer         = false
        userdata_content                      = file("${path.module}/userdata.sh")

        # Scaling - 128 max (128 × 4 vCPUs = 512 vCPUs, within 1388 on-demand quota)
        runners_maximum_count          = 128
        scale_down_schedule_expression = "cron(* * * * ? *)"

        # Grace period: instances must run at least 15 minutes before scale-down can terminate them
        # CRITICAL: Scale-down Lambda has a bug where it ignores grace period for runners "not found" on GitHub
        # Increased from 5 to 15 minutes to work around this bug and give runners time to:
        #   - Boot and register (3-4 min)
        #   - Start job and get marked "busy" on GitHub (1-2 min)
        #   - Buffer for GitHub API latency/race conditions (5+ min)
        minimum_running_time_in_minutes = 15

        # Set runner user for Fedora
        runner_as_root = false
        runner_run_as  = "fedora"

        # Disable CloudWatch agent (not available in Fedora repos)
        enable_cloudwatch_agent           = false
        enable_runner_detailed_monitoring = false
      }
    }

    # aws-cloud-2 x86_64 pool (1 max)
    "standard-x64" = {
      matcherConfig = {
        labelMatchers = [["self-hosted", "aws-cloud-2", "X64"]]
        exactMatch    = true
      }
      job_retry = {
        enable           = true
        delay_in_seconds = 300
        max_attempts     = 3
      }
      runner_config = {
        runner_os           = "linux"
        runner_architecture = "x64"
        runner_name_prefix  = "${local.environment}-std-x64_"

        ami = {
          filter = {
            name  = ["crucible-ci-fedora-43-runner-standard-x64-*"]
            state = ["available"]
          }
          owners = ["self"]
        }

        enable_organization_runners = true
        runner_extra_labels         = ["aws-cloud-2"]
        enable_ssm_on_runners       = true

        instance_types                = ["c7a.xlarge"]
        instance_target_capacity_type = "on-demand"
        enable_ephemeral_runners      = false
        enable_jit_config             = false
        enable_runner_binaries_syncer = false
        userdata_content              = file("${path.module}/userdata.sh")

        runners_maximum_count           = 1
        scale_down_schedule_expression  = "cron(* * * * ? *)"
        minimum_running_time_in_minutes = 15

        runner_as_root = false
        runner_run_as  = "fedora"

        enable_cloudwatch_agent           = false
        enable_runner_detailed_monitoring = false
      }
    }

    # aws-cloud-2 aarch64 pool (1 max)
    "standard-arm64" = {
      matcherConfig = {
        labelMatchers = [["self-hosted", "aws-cloud-2", "ARM64"]]
        exactMatch    = true
      }
      job_retry = {
        enable           = true
        delay_in_seconds = 300
        max_attempts     = 3
      }
      runner_config = {
        runner_os           = "linux"
        runner_architecture = "arm64"
        runner_name_prefix  = "${local.environment}-std-arm64_"

        ami = {
          filter = {
            name  = ["crucible-ci-fedora-43-runner-standard-arm64-*"]
            state = ["available"]
          }
          owners = ["self"]
        }

        enable_organization_runners = true
        runner_extra_labels         = ["aws-cloud-2"]
        enable_ssm_on_runners       = true

        instance_types                = ["c7g.xlarge"]
        instance_target_capacity_type = "on-demand"
        enable_ephemeral_runners      = false
        enable_jit_config             = false
        enable_runner_binaries_syncer = false
        userdata_content              = file("${path.module}/userdata.sh")

        runners_maximum_count           = 1
        scale_down_schedule_expression  = "cron(* * * * ? *)"
        minimum_running_time_in_minutes = 15

        runner_as_root = false
        runner_run_as  = "fedora"

        enable_cloudwatch_agent           = false
        enable_runner_detailed_monitoring = false
      }
    }
  }

  # Global settings
  enable_ami_housekeeper     = true
  ami_housekeeper_lambda_zip = "./lambdas/ami-housekeeper.zip"
  ami_housekeeper_cleanup_config = {
    ssmParameterNames = ["*/ami-id"]
    minimumDaysOld    = 30
    amiFilters = [
      {
        Name   = "name"
        Values = ["*Fedora-Cloud-Base*", "*ubuntu*", "crucible-ci-fedora-43-runner-*"]
      }
    ]
  }

  instance_termination_watcher = {
    enable = true
    zip    = "./lambdas/termination-watcher.zip"
  }

  # Webhook must accept workflow_job events to trigger runner scaling
  eventbridge = {
    enable        = true
    accept_events = ["workflow_job"]
  }
}

# Configure GitHub App webhook
module "webhook_github_app" {
  source     = "github-aws-runners/github-runner/aws//modules/webhook-github-app"
  version    = "7.6.0"
  depends_on = [module.runners]

  github_app = {
    key_base64     = var.github_app_key_base64
    id             = var.github_app_id
    webhook_secret = random_id.random.hex
  }
  webhook_endpoint = module.runners.webhook.endpoint
}
