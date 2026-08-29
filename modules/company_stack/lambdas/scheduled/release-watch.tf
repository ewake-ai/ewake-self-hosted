# No static event rule — reactive creates a per-deployment schedule at ingest time.

variable "lambda_queue_url" {
  description = "URL of the reactive SQS queue. Release-watch publishes RELEASE_WATCH_ALERT messages here for reactive-lambda to pick up."
  type        = string
}

resource "aws_cloudwatch_log_group" "release_watch" {
  name              = "/${var.ssm_path}/release-watch"
  retention_in_days = 14
  tags              = local.scheduled_tags
}

resource "aws_lambda_function" "release_watch" {
  function_name = "${var.arn_prefix}-release-watch"
  description   = "\"release-watch\" for ${var.arn_prefix}"
  role          = var.task_role_arn
  package_type  = "Image"
  image_uri     = var.lambda_bundle_image_uri
  timeout       = 300
  memory_size   = 1024

  # The bundled image has no CMD, so this is what makes the function run this Lambda.
  image_config {
    command = ["handlers/release-watch.handler"]
  }

  environment {
    variables = merge(local.scheduled_lambda_env_common, {
      DD_SERVICE       = "release-watch"
      LAMBDA_QUEUE_URL = var.lambda_queue_url
    })
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.release_watch.name
  }

  vpc_config {
    subnet_ids         = var.private_subnets
    security_group_ids = local.vpc_security_group_ids
  }

  tags = merge(local.scheduled_tags, { Service = "release-watch" })
}

resource "aws_cloudwatch_log_subscription_filter" "release_watch_to_datadog" {
  count           = var.datadog_enabled ? 1 : 0
  name            = "${var.arn_prefix}-release-watch-to-datadog"
  log_group_name  = aws_cloudwatch_log_group.release_watch.name
  filter_pattern  = ""
  destination_arn = var.datadog_forwarder_arn
}
