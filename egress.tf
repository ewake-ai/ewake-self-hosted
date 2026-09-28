# Internet egress for a VPC we were handed (var.existing_network).
#
# A deployment that builds its own VPC gets NAT gateways from vpc.tf. One placed in
# an existing VPC gets nothing, on the assumption that a VPC somebody already runs
# already reaches the internet. That does not hold for a landing-zone VPC used only
# for private or VPN-reached workloads: it can have no route out at all, and then
# every task fails to pull its image or read its secrets, and nothing that talks to
# Bedrock, Slack or GitHub works even when interface endpoints are added.
#
# existing_network.create_nat_gateway fills that gap with the least the VPC is
# missing:
#
#   * NAT gateways, one per public subnet, and a 0.0.0.0/0 route to them in each of
#     private_route_table_ids.
#   * The public subnets they sit in, when the VPC has none: public_subnet_cidrs
#     are carved into new subnets, one per availability zone of the private
#     subnets, behind a route table of their own.
#   * An internet gateway for those subnets, unless internet_gateway_id names the
#     one the VPC already has. A VPC takes only one; attaching a second fails.
#
# Nothing here edits a route the customer made. The default route is added only to
# the tables they list, and a table that already has one pointing anywhere but a
# NAT gateway is refused at plan time: that table already has an egress path, and
# replacing it would move every other workload on it to ours.

locals {
  byo_nat = local.byo_network && try(var.existing_network.create_nat_gateway, false)

  byo_public_cidrs   = try(var.existing_network.public_subnet_cidrs, [])
  byo_create_public  = local.byo_nat && length(local.byo_public_cidrs) > 0
  byo_create_igw     = local.byo_create_public && try(var.existing_network.internet_gateway_id, null) == null
  byo_internet_gw_id = local.byo_create_igw ? one(aws_internet_gateway.byo[*].id) : try(var.existing_network.internet_gateway_id, null)
  byo_nat_subnet_ids = local.byo_create_public ? aws_subnet.byo_public[*].id : local.byo_public_subnets
  byo_nat_subnet_azs = local.byo_create_public ? [
    for i in range(length(local.byo_public_cidrs)) : local.private_subnet_azs[i]
    ] : [
    for id in local.byo_public_subnets : data.aws_subnet.existing_public[id].availability_zone
  ]
  byo_nat_count = !local.byo_nat ? 0 : (
    local.byo_create_public ? length(local.byo_public_cidrs) : length(local.byo_public_subnets)
  )

  # Which NAT gateway each private route table sends to: the one in the zone of the
  # private subnets it serves, so traffic does not cross zones and one zone's outage
  # does not take the other's egress with it. A table serving none of our subnets
  # (the main table, say) falls back to the first.
  byo_rt_nat_index = {
    for rt, table in data.aws_route_table.byo_private : rt => try(
      index(local.byo_nat_subnet_azs, [
        for a in table.associations : data.aws_subnet.existing_private[a.subnet_id].availability_zone
        if contains(keys(data.aws_subnet.existing_private), a.subnet_id)
      ][0]),
      0
    )
  }
}

data "aws_route_table" "byo_private" {
  for_each = local.byo_nat ? toset(local.byo_private_rt_ids) : toset([])

  route_table_id = each.value

  lifecycle {
    postcondition {
      condition     = self.vpc_id == local.byo_vpc_id
      error_message = "Route table ${self.id} is in VPC ${self.vpc_id}, not ${local.byo_vpc_id}. Every id in existing_network.private_route_table_ids must belong to existing_network.vpc_id."
    }

    # A default route to a NAT gateway is tolerated so that the route this file adds
    # does not fail the next plan. Anything else means the table already has a way
    # out that other workloads may rely on.
    postcondition {
      condition = alltrue([
        for r in self.routes : r.cidr_block != "0.0.0.0/0" || r.nat_gateway_id != ""
      ])
      error_message = "Route table ${self.id} already has a 0.0.0.0/0 route that is not to a NAT gateway, so this deployment will not add one: replacing it would reroute everything else using that table. Either leave create_nat_gateway unset and use the egress that route provides, or list route tables that serve only this deployment's subnets."
    }
  }
}

resource "aws_internet_gateway" "byo" {
  count = local.byo_create_igw ? 1 : 0

  vpc_id = local.byo_vpc_id

  tags = {
    Name = "${var.tenant_name}-igw"
  }
}

resource "aws_subnet" "byo_public" {
  count = local.byo_create_public ? length(local.byo_public_cidrs) : 0

  vpc_id            = local.byo_vpc_id
  cidr_block        = local.byo_public_cidrs[count.index]
  availability_zone = local.private_subnet_azs[count.index]

  # Only the NAT gateways live here, and they bring their own addresses.
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.tenant_name}-public-${local.private_subnet_azs[count.index]}"
    Tier = "public"
  }

  lifecycle {
    precondition {
      condition     = length(local.byo_public_cidrs) <= length(local.private_subnet_azs)
      error_message = "existing_network.public_subnet_cidrs has ${length(local.byo_public_cidrs)} entries but the private subnets span ${length(local.private_subnet_azs)} availability zones. Give at most one CIDR per zone; one is enough, and cheaper, if a single NAT gateway will do."
    }
  }
}

# Standalone routes, as everywhere in this repo — see the note in vpc.tf.
resource "aws_route_table" "byo_public" {
  count = local.byo_create_public ? 1 : 0

  vpc_id = local.byo_vpc_id

  tags = {
    Name = "${var.tenant_name}-public-rt"
  }
}

resource "aws_route" "byo_public_default" {
  count = local.byo_create_public ? 1 : 0

  route_table_id         = aws_route_table.byo_public[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = local.byo_internet_gw_id
}

resource "aws_route_table_association" "byo_public" {
  count = length(aws_subnet.byo_public)

  subnet_id      = aws_subnet.byo_public[count.index].id
  route_table_id = aws_route_table.byo_public[0].id
}

resource "aws_eip" "byo_nat" {
  count  = local.byo_nat_count
  domain = "vpc"

  tags = {
    Name = "${var.tenant_name}-nat-${local.byo_nat_subnet_azs[count.index]}"
  }
}

resource "aws_nat_gateway" "byo" {
  count = local.byo_nat_count

  allocation_id = aws_eip.byo_nat[count.index].id
  subnet_id     = local.byo_nat_subnet_ids[count.index]

  tags = {
    Name = "${var.tenant_name}-nat-${local.byo_nat_subnet_azs[count.index]}"
  }

  # A NAT gateway comes up before its subnet can reach the internet gateway, and
  # then passes nothing until the route exists.
  depends_on = [aws_route.byo_public_default, aws_route_table_association.byo_public]
}

resource "aws_route" "byo_private_default" {
  for_each = local.byo_nat ? toset(local.byo_private_rt_ids) : toset([])

  route_table_id         = each.value
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.byo[local.byo_rt_nat_index[each.value]].id
}
