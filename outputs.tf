output "dashboard_url" {
  description = "Public URL of the reactive dashboard. Log in via the OIDC IdP configured in company_stack (see PR #3014 stack)."
  value       = "https://${var.company.name}.${var.root_domain}"
}

output "alb_dns_name" {
  description = "Public DNS of the tenant ALB. Point var.root_domain (or a subdomain) here in Route53 — the module already creates <company>.<root_domain>."
  value       = aws_lb.this.dns_name
}

output "rds_endpoint" {
  description = "RDS Postgres endpoint. Not publicly reachable — provided for operator diagnostics via aws ecs execute-command."
  value       = aws_db_instance.this.address
}
