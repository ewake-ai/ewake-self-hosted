resource "aws_cloudwatch_log_group" "knowledge_graph" {
  name              = "/${var.ssm_path}/knowledge-graph"
  retention_in_days = 14
  tags              = local.scheduled_tags
}

locals {
  # Only knowledge-graph among the scheduled Lambdas imports GithubService, so the other scheduled Lambdas don't get these env keys.
  knowledge_graph_github_env = var.github_app_enabled ? {
    GITHUB_CLIENT_ID       = jsondecode(var.github_app_secret_string)["CLIENT_ID"]
    GITHUB_CLIENT_SECRET   = jsondecode(var.github_app_secret_string)["CLIENT_SECRET"]
    GITHUB_APP_PRIVATE_KEY = jsondecode(var.github_app_secret_string)["APP_PRIVATE_KEY"]
  } : {}

  # Only knowledge-graph registers a flag provider, so the other scheduled Lambdas get neither these keys nor the API key.
  # Agentless because this is the one runtime with neither an agent nor an extension to carry remote config.
  # Gated on the bool, never on the key: a condition over a sensitive value marks the whole env map sensitive.
  knowledge_graph_flag_env = var.datadog_enabled ? {
    DD_FEATURE_FLAGS_ENABLED                                              = "true"
    DD_FEATURE_FLAGS_CONFIGURATION_SOURCE                                 = "agentless"
    DD_FEATURE_FLAGS_CONFIGURATION_SOURCE_AGENTLESS_POLL_INTERVAL_SECONDS = "300"
    DD_API_KEY                                                            = var.datadog_api_key
    } : {
    # Stated, not omitted: the tracer defaults to enabled and agentless, so silence buys a 30s stall on every cold start.
    DD_FEATURE_FLAGS_ENABLED = "false"
    # With no agent to receive spans, an initialised tracer would export to a port nothing listens on.
    DD_TRACE_ENABLED = "false"
  }

  knowledge_graph_env = merge(local.scheduled_lambda_env_common, local.knowledge_graph_github_env, local.knowledge_graph_flag_env, {
    DD_SERVICE = "knowledge-graph"
  })
}

resource "aws_lambda_function" "knowledge_graph" {
  function_name = "${var.arn_prefix}-knowledge-graph"
  description   = "\"knowledge-graph\" for ${var.arn_prefix}"
  role          = var.task_role_arn
  package_type  = "Image"
  image_uri     = var.lambda_bundle_image_uri
  timeout       = 900
  memory_size   = 1024

  # The bundled image has no CMD, so this is what makes the function run this Lambda.
  image_config {
    command = ["handlers/knowledge-graph.handler"]
  }

  environment {
    variables = local.knowledge_graph_env
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.knowledge_graph.name
  }

  vpc_config {
    subnet_ids         = var.private_subnets
    security_group_ids = local.vpc_security_group_ids
  }

  tags = merge(local.scheduled_tags, { Service = "knowledge-graph" })

  lifecycle {
    # Agentless resolves its endpoint from DD_SITE and authenticates with DD_API_KEY, and a wrong or
    # missing one fails terminally and silently: 401/403 is never retried and nothing is logged.
    precondition {
      condition = lookup(local.knowledge_graph_env, "DD_FEATURE_FLAGS_CONFIGURATION_SOURCE", null) != "agentless" || (
        lookup(local.knowledge_graph_env, "DD_SITE", null) != null &&
        var.datadog_api_key != null && var.datadog_api_key != ""
      )
      error_message = "knowledge-graph sets agentless feature flags without DD_SITE and DD_API_KEY in the same env."
    }
  }
}

resource "aws_cloudwatch_log_subscription_filter" "knowledge_graph_to_datadog" {
  count           = var.datadog_enabled ? 1 : 0
  name            = "${var.arn_prefix}-knowledge-graph-to-datadog"
  log_group_name  = aws_cloudwatch_log_group.knowledge_graph.name
  filter_pattern  = ""
  destination_arn = var.datadog_forwarder_arn
}
