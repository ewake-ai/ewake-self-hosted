resource "aws_db_subnet_group" "this" {
  # name_prefix by default: a fixed name cannot be replaced, and RDS refuses to drop
  # a subnet its instance sits in — so any change to the subnet set would deadlock
  # on a group terraform can neither update nor recreate.
  #
  # var.rds_subnet_group_name overrides it for a deployment created before this repo
  # moved to name_prefix, whose group is named `<tenant_name>` with no suffix. Renaming
  # the attribute replaces the group, and terraform then calls ModifyDBInstance to
  # repoint the live database — which RDS rejects outright on a Multi-AZ instance:
  #
  #   InvalidParameterCombination: You cannot move a DB instance with Multi-Az enabled to a VPC
  #
  # Setting it to that deployment's existing group name is a no-op instead, and no
  # database is touched.
  name        = var.rds_subnet_group_name
  name_prefix = var.rds_subnet_group_name == null ? "${var.tenant_name}-" : null
  subnet_ids  = aws_subnet.private[*].id

  tags = {
    Name = var.tenant_name
  }
}

resource "random_password" "rds_master" {
  length  = 32
  special = false # avoids characters that need escaping in connection strings
}

resource "aws_secretsmanager_secret" "rds_master" {
  name = "ewake/${var.tenant_name}/rds/master"
}

resource "aws_secretsmanager_secret_version" "rds_master" {
  secret_id = aws_secretsmanager_secret.rds_master.id
  secret_string = jsonencode({
    username = "postgres"
    password = random_password.rds_master.result
    host     = aws_db_instance.this.address
    port     = aws_db_instance.this.port
  })
}

resource "random_id" "final_snapshot" {
  byte_length = 4
}

resource "aws_db_instance" "this" {
  identifier = var.tenant_name

  engine                      = "postgres"
  engine_version              = "18.4"
  allow_major_version_upgrade = true
  instance_class              = var.rds_instance_class
  allocated_storage           = var.rds_storage_gb
  storage_type                = "gp3"
  storage_encrypted           = true
  multi_az                    = var.rds_multi_az
  db_subnet_group_name        = aws_db_subnet_group.this.name
  vpc_security_group_ids      = [aws_security_group.rds.id]
  username                    = "postgres"
  password                    = random_password.rds_master.result
  backup_retention_period     = 7
  # Hardcoded, not a variable: its job is not stopping a deliberate destroy — that
  # only needs the one CLI call in the README, since destroy never re-applies
  # config. It is stopping an accidental replacement, which terraform will
  # otherwise carry out on a live database without asking. A guard tfvars can
  # switch off is one that gets switched off for a teardown and never switched back.
  deletion_protection = true
  apply_immediately   = false
  publicly_accessible = false
  skip_final_snapshot = false
  # Not timestamp(): that changes on every plan, which is why this attribute used to
  # carry ignore_changes — and ignore_changes kept it out of state entirely, so the
  # destroy had no identifier to hand AWS and failed on every attempt:
  #
  #   Error: final_snapshot_identifier is required when skip_final_snapshot is false
  #
  # random_id is drawn once at create and stored, so plans stay quiet, the name stays
  # unique across rebuilds, and terraform still knows what to call the snapshot.
  final_snapshot_identifier = "${var.tenant_name}-final-${random_id.final_snapshot.hex}"

  tags = {
    Name = var.tenant_name
  }
}
