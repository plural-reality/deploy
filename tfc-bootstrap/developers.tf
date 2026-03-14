resource "aws_iam_user" "developer" {
  for_each = toset(local.developers)
  name     = each.value
  path     = "/developers/sonar/"

  tags = {
    Project = "sonar"
    Role    = "developer"
  }
}

output "developer_arns" {
  value       = [for user in aws_iam_user.developer : user.arn]
  description = "Developer IAM ARNs (for KMS policy)"
}
