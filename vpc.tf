# NOTE(byoc-duplication): The tenant-level resources in this root (vpc.tf,
# vpc_endpoints.tf, security_groups.tf, alb.tf, ecs_cluster.tf, rds.tf,
# bootstrap_lambda.tf, log_clustering.tf) are direct copies of
# terraform/tenants/*.tf with the workspace + registry references replaced by
# variables. Any bug fix or infra change in terraform/tenants/ MUST be mirrored
# here. Extraction into a shared module (terraform/modules/tenant_stack/) is
# deliberately deferred until we can validate the state migration with real
# `terraform plan` output on the SaaS tenants — moving resources into a module
# changes their state addresses and one mis-issued `moved {}` block would
# destroy live tenant infra.

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = var.tenant_name
  }
}

resource "aws_subnet" "public" {
  count = length(var.azs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index)
  availability_zone = var.azs[count.index]

  # Diff from terraform/tenants/vpc.tf, which still has this true. Only the ALB
  # and the NAT gateways live here, and both bring their own public addresses,
  # so nothing needs it — and leaving it on hands a public IP to whatever gets
  # put in a public subnet next. Mirror back into tenants/ when the SaaS roots
  # get the same sweep.
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.tenant_name}-public-${var.azs[count.index]}"
    Tier = "public"
  }
}

resource "aws_subnet" "private" {
  count = length(var.azs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index + length(var.azs))
  availability_zone = var.azs[count.index]

  tags = {
    Name = "${var.tenant_name}-private-${var.azs[count.index]}"
    Tier = "private"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.tenant_name}-igw"
  }
}

resource "aws_eip" "nat" {
  count  = length(var.azs)
  domain = "vpc"

  tags = {
    Name = "${var.tenant_name}-nat-${var.azs[count.index]}"
  }
}

resource "aws_nat_gateway" "this" {
  count = length(var.azs)

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = {
    Name = "${var.tenant_name}-nat-${var.azs[count.index]}"
  }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = "${var.tenant_name}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  count  = length(var.azs)
  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this[count.index].id
  }

  tags = {
    Name = "${var.tenant_name}-private-rt-${var.azs[count.index]}"
  }
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}
