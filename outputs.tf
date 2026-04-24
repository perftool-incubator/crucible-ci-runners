output "webhook_endpoint" {
  description = "Webhook endpoint URL to configure in GitHub App"
  value       = module.runners.webhook.endpoint
}

output "webhook_secret" {
  description = "Webhook secret to configure in GitHub App"
  value       = random_id.random.hex
  sensitive   = true
}

output "vpc_id" {
  description = "VPC ID where runners are deployed"
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs where runners launch"
  value       = module.vpc.private_subnets
}

# Note: Multi-runner module doesn't expose individual runner role ARNs
# Each runner pool has its own IAM role
# output "runner_role_arn" {
#   description = "IAM role ARN used by runners"
#   value       = module.runners.runners.role_runner.arn
# }
