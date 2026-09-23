resource "aws_lb" "this" {
  name               = "${var.tenant_name}-tenant-alb"
  internal           = var.alb_internal
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  # An internal ALB has no business in a public subnet: it takes private IPs either
  # way, and leaving it public-side only widens what an SG mistake would expose.
  subnets = var.alb_internal ? local.private_subnets : local.public_subnets

  # Strip headers whose names aren't [-A-Za-z0-9]+ rather than passing them to
  # reactive. Separate from desync_mitigation_mode, which stays on its
  # same sweep.
  drop_invalid_header_fields = true

  tags = {
    Name = "${var.tenant_name}-tenant-alb"
  }

  # The load balancer is the first thing that fails when a supplied network is the
  # wrong shape, and it fails with "At least two subnets in two different Availability
  # Zones must be specified" twenty minutes into an apply that has already built RDS.
  # Checked here instead, at plan, against what AWS says the subnets actually are —
  # the variable validation can only count ids, not place them.
  lifecycle {
    precondition {
      condition     = length(local.private_subnet_azs) >= 2
      error_message = "The subnets in existing_network.private_subnet_ids are all in ${join(", ", local.private_subnet_azs)}. The load balancer and the database both need at least two availability zones; supply a private subnet in a second one."
    }

    precondition {
      condition     = var.alb_internal || length(local.alb_public_subnet_azs) >= 2
      error_message = "The subnets in existing_network.public_subnet_ids are all in ${join(", ", local.alb_public_subnet_azs)}. A public load balancer needs at least two availability zones."
    }
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = local.certificate_arn

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "no route"
      status_code  = "404"
    }
  }
}

resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# Extra SNI certificates, for serving an old and a new hostname at once during a
# cutover. The listener's default certificate stays the one above; these are only
# presented when the client's SNI matches. Routing is separate — see
# var.alb_extra_host_headers.
resource "aws_lb_listener_certificate" "extra" {
  for_each = toset(var.extra_certificate_arns)

  listener_arn    = aws_lb_listener.https.arn
  certificate_arn = each.value
}
