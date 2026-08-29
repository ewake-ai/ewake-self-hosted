resource "aws_cloudwatch_log_group" "kubernetes_discovery" {
  name              = "/${var.ssm_path}/kubernetes-discovery"
  retention_in_days = 14
  tags              = local.scheduled_tags
}

resource "aws_lambda_function" "kubernetes_discovery" {
  function_name = "${var.arn_prefix}-kubernetes-discovery"
  description   = "\"kubernetes-discovery\" for ${var.arn_prefix}"
  role          = var.task_role_arn
  package_type  = "Image"
  image_uri     = var.lambda_bundle_image_uri
  # Runs an agentic discovery loop per connected cluster, so it needs more
  # headroom than the deterministic Datadog scrapers.
  timeout     = 900
  memory_size = 1024

  # The bundled image has no CMD, so this is what makes the function run this Lambda.
  image_config {
    command = ["handlers/kubernetes-discovery.handler"]
  }

  environment {
    variables = merge(local.scheduled_lambda_env_common, {
      DD_SERVICE = "kubernetes-discovery"
    })
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.kubernetes_discovery.name
  }

  vpc_config {
    subnet_ids         = var.private_subnets
    security_group_ids = local.vpc_security_group_ids
  }

  tags = merge(local.scheduled_tags, { Service = "kubernetes-discovery" })
}

resource "aws_cloudwatch_log_subscription_filter" "kubernetes_discovery_to_datadog" {
  count           = var.datadog_enabled ? 1 : 0
  name            = "${var.arn_prefix}-kubernetes-discovery-to-datadog"
  log_group_name  = aws_cloudwatch_log_group.kubernetes_discovery.name
  filter_pattern  = ""
  destination_arn = var.datadog_forwarder_arn

  depends_on = [aws_lambda_permission.allow_cloudwatch_kubernetes_discovery]
}

resource "aws_lambda_permission" "allow_cloudwatch_kubernetes_discovery" {
  count         = var.datadog_enabled ? 1 : 0
  statement_id  = "AllowCloudWatchKubernetesDiscovery${substr(sha1(aws_cloudwatch_log_group.kubernetes_discovery.name), 0, 12)}"
  action        = "lambda:InvokeFunction"
  function_name = var.datadog_forwarder_arn
  principal     = "logs.amazonaws.com"
  source_arn    = "${aws_cloudwatch_log_group.kubernetes_discovery.arn}:*"
}
