# See vpc.tf for the duplication note. Diff from terraform/tenants/rds.tf:
# no DBM parameter group / no datadog_pg secret — DBM ships query samples to
# Ewake's Datadog org, which a customer deployment must not do.

resource "aws_db_subnet_group" "this" {
  # name_prefix, not name: a subnet_cidr move cannot update this group in place,
  # because RDS refuses to drop a subnet its instance sits in. The group is
  # replaced instead, which needs a free name at the moment of creation.
  #
  # Deliberately NOT create_before_destroy. CBD propagates to dependents, and
  # aws_db_instance below carries a fixed `identifier` — so the database would be
  # planned create-before-destroy and fail with DBInstanceAlreadyExists. Plain
  # replacement gives the only order AWS accepts: drop the instance, drop the
  # group, recreate both.
  name_prefix = "${var.tenant_name}-"
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
  deletion_protection         = var.rds_deletion_protection
  apply_immediately           = false
  publicly_accessible         = false
  skip_final_snapshot         = false
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
