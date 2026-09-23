# Bring-your-own network.
#
# By default this deployment builds its own VPC, subnets, NAT gateways and route
# tables — see vpc.tf. That is the right shape for an account opened for Ewake and
# nothing else, and it stays the default.
#
# It is the wrong shape for a customer running a managed landing zone. Their
# addressing is planned centrally, their egress is inspected, and a VPC we invent
# arrives with a CIDR that collides with production. Those customers hand us a VPC
# and a set of subnets. Setting var.existing_network switches to that mode: every
# resource in vpc.tf drops out and the deployment creates only what is genuinely
# its own — security groups, the load balancer, the database, and the ENIs its
# tasks and functions run on.
#
# Three things the deployment then depends on and cannot verify for itself:
#
#   * Egress. The private subnets must reach the internet or an approved proxy.
#     No NAT gateway is created in this mode, and the deployment pulls images from
#     Ewake's ECR, calls Bedrock, and talks to whatever integrations get connected.
#     Without it nothing boots, and the first symptom is an image pull timeout that
#     reads like a permissions problem.
#   * Routing to the load balancer from wherever the dashboard is reached. A VPC
#     the customer already attached to their network needs nothing from us, which
#     is why transit_gateway_id is rejected in this mode.
#   * Free addresses. The load balancer wants eight per subnet, and every ECS task
#     and Lambda ENI takes one.
#
# Everything downstream reads the network through the locals at the bottom of this
# file rather than through aws_vpc.this directly, so a resource added later works
# in both modes by default.

data "aws_vpc" "existing" {
  count = local.byo_network ? 1 : 0

  id = local.byo_vpc_id
}

data "aws_subnet" "existing_private" {
  for_each = toset(local.byo_private_subnets)

  id = each.value

  lifecycle {
    # A subnet id from a different VPC is the likeliest thing to be wrong here, and
    # it does not fail on its own: security groups would be created in one VPC and
    # the tasks placed in another, and the apply dies much later with an error that
    # names neither.
    postcondition {
      condition     = self.vpc_id == local.byo_vpc_id
      error_message = "Subnet ${self.id} is in VPC ${self.vpc_id}, not ${local.byo_vpc_id}. Every id in existing_network.private_subnet_ids must belong to existing_network.vpc_id."
    }
  }
}

data "aws_subnet" "existing_public" {
  for_each = toset(local.byo_public_subnets)

  id = each.value

  lifecycle {
    postcondition {
      condition     = self.vpc_id == local.byo_vpc_id
      error_message = "Subnet ${self.id} is in VPC ${self.vpc_id}, not ${local.byo_vpc_id}. Every id in existing_network.public_subnet_ids must belong to existing_network.vpc_id."
    }
  }
}

locals {
  byo_network = var.existing_network != null

  # try(), not var.existing_network.<field>, so that every expression below is
  # evaluable in both modes without guarding each use.
  byo_vpc_id          = try(var.existing_network.vpc_id, null)
  byo_private_subnets = try(var.existing_network.private_subnet_ids, [])
  byo_public_subnets  = try(var.existing_network.public_subnet_ids, [])
  byo_private_rt_ids  = try(var.existing_network.private_route_table_ids, [])

  # How many of each thing vpc.tf builds. Zero in bring-your-own mode.
  created_az_count = local.byo_network ? 0 : length(var.azs)

  # The five handles every other file uses. one() rather than [0] so the created
  # side is null instead of an error when the count is zero.
  vpc_id          = local.byo_network ? local.byo_vpc_id : one(aws_vpc.this[*].id)
  private_subnets = local.byo_network ? local.byo_private_subnets : aws_subnet.private[*].id
  public_subnets  = local.byo_network ? local.byo_public_subnets : aws_subnet.public[*].id

  # Route tables are only known to us when we made them. In bring-your-own mode the
  # customer names them, and if they do not, the gateway endpoint is skipped rather
  # than written into tables we were not given.
  private_route_table_ids = local.byo_network ? local.byo_private_rt_ids : aws_route_table.private[*].id

  # Every CIDR on the VPC, not just the primary. A landing-zone VPC often carries
  # secondary ranges, and a security group that admitted only the primary would
  # silently refuse half the subnets it is supposed to serve.
  vpc_cidr_blocks = local.byo_network ? flatten([
    for v in data.aws_vpc.existing : v.cidr_block_associations[*].cidr_block
  ]) : [var.vpc_cidr]

  # A gateway endpoint is nothing but a route in each route table, so in a VPC we
  # were handed it is very likely to be there already — and AWS rejects the second
  # one with RouteAlreadyExists, mid-apply. Off by default there, on where we built
  # the VPC ourselves and know there is none.
  vpc_s3_gateway_endpoint = (
    var.vpc_s3_gateway_endpoint != null ? var.vpc_s3_gateway_endpoint : !local.byo_network
  )

  # Interface endpoints default to on when we build the VPC and off when we are
  # given one: a landing-zone VPC usually has them already, and a second endpoint
  # for the same service with private DNS is rejected by AWS mid-apply. An explicit
  # true or false always wins.
  vpc_interface_endpoints = var.vpc_interface_endpoints != null ? var.vpc_interface_endpoints : !local.byo_network

  # Where the subnets really are, read back from AWS. The variable validations can
  # count ids; only this can tell whether two of them are in the same zone.
  private_subnet_azs = local.byo_network ? distinct([
    for s in data.aws_subnet.existing_private : s.availability_zone
  ]) : var.azs

  alb_public_subnet_azs = local.byo_network ? distinct([
    for s in data.aws_subnet.existing_public : s.availability_zone
  ]) : var.azs
}
