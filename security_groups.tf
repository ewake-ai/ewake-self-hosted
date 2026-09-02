resource "aws_security_group" "alb" {
  # name_prefix, not name: a security group's description is immutable in AWS, so editing it
  # forces replacement — and a replacement of a fixed-name group fails with
  # InvalidGroup.Duplicate, because the new one is created before the old is gone. That is
  # unrecoverable without hand-deleting the group the live ALB is using. The generated suffix
  # lets the two coexist for the seconds it takes to swap; tags.Name stays readable.
  name_prefix = "${var.tenant_name}-alb-"
  description = "ALB ingress, from var.alb_ingress_cidrs (the public internet by default)"
  vpc_id      = aws_vpc.this.id

  lifecycle {
    create_before_destroy = true
    # description is immutable in AWS: changing its text forces a replacement of the
    # live security group. Ignore drift so a wording change never churns an existing
    # deployment; a fresh install still gets whatever text is set here.
    ignore_changes = [description]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = local.alb_ingress_cidrs
  }

  # Serves only the 301 to 443 (alb.tf's http_redirect). Kept on the same CIDR list
  # so a private deployment does not leave an open port answering on the public side.
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = local.alb_ingress_cidrs
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
  # Ingress is deliberately NOT inline: the module's rules live on its own SG
  # (modules/company_stack/task_discovery.tf), so nothing attaches here but
  # ecs_task_from_alb below.
  name        = "${var.tenant_name}-ecs-task"
  description = "ECS task ingress from the ALB only"
  vpc_id      = aws_vpc.this.id

  lifecycle {
    # description is immutable in AWS; ignore drift so a wording change never forces
    # a replacement of the live security group.
    ignore_changes = [description]
  }

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
  description = "RDS Postgres ingress from ECS tasks in this VPC only"
  vpc_id      = aws_vpc.this.id

  lifecycle {
    # description is immutable in AWS; ignore drift so a wording change never forces
    # a replacement of the live security group.
    ignore_changes = [description]
  }

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

  # No egress block: Postgres never dials out, and omitting it is what removes
  # the default allow-all. Security groups are stateful, so replies still flow.

  tags = {
    Name = "${var.tenant_name}-rds"
  }
}
