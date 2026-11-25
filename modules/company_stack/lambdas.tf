locals {
  # Read by the application at process start, as SIMPLE_MODEL, MEDIUM_MODEL and ADVANCED_MODEL.
  # Only the tiers that are set are sent, so an empty llm_models leaves every env map as it was.
  llm_model_env = { for name, id in {
    SIMPLE_MODEL   = var.llm_models.simple
    MEDIUM_MODEL   = var.llm_models.medium
    ADVANCED_MODEL = var.llm_models.advanced
  } : name => id if id != null }

  # The ARN, not the key: the Lambda reads the key at run time, so no env and no state holds it.
  braintrust_lambda_env = var.company.braintrust != null ? merge(
    { BRAINTRUST_API_KEY_SECRET_ARN = var.company.braintrust.api_key_secret_arn },
    var.company.braintrust.project != null ? { BRAINTRUST_PROJECT = var.company.braintrust.project } : {},
    var.company.braintrust.app_url != null ? { BRAINTRUST_APP_URL = var.company.braintrust.app_url } : {},
  ) : {}
}

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

  # What each Lambda reads from Secrets Manager at cold start. A value is a reference in the
  # format of the ECS valueFrom, so the function environment and terraform state hold the ARN
  # of a secret and never what is in it.
  lambda_secret_env = merge(
    {
      POSTGRES_PASSWORD = "${aws_secretsmanager_secret.company_db.arn}:password::"
      NEO4J_PASSWORD    = aws_secretsmanager_secret.company_neo4j_password.arn
    },
    # Header on the Lambda's calls to the internal API of its own reactive server. Without it a
    # finished run cannot report its result.
    local.orchestrator_secret_value_from != null ? {
      ORCHESTRATOR_SECRET = local.orchestrator_secret_value_from
    } : {},
    local.is_byoc ? {} : {
      LANGSMITH_ENDPOINT = "${one(data.aws_secretsmanager_secret.langsmith[*].arn)}:ENDPOINT::"
      LANGSMITH_PROJECT  = "${one(data.aws_secretsmanager_secret.langsmith[*].arn)}:PROJECT::"
      LANGSMITH_API_KEY  = "${one(data.aws_secretsmanager_secret.langsmith[*].arn)}:API_KEY::"
    },
    !local.is_byoc && var.datadog_api_key_secret_arn != null ? {
      DD_API_KEY = var.datadog_api_key_secret_arn
    } : {},
  )
}

module "lambdas" {
  source = "./lambdas"

  # internal_reactive_base_url is a plain string, so nothing else orders these after the ECS
  # service. Until its new deployment is steady the Cloud Map name has no A record, and a
  # Lambda updated first fails every internal call and loses the run to SQS redelivery.
  depends_on = [aws_ecs_service.reactive, aws_lambda_invocation.secret_values]

  company                   = var.company
  tenant_name               = var.tenant_name
  company_base_url          = local.company_base_url
  reactive_lambda_memory_mb = var.reactive_lambda_memory_mb
  llm_model_env             = local.llm_model_env
  braintrust_env            = local.braintrust_lambda_env
  arn_prefix                = local.arn_prefix
  ssm_path                  = local.ssm_path
  task_role_arn             = aws_iam_role.task.arn
  private_subnets           = var.private_subnets
  ecs_task_sg_id            = var.ecs_task_sg_id
  rds_endpoint              = var.rds_endpoint
  rds_port                  = var.rds_port
  neo4j_uri                 = local.neo4j_uri
  neo4j_username            = local.neo4j_username
  deployment_mode           = var.deployment_mode
  datadog_enabled           = !local.is_byoc
  datadog_base_env          = local.datadog_lambda_base_env
  datadog_forwarder_arn     = var.datadog_forwarder_arn
  reactive_image_uri        = var.lambda_image_uris["reactive"]
  aws_region                = data.aws_region.current.name
  sqs_queue_arn             = aws_sqs_queue.lambda.arn
  langsmith_enabled         = !local.is_byoc
  # JWT_SECRET is not read by this function, but the config requires it at import.
  secret_env = merge(local.lambda_secret_env, local.is_byoc ? {
    JWT_SECRET = "${one(aws_secretsmanager_secret.app[*].arn)}:JWT_SECRET::"
  } : {})
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

  # Every handler reads its secrets at cold start, so the values must exist first.
  depends_on = [aws_lambda_invocation.secret_values]

  company                    = var.company
  tenant_name                = var.tenant_name
  arn_prefix                 = local.arn_prefix
  ssm_path                   = local.ssm_path
  task_role_arn              = aws_iam_role.task.arn
  private_subnets            = var.private_subnets
  ecs_task_sg_id             = var.ecs_task_sg_id
  rds_endpoint               = var.rds_endpoint
  rds_port                   = var.rds_port
  neo4j_uri                  = local.neo4j_uri
  neo4j_username             = local.neo4j_username
  secret_env                 = local.lambda_secret_env
  deployment_mode            = var.deployment_mode
  datadog_enabled            = !local.is_byoc
  datadog_base_env           = local.datadog_lambda_base_env
  datadog_forwarder_arn      = var.datadog_forwarder_arn
  langsmith_enabled          = !local.is_byoc
  lambda_bundle_image_uri    = var.lambda_bundle_image_uri
  memory_mb                  = var.scheduled_lambda_memory_mb
  llm_model_env              = local.llm_model_env
  braintrust_env             = local.braintrust_lambda_env
  lambda_queue_url           = aws_sqs_queue.lambda.url
  log_clustering_sidecar_url = local.log_clustering_sidecar_url
  cloudwatch_mcp_url         = local.cloudwatch_mcp_url
  # Reaches the log-clustering sidecar on 8000 and the CloudWatch MCP one on 8931 through the
  # same SG, whose rules log_clustering_sidecar.tf and cloudwatch_mcp.tf self-reference. Every
  # deployment runs the first, so its Lambdas are always inside it.
  internal_sg_id = aws_security_group.internal.id
  # knowledge-graph alone: it asks reactive for a GitHub installation token over the internal API.
  internal_reactive_base_url = local.internal_reactive_base_url
  tags                       = local.tags
}
