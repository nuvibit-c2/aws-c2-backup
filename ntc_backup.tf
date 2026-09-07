# =====================================================================================================================
# NTC BACKUP - CENTRALIZED AWS BACKUP
# =====================================================================================================================
# Central backup account: aggregates recovery points from member accounts into per-entry vaults, and owns
# the AWS Organizations BACKUP_POLICY that drives which resources those accounts back up.
#
# WHAT IS NTC BACKUP?
# --------------------
# A centralized backup account that orchestrates AWS Backup across the organization via AWS Organizations
# BACKUP_POLICY documents, instead of configuring AWS Backup separately in every member account:
#   • Each backup_definitions[] entry defines one central vault + KMS key, its own tag-driven selection
#     rules, and the OUs/accounts it applies to
#   • Member accounts back up locally first (fast operational recovery), then optionally copy into this
#     account's central vault (durability, plus isolation from the source account)
#   • central_vault_lock_config gives a central vault WORM-style immutability once its grace period
#     expires - the retention floor a ransomware or compliance-driven backup strategy needs
#
# WHY A SEPARATE BACKUP ACCOUNT?
# -------------------------------
#   • Isolates recovery points from the accounts that produced them - a compromised or accidentally
#     deleted workload account doesn't take its own backups down with it
#   • Different account = different IAM trust boundary: the central vault policy grants workload
#     accounts exactly one permission - backup:CopyIntoBackupVault. Even a fully compromised workload
#     account (including its own admins) has no path to read, restore, or delete a recovery point once
#     it has landed here
#   • Decouples a recovery point's lifecycle from its source account's lifecycle - retention (and Vault
#     Lock immutability) keeps running on this account's own schedule even if the workload account is
#     later closed, suspended, or offboarded
#   • Matches compliance frameworks (ISO 27001, FINMA) that expect backup/recovery to be demonstrably
#     independent of the systems it protects
#
# PREREQUISITES:
# ---------------
#   • AWS Organizations must delegate to this account three separate pieces, all required:
#       - delegated_administrators: registers this account as delegated admin for the backup.amazonaws.com
#         service itself - without it, this account cannot act as AWS Backup's admin at all
#       - delegation_policies (policy_types = ["BACKUP_POLICY"]): grants this account rights over
#         Organizations' OWN policy-management APIs, scoped to BACKUP_POLICY - without it, attaching a
#         backup_definitions[] entry's policy to an OU/account fails
#       - backup_global_settings.enable_delegated_administrator = true (plus enable_cross_account_backup
#         = true) - the org-wide AWS Backup settings that actually let the delegated admin manage
#         org-wide policies and let plans copy recovery points across accounts
#   • Every target member/workload account must already have the account factory's "backup" baseline
#     template applied. That template creates the two things this module depends on in each account:
#       - the member_account_backup_role_name IAM role (default "ntc-local-backup-operator-role") -
#         AWS Backup assumes this to copy a recovery point into this account's central vault
#       - the LOCAL vault itself ("ntc-local-backup-vault-<region>") - this module's backup plans write
#         the first, local recovery point there before any central copy_action can run. The prefix is
#         hardcoded on both sides (baseline template + this module) - changing it in one requires
#         changing it in the other
#     Without either, backup jobs fail before a copy into this account's central vault is even possible.
#
# HOW SELECTION WORKS:
# ---------------------
#   • backup_definitions[].resource_types (below) - which AWS services are eligible for backup, per entry
#   • ntc:backup / ntc:backup-scope tags - per-resource opt-in/opt-out on top of that (or bypass entirely
#     by setting backup_definitions[].tag_based_selection_enabled = false)
#
# HOW MULTI-REGION / CROSS-VAULT COPY WORKS:
# --------------------------------------------
#   • One backup_definitions[] entry creates its own central vault + KMS key, named after that entry's
#     `name` (not its `region`) - multiple entries CAN share a region if you ever need more than one
#     central vault there (e.g. different retention/lock per workload tier)
#   • backup_definitions[].copy_to_backup_definition_by_name is the opt-in exception that ALSO copies an entry's
#     backups into another entry's vault (by name, not region) - destination must also have its own
#     backup_definitions[] entry
#
# =====================================================================================================================

moved {
  from = module.backup
  to   = module.ntc_backup
}

# =====================================================================================================================
# NTC BACKUP MODULE
# =====================================================================================================================
module "ntc_backup" {
  source = "github.com/nuvibit-terraform-collection/terraform-aws-ntc-backup?ref=feature/initial-release"

