# =====================================================================================================================
# NTC PARAMETERS - CROSS-ACCOUNT CONFIGURATION SHARING
# =====================================================================================================================
# The NTC Parameters system provides a centralized, secure way to share configuration data across AWS accounts
# in your organization. Think of it as a distributed key-value store accessible to all accounts.
#
# WHY USE NTC PARAMETERS?
# -----------------------
# Problem: Terraform modules in different accounts need to reference outputs from other accounts
# 
# Traditional Solutions (and their problems):
#   ❌ Hardcode values: Not dynamic, breaks when resources change
#   ❌ AWS SSM Parameter Store: Complex cross-account access (requires assume role to write parameters)
#   ❌ Terraform remote state: Tight coupling, security concerns with state file access
#   ❌ Manual coordination: Error-prone, doesn't scale
#
# NTC Parameters Solution:
#   ✅ Centralized S3 bucket stores all parameters
#   ✅ Each account writes to its own "parameter node" (namespace)
#   ✅ All organization accounts can read all parameters
#   ✅ No circular dependencies or tight coupling
#   ✅ Automatic drift detection and updates
#
# HOW IT WORKS:
# -------------
# 1. Management account creates S3 bucket with organization-wide read access
# 2. Each account writes its outputs to a dedicated parameter node:
#    - mgmt-organizations → org_id, ou_ids, etc.
#    - connectivity → vpc_ids, subnet_ids, transit_gateway_id
#    - log-archive → s3_bucket_name, kms_key_arn
# 3. Any account reads parameters using the reader module
# 4. Parameters are referenced via: local.ntc_parameters["node-name"]["key"]
# =====================================================================================================================

# =====================================================================================================================
# LOCAL VARIABLES - CONNECTIVITY PARAMETERS
# =====================================================================================================================
locals {
  # -------------------------------------------------------------------------------------------------------------------
  # S3 Bucket Name
  # -------------------------------------------------------------------------------------------------------------------
  # Centralized parameter storage bucket (created by mgmt-organizations)
  # ⚠️  Must match the bucket name across all accounts in the organization
  # -------------------------------------------------------------------------------------------------------------------
  ntc_parameters_bucket_name = "aws-c2-ntc-parameters"

  # -----------------------------------------------------
  # PARAMETERS TO READ - From All Parameter Nodes
  # -----------------------------------------------------
  # Access parameters from any account in the organization
  # Examples:
  #   - local.ntc_parameters["mgmt-organizations"]["org_id"]
  #   - local.ntc_parameters["mgmt-account-factory"]["core_accounts"]
  #   - local.ntc_parameters["connectivity"]["transit_gateway_id"]
  # -----------------------------------------------------
  ntc_parameters = module.ntc_parameters_reader.all_parameters
}

# =====================================================================================================================
# NTC PARAMETERS READER - READ PARAMETERS FROM ALL NODES
# =====================================================================================================================
# Reads and merges parameters from ALL parameter nodes in the S3 bucket
#
# WHAT THIS MODULE DOES:
# ----------------------
# 1. Lists all objects in the S3 bucket (all parameter nodes)
# 2. Downloads and parses each parameter node's JSON file
# 3. Merges all parameters into a single map structure
# 4. Makes them available via: 'module.ntc_parameters_reader.all_parameters'
#
# OUTPUT STRUCTURE:
# -----------------
# {
#   "mgmt-organizations" = {
#     "org_id" = "o-xxxxx",
#     "ou_ids" = {...}
#   },
#   "connectivity" = {
#     "vpc_id" = "vpc-xxxxx",
#     "subnet_ids" = [...]
#   },
#   "security-tooling" = {
#     "guardduty_detector_id" = "xxxxx"
#   }
# }
#
# USAGE EXAMPLES:
# ---------------
# Access organization ID:
#   local.ntc_parameters["mgmt-organizations"]["org_id"]
#
# Access Transit Gateway ID from connectivity account:
#   local.ntc_parameters["connectivity"]["transit_gateway_id"]
#
# Access core account IDs:
#   local.ntc_parameters["mgmt-account-factory"]["core_accounts"]["INSERT_ACCOUNT_NAME"]
# =====================================================================================================================
module "ntc_parameters_reader" {
  source = "github.com/nuvibit-terraform-collection/terraform-aws-ntc-parameters//modules/reader?ref=2.0.0"

  region      = "eu-central-1"
  bucket_name = local.ntc_parameters_bucket_name
}
