# Database, roles, pgvector extension, and grants on the RDS instance. All
# created by the RDS bootstrap Lambda, which runs inside the VPC and has direct
# network access to RDS.
#
# Two roles:
#   <company>_app  →  read-write, owns the database. The ECS task uses these
#                     credentials via the {ssm_path}/db secret.
#   <company>_ro   →  read-only on the public schema (existing + future
#                     objects). Credentials in {ssm_path}/db-readonly for
#                     operators / engineers to connect manually. The ECS
#                     task never reads it.

resource "random_password" "company_db" {
  length  = 32
  special = false
}

resource "random_password" "company_db_ro" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "company_db" {
  name = "${local.ssm_path}/db"
  tags = local.tags
}

resource "aws_secretsmanager_secret_version" "company_db" {
  secret_id = aws_secretsmanager_secret.company_db.id
  secret_string = jsonencode({
    host     = var.rds_endpoint
    port     = var.rds_port
    database = var.company.public_id
    username = "${var.company.name}_app"
    password = random_password.company_db.result
  })
}

resource "aws_secretsmanager_secret" "company_db_ro" {
  name = "${local.ssm_path}/db-readonly"
  tags = merge(local.tags, {
    Access = "read-only"
  })
}

resource "aws_secretsmanager_secret_version" "company_db_ro" {
  secret_id = aws_secretsmanager_secret.company_db_ro.id
  secret_string = jsonencode({
    host     = var.rds_endpoint
    port     = var.rds_port
    database = var.company.public_id
    username = "${var.company.name}_ro"
    password = random_password.company_db_ro.result
  })
}

# Invokes the bootstrap Lambda once at create time. The
# default lifecycle_scope ("CREATE") means the invocation does NOT re-run on
# subsequent applies, so changes that should reflect in the DB (password
# rotation, db rename, role rename, new extension) require an explicit
# `terraform taint module.company["<name>"].aws_lambda_invocation.bootstrap_db`
# to fire again. Delete is a no-op inside the Lambda.
resource "aws_lambda_invocation" "bootstrap_db" {
  function_name = var.bootstrap_lambda_function_name

  input = jsonencode(merge(
    {
      master_secret_arn = var.rds_master_secret_arn
      rds_host          = var.rds_endpoint
      rds_port          = var.rds_port
      database_name     = var.company.public_id
      extensions        = concat(["vector"], var.datadog_pg_secret_arn != null ? ["pg_stat_statements"] : [])
      app_role = {
        name       = "${var.company.name}_app"
        secret_arn = aws_secretsmanager_secret.company_db.arn
      }
      ro_role = {
        name       = "${var.company.name}_ro"
        secret_arn = aws_secretsmanager_secret.company_db_ro.arn
      }
    },
    var.datadog_pg_secret_arn != null ? {
      datadog_role = {
        name       = "datadog"
        secret_arn = var.datadog_pg_secret_arn
      }
    } : {}
  ))

  depends_on = [
    aws_secretsmanager_secret_version.company_db,
    aws_secretsmanager_secret_version.company_db_ro,
  ]
}
