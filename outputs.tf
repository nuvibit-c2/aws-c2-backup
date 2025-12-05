output "default_region" {
  description = "The default region name"
  value       = data.aws_region.default.region
}

output "account_id" {
  description = "The current account id"
  value       = data.aws_caller_identity.current.account_id
}

# output "ntc_parameters" {
#   description = "Map of all ntc parameters"
#   value       = local.ntc_parameters
# }