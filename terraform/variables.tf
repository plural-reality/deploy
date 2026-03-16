variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-1"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "prod"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t4g.medium"
}

variable "ssh_public_key" {
  description = "SSH public key for EC2 access"
  type        = string
  default     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHcjDeqStU70L2swBOL3E4IJgwnDt3EwR5e3A8iBuTC2 sonar-deploy-yui-20260304"
}

variable "cloudflare_zone_id" {
  description = "Cloudflare Zone ID for plural-reality.com"
  type        = string
  default     = "308afb757fb09a278f0468622c036886"
}

variable "cloudflare_account_id" {
  description = "Cloudflare Account ID"
  type        = string
  default     = "cb68dac917fabab6fcfde3ab12632404"
}

variable "domain_name" {
  description = "Base domain name"
  type        = string
  default     = "plural-reality.com"
}

variable "kms_key_arn" {
  description = "KMS key ARN for SOPS (created in tfc-bootstrap)"
  type        = string
  default     = "arn:aws:kms:ap-northeast-1:377786476154:key/74beb9ae-57b3-4789-b41c-588fca1d960e"
}
