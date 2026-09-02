# A public door in front of a private ALB, for the third parties that have to reach
# in: Slack's Events and interactivity callbacks, and the Datadog webhook. None of
# them can route to an internal load balancer, and none of them can be asked to.
#
# Only the paths those callers actually use are routed. The dashboard, the API, SSO
# and everything else stay unreachable from the internet — the point is a public
# door, not a public deployment.
#
# Off by default, and only meaningful with alb_internal: a public ALB already serves
# these paths itself.

locals {
  public_inbound_gateway = var.public_inbound_gateway && var.alb_internal

  # What Slack and Datadog are registered against once the gateway is in front.
  # An explicit public_inbound_base_url still wins — a customer may already run
  # their own entry point and prefer to keep it.
  # The VPC link reaches the ALB from inside the VPC, so its range has to be
  # admitted whatever the customer scoped alb_ingress_cidrs down to — a private
  # deployment may list only a VPN range, which would leave the gateway timing out.
  alb_ingress_cidrs = local.public_inbound_gateway ? distinct(concat(var.alb_ingress_cidrs, [var.vpc_cidr])) : var.alb_ingress_cidrs

  gateway_base_url = local.public_inbound_gateway ? "https://${aws_apigatewayv2_api.public_inbound[0].id}.execute-api.${var.aws_region}.amazonaws.com" : null
}

resource "aws_apigatewayv2_api" "public_inbound" {
  count = local.public_inbound_gateway ? 1 : 0

  name          = "${var.tenant_name}-public-inbound"
  protocol_type = "HTTP"
  description   = "Inbound webhooks for ${local.company_host}. Only the paths third parties call are routed."

  tags = local.common_tags
}

# The link's own group. Its ENIs take private IPs from the deployment's own private
# subnets, so the ALB admits them through the subnet range rather than a group reference —
# aws_security_group.alb declares its ingress inline, and terraform will not let a
# separate rule resource coexist with that. The two fight on every plan.
resource "aws_security_group" "vpc_link" {
  count = local.public_inbound_gateway ? 1 : 0

  name_prefix = "${var.tenant_name}-vpc-link-"
  description = "API Gateway VPC link to the ALB"
  vpc_id      = aws_vpc.this.id

  lifecycle {
    create_before_destroy = true
    # description is immutable in AWS; ignore drift so a wording change never forces
    # a replacement of the live security group.
    ignore_changes = [description]
  }

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = { Name = "${var.tenant_name}-vpc-link" }
}


resource "aws_apigatewayv2_vpc_link" "public_inbound" {
  count = local.public_inbound_gateway ? 1 : 0

  name               = "${var.tenant_name}-public-inbound"
  subnet_ids         = aws_subnet.private[*].id
  security_group_ids = [aws_security_group.vpc_link[0].id]

  tags = local.common_tags
}

resource "aws_apigatewayv2_integration" "public_inbound" {
  count = local.public_inbound_gateway ? 1 : 0

  api_id           = aws_apigatewayv2_api.public_inbound[0].id
  integration_type = "HTTP_PROXY"
  integration_uri  = aws_lb_listener.https.arn
  connection_type  = "VPC_LINK"
  connection_id    = aws_apigatewayv2_vpc_link.public_inbound[0].id

  integration_method     = "ANY"
  payload_format_version = "1.0"

  # Without this the ALB sees the gateway's own execute-api hostname, matches no
  # listener rule, and answers 404 — the deployment looks broken in a way that
  # points nowhere near here. The rule keys on the company host, so say it.
  request_parameters = {
    "overwrite:header.Host" = local.company_host
  }

  # Required, and the failure without it points nowhere useful: API Gateway talks
  # plaintext HTTP to the listener unless a server name is given, the ALB answers
  # 400 to what looks like a malformed request, and nothing reaches the app. The
  # listener is HTTPS because that is what the certificate is on; this names the
  # host to present in SNI and verify against.
  tls_config {
    server_name_to_verify = local.company_host
  }
}

# One route per path a third party actually calls. Anything else is a 404 at the
# gateway and never reaches the VPC.
resource "aws_apigatewayv2_route" "public_inbound" {
  for_each = local.public_inbound_gateway ? toset([
    # Slack: events, and the interactivity callback for buttons and modals.
    "POST /api/v1/slack/events",
    "POST /api/v1/slack/interactive",
    # Datadog monitors. The token in the path is the credential — see
    # integration/datadog.ts, which mints one per integration.
    "POST /api/webhook/datadog/{token}",
    # Slack's own servers fetch this to render the loading icon in a message
    # block, so it is inbound rather than something a browser asks for.
    "GET /android-chrome-512x512.png",
    # Deployment events from the customer's CI. Authenticated by an API key
    # minted in the dashboard, which the caller presents directly.
    "POST /api/v1/events/deployment",
  ]) : toset([])

  api_id    = aws_apigatewayv2_api.public_inbound[0].id
  route_key = each.value
  target    = "integrations/${aws_apigatewayv2_integration.public_inbound[0].id}"
}

resource "aws_apigatewayv2_stage" "public_inbound" {
  count = local.public_inbound_gateway ? 1 : 0

  api_id      = aws_apigatewayv2_api.public_inbound[0].id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.public_inbound[0].arn
    # Enough to answer "did Slack reach us, and what did we answer" without
    # keeping request bodies, which carry message text.
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      integrationErr = "$context.integrationErrorMessage"
    })
  }

  tags = local.common_tags
}

resource "aws_cloudwatch_log_group" "public_inbound" {
  count = local.public_inbound_gateway ? 1 : 0

  name              = "/ewake/${var.tenant_name}/public-inbound"
  retention_in_days = 30
  tags              = local.common_tags
}
