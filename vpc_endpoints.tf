# See vpc.tf for the duplication note.

resource "aws_security_group" "vpc_endpoints" {
  count       = local.vpc_interface_endpoints ? 1 : 0
  name        = "${var.tenant_name}-vpc-endpoints"
  description = "Allow HTTPS from inside the VPC to interface endpoints"
  vpc_id      = local.vpc_id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = local.vpc_cidr_blocks
  }

  tags = {
    Name = "${var.tenant_name}-vpc-endpoints"
  }
}

locals {
  interface_endpoints = toset([
    "ec2messages",
    "ssm",
    "ssmmessages",
    "secretsmanager",
    "ecr.api",
    "ecr.dkr",
    "logs"
  ])
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.vpc_interface_endpoints ? local.interface_endpoints : toset([])

  vpc_id              = local.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.private_subnets
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = true

  tags = {
    Name = "${var.tenant_name}-${each.value}"
  }
}

resource "aws_vpc_endpoint" "s3" {
  # A gateway endpoint is nothing but routes in route tables. We only have tables to
  # write into when we built them, or when existing_network named them — otherwise
  # skip it rather than reach into a customer's routing.
  count = length(local.private_route_table_ids) > 0 ? 1 : 0

  vpc_id            = local.vpc_id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = local.private_route_table_ids

  tags = {
    Name = "${var.tenant_name}-s3"
  }
}
