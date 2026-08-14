resource "aws_cloudwatch_log_group" "incident_indexing" {
  name              = "/${var.ssm_path}/incident-indexing"
  retention_in_days = 14
  tags              = local.scheduled_tags
}

resource "aws_lambda_function" "incident_indexing" {
  function_name = "${var.arn_prefix}-incident-indexing"
  description   = "\"incident-indexing\" for ${var.arn_prefix}"
  role          = var.task_role_arn
  package_type  = "Image"
  image_uri     = var.incident_indexing_image_uri
  timeout       = 300
  memory_size   = 1024

  environment {
    variables = merge(local.scheduled_lambda_env_common, {
      DD_SERVICE = "incident-indexing"
    })
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.incident_indexing.name
  }

  vpc_config {
    subnet_ids         = var.private_subnets
    security_group_ids = local.vpc_security_group_ids
  }

  tags = merge(local.scheduled_tags, { Service = "incident-indexing" })

  lifecycle {
    ignore_changes = [image_uri]
  }
}

resource "aws_cloudwatch_log_subscription_filter" "incident_indexing_to_datadog" {
  count           = var.datadog_enabled ? 1 : 0
  name            = "${var.arn_prefix}-incident-indexing-to-datadog"
  log_group_name  = aws_cloudwatch_log_group.incident_indexing.name
  filter_pattern  = ""
  destination_arn = var.datadog_forwarder_arn
}
