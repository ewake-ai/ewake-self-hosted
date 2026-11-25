# What each secret of this deployment holds. Terraform creates the secrets empty, and this
# invocation has the bootstrap Lambda fill them, so terraform state holds ARNs and never a
# password. The result of the invocation names what was written and holds no value.
#
# A literal below is written on every run, because terraform owns it: a host name, a port.
# A rule fills a gap and never replaces a value. `generate` draws a password, and `default`
# writes a placeholder. So a second run changes no password, and a deployment whose secrets
# an earlier release of this repository filled keeps every value.
#
# Like bootstrap_db, the invocation runs when it is created and when its input changes.
# To run it again by hand:
#   terraform apply -replace='module.company.aws_lambda_invocation.secret_values'

locals {
  # No symbols: these go into connection strings and get pasted into a shell.
  password_rule = { generate = { length = 32 } }
  key_rule      = { generate = { length = 64, symbols = "!#$%^&*()-_=+[]{}<>?" } }

  secret_values = concat(
    [
      {
        arn = aws_secretsmanager_secret.company_db.arn
        fields = {
          host     = var.rds_endpoint
          port     = var.rds_port
          database = var.company.public_id
          username = "${var.company.name}_app"
          password = local.password_rule
        }
      },
      {
        arn = aws_secretsmanager_secret.company_db_ro.arn
        fields = {
          host     = var.rds_endpoint
          port     = var.rds_port
          database = var.company.public_id
          username = "${var.company.name}_ro"
          password = local.password_rule
        }
      },
      {
        arn  = aws_secretsmanager_secret.company_neo4j_password.arn
        text = local.password_rule
      },
    ],
    [
      for secret in aws_secretsmanager_secret.app : {
        arn = secret.arn
        fields = {
          ADMIN_PASSWORD      = local.password_rule
          JWT_SECRET          = local.key_rule
          DEX_CLIENT_SECRET   = local.key_rule
          ORCHESTRATOR_SECRET = local.key_rule
        }
      }
    ],
    [
      for id in var.company.sso_connectors : {
        arn  = aws_secretsmanager_secret.sso_connector[id].arn
        text = { default = jsonencode({ id = id, name = id, type = "" }) }
      }
    ],
  )
}

resource "aws_lambda_invocation" "secret_values" {
  function_name = var.bootstrap_lambda_function_name

  input = jsonencode({
    action  = "secrets"
    secrets = local.secret_values
  })
}
