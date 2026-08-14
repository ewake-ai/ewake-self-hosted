# Per-company secrets in Secrets Manager. The DB credential secret lives in
# rds_db.tf because it's tightly coupled to the postgresql provider; this file
# is the place for additional per-company secrets if they appear later.
#
# Naming convention: ${var.project_name}/${var.tenant_name}/${var.company.name}/<name>
# IAM (iam.tf) restricts the task role to this prefix.
#
# Per-integration tokens live at the convention-defined path:
#   ${var.project_name}/${var.tenant_name}/${var.company.name}/integrations/${type}
# (one secret per integration type, JSON-encoded payload with each token field).
# Created/updated/deleted by the reactive server at runtime via the OAuth /
# manual-connect flows in src/reactive/server/routers/api/v1/{auth,integration}.
# The SecretsScopedToCompany statement in iam.tf already covers this prefix
# (Get/Describe + Create/Update/Delete/Restore + TagResource).

# Ewake-owned, so absent in a customer account: byoc must not read it at all, or the plan fails.
data "aws_secretsmanager_secret" "langsmith" {
  count = local.is_byoc ? 0 : 1
  name  = "langsmith"
}

data "aws_secretsmanager_secret_version" "langsmith" {
  count     = local.is_byoc ? 0 : 1
  secret_id = "langsmith"
}

# Lambda has no `valueFrom` equivalent — reactive + knowledge-graph read GithubService, so their env vars are inlined at plan time. Same as langsmith below.
data "aws_secretsmanager_secret_version" "github_app" {
  count     = !local.is_byoc && var.github_app_secret_arn != null ? 1 : 0
  secret_id = var.github_app_secret_arn
}

# The knowledge-graph Lambda reads feature flags agentless, and the agentless source wants the key itself rather than the ARN every other consumer takes.
data "aws_secretsmanager_secret_version" "datadog_api_key" {
  count     = !local.is_byoc && var.datadog_api_key_secret_arn != null ? 1 : 0
  secret_id = var.datadog_api_key_secret_arn
}

# Per-company byoc replacement for ewake-secrets (JWT_SECRET today). Generated once on first apply; rotations happen out-of-band so we don't clobber a live secret.
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

# Authenticates the Lambda's calls to its own reactive server; byoc has no orchestrator to mint it.
resource "random_password" "orchestrator_secret" {
  count            = local.is_byoc ? 1 : 0
  length           = 64
  special          = true
  override_special = "!#$%^&*()-_=+[]{}<>?"
}

resource "aws_secretsmanager_secret" "app" {
  count       = local.is_byoc ? 1 : 0
  name        = "${local.ssm_path}/app"
  description = "Per-company application secrets (JWT_SECRET, DEX_CLIENT_SECRET, ...) for standalone (byoc) deployments."
  tags        = local.tags
}

# No ignore_changes, unlike the operator-seeded secrets in shared/: terraform generates these and
# is the only writer, so suppressing updates would only stop a new key reaching existing installs.
resource "aws_secretsmanager_secret_version" "app" {
  count     = local.is_byoc ? 1 : 0
  secret_id = aws_secretsmanager_secret.app[0].id
  secret_string = jsonencode({
    JWT_SECRET          = random_password.jwt_secret[0].result
    DEX_CLIENT_SECRET   = random_password.dex_client_secret[0].result
    ORCHESTRATOR_SECRET = random_password.orchestrator_secret[0].result
  })
}
