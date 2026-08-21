# See vpc.tf for the duplication note. Diffs from terraform/tenants/alb.tf:
# certificate_arn points at the customer's own cert (acm.tf) instead of the
# shared Ewake wildcard, and drop_invalid_header_fields is on below.

resource "aws_lb" "this" {
  name               = "${var.tenant_name}-tenant-alb"
  internal           = var.alb_internal
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  # An internal ALB has no business in a public subnet: it takes private IPs either
  # way, and leaving it public-side only widens what an SG mistake would expose.
  subnets = var.alb_internal ? aws_subnet.private[*].id : aws_subnet.public[*].id

  # Strip headers whose names aren't [-A-Za-z0-9]+ rather than passing them to
  # reactive. Separate from desync_mitigation_mode, which stays on its
  # "defensive" default. Mirror back into tenants/ when the SaaS roots get the
  # same sweep.
  drop_invalid_header_fields = true

  tags = {
    Name = "${var.tenant_name}-tenant-alb"
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.this.certificate_arn

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