  # -----------------------------------------------------------------------------------------------------------------
  # SERVICE-LINKED ROLES - Prerequisites for Cross-Service Backup/Copy Operations
  # -----------------------------------------------------------------------------------------------------------------
  # AWSServiceRoleForRDS: required before AWS Backup can copy an RDS/Aurora/Neptune/DocumentDB recovery
  # point into a vault here; copy jobs fail without it.
  #   - true (current value): the module creates it.
  #   - false: use when it already exists in this account (creating it again errors with
  #     EntityAlreadyExists) or import the existing one instead:
  #     `tofu import aws_iam_service_linked_role.ntc_rds_service_linked_role
  #     arn:aws:iam::<ACCOUNT_ID>:role/aws-service-role/rds.amazonaws.com/AWSServiceRoleForRDS`.
  # -----------------------------------------------------------------------------------------------------------------
  create_rds_service_linked_role = true

  # AWSServiceRoleForBackup: the role AWS Backup itself uses as caller identity for native-service
  # copy/read and KMS grants in this account. Same true/false/import tradeoff as above, but for
  # `tofu import aws_iam_service_linked_role.ntc_backup_service_linked_role
  # arn:aws:iam::<ACCOUNT_ID>:role/aws-service-role/backup.amazonaws.com/AWSServiceRoleForBackup`.
  create_backup_service_linked_role = false

  # -----------------------------------------------------------------------------------------------------------------
  # NOTIFICATIONS - Alert on Backup/Copy/Restore Job Failures
  # -----------------------------------------------------------------------------------------------------------------
  backup_notification_settings = {
    org_identifier = "c2" # Organization identifier for notification subjects
    subscriptions = [
      {
        protocol  = "email"
        endpoints = ["operations+aws-c2@nuvibit.com"] # Replace with team distribution list
      }
    ]
  }

