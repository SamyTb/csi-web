# =============================================================================
# Provision a Workato managed customer (sub-tenant) and replicate all projects
# from the parent workspace into it.
#
# - The tenant is created declaratively (restapi provider -> OEM API).
# - Project replication is procedural (export package -> import), so it runs
#   as a provisioner script bound to the tenant's lifecycle: it executes once
#   when the tenant is created, and re-runs only if the tenant is replaced.
#
# Usage:
#   export TF_VAR_workato_api_token=<OEM API token>
#   terraform init
#   terraform apply
# =============================================================================

terraform {
  required_version = ">= 1.4"

  required_providers {
    restapi = {
      source  = "Mastercard/restapi"
      version = "~> 1.19"
    }
  }
}

variable "workato_api_token" {
  description = "Workato OEM API token (set via TF_VAR_workato_api_token)"
  type        = string
  sensitive   = true
}

variable "tenant_name" {
  description = "Display name of the managed customer to create"
  type        = string
  default     = "CSI Web - Replicated Tenant"
}

variable "external_id" {
  description = "External ID for the managed customer"
  type        = string
  default     = "csiweb-replica-001"
}

variable "notification_email" {
  description = "Admin/notification email for the managed customer"
  type        = string
  default     = "samy.toubal1@gmail.com"
}

variable "exclude_projects" {
  description = "Parent project names NOT to replicate"
  type        = list(string)
  default     = ["Home"]
}

provider "restapi" {
  uri                  = "https://www.workato.com/api"
  write_returns_object = true
  id_attribute         = "id"

  headers = {
    Authorization = "Bearer ${var.workato_api_token}"
    Content-Type  = "application/json"
  }
}

# -----------------------------------------------------------------------------
# 1. The managed customer (sub-tenant)  —  POST /api/managed_users
# -----------------------------------------------------------------------------
resource "restapi_object" "managed_customer" {
  path = "/managed_users"
  data = jsonencode({
    name               = var.tenant_name
    external_id        = var.external_id
    notification_email = var.notification_email
  })
}

# -----------------------------------------------------------------------------
# 2. Replicate every parent project into the new tenant
#    (export package from parent -> import into tenant, one per project)
# -----------------------------------------------------------------------------
resource "terraform_data" "replicate_projects" {
  triggers_replace = [restapi_object.managed_customer.id]

  provisioner "local-exec" {
    command = "python3 '${path.module}/replicate.py'"
    environment = {
      WORKATO_API_TOKEN = var.workato_api_token
      TARGET_ENV_ID     = restapi_object.managed_customer.id
      EXCLUDE_PROJECTS  = join(",", var.exclude_projects)
    }
  }
}

output "tenant_id" {
  description = "managed_user_id of the created sub-tenant"
  value       = restapi_object.managed_customer.id
}

output "tenant_name" {
  value = var.tenant_name
}
