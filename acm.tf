# Certificate for var.company_host, issued and DNS-validated here.
#
# Setting var.acm_certificate_arn creates nothing in this file: alb.tf attaches
# that ARN instead, and its renewal is yours.

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
