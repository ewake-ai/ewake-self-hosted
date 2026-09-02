# ALB target group + listener rule on the HTTPS listener.
# Routes traffic for this deployment's public_id to its ECS service.

resource "aws_lb_target_group" "reactive" {
  name        = substr("${local.arn_prefix}-rx", 0, 32)
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    matcher             = "200-399"
    path                = "/health"
    timeout             = 10
  }

  tags = local.tags

  # Required when the name changes (e.g. the arn_prefix rename): without this
  # terraform tries to DELETE the old TG before the listener rule's
  # target_group_arn is updated, and ELBv2 refuses with ResourceInUse.
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_listener_rule" "reactive" {
  listener_arn = var.alb_listener_arn

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.reactive.arn
  }

  condition {
    host_header {
      # company_host first so the common case reads plainly; the extras are a
      # migration affordance and normally empty.
      values = concat([local.company_host], var.extra_host_headers)
    }
  }
}
