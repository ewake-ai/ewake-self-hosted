# Every scheduled Lambda as one function. Its handler reads `lambda` from the schedule payload
# and loads that folder's bundle, so the twelve differ only by what the schedule sends.
#
# Added beside the per-agent functions rather than replacing them: the dashboard service
# repoints the existing schedules onto this ARN when it restarts, and it can only do that
# while both exist. See UPGRADING.md.

resource "aws_cloudwatch_log_group" "scheduled" {
  name              = "/${var.ssm_path}/scheduled"
  retention_in_days = 14
  tags              = local.scheduled_tags
}

locals {
  scheduled_env = merge(local.scheduled_lambda_env_common, local.flag_env, {
    # One function, so one value: a run's own identity reaches Datadog through the `service`
    # attribute each Lambda already logs.
    DD_SERVICE       = "scheduled"
    LAMBDA_QUEUE_URL = var.lambda_queue_url
    # knowledge-graph alone reads GitHub, and asks reactive for an installation token rather than
    # holding the App signing key. It shares this function, so the pair reaches all twelve.
    INTERNAL_BASE_URL   = var.internal_reactive_base_url
    ORCHESTRATOR_SECRET = var.orchestrator_secret
  })
}

resource "aws_lambda_function" "scheduled" {
  function_name = "${var.arn_prefix}-scheduled"
  description   = "Every scheduled Lambda for ${var.arn_prefix}; the schedule payload names which one runs."
  role          = var.task_role_arn
  package_type  = "Image"
  image_uri     = var.lambda_bundle_image_uri

  # The ceiling of the twelve it serves: knowledge-graph and the log surveys need the full 900s,
  # and datadog/loki-log-analysis need 2048MB.
  timeout     = 900
  memory_size = 2048

  # Restates the image's own CMD: the deploy reads the function's configuration, not the image,
  # to tell which ECR repository re-points it.
  image_config {
    command = ["entrypoint.handler"]
  }

  environment {
    variables = local.scheduled_env
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.scheduled.name
  }

  vpc_config {
    subnet_ids         = var.private_subnets
    security_group_ids = local.vpc_security_group_ids
  }

  tags = merge(local.scheduled_tags, { Service = "scheduled" })

  lifecycle {
    ignore_changes = [image_uri]

    # Agentless resolves its endpoint from DD_SITE and authenticates with DD_API_KEY, and a wrong or
    # missing one fails terminally and silently: 401/403 is never retried and nothing is logged.
    precondition {
      condition = lookup(local.scheduled_env, "DD_FEATURE_FLAGS_CONFIGURATION_SOURCE", null) != "agentless" || (
        lookup(local.scheduled_env, "DD_SITE", null) != null &&
        var.datadog_api_key != null && var.datadog_api_key != ""
      )
      error_message = "scheduled sets agentless feature flags without DD_SITE and DD_API_KEY in the same env."
    }
  }
}
