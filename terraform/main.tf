# =============================================================================
# CSI Web — Workato Embedded platform managed as code (demo)
#
# What this file demonstrates
#   1. Environment management  : dev / test / staging / prod declared as code,
#                                provisioned consistently from one definition
#   2. Environment consistency : same folder structure, properties, and
#                                connection shells stamped into every env
#   3. Version control + audit : this file lives in Bitbucket; every change is
#                                a reviewed PR; terraform plan output is the
#                                change record; remote state keeps history
#   4. Release management      : Bitbucket repo, branch model, and per-env
#                                deployment variables (used by the CI pipeline
#                                that deploys recipes) are themselves Terraform-
#                                managed
#
# What this file does NOT do (by design)
#   - Recipe/asset deployment: that is Recipe Lifecycle Management, handled by
#     the CI pipeline (export package -> import into env). Terraform manages
#     the PLATFORM; the pipeline manages the CONTENT.
#   - Workato platform patching/upgrades: Workato is SaaS; Workato operates
#     the runtime. We manage tenant configuration.
#
# There is no official Workato Terraform provider, so Workato tenant objects
# are managed through the OEM REST API via the generic REST provider
# (Mastercard/restapi). Every resource below maps 1:1 to a documented
# Workato Embedded API endpoint.
# =============================================================================

terraform {
  required_version = ">= 1.6"

  required_providers {
    restapi = {
      source  = "Mastercard/restapi"
      version = "~> 1.19"
    }
    bitbucket = {
      source  = "DrFaust92/bitbucket"
      version = "~> 2.40"
    }
  }

  # ---------------------------------------------------------------------------
  # AUDIT: remote state with locking + versioning. Every apply is recorded;
  # S3 object versions give point-in-time state history for rollback review.
  # ---------------------------------------------------------------------------
  # backend "s3" {
  #   bucket         = "csiweb-terraform-state"
  #   key            = "workato/platform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "terraform-locks"
  # }
}

# -----------------------------------------------------------------------------
# Inputs
# -----------------------------------------------------------------------------

variable "workato_api_token" {
  description = "Workato OEM API token (inject via TF_VAR_workato_api_token from the secret store — never committed)"
  type        = string
  sensitive   = true
}

variable "bitbucket_workspace" {
  description = "Bitbucket workspace slug"
  type        = string
  default     = "csiweb"
}

# One block per environment = the single source of truth for the landscape.
# Adding "staging" here and running `terraform apply` provisions a complete,
# consistent new environment.
variable "environments" {
  description = "Workato managed-customer environments"
  type = map(object({
    display_name       = string
    notification_email = string
    audience_id        = string # example env-specific property
  }))
  default = {
    dev = {
      display_name       = "CSI Web - Dev"
      notification_email = "ops@csiweb.example.com"
      audience_id        = "aud-dev-001"
    }
    test = {
      display_name       = "CSI Web - Test"
      notification_email = "ops@csiweb.example.com"
      audience_id        = "aud-test-001"
    }
    staging = {
      display_name       = "CSI Web - Staging"
      notification_email = "ops@csiweb.example.com"
      audience_id        = "aud-stg-001"
    }
    prod = {
      display_name       = "CSI Web - Production"
      notification_email = "ops@csiweb.example.com"
      audience_id        = "aud-prod-001"
    }
  }
}

# -----------------------------------------------------------------------------
# Providers
# -----------------------------------------------------------------------------

provider "restapi" {
  uri                  = "https://www.workato.com/api"
  write_returns_object = true
  id_attribute         = "id"

  headers = {
    Authorization = "Bearer ${var.workato_api_token}"
    Content-Type  = "application/json"
  }
}

provider "bitbucket" {
  # Auth via BITBUCKET_USERNAME / BITBUCKET_PASSWORD (app password) env vars
}

# =============================================================================
# 1. WORKATO ENVIRONMENTS (managed customers)
#    POST /api/managed_users
#
#    Existing environments are adopted with `terraform import`, e.g.:
#      terraform import 'restapi_object.workato_environment["dev"]'  /managed_users/8704836
#      terraform import 'restapi_object.workato_environment["test"]' /managed_users/8704837
# =============================================================================

