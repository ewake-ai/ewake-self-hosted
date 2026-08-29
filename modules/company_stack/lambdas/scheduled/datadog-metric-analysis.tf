resource "aws_cloudwatch_log_group" "datadog_metric_analysis" {
  name              = "/${var.ssm_path}/datadog-metric-analysis"
  retention_in_days = 14
  tags              = local.scheduled_tags
}

resource "aws_lambda_function" "datadog_metric_analysis" {
  function_name = "${var.arn_prefix}-datadog-metric-analysis"
  description   = "\"datadog-metric-analysis\" for ${var.arn_prefix}"
  role          = var.task_role_arn
  package_type  = "Image"
  image_uri     = var.lambda_bundle_image_uri
  timeout       = 300
  memory_size   = 512

  # The bundled image has no CMD, so this is what makes the function run this Lambda.
  image_config {
    command = ["handlers/datadog-metric-analysis.handler"]
  }

  environment {
    variables = merge(local.scheduled_lambda_env_common, {
      DD_SERVICE = "datadog-metric-analysis"
    })
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.datadog_metric_analysis.name
  }

  vpc_config {
    subnet_ids         = var.private_subnets
    security_group_ids = local.vpc_security_group_ids
  }

  tags = merge(local.scheduled_tags, { Service = "datadog-metric-analysis" })
}

resource "aws_cloudwatch_log_subscription_filter" "datadog_metric_analysis_to_datadog" {
  count           = var.datadog_enabled ? 1 : 0
  name            = "${var.arn_prefix}-datadog-metric-analysis-to-datadog"
  log_group_name  = aws_cloudwatch_log_group.datadog_metric_analysis.name
  filter_pattern  = ""
  destination_arn = var.datadog_forwarder_arn
}
