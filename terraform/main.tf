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
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
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

provider "github" {
  owner = var.github_owner
  app_auth {
    id              = data.sops_file.ci.data["github_app_id"]
    installation_id = data.sops_file.ci.data["github_app_installation_id"]
    pem_file        = data.sops_file.ci.data["github_app_private_key"]
  }
}

provider "sops" {}

data "sops_file" "ci" {
  source_file = "${path.module}/../secrets/ci.yaml"
}