  # =====================================================================================================================
  # BACKUP DEFINITIONS - Per-Vault Backup Policy Configuration
  # =====================================================================================================================
  # One entry per central vault. `name` drives the actual AWS Backup vault name this module generates.
  # Vault names can't be changed in place, so changing an existing entry's `name` destroys and recreates
  # the live vault.
  # =====================================================================================================================
  backup_definitions = [
    # =================================================================================================================
    # BACKUP DEFINITION: BACKUP-EU-CENTRAL-1
    # =================================================================================================================
    {
      name   = "ntc-central-backup-vault-eu-central-1"
      region = "eu-central-1"

      # -----------------------------------------------------------------------------------------------------------
      # Resource Types & Schedule
      # -----------------------------------------------------------------------------------------------------------
      # Centrally defined list of AWS services eligible for backup - keep in sync with the backup
      # baseline-template rolled out to member accounts.
      resource_types = ["EC2", "EBS", "RDS", "Aurora", "Neptune", "DocumentDB", "DynamoDB", "EFS", "S3"]

      # AWS Backup's schedule only supports hourly-or-coarser granularity
      cron_schedule = "cron(0 3 * * ? *)" # once daily at 03:00 UTC

      # -----------------------------------------------------------------------------------------------------------
      # Vault Lock - Compliance/Immutability (Optional)
      # -----------------------------------------------------------------------------------------------------------
      # Backup Vault Lock for this entry's CENTRAL vault only - the local vault is never locked by this
      # module. The lock protects individual recovery points from deletion until their own retention
      # expires, it does not pin the vault itself - the vault (locked or not) can only be deleted once it
      # holds no recovery points anymore.
      #   - enabled: turns the lock on for this entry's central vault.
      #   - min_retention_days: shortest retention any backup/copy job's lifecycle may specify once the
      #     lock is active - jobs requesting less fail.
      #   - max_retention_days: longest retention any backup/copy job's lifecycle may specify once the
      #     lock is active - jobs requesting more fail. central_backup_vault_retention_days below must fall
      #     within [min_retention_days, max_retention_days].
      #   - changeable_for_days: grace period during which this lock config can still be freely tightened,
      #     loosened, or removed. WARNING: once it expires, the lock becomes PERMANENT - from then on it
      #     can only be tightened (raise min / lower max), never loosened or disabled, even by the account
      #     root user. Keep disabled until backup/restore workflows are validated.
      # -----------------------------------------------------------------------------------------------------------
      central_vault_lock_config = {
        enabled             = false
        min_retention_days  = 10
        max_retention_days  = 90
        changeable_for_days = 30
      }

      # -----------------------------------------------------------------------------------------------------------
      # Retention
      # -----------------------------------------------------------------------------------------------------------
      local_backup_vault_retention_days   = 7
      central_backup_vault_retention_days = 30

      # -----------------------------------------------------------------------------------------------------------
      # Member Account Role
      # -----------------------------------------------------------------------------------------------------------
      # The EXACT IAM role name that MUST exist in ALL member accounts targeted below, in order to copy
      # backups into this vault. Not a role in this account - the role every member account creates via
      # the backup baseline-template.
      # -----------------------------------------------------------------------------------------------------------
      member_account_backup_role_name = "ntc-local-backup-operator-role"

      # Same idea as member_account_backup_role_name above, but the role AWS Backup passes to GuardDuty
      # when initiating a scan - must match the local scanner role every member account creates via the
      # backup baseline-template.
      member_account_malware_scanner_role_name = "ntc-local-backup-malware-scanner-role"

      # -----------------------------------------------------------------------------------------------------------
      # Malware Scanning (Optional)
      # -----------------------------------------------------------------------------------------------------------
      # Amazon GuardDuty Malware Protection for this entry's LOCAL (member account) recovery points only -
      # a copy into this entry's central vault is never automatically scanned, see the Malware Protection
      # page. The scanner IAM roles are always created regardless of this setting, so an on-demand scan
      # still works even while this is disabled.
      #   - enabled: turns automatic scanning on for this entry.
      #   - resource_types: only "EC2", "EBS", and "S3" support scanning today - matches this entry's own
      #     resource_types above (everything else here has nothing to scan).
      #   - scan_mode: "INCREMENTAL_SCAN" (only changed files since the last scan) vs "FULL_SCAN" (every
      #     file, every time) - incremental is cheaper and enough for a daily cadence.
      # -----------------------------------------------------------------------------------------------------------
      malware_scanning = {
        enabled        = false
        resource_types = ["EC2", "EBS", "S3"]
        scan_mode      = "INCREMENTAL_SCAN"
      }

      # -----------------------------------------------------------------------------------------------------------
      # Account Targeting
      # -----------------------------------------------------------------------------------------------------------
      # OU path IDs (without trailing "/*") in scope for this entry - used both for the vault/KMS trust
      # policy condition (as the full path ID) and to attach the central BACKUP_POLICY document (the
      # module derives the bare OU ID itself, so only the path ID format needs passing in here).
      backup_target_ou_path_ids = [
        local.ntc_parameters["mgmt-organizations"]["ou_path_ids"]["/root/workloads/prod"]
      ]
      # Explicitly listed member account IDs in scope for this entry - used both for the vault/KMS trust
      # policy condition and to attach the central BACKUP_POLICY document. Can be empty if all member
      # accounts are covered by the OU path(s) above.
      backup_target_account_ids = []

      # -----------------------------------------------------------------------------------------------------------
      # Tag-Based Resource Selection
      # -----------------------------------------------------------------------------------------------------------
      # Namespaced tag keys driving resource selection, to avoid colliding with a customer's own
      # pre-existing tagging scheme.
      #   - tag_key_to_enable_backup: tag value "true"/"false" - whether the resource is backed up at all
      #     (see backup_enabled_if_untagged for resources missing this tag).
      #   - tag_key_to_define_backup_scope: tag value "local-only"/"local-and-central" - whether a backed
      #     up resource also gets copied to this entry's central vault (see default_backup_scope for
      #     resources missing this tag).
      # -----------------------------------------------------------------------------------------------------------
      tag_key_to_enable_backup       = "ntc:backup"
      tag_key_to_define_backup_scope = "ntc:backup-scope"

      # Whether a resource with NO tag_key_to_enable_backup tag at all is backed up by default.
      #   - false (current value): default-deny - a resource must be tagged ntc:backup=true to be backed
      #     up at all.
      #   - true: default-allow - a resource must be tagged ntc:backup=false to opt out.
      backup_enabled_if_untagged = false

      # Scope applied to a backed-up resource with no tag_key_to_define_backup_scope tag. Only matters
      # while tag_based_selection_enabled is true; once that's false, this becomes the static, entry-wide
      # scope for every selected resource regardless of tags.
      default_backup_scope = "local-and-central"

      # Whether the tag_key_to_enable_backup / tag_key_to_define_backup_scope tags above are consulted at
      # all.
      #   - true (current value): per-resource tags decide inclusion/scope, falling back to
      #     backup_enabled_if_untagged / default_backup_scope for resources missing a tag.
      #   - false: escape hatch - tags are ignored entirely, default_backup_scope becomes the static,
      #     entry-wide scope for every resource matching resource_types, no exceptions.
      tag_based_selection_enabled = true

      # -----------------------------------------------------------------------------------------------------------
      # Cross-Vault Copy (Optional)
      # -----------------------------------------------------------------------------------------------------------
      # Other backup_definitions[] entries (by `name`) whose central vault should ALSO receive a copy of
      # this entry's "local-and-central"-scoped backups, on top of this entry's own central vault (which
      # always gets a copy regardless of this list). "local-only" resources are never copied anywhere.
      # This is how backup data crosses regions/vaults. The target name must reference another
      # backup_definitions[] entry that also exists - left empty here since this example only defines one.
      # -----------------------------------------------------------------------------------------------------------
      copy_to_backup_definition_by_name = []
    }
  ]
}