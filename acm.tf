# Certificate for var.company_host. Two shapes, chosen by var.acm_certificate_arn:
#
#   null (default) — we issue it here and DNS-validate it in var.hosted_zone_id,
#     the customer's own Route53 zone. Unlike the SaaS shape (terraform/shared/
#     acm.tf uses one wildcard cert for every tenant), this is a per-deployment
#     cert on the customer's own domain. ACM renews it against the same
#     validation records, which Terraform keeps in place.
#
#   set — the customer issued it themselves, because DNS is theirs. Nothing in
#     this file is created; alb.tf attaches their ARN. Renewal is then their
#     responsibility, and a lapse is invisible from this stack.
#
# Every resource here is gated on local.manage_certificate, so the customer-owned
# case is an absence of resources rather than a branch.

resource "aws_acm_certificate" "this" {
  count = local.manage_certificate ? 1 : 0

  domain_name               = var.root_domain
  subject_alternative_names = ["*.${var.root_domain}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = var.root_domain
  }
}

resource "aws_route53_record" "cert_validation" {
  # Both the apex and the wildcard validate through one record with the same
  # name and value, so for_each over domain_name collapses them to a single
  # write rather than two resources fighting over one record.
  for_each = local.manage_certificate ? {
    for dvo in aws_acm_certificate.this[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  } : {}

  zone_id         = var.hosted_zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  count = local.manage_certificate ? 1 : 0

  certificate_arn         = aws_acm_certificate.this[0].arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]

  # ACM reads validation records over public DNS. If var.hosted_zone_id is a zone
  # the parent has not delegated — or a private zone — the records exist, resolve
  # for us, and are invisible to ACM. This resource then blocks for 75 minutes
  # before failing, and main.tf puts the whole company module behind the HTTPS
  # listener, so the dashboard goes with it. Check the delegation first:
  #
  #   dig +short NS <root_domain> @8.8.8.8
  #
  # must return this zone's four ns-*.awsdns-* names. If the customer cannot
  # delegate publicly, that is the acm_certificate_arn case, not a longer wait.
  timeouts {
    create = "20m"
  }
}
