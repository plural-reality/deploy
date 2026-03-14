resource "cloudflare_record" "app" {
  for_each = local.environments

  zone_id = var.cloudflare_zone_id
  name    = each.value.app_subdomain
  content = aws_eip.app[each.key].public_ip
  type    = "A"
  proxied = false
  comment = "Managed by Terraform"

  allow_overwrite = true
}

resource "cloudflare_record" "supabase" {
  for_each = local.environments

  zone_id = var.cloudflare_zone_id
  name    = each.value.supabase_subdomain
  content = aws_eip.app[each.key].public_ip
  type    = "A"
  proxied = false
  comment = "Managed by Terraform"

  allow_overwrite = true
}

# --- moved blocks: migrate existing singleton DNS records to for_each["prod"] ---

moved {
  from = cloudflare_record.app
  to   = cloudflare_record.app["prod"]
}

moved {
  from = cloudflare_record.supabase
  to   = cloudflare_record.supabase["prod"]
}
