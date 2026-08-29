resource "aws_cloudwatch_log_group" "loki_log_analysis" {
  name              = "/${var.ssm_path}/loki-log-analysis"
  retention_in_days = 14
  tags              = local.scheduled_tags
}

resource "aws_lambda_function" "loki_log_analysis" {
  function_name = "${var.arn_prefix}-loki-log-analysis"
  description   = "\"loki-log-analysis\" for ${var.arn_prefix}"
  role          = var.task_role_arn
  package_type  = "Image"
  image_uri     = var.lambda_bundle_image_uri
  timeout       = 900
  memory_size   = 2048

  # The bundled image has no CMD, so this is what makes the function run this Lambda.
  image_config {
    command = ["handlers/loki-log-analysis.handler"]
  }

  environment {
    variables = merge(local.scheduled_lambda_env_common, {
      DD_SERVICE = "loki-log-analysis"
    })
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.loki_log_analysis.name
  }

  vpc_config {
    subnet_ids         = var.private_subnets
    security_group_ids = local.vpc_security_group_ids
  }

  tags = merge(local.scheduled_tags, { Service = "loki-log-analysis" })
}

resource "aws_cloudwatch_log_subscription_filter" "loki_log_analysis_to_datadog" {
  count           = var.datadog_enabled ? 1 : 0
  name            = "${var.arn_prefix}-loki-log-analysis-to-datadog"
  log_group_name  = aws_cloudwatch_log_group.loki_log_analysis.name
  filter_pattern  = ""
  destination_arn = var.datadog_forwarder_arn
}
