output "instance_public_ip" {
  description = "EC2 Elastic IPs per environment"
  value       = { for env, _ in local.environments : env => aws_eip.app[env].public_ip }
}

output "ssh_command" {
  description = "SSH commands per environment"
  value       = { for env, _ in local.environments : env => "ssh root@${aws_eip.app[env].public_ip}" }
}

output "domain_url" {
  description = "Application URLs per environment"
  value       = { for env, cfg in local.environments : env => "https://${cfg.app_subdomain}.${var.domain_name}/" }
}

output "domain" {
  description = "Application domains per environment"
  value       = { for env, cfg in local.environments : env => "${cfg.app_subdomain}.${var.domain_name}" }
}

output "supabase_domain" {
  description = "Supabase API domains per environment"
  value       = { for env, cfg in local.environments : env => "${cfg.supabase_subdomain}.${var.domain_name}" }
}

output "kms_key_arn" {
  description = "KMS key ARN for SOPS"
  value       = var.kms_key_arn
}

resource "local_file" "infra_json" {
  for_each = local.environments

  filename = "${path.module}/infra-sonar-${each.key}.json"
  content = jsonencode({
    instance_public_ip = aws_eip.app[each.key].public_ip
    domain             = "${each.value.app_subdomain}.${var.domain_name}"
    supabase_domain    = "${each.value.supabase_subdomain}.${var.domain_name}"
    domain_url         = "https://${each.value.app_subdomain}.${var.domain_name}/"
    kms_key_arn        = var.kms_key_arn
  })
}

# --- moved block: migrate existing singleton JSON file to for_each["prod"] ---

moved {
  from = local_file.infra_json
  to   = local_file.infra_json["prod"]
}
