resource "aws_route53_record" "company" {
  zone_id = var.hosted_zone_id
  name    = "${var.company.name}.${var.root_domain}"
  type    = "A"

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = true
  }
}
