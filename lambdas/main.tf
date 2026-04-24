module "lambdas" {
  source = "github-aws-runners/github-runner/aws//modules/download-lambda"

  lambdas = [
    {
      name = "webhook"
      tag  = "v7.4.0"
    },
    {
      name = "runners"
      tag  = "v7.4.0"
    },
    {
      name = "runner-binaries-syncer"
      tag  = "v7.4.0"
    },
    {
      name = "ami-housekeeper"
      tag  = "v7.4.0"
    },
    {
      name = "termination-watcher"
      tag  = "v7.4.0"
    }
  ]
}

output "files" {
  value = module.lambdas.files
}
