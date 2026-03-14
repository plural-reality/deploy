# EBS daily backup via AWS Backup
resource "aws_backup_vault" "main" {
  name = "${local.name_prefix}-backup"
  tags = { Name = "${local.name_prefix}-backup" }
}

resource "aws_backup_plan" "daily" {
  name = "${local.name_prefix}-daily"

  rule {
    rule_name         = "daily-snapshot"
    target_vault_name = aws_backup_vault.main.name
    schedule          = "cron(0 3 * * ? *)" # 03:00 UTC daily

    lifecycle {
      delete_after = 14 # 14-day retention
    }
  }

  tags = { Name = "${local.name_prefix}-backup-plan" }
}

resource "aws_backup_selection" "ec2" {
  name         = "${local.name_prefix}-ec2"
  iam_role_arn = aws_iam_role.backup.arn
  plan_id      = aws_backup_plan.daily.id

  selection_tag {
    type  = "STRINGEQUALS"
    key   = "Project"
    value = "sonar"
  }
}

resource "aws_iam_role" "backup" {
  name = "${local.name_prefix}-backup"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "backup.amazonaws.com" }
    }]
  })

  tags = { Project = "sonar" }
}

resource "aws_iam_role_policy_attachment" "backup" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}
