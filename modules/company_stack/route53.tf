# Absent when var.hosted_zone_id is null: the customer owns DNS and points the
# hostname at the ALB themselves. Nothing else in the stack reads this record — the
# listener rule matches on the Host header, not on what resolves — so a customer-managed
# deployment is complete without it, just unreachable until they create it.
resource "aws_route53_record" "company" {
  count = var.hosted_zone_id == null ? 0 : 1

  zone_id = var.hosted_zone_id
  name    = local.company_host
  type    = "A"

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = true
  }
}
