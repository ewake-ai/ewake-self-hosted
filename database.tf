# Bring-your-own database.
#
# By default this deployment creates its own RDS Postgres instance — see rds.tf.
# A customer who runs databases centrally hands one over instead: provisioned to
# their standards, backed up by their tooling, sized by them.
#
# var.existing_database switches to that. No instance, no subnet group, no master
# password and no master secret are created. What this deployment still does to
# the instance is create its own database inside it, and two roles that own and
# read it — the same thing it does to an instance it made itself, through the same
# bootstrap Lambda.
#
# What it needs from you:
#
#   * The master username and password, in a Secrets Manager secret, as
#     {"username": ..., "password": ...}. Used once, at first apply, to create the
#     database and the roles. If the secret is encrypted with a customer-managed
#     KMS key, that key must allow this deployment's roles to decrypt.
#   * Network reach. The instance has to be reachable from the private subnets the
#     tasks and the bootstrap Lambda run in. Give security_group_id and the ingress
#     rules are added to your instance's group for you; leave it out and they are
#     yours to add.
#   * Postgres 18 or later, and an instance this deployment is alone on. It creates
#     a database named company.public_id and roles named after company.name.

data "aws_db_instance" "existing" {
  count = local.byo_database ? 1 : 0

  db_instance_identifier = local.byo_database_identifier
}

locals {
  byo_database            = var.existing_database != null
  byo_database_identifier = try(var.existing_database.identifier, null)
  byo_database_sg         = try(var.existing_database.security_group_id, null)

  # The four values the company module needs, from whichever instance is in play.
  rds_endpoint    = local.byo_database ? one(data.aws_db_instance.existing[*].address) : one(aws_db_instance.this[*].address)
  rds_port        = local.byo_database ? one(data.aws_db_instance.existing[*].port) : one(aws_db_instance.this[*].port)
  rds_resource_id = local.byo_database ? one(data.aws_db_instance.existing[*].resource_id) : one(aws_db_instance.this[*].resource_id)

  rds_master_secret_arn = local.byo_database ? var.existing_database.master_secret_arn : one(aws_secretsmanager_secret.rds_master[*].arn)
}

# Ingress on the customer's own security group, added only when they name it. Two
# rules, because the two things that talk to Postgres here run in different groups:
# the ECS tasks and reactive Lambda share one, the bootstrap Lambda has its own.
#
# Separate resources rather than an aws_security_group with inline rules: this group
# is not ours, and an inline block would make Terraform authoritative over every rule
# on it — deleting whatever the customer has there on the next apply.
resource "aws_vpc_security_group_ingress_rule" "existing_db_from_tasks" {
  count = local.byo_database && local.byo_database_sg != null ? 1 : 0

  security_group_id            = local.byo_database_sg
  referenced_security_group_id = aws_security_group.ecs_task.id
  from_port                    = local.rds_port
  to_port                      = local.rds_port
  ip_protocol                  = "tcp"
  description                  = "Postgres from the ${var.tenant_name} tasks"

  tags = {
    Name = "${var.tenant_name}-tasks"
  }
}

resource "aws_vpc_security_group_ingress_rule" "existing_db_from_bootstrap" {
  count = local.byo_database && local.byo_database_sg != null ? 1 : 0

  security_group_id            = local.byo_database_sg
  referenced_security_group_id = aws_security_group.bootstrap_lambda.id
  from_port                    = local.rds_port
  to_port                      = local.rds_port
  ip_protocol                  = "tcp"
  description                  = "Postgres from the ${var.tenant_name} bootstrap Lambda"

  tags = {
    Name = "${var.tenant_name}-bootstrap"
  }
}
