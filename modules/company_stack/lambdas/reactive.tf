# Reactive processor Lambda. SQS-triggered (batch_size=1). Packaged as
# a container image so it can bundle the Datadog Lambda extension and tracer.

locals {
  langsmith_secret = var.langsmith_enabled ? jsondecode(var.langsmith_secret_string) : null

  # Mastra code agent tools running here use GithubService/appAuth.ts.
  github_app_secret = var.github_app_enabled ? jsondecode(var.github_app_secret_string) : null

  reactive_datadog_env = var.datadog_enabled ? merge(var.datadog_base_env, {
    # Agentless because dd-trace force-disables remote config under IS_SERVERLESS, whatever the extension carries.
    DD_FEATURE_FLAGS_ENABLED                                              = "true"
    DD_FEATURE_FLAGS_CONFIGURATION_SOURCE                                 = "agentless"
    DD_FEATURE_FLAGS_CONFIGURATION_SOURCE_AGENTLESS_POLL_INTERVAL_SECONDS = "300"
    DD_API_KEY                                                            = var.datadog_api_key
    # datadog-lambda-js inits the tracer first, so the provider is built before app code can pass its own timeout.
    DD_EXPERIMENTAL_FLAGGING_PROVIDER_INITIALIZATION_TIMEOUT_MS = "3000"
    }) : {
    # Stated, not omitted: the tracer defaults to enabled and agentless, so silence buys a 30s stall on every cold start.
    DD_FEATURE_FLAGS_ENABLED = "false"
    # With no agent to receive spans, an initialised tracer would export to a port nothing listens on.
    DD_TRACE_ENABLED = "false"
  }
}

resource "aws_cloudwatch_log_group" "reactive" {
  name              = "/${var.ssm_path}/reactive-lambda"
  retention_in_days = 14
  tags              = var.tags
}

resource "aws_lambda_function" "reactive_processor" {
  function_name                  = "${var.arn_prefix}-reactive"
  description                    = "\"reactive\" for ${var.arn_prefix}"
  role                           = var.task_role_arn
  package_type                   = "Image"
  image_uri                      = var.reactive_image_uri
  timeout                        = 900
  memory_size                    = 2048
  reserved_concurrent_executions = 8

  environment {
    variables = merge(
      {
        NODE_ENV       = "production"
        EWAKE_BASE_URL = var.internal_reactive_base_url
        # Same value, named for the job: reactiveClient.ts reads internalBaseURL, and this hop
        # must not resolve the ALB and hairpin back out.
        INTERNAL_BASE_URL = var.internal_reactive_base_url
        # Unread here, but required at config import.
        PUBLIC_INBOUND_BASE_URL = var.public_inbound_base_url
        DASHBOARD_BASE_URL      = var.company_base_url
        SSO_BASE_URL            = var.sso_base_url
        # --disable-warning=DEP0040: see scheduled/locals.tf for rationale.
        NODE_OPTIONS      = "--enable-source-maps --disable-warning=DEP0040"
        CLIENT            = var.company.name
        TENANT            = var.tenant_name
        COMPANY_DOMAIN    = var.company.domain
        DD_SERVICE        = "reactive-lambda"
        POSTGRES_HOST     = var.rds_endpoint
        POSTGRES_PORT     = tostring(var.rds_port)
        POSTGRES_DB       = var.company.public_id
        POSTGRES_USER     = "${var.company.name}_app"
        POSTGRES_PASSWORD = var.postgres_password
        # Above the Lambda default of 2 — the agent loop drains background tasks
        # concurrently with agent storage. The connection budget is shared across all runtimes.
        POSTGRES_POOL_MAX            = "5"
        NEO4J_URI                    = var.neo4j_uri
        NEO4J_USERNAME               = var.neo4j_username
        NEO4J_PASSWORD               = var.neo4j_password
        LOG_CLUSTERING_FUNCTION_NAME = var.log_clustering_function_name
        JWT_SECRET                   = var.jwt_secret
      },
      # Empty only before shared/ has been applied, and the server gates the
      # internal API on it either way — so an empty string would fail closed at the first result post.
      var.orchestrator_secret != "" ? {
        ORCHESTRATOR_SECRET = var.orchestrator_secret
      } : {},
      local.reactive_datadog_env,
      var.langsmith_enabled ? {
        LANGSMITH_TRACING  = "true"
        LANGSMITH_ENDPOINT = local.langsmith_secret["ENDPOINT"]
        LANGSMITH_PROJECT  = local.langsmith_secret["PROJECT"]
        LANGSMITH_API_KEY  = local.langsmith_secret["API_KEY"]
      } : {},
      var.github_app_enabled ? {
        GITHUB_CLIENT_ID       = local.github_app_secret["CLIENT_ID"]
        GITHUB_CLIENT_SECRET   = local.github_app_secret["CLIENT_SECRET"]
        GITHUB_APP_PRIVATE_KEY = local.github_app_secret["APP_PRIVATE_KEY"]
      } : {},
      var.elasticsearch_enabled ? {
        ELASTICSEARCH_URL     = var.elasticsearch_url
        ELASTICSEARCH_API_KEY = var.elasticsearch_api_key
      } : {},
      var.company.features.cloudwatchMcpSidecar && var.cloudwatch_mcp_url != null ? {
        CLOUDWATCH_MCP_SERVER_URL = var.cloudwatch_mcp_url
      } : {},
      var.log_clustering_sidecar_url != null ? {
        LOG_CLUSTERING_SIDECAR_URL = var.log_clustering_sidecar_url
      } : {}
    )
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.reactive.name
  }

  vpc_config {
    subnet_ids         = var.private_subnets
    security_group_ids = [var.ecs_task_sg_id, var.internal_sg_id]
  }

  tags = merge(var.tags, {
    Service = "reactive-lambda"
  })

  lifecycle {
    # Agentless resolves its endpoint from DD_SITE and authenticates with DD_API_KEY, and a missing or
    # wrong one fails terminally and silently: 401/403 is never retried and nothing is logged.
    precondition {
      condition = lookup(local.reactive_datadog_env, "DD_FEATURE_FLAGS_CONFIGURATION_SOURCE", null) != "agentless" || (
        lookup(local.reactive_datadog_env, "DD_SITE", null) != null &&
        var.datadog_api_key != null && var.datadog_api_key != ""
      )
      error_message = "reactive Lambda sets agentless feature flags without DD_SITE and DD_API_KEY in the same env."
    }
  }
}

resource "aws_lambda_event_source_mapping" "reactive_sqs" {
  event_source_arn        = var.sqs_queue_arn
  function_name           = aws_lambda_function.reactive_processor.arn
  batch_size              = 1
  function_response_types = ["ReportBatchItemFailures"]
}

resource "aws_lambda_permission" "reactive_sqs" {
  statement_id  = "AllowExecutionFromSQS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.reactive_processor.function_name
  principal     = "sqs.amazonaws.com"
  source_arn    = var.sqs_queue_arn
}
