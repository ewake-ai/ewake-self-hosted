# See vpc.tf for the duplication note.

resource "aws_security_group" "alb" {
  name        = "${var.tenant_name}-alb"
  description = "Tenant ALB ingress from the public internet"
  vpc_id      = aws_vpc.this.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.tenant_name}-alb"
  }
}

resource "aws_security_group" "ecs_task" {
  # Ingress is deliberately NOT inline — see terraform/tenants/security_groups.tf
  # for the full explanation. company_stack's per-company rules live on its own
  # SG (modules/company_stack/task_discovery.tf), so nothing attaches here but
  # ecs_task_from_alb below.
  name        = "${var.tenant_name}-ecs-task"
  description = "Tenant ECS task ingress from the tenant ALB only"
  vpc_id      = aws_vpc.this.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.tenant_name}-ecs-task"
  }
}

resource "aws_vpc_security_group_ingress_rule" "ecs_task_from_alb" {
  security_group_id            = aws_security_group.ecs_task.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 0
  to_port                      = 65535
  ip_protocol                  = "tcp"
}

resource "aws_security_group" "rds" {
  name        = "${var.tenant_name}-rds"
  description = "Tenant RDS Postgres ingress from ECS tasks in this VPC only"
  vpc_id      = aws_vpc.this.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_task.id]
  }

  ingress {
    description     = "Postgres from the RDS bootstrap Lambda"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.bootstrap_lambda.id]
  }

  # Diff from terraform/tenants/security_groups.tf, which still carries an
  # allow-all egress block here. Postgres never dials out, and security groups
  # are stateful, so replies to the two ingress rules above still flow. Omitting
  # egress entirely is what removes the default allow-all. Mirror back into
  # tenants/ when the SaaS roots get the same sweep.

  tags = {
    Name = "${var.tenant_name}-rds"
  }
}
