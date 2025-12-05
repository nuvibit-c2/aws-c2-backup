# ---------------------------------------------------------------------------------------------------------------------
# ¦ PROVIDER
# ---------------------------------------------------------------------------------------------------------------------
provider "aws" {
  region = "eu-central-1"
  default_tags {
    tags = local.default_tags
  }
}

provider "aws" {
  alias  = "euc1"
  region = "eu-central-1"
  default_tags {
    tags = local.default_tags
  }
}

provider "aws" {
  alias  = "euc2"
  region = "eu-central-2"
  default_tags {
    tags = local.default_tags
  }
}

# provider for us-east-1 region is sometimes required for specific features or services
provider "aws" {
  alias  = "use1"
  region = "us-east-1"
  default_tags {
    tags = local.default_tags
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# ¦ REQUIREMENTS
# ---------------------------------------------------------------------------------------------------------------------
terraform {
  required_version = ">= 1.5.7"

  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = "~> 5.0"
      configuration_aliases = []
    }
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# ¦ DATA
# ---------------------------------------------------------------------------------------------------------------------
data "aws_region" "default" {}
data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------------------------------------------------
# ¦ LOCALS
# ---------------------------------------------------------------------------------------------------------------------
locals {
  default_tags = {
    ManagedBy = "OpenTofu"
    # ProvisionedBy = "aws-xx-yyy"
  }
}
