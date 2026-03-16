terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
    sops = {
      source  = "carlpett/sops"
      version = "~> 1.0"
    }
  }
}

locals {
  name_prefix = "sonar"

  environments = {
    staging = {
      app_subdomain      = "staging.baisoku-survey"
      supabase_subdomain = "staging-supabase.baisoku-survey"
    }
    prod = {
      app_subdomain      = "app.baisoku-survey"
      supabase_subdomain = "supabase.baisoku-survey"
    }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project     = "sonar"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

provider "cloudflare" {}

provider "sops" {}
