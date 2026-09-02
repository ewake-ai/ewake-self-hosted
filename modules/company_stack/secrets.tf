# Secrets in Secrets Manager. The DB credential secret lives in
# rds_db.tf because it's tightly coupled to the postgresql provider; this file
# is the place for additional secrets if they appear later.
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

data "aws_secretsmanager_secret_version" "langsmith" {
  count     = local.is_byoc ? 0 : 1
  secret_id = "langsmith"
}

# Lambda has no `valueFrom` equivalent — reactive + knowledge-graph read GithubService, so their env vars are inlined at plan time.
data "aws_secretsmanager_secret_version" "github_app" {
  count     = !local.is_byoc && var.github_app_secret_arn != null ? 1 : 0
  secret_id = var.github_app_secret_arn
}

# The knowledge-graph Lambda reads feature flags agentless, and the agentless source wants the key itself rather than the ARN every other consumer takes.
data "aws_secretsmanager_secret_version" "datadog_api_key" {
  count     = !local.is_byoc && var.datadog_api_key_secret_arn != null ? 1 : 0
  secret_id = var.datadog_api_key_secret_arn
}

# Holds JWT_SECRET today. Generated once on first apply; rotations happen separately so we don't clobber a live secret.
resource "random_password" "jwt_secret" {
  count            = local.is_byoc ? 1 : 0
  length           = 64
  special          = true
  override_special = "!#$%^&*()-_=+[]{}<>?"
}

# Reactive's OIDC client secret against its own Dex sidecar. Never leaves the task, so it
# is generated here rather than handed over — nothing outside the deployment needs it.
resource "random_password" "dex_client_secret" {
  count            = local.is_byoc ? 1 : 0
  length           = 64
  special          = true
  override_special = "!#$%^&*()-_=+[]{}<>?"
}

# Authenticates the Lambda's calls to its own reactive server.
resource "random_password" "orchestrator_secret" {
  count            = local.is_byoc ? 1 : 0
  length           = 64
  special          = true
  override_special = "!#$%^&*()-_=+[]{}<>?"
}

# The password signed in with where there is no SSO connector. sso_connectors defaults to [],
# and this repo has no static-password fallback of its own, so without this a connectorless
# deployment comes up with no login path at all. The seed step in db_migrate.tf hashes it; the
# plaintext lives only here, for an operator to read out of Secrets Manager. No special
# characters: it gets pasted into a shell and then a form.
resource "random_password" "admin_password" {
  length  = 32
  special = false
}

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

# No ignore_changes: terraform generates these and
# is the only writer, so suppressing updates would only stop a new key reaching existing installs.
resource "aws_secretsmanager_secret_version" "app" {
  count     = local.is_byoc ? 1 : 0
  secret_id = aws_secretsmanager_secret.app[0].id
  secret_string = jsonencode({
    ADMIN_PASSWORD      = random_password.admin_password.result
    JWT_SECRET          = random_password.jwt_secret[0].result
    DEX_CLIENT_SECRET   = random_password.dex_client_secret[0].result
    ORCHESTRATOR_SECRET = random_password.orchestrator_secret[0].result
  })
}
