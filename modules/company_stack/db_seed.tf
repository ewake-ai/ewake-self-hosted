# The two rows this deployment cannot serve without: its company row, which the dashboard
# reads before it starts listening, and the ewake@ewake.ai system user it signs in as before
# it has SSO. Both written by the RDS bootstrap Lambda.
#
# A second invocation rather than part of bootstrap_db, which creates the database: neither
# table exists until the migration chains have run against it, hence the ordering below.
#
# This replaced the seed step inside the migrate task in ewake-v0.168.0. On that image or
# later, this resource is the only thing that writes either row.
resource "aws_lambda_invocation" "seed_company" {
  function_name = var.bootstrap_lambda_function_name

  input = jsonencode({
    action        = "seed"
    rds_host      = var.rds_endpoint
    rds_port      = var.rds_port
    database_name = var.company.public_id
    # Connects as the app role, which owns every table the migrations created.
    app_secret_arn = aws_secretsmanager_secret.company_db.arn
    # ADMIN_PASSWORD lives in this blob, hashed onto the user the seed writes.
    admin_secret_arn = aws_secretsmanager_secret.app[0].arn
    company = {
      name      = var.company.name
      domain    = var.company.domain
      public_id = var.company.public_id
    }
  })

  # CREATE_ONLY like bootstrap_db: it fires on create, and a taint re-runs it. A re-run only
  # re-checks the password — it keeps an existing company row, so a renamed company or a
  # changed domain needs that row updated separately.
  depends_on = [
    terraform_data.db_migrate,
    # The secret alone does not order against its version, and this reads ADMIN_PASSWORD.
    aws_secretsmanager_secret_version.app,
  ]
}
