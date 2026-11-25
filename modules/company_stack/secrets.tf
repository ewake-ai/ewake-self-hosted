# Secrets in Secrets Manager. Terraform creates each secret empty and holds its ARN.
# secret_values.tf says what goes in each one, and the bootstrap Lambda writes it,
# so no secret value is ever in terraform state.
#
# Naming convention: ${var.project_name}/${var.tenant_name}/${var.company.name}/<name>
# IAM (iam.tf) restricts the task role to this prefix.
#
# Per-integration tokens live at the convention-defined path:
#   ${var.project_name}/${var.tenant_name}/${var.company.name}/integrations/${type}
# (one secret per integration type, JSON-encoded payload with each token field).
# Created/updated/deleted by the reactive server at runtime via the OAuth /
# manual-connect flows in the dashboard.
# The SecretsScopedToCompany statement in iam.tf already covers this prefix
# (Get/Describe + Create/Update/Delete/Restore + TagResource).

data "aws_secretsmanager_secret" "langsmith" {
  count = local.is_byoc ? 0 : 1
  name  = "langsmith"
}

# JWT_SECRET signs the sessions. DEX_CLIENT_SECRET is reactive's OIDC client secret against its
# own Dex sidecar. ORCHESTRATOR_SECRET authenticates the Lambda's calls to its own reactive
# server. ADMIN_PASSWORD is the password signed in with where there is no SSO connector: the
# bootstrap Lambda hashes it onto the system user, and the plaintext lives only here, for an
# operator to read out of Secrets Manager.
resource "aws_secretsmanager_secret" "app" {
  count       = local.is_byoc ? 1 : 0
  name        = "${local.ssm_path}/app"
  description = "Application secrets: ADMIN_PASSWORD, JWT_SECRET, DEX_CLIENT_SECRET, ORCHESTRATOR_SECRET."
  tags        = local.tags

  lifecycle {
    # description is applied state; ignore drift so a wording change is never a plan diff.
    # A changed description here would also re-render the reactive task definition (it
    # reads this secret's ARN), forcing a needless new revision.
    ignore_changes = [description]
  }
}
