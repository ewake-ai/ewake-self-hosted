# The GitHub App this deployment acts as.
#
# Optional. GitHub can be connected with a fine-grained personal access token pasted into the
# dashboard, which needs nothing here. Setting the three variables below adds the other route:
# the dashboard gains an "Install" action that installs a GitHub App on your organisation, and
# the deployment then reads GitHub through short-lived installation tokens instead of a token
# belonging to a person. See README.md for how to create the App.
#
# All three or none. Two of the three would leave the dashboard offering the token form while
# your tfvars say otherwise, so terraform refuses the plan instead.
#
# Deliberately not under ${ssm_path}/integrations/: the application creates and deletes secrets
# under that prefix at runtime, and would fight terraform over one placed there.
#
# `sensitive` keeps the private key out of plan output and the console, not out of the state
# file. A backend holding this wants encryption and restricted reads.

variable "github_app_client_id" {
  description = "Client ID of the GitHub App this deployment acts as — \"Client ID\" on the App's settings page. Null, together with the other two, to run without a GitHub App."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.github_app_client_id == null || trimspace(var.github_app_client_id) != ""
    error_message = "github_app_client_id is blank. Pass null to run without a GitHub App — a blank string is almost always an unexpanded variable."
  }
}

variable "github_app_slug" {
  description = "Slug of that App: the URL-safe name GitHub derives from its title, and the <slug> in github.com/apps/<slug>. It is the only way to address an App in an install URL. Read it off the App's settings URL."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.github_app_slug == null || can(regex("^[a-z0-9-]+$", var.github_app_slug))
    error_message = "github_app_slug must be a GitHub App slug: lowercase letters, digits and hyphens. Read it off the App's settings URL, or pass null to run without a GitHub App."
  }
}

variable "github_app_private_key" {
  description = "PEM contents of a private key generated on that App's settings page — the file itself, newlines and all, not a path to it. Signs the App JWT that mints installation tokens. Reaches terraform state; see the comment above this variable."
  type        = string
  default     = null
  sensitive   = true
  nullable    = true

  validation {
    condition     = var.github_app_private_key == null || trimspace(var.github_app_private_key) != ""
    error_message = "github_app_private_key is blank. Pass null to run without a GitHub App — a blank string is almost always an unexpanded variable."
  }
}

locals {
  # A list of argument *names*, and nonsensitive() because that is all it is: which arguments were
  # supplied is not what any of them contains. Without it the private key's marking spreads into
  # the precondition's message below, which terraform then refuses to render — leaving a check
  # that fires and explains nothing.
  github_app_given = nonsensitive(compact([
    var.github_app_client_id != null ? "github_app_client_id" : "",
    var.github_app_slug != null ? "github_app_slug" : "",
    var.github_app_private_key != null ? "github_app_private_key" : "",
  ]))

  github_app_enabled = length(local.github_app_given) == 3
}

resource "terraform_data" "github_app_shape" {
  lifecycle {
    precondition {
      condition = local.github_app_enabled || length(local.github_app_given) == 0
      error_message = join(" ", [
        "github_app_client_id, github_app_slug and github_app_private_key go together:",
        "${length(local.github_app_given)} of the 3 were set (${join(", ", local.github_app_given)}).",
        "Set all three to act as a GitHub App, or none to connect GitHub with a token instead."
      ])
    }
  }
}

resource "aws_secretsmanager_secret" "github_app" {
  count       = local.github_app_enabled ? 1 : 0
  name        = "${local.ssm_path}/github-app"
  description = "Credentials of the GitHub App this deployment acts as (CLIENT_ID, APP_SLUG, APP_PRIVATE_KEY). Written from terraform variables; ecs_task.tf injects the three into the dashboard task."
  tags        = local.tags
}

# No ignore_changes: terraform is the only writer here, so suppressing updates would mean a
# rotated key never reaching the task.
resource "aws_secretsmanager_secret_version" "github_app" {
  count     = local.github_app_enabled ? 1 : 0
  secret_id = aws_secretsmanager_secret.github_app[0].id
  secret_string = jsonencode({
    CLIENT_ID       = var.github_app_client_id
    APP_SLUG        = var.github_app_slug
    APP_PRIVATE_KEY = var.github_app_private_key
  })
}
