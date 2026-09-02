# Lambdas owned by company_stack.
#
# `./lambdas` holds the reactive (SQS-triggered) Lambda as a flat .tf file
# inside that child module.
#
# `./lambdas/scheduled` is its own sub-child module — one .tf per scheduled
# Lambda, with the Type=Scheduled tag inherited from a local. Invoked
# directly from this file rather than re-exported through `./lambdas`,
# so we don't carry a thin scheduled.tf wrapper inside lambdas/.

locals {
  datadog_lambda_base_env = !local.is_byoc ? {
    DD_API_KEY_SECRET_ARN      = var.datadog_api_key_secret_arn
    DD_SITE                    = "datadoghq.eu"
    DD_TRACE_ENABLED           = "true"
    DD_SERVERLESS_LOGS_ENABLED = "true"
    DD_ENV                     = "production"
  } : {}
}

module "lambdas" {
  source = "./lambdas"

  # internal_reactive_base_url is a plain string, so nothing else orders these after the ECS
  # service. Until its new deployment is steady the Cloud Map name has no A record, and a
  # Lambda updated first fails every internal call and loses the run to SQS redelivery.
  depends_on = [aws_ecs_service.reactive]

  company                      = var.company
  tenant_name                  = var.tenant_name
  company_base_url             = local.company_base_url
  public_inbound_base_url      = local.public_inbound_base_url
  sso_base_url                 = local.dex_base_url
  arn_prefix                   = local.arn_prefix
  ssm_path                     = local.ssm_path
  task_role_arn                = aws_iam_role.task.arn
  private_subnets              = var.private_subnets
  ecs_task_sg_id               = var.ecs_task_sg_id
  rds_endpoint                 = var.rds_endpoint
  rds_port                     = var.rds_port
  postgres_password            = random_password.company_db.result
  neo4j_uri                    = local.neo4j_uri
  neo4j_username               = local.neo4j_username
  neo4j_password               = random_password.company_neo4j.result
  deployment_mode              = var.deployment_mode
  datadog_enabled              = !local.is_byoc
  datadog_base_env             = local.datadog_lambda_base_env
  datadog_api_key              = one(data.aws_secretsmanager_secret_version.datadog_api_key[*].secret_string)
  datadog_forwarder_arn        = var.datadog_forwarder_arn
  reactive_image_uri           = var.lambda_image_uris["reactive"]
  log_clustering_function_name = var.log_clustering_function_name
  aws_region                   = data.aws_region.current.name
  sqs_queue_arn                = aws_sqs_queue.lambda.arn
  langsmith_enabled            = !local.is_byoc
  langsmith_secret_string      = one(data.aws_secretsmanager_secret_version.langsmith[*].secret_string)
  # Reactive Lambda runs mastra agents whose code tools use GithubService — needs the same creds ECS gets.
  github_app_enabled       = length(data.aws_secretsmanager_secret_version.github_app) > 0
  github_app_secret_string = one(data.aws_secretsmanager_secret_version.github_app[*].secret_string)
  # Header on reactive-Lambda self-calls to the internal API; without it a finished run cannot report its result.
  # Ternary, not coalesce — coalesce(null, "") throws.
  orchestrator_secret = local.is_byoc ? random_password.orchestrator_secret[0].result : (
    var.orchestrator_internal_token_secret_arn != null ? one(data.aws_secretsmanager_secret_version.orchestrator_internal_token[*].secret_string) : ""
  )
  jwt_secret                 = local.is_byoc ? random_password.jwt_secret[0].result : ""
  elasticsearch_enabled      = local.elasticsearch_enabled
  elasticsearch_url          = local.elasticsearch_enabled ? data.aws_ssm_parameter.elasticsearch_url[0].value : null
  elasticsearch_api_key      = local.elasticsearch_enabled ? data.aws_ssm_parameter.elasticsearch_api_key[0].value : null
  cloudwatch_mcp_url         = local.cloudwatch_mcp_url
  log_clustering_sidecar_url = local.log_clustering_sidecar_url
  internal_reactive_base_url = local.internal_reactive_base_url
  internal_sg_id             = aws_security_group.internal.id
  tags                       = local.tags
}

module "scheduled_lambdas" {
  source = "./lambdas/scheduled"

  company                 = var.company
  tenant_name             = var.tenant_name
  company_base_url        = local.company_base_url
  public_inbound_base_url = local.public_inbound_base_url
  sso_base_url            = local.dex_base_url
  arn_prefix              = local.arn_prefix
  ssm_path                = local.ssm_path
  task_role_arn           = aws_iam_role.task.arn
  private_subnets         = var.private_subnets
  ecs_task_sg_id          = var.ecs_task_sg_id
  rds_endpoint            = var.rds_endpoint
  rds_port                = var.rds_port
  postgres_password       = random_password.company_db.result
  neo4j_uri               = local.neo4j_uri
  neo4j_username          = local.neo4j_username
  neo4j_password          = random_password.company_neo4j.result
  deployment_mode         = var.deployment_mode
  datadog_enabled         = !local.is_byoc
  datadog_base_env        = local.datadog_lambda_base_env
  datadog_forwarder_arn   = var.datadog_forwarder_arn
  langsmith_enabled       = !local.is_byoc
  langsmith_secret_string = one(data.aws_secretsmanager_secret_version.langsmith[*].secret_string)
  # knowledge-graph is the only scheduled Lambda that uses GithubService today; the child module scopes injection to it.
  github_app_enabled           = length(data.aws_secretsmanager_secret_version.github_app) > 0
  github_app_secret_string     = one(data.aws_secretsmanager_secret_version.github_app[*].secret_string)
  datadog_api_key              = one(data.aws_secretsmanager_secret_version.datadog_api_key[*].secret_string)
  lambda_bundle_image_uri      = var.lambda_bundle_image_uri
  lambda_queue_url             = aws_sqs_queue.lambda.url
  log_clustering_function_name = var.log_clustering_function_name
  log_clustering_sidecar_url   = local.log_clustering_sidecar_url
  internal_sg_id               = local.log_clustering_sidecar_enabled ? aws_security_group.internal.id : null
  jwt_secret                   = local.is_byoc ? random_password.jwt_secret[0].result : ""
  orchestrator_secret = local.is_byoc ? random_password.orchestrator_secret[0].result : (
    var.orchestrator_internal_token_secret_arn != null ? one(data.aws_secretsmanager_secret_version.orchestrator_internal_token[*].secret_string) : ""
  )
  tags = local.tags
}
