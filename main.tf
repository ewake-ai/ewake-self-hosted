# Single instantiation of company_stack for this deployment.

module "company" {
  source = "./modules/company_stack"

  company = var.company

  project_name    = "ewake"
  deployment_mode = "byoc"
  tenant_name     = var.tenant_name
  root_domain     = var.root_domain
  company_host    = local.company_host
  # null falls through to the module's own default, the company host.
  public_inbound_base_url        = try(coalesce(var.public_inbound_base_url, local.gateway_base_url), null)
  orchestrator_url               = null
  admin_notify_url               = null
  hosted_zone_id                 = var.hosted_zone_id
  extra_host_headers             = var.alb_extra_host_headers
  aws_region                     = var.aws_region
  common_tags                    = local.common_tags
  vpc_id                         = aws_vpc.this.id
  private_subnets                = aws_subnet.private[*].id
  ecs_cluster_arn                = aws_ecs_cluster.this.arn
  alb_arn                        = aws_lb.this.arn
  alb_dns_name                   = aws_lb.this.dns_name
  alb_zone_id                    = aws_lb.this.zone_id
  alb_listener_arn               = aws_lb_listener.https.arn
  ecs_task_sg_id                 = aws_security_group.ecs_task.id
  rds_endpoint                   = aws_db_instance.this.address
  rds_resource_id                = aws_db_instance.this.resource_id
  rds_port                       = aws_db_instance.this.port
  rds_master_secret_arn          = aws_secretsmanager_secret.rds_master.arn
  bootstrap_lambda_function_name = aws_lambda_function.bootstrap.function_name
  log_clustering_function_name   = aws_lambda_function.log_clustering.function_name
  log_clustering_function_arn    = aws_lambda_function.log_clustering.arn
  datadog_forwarder_arn          = null
  datadog_api_key_secret_arn     = null
  datadog_pg_secret_arn          = null
  ecr_repository_urls            = local.ecr_repository_urls
  reactive_service_image_uri     = "${local.ecr_repository_urls["reactive"]}:${local.app_image_tag}"
  # The service image, not ewake-db-migrate: one build serves and migrates, so app_image_tag
  # cannot pin a server against another commit's schema. db_migrate.tf supplies the command.
  db_migrate_image_uri    = "${local.ecr_repository_urls["reactive"]}:${local.app_image_tag}"
  lambda_image_uris       = local.lambda_image_uris
  lambda_bundle_image_uri = local.lambda_bundle_image_uri
  neo4j_instance_type     = var.neo4j_instance_type

  depends_on = [
    aws_db_instance.this,
    aws_lb_listener.https,
    aws_lambda_function.bootstrap,
    aws_iam_role.dlm_default,
  ]
}
