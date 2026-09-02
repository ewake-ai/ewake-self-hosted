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

  # Only the ALB and the NAT gateways live here, and both bring their own public
  # addresses. Leaving this on would hand a public IP to whatever is added next.
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

# Routes are standalone aws_route resources, deliberately, NOT in-line `route`
# blocks. An in-line block makes Terraform authoritative over the table's entire
# route set, so any route the customer adds out of band — a VPN, a peering, a
# Transit Gateway attachment — is deleted on the next apply. It does not even
# surface as drift to argue about: the plan shows the route table updating and
# the customer's connectivity disappears. Standalone resources let Terraform
# manage only what it declares and leave the rest alone.
#
# The two cannot be mixed on one table (the provider overwrites in-line rules),
# so if a route ever needs adding here, add another aws_route.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.tenant_name}-public-rt"
  }
}

resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  count  = length(var.azs)
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.tenant_name}-private-rt-${var.azs[count.index]}"
  }
}

# See the note above aws_route_table.public: standalone so a customer-managed
# VPN or peering route on the same table survives our applies.
resource "aws_route" "private_default" {
  count                  = length(var.azs)
  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[count.index].id
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# Attachment to a customer-owned transit gateway, for reaching this VPC from
# their corporate network. Placed in the private subnets: the attachment only
# needs one subnet per AZ to build its ENIs, and the private subnets are the
# ones whose traffic it carries.
resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
  count = var.transit_gateway_id != null ? 1 : 0

  transit_gateway_id = var.transit_gateway_id
  vpc_id             = aws_vpc.this.id
  subnet_ids         = aws_subnet.private[*].id

  # Both false because the TGW belongs to another account. Association and
  # propagation are the owner's to make, and an attachment resource that tried
  # to manage them cross-account would fail. When the TGW has
  # DefaultRouteTableAssociation/Propagation enabled, AWS does both on accept
  # and there is nothing for either side to do by hand.
  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  tags = {
    Name = "${var.tenant_name}-tgw-attachment"
  }

  # The two flags above are create-time only. A TGW with DefaultRouteTable-
  # Association/Propagation enabled associates and propagates the attachment
  # itself on accept, so AWS reports true while the config says false. Without
  # this the plan carries a permanent diff whose apply would DISASSOCIATE the
  # attachment from the owner's route table and black-hole the customer's
  # traffic. Both are the TGW owner's to set; we neither send nor reconcile them.
  lifecycle {
    ignore_changes = [
      transit_gateway_default_route_table_association,
      transit_gateway_default_route_table_propagation,
    ]
  }
}

# One route per CIDR per private table. Standalone, like every route here, so a
# route the customer adds themselves is never clobbered.
resource "aws_route" "private_transit_gateway" {
  for_each = var.transit_gateway_id != null ? {
    for pair in setproduct(range(length(var.azs)), var.transit_gateway_routes) :
    "${pair[0]}-${pair[1]}" => { rt_index = pair[0], cidr = pair[1] }
  } : {}

  route_table_id         = aws_route_table.private[each.value.rt_index].id
  destination_cidr_block = each.value.cidr
  transit_gateway_id     = var.transit_gateway_id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}
