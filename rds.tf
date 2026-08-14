# See vpc.tf for the duplication note. Diff from terraform/tenants/rds.tf:
# no DBM parameter group / no datadog_pg secret — DBM ships query samples to
# Ewake's Datadog org, which a customer deployment must not do.

resource "aws_db_subnet_group" "this" {
  name       = var.tenant_name
  subnet_ids = aws_subnet.private[*].id

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
  deletion_protection         = true
  apply_immediately           = false
  publicly_accessible         = false
  skip_final_snapshot         = false
  final_snapshot_identifier   = "${var.tenant_name}-final-${formatdate("YYYY-MM-DD", timestamp())}"

  lifecycle {
    ignore_changes = [final_snapshot_identifier]
  }

  tags = {
    Name = var.tenant_name
  }
}
