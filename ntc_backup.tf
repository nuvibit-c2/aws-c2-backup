module "backup" {
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
      name   = "backup-eu-central-1"
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
      # min/max_retention_days only bound what a recovery point's OWN retention is allowed to be, they
      # don't set it - that comes from central_backup_vault_retention_days below, which must fall within
      # [min_retention_days, max_retention_days] once the lock is enabled.
      # During changeable_for_days, the lock config here can still be freely tightened, loosened, or
      # removed. WARNING: once changeable_for_days expires, the lock becomes PERMANENT - from then on it
      # can only be tightened (raise min / lower max), never loosened or disabled. Keep disabled until
      # backup/restore workflows are validated.
      # -----------------------------------------------------------------------------------------------------------
      central_vault_lock_config = {
        enabled = false # only activate if you want the central vault to have a lock config
      }

      # -----------------------------------------------------------------------------------------------------------
      # Retention
      # -----------------------------------------------------------------------------------------------------------
      local_backup_vault_retention_days   = 7
      central_backup_vault_retention_days = 30

      # -----------------------------------------------------------------------------------------------------------
      # Member Account Role
      # -----------------------------------------------------------------------------------------------------------
      # Must match backup_operator_iam_role_name / malware_scan_scanner_iam_role_name from the "backup"
      # baseline template applied in step 1
      # -----------------------------------------------------------------------------------------------------------
      member_account_backup_role_name          = "ntc-local-backup-operator-role"
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
      backup_target_ou_path_ids = [
        local.ntc_parameters["mgmt-organizations"]["ou_path_ids"]["/root/workloads/prod"]
      ]
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