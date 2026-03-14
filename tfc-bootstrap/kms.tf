resource "aws_kms_key" "sops" {
  description             = "KMS key for SOPS encryption (Sonar)"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRootAccountAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
          # NOTE: The double colon (::) is correct — IAM ARNs omit the region field
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowDeveloperAccess"
        Effect = "Allow"
        Principal = {
          AWS = [for user in aws_iam_user.developer : user.arn]
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:DescribeKey",
          "kms:GenerateDataKey*",
          "kms:ReEncrypt*",
        ]
        Resource = "*"
      },
    ]
  })

  tags = {
    Name    = "sonar-sops"
    Project = "sonar"
  }
}

data "aws_caller_identity" "current" {}

resource "aws_kms_alias" "sops" {
  name          = "alias/sonar-sops"
  target_key_id = aws_kms_key.sops.key_id
}

output "kms_key_arn" {
  description = "KMS key ARN for .sops.yaml"
  value       = aws_kms_key.sops.arn
}
