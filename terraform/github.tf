resource "github_repository_webhook" "deploy" {
  for_each   = local.environments
  repository = var.github_repository

  configuration {
    url          = "https://${each.value.app_subdomain}.${var.domain_name}/.well-known/deploy"
    content_type = "json"
    secret       = data.sops_file.ci.data["webhook_secret"]
    insecure_ssl = false
  }

  active = true
  events = ["push"]
}

# --- moved block: migrate existing singleton webhook to for_each["prod"] ---

moved {
  from = github_repository_webhook.deploy
  to   = github_repository_webhook.deploy["prod"]
}
