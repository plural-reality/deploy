data "aws_ami" "nixos" {
  most_recent = true
  owners      = ["427812963091"]

  filter {
    name   = "name"
    values = ["nixos/25.11*-aarch64-linux"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_key_pair" "deploy" {
  key_name   = "${local.name_prefix}-deploy"
  public_key = var.ssh_public_key

  tags = {
    Name = "${local.name_prefix}-deploy-key"
  }
}

resource "aws_instance" "app" {
  for_each = local.environments

  ami                    = data.aws_ami.nixos.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.app.id]
  key_name               = aws_key_pair.deploy.key_name
  iam_instance_profile   = aws_iam_instance_profile.ec2_sops.name

  root_block_device {
    volume_size = 40
    volume_type = "gp3"
  }

  user_data = file("${path.module}/bootstrap.sh")
  user_data_replace_on_change = false

  metadata_options {
    http_tokens                 = "required"
    instance_metadata_tags      = "enabled"
  }

  tags = {
    Name = "${local.name_prefix}-${each.key}-app"
  }

  lifecycle {
    ignore_changes = [ami, user_data]
  }
}

resource "aws_eip" "app" {
  for_each = local.environments

  instance = aws_instance.app[each.key].id

  tags = {
    Name = "${local.name_prefix}-${each.key}-eip"
  }
}

resource "aws_iam_role" "ec2_sops" {
  name = "${local.name_prefix}-ec2-sops"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = {
    Name = "${local.name_prefix}-ec2-sops-role"
  }
}

resource "aws_iam_role_policy" "kms_decrypt" {
  name = "${local.name_prefix}-kms-decrypt"
  role = aws_iam_role.ec2_sops.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:DescribeKey"]
        Resource = [var.kms_key_arn]
      },
    ]
  })
}

resource "aws_iam_instance_profile" "ec2_sops" {
  name = "${local.name_prefix}-ec2-sops"
  role = aws_iam_role.ec2_sops.name

  tags = {
    Name = "${local.name_prefix}-ec2-sops-profile"
  }
}

# --- moved blocks: migrate existing singleton resources to for_each["prod"] ---

moved {
  from = aws_instance.app
  to   = aws_instance.app["prod"]
}

moved {
  from = aws_eip.app
  to   = aws_eip.app["prod"]
}