resource "restapi_object" "workato_environment" {
  for_each = var.environments

  path = "/managed_users"
  data = jsonencode({
    name               = each.value.display_name
    external_id        = "csiweb-${each.key}"
    notification_email = each.value.notification_email
  })
}

# =============================================================================
# 2. CONSISTENT PROJECT STRUCTURE IN EVERY ENVIRONMENT
#    POST /api/managed_users/:id/folders
#    The CI/CD pipeline imports recipe packages into this folder.
# =============================================================================

resource "restapi_object" "project_folder" {
  for_each = var.environments

  path = "/managed_users/${restapi_object.workato_environment[each.key].id}/folders"
  data = jsonencode({
    name = "CSI Web"
  })
}

# =============================================================================
# 3. ENVIRONMENT-SPECIFIC CONFIGURATION (project properties)
#    POST /api/managed_users/:id/properties
#    Same property names everywhere, env-specific values -> recipes promote
#    between environments without edits.
# =============================================================================

resource "restapi_object" "environment_properties" {
  for_each = var.environments

  path = "/managed_users/${restapi_object.workato_environment[each.key].id}/properties"
  data = jsonencode({
    properties = {
      audience_id = each.value.audience_id
      environment = each.key
    }
  })
}

# =============================================================================
# 4. CONNECTION SHELLS
#    POST /api/managed_users/:id/connections
#    Connections are pre-created per environment (credentials are entered once
#    by an admin in the Workato UI — secrets never live in code or state).
# =============================================================================

resource "restapi_object" "mailchimp_connection" {
  for_each = var.environments

  path = "/managed_users/${restapi_object.workato_environment[each.key].id}/connections"
  data = jsonencode({
    name      = "MailChimp - ${each.key}"
    provider  = "mailchimp"
    folder_id = restapi_object.project_folder[each.key].id
  })
}

# =============================================================================
# 5. BITBUCKET: VERSION CONTROL, CHANGE GOVERNANCE, RELEASE MANAGEMENT
#    The repo that holds recipes + this Terraform config, with an enforced
#    branch model: all changes flow PR -> develop -> test -> main(prod),
#    which is exactly the audit trail auditors ask for.
# =============================================================================

resource "bitbucket_repository" "csi_web" {
  owner     = var.bitbucket_workspace
  name      = "csi-web"
  scm       = "git"
  is_private = true
}

# main represents production: no direct pushes, PRs only, min. 1 approval
resource "bitbucket_branch_restriction" "no_direct_push_main" {
  owner      = var.bitbucket_workspace
  repository = bitbucket_repository.csi_web.name
  kind       = "push"
  pattern    = "main"
}

resource "bitbucket_branch_restriction" "require_approvals_main" {
  owner      = var.bitbucket_workspace
  repository = bitbucket_repository.csi_web.name
  kind       = "require_approvals_to_merge"
  pattern    = "main"
  value      = 1
}

# Per-environment deployment stages; CI deploy steps bind to these, giving
# deployment history + one-click redeploy of any previous pipeline (rollback).
resource "bitbucket_deployment" "stage" {
  for_each = var.environments

  repository = "${var.bitbucket_workspace}/${bitbucket_repository.csi_web.name}"
  name       = each.key
  stage      = each.key == "prod" ? "Production" : (each.key == "staging" ? "Staging" : "Test")
}

# The env id each pipeline stage deploys to — wired from Terraform so the
# pipeline and the platform definition can never drift apart.
resource "bitbucket_deployment_variable" "workato_env_id" {
  for_each = var.environments

  deployment = bitbucket_deployment.stage[each.key].id
  key        = "TARGET_ENV_ID"
  value      = restapi_object.workato_environment[each.key].id
  secured    = false
}

# =============================================================================
# Outputs — consumed by CI and by operators
# =============================================================================

output "workato_environment_ids" {
  description = "managed_user_id per environment (used by the recipe deploy pipeline)"
  value       = { for k, v in restapi_object.workato_environment : k => v.id }
}

output "project_folder_ids" {
  description = "Deployment target folder per environment"
  value       = { for k, v in restapi_object.project_folder : k => v.id }
}
