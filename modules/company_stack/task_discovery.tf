# Gives the reactive task an internal DNS name so the Lambdas reach it inside the
# VPC instead of resolving to the public-facing ALB.
#
resource "aws_service_discovery_private_dns_namespace" "task" {
  name        = "${var.company.name}.internal"
  vpc         = var.vpc_id
  description = "Private discovery for the ${local.arn_prefix} task"
  tags        = local.tags
}

# Left empty on purpose: Cloud Map refuses to delete a namespace whose services
# still have registered instances, and ECS deregisters asynchronously.
resource "aws_service_discovery_private_dns_namespace" "mcp" {
  name        = "${var.company.name}.mcp.internal"
  vpc         = var.vpc_id
  description = "MCP discovery namespace for ${var.company.name}"
  tags        = local.tags

  lifecycle {
    # description is applied state; ignore drift so a wording change is never a plan diff.
    ignore_changes = [description]
  }
}

# ECS accepts exactly one service_registries entry per service, and every container
# shares the task's single awsvpc ENI, so one A record addresses all of them and only the
# port differs. Registering the task rather than one of its sidecars is what lets reactive
# (3000) and cloudwatch-mcp (8931) share it under a name that describes what it resolves to.
resource "aws_service_discovery_service" "reactive" {
  name = "reactive"

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.task.id
    dns_records {
      type = "A"
      ttl  = 10
    }
    routing_policy = "MULTIVALUE"
  }

  health_check_custom_config {
    failure_threshold = 1
  }

  tags = local.tags
}

locals {
  task_host = "reactive.${var.company.name}.internal"

  # Plain HTTP on purpose: the hop never leaves the VPC, and x-ewake-auth is what
  # authenticates an internal call — the ALB's TLS was terminating a round trip over the
  # public internet to reach a task in the same subnet.
  internal_reactive_base_url = "http://${local.task_host}:3000"
}

# A dedicated group for everything that talks to this task internally. These rules
# cannot live on the shared ECS task SG: a self-referencing rule there would admit
# every task that shares that group.
resource "aws_security_group" "internal" {
  name = "${local.arn_prefix}-internal"
  # No apostrophe: EC2 rejects one in a security group description.
  description = "Reaches the internal ports of the ${var.company.name} reactive task"
  vpc_id      = var.vpc_id

  tags = merge(local.tags, { Name = "${local.arn_prefix}-internal" })
}

resource "aws_vpc_security_group_ingress_rule" "internal_reactive" {
  security_group_id            = aws_security_group.internal.id
  referenced_security_group_id = aws_security_group.internal.id
  from_port                    = 3000
  to_port                      = 3000
  ip_protocol                  = "tcp"
  description                  = "reactive internal API, from this deployment's Lambdas only"

  lifecycle {
    # description is applied state; ignore drift so a wording change is never a plan diff.
    ignore_changes = [description]
  }
}
