resource "aws_iam_role" "log_clustering" {
  name = "${var.tenant_name}-log-clustering"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "log_clustering" {
  name = "${var.tenant_name}-log-clustering"
  role = aws_iam_role.log_clustering.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "Logs"
      Effect = "Allow"
      Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = [
        "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.tenant_name}-log-clustering*"
      ]
    }]
  })
}

resource "aws_cloudwatch_log_group" "log_clustering" {
  name              = "/aws/lambda/${var.tenant_name}-log-clustering"
  retention_in_days = 14
}

resource "aws_lambda_function" "log_clustering" {
  function_name = "${var.tenant_name}-log-clustering"
  description   = "drain3 log clustering for the ${var.tenant_name} deployment"
  role          = aws_iam_role.log_clustering.arn
  package_type  = "Image"
  # CI only publishes this Lambda under :latest, not per release channel.
  image_uri   = "${local.ewake_ecr_registry}/ewake-lambda-log-clustering:latest"
  timeout     = 30
  memory_size = 1024

  environment {
    variables = {
      TENANT     = var.tenant_name
      DD_SERVICE = "log-clustering"
    }
  }

  depends_on = [
    aws_iam_role_policy.log_clustering,
    aws_cloudwatch_log_group.log_clustering
  ]

  lifecycle {
    ignore_changes = [image_uri]
  }
}
