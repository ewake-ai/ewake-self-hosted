output "dashboard_url" {
  description = "Public URL of the dashboard. Log in via the OIDC IdP configured in company_stack."
  value       = "https://${local.company_host}"
}

output "alb_dns_name" {
  description = "DNS name of the tenant ALB. Terraform already creates the A alias for var.company_host when var.hosted_zone_id is set; when it is null this is the value to point the hostname at."
  value       = aws_lb.this.dns_name
}

output "vpc_id" {
  description = "ID of the VPC this deployment created. Needed when a transit gateway attachment has to be identified or accepted from the gateway owner's account."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "Primary CIDR of the VPC. The network on the other side of a transit gateway needs a route back to this range."
  value       = aws_vpc.this.cidr_block
}

output "dns_wiring" {
  description = <<-EOT
    Everything the edge depends on, in one place, whether or not Terraform owns
    it. Read this before changing DNS and after any apply that touched the
    listener — `terraform output -json dns_wiring` is the record of what the
    values were when the deployment last worked.

    managed_by_terraform tells you which half is ours. Where it says "customer",
    the value under `create_manually` is what somebody has to keep alive by hand,
    and nothing in this stack will notice if it lapses.
  EOT
  value = {
    host        = local.company_host
    dashboard   = "https://${local.company_host}"
    alb_dns     = aws_lb.this.dns_name
    alb_zone_id = aws_lb.this.zone_id
    alb_scheme  = var.alb_internal ? "internal" : "internet-facing"

    dns = {
      managed_by_terraform = local.manage_dns
      hosted_zone_id       = var.hosted_zone_id
      create_manually = local.manage_dns ? null : {
        name = local.company_host
        type = "A (alias) or CNAME"
        # An alias needs a Route53 zone; anywhere else, CNAME the ALB name.
        # An internal ALB resolves to private addresses, so the record is only
        # useful from inside the network that reaches them.
        value = aws_lb.this.dns_name
        alias = { dns_name = aws_lb.this.dns_name, hosted_zone_id = aws_lb.this.zone_id }
        note  = "Apex records cannot be CNAMEs. On a non-Route53 provider without ALIAS/ANAME support, serve the dashboard from a subdomain instead."
      }
    }

    certificate = {
      managed_by_terraform = local.manage_certificate
      arn                  = local.certificate_arn
      # The record ACM re-reads at renewal. When we own the zone this is already
      # in place; when the customer does, deleting it silently breaks renewal
      # roughly eleven months later.
      renewal_validation = local.manage_certificate ? [
        for dvo in aws_acm_certificate.this[0].domain_validation_options : {
          domain = dvo.domain_name
          name   = dvo.resource_record_name
          type   = dvo.resource_record_type
          value  = dvo.resource_record_value
        }
      ] : null
      extra_sni_arns = var.extra_certificate_arns
    }

    listener = {
      arn          = aws_lb_listener.https.arn
      host_headers = concat([local.company_host], var.alb_extra_host_headers)
    }
  }
}

output "manual_dns_steps" {
  description = "Human-readable form of dns_wiring's outstanding work. Empty when Terraform owns both halves of the edge."
  value = compact([
    local.manage_dns ? "" : "Create ${local.company_host} -> ${aws_lb.this.dns_name} (A alias, zone ${aws_lb.this.zone_id}${var.alb_internal ? "; ALB is internal, so resolve it from inside the network" : ""}).",
    local.manage_certificate ? "" : "Certificate ${var.acm_certificate_arn} is customer-issued: keep its ACM validation CNAME in place or renewal fails silently.",
    local.manage_certificate && !local.manage_dns ? "Unreachable state: Terraform issued the certificate but does not own the zone." : "",
  ])
}

output "rds_endpoint" {
  description = "RDS Postgres endpoint. Not publicly reachable — provided for operator diagnostics via aws ecs execute-command."
  value       = aws_db_instance.this.address
}

output "public_inbound_url" {
  description = "The public entry point Slack and Datadog are registered against, when public_inbound_gateway is on. Null otherwise, and the company host serves those paths itself."
  value       = local.gateway_base_url
}
