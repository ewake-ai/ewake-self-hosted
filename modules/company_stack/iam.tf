# Task / Lambda role. Every ARN is prefixed with
# ${project}/${tenant}/${name} so the role can only reach its own resources.

data "aws_iam_policy_document" "task_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com", "lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "task" {
  name               = "${local.arn_prefix}-task"
  assume_role_policy = data.aws_iam_policy_document.task_assume.json

  tags = local.tags
}

data "aws_secretsmanager_secret" "grafana" {
  count = local.is_byoc ? 0 : 1
  name  = "grafana"
}

data "aws_iam_policy_document" "task" {
  statement {
    sid     = "Logs"
    actions = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [
      "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/${local.ssm_path}/*"
    ]
  }

  statement {
    sid     = "SSMParamsScopedToCompany"
    actions = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = [
      "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter/${local.ssm_path}/*",
      "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter/${var.project_name}/global/*"
    ]
  }

  # The path where the app creates, rotates and deletes integration secrets.
  statement {
    sid = "SecretsScopedToCompany"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
      "secretsmanager:CreateSecret",
      "secretsmanager:UpdateSecret",
      "secretsmanager:PutSecretValue",
      "secretsmanager:DeleteSecret",
      "secretsmanager:RestoreSecret",
      "secretsmanager:TagResource"
    ]
    resources = [
      "arn:aws:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:${local.ssm_path}/*"
    ]
  }

  dynamic "statement" {
    for_each = length(local.shared_secret_arns) > 0 ? [local.shared_secret_arns] : []
    content {
      sid       = "SharedSecretsReadOnly"
      actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      resources = statement.value
    }
  }

  statement {
    sid     = "SQSScopedToCompany"
    actions = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:SendMessage"]
    resources = [
      "arn:aws:sqs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:${local.arn_prefix}-*"
    ]
  }

  statement {
    sid     = "S3ScopedToCompany"
    actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
    resources = [
      "arn:aws:s3:::${local.arn_prefix}-*",
      "arn:aws:s3:::${local.arn_prefix}-*/*",
      "arn:aws:s3:::${var.company.public_id}-*",
      "arn:aws:s3:::${var.company.public_id}-*/*"
    ]
  }

  # Write to the <tenant>/<company name>/ prefix in the database-dumps bucket.
  statement {
    sid     = "DatabaseDumpsScopedToCompany"
    actions = ["s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload"]
    resources = [
      "arn:aws:s3:::${var.project_name}-database-dumps/${var.tenant_name}/${var.company.name}/*"
    ]
  }

  statement {
    sid       = "IngestionReadScopedToCompany"
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::${var.project_name}-ingestion/${var.tenant_name}/${var.company.name}/*"]
  }

  # Directory-mode ingestion needs list access; the s3:prefix condition scopes it.
  statement {
    sid       = "IngestionListScopedToCompany"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.project_name}-ingestion"]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${var.tenant_name}/${var.company.name}/*"]
    }
  }

  statement {
    sid       = "ECRReadOnly"
    actions   = ["ecr:GetAuthorizationToken", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
    resources = ["*"] # ECR auth requires "*"; the specific repos are restricted below
  }

  statement {
    sid       = "InvokeLogClustering"
    actions   = ["lambda:InvokeFunction"]
    resources = [var.log_clustering_function_arn]
  }

  statement {
    sid       = "BedrockInvoke"
    actions   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
    resources = ["*"]
  }

  statement {
    sid       = "VPCNetworking"
    actions   = ["ec2:CreateNetworkInterface", "ec2:DescribeNetworkInterfaces", "ec2:DeleteNetworkInterface"]
    resources = ["*"]
  }

  statement {
    sid     = "SchedulerSchedulesScopedToCompany"
    actions = ["scheduler:CreateSchedule", "scheduler:UpdateSchedule", "scheduler:DeleteSchedule", "scheduler:GetSchedule"]
    resources = [
      "arn:aws:scheduler:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:schedule/${local.arn_prefix}/*"
    ]
  }

  statement {
    sid     = "PassEventBridgeSchedulerRole"
    actions = ["iam:PassRole"]
    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/Amazon_EventBridge_Scheduler_LAMBDA_${local.arn_prefix}",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/Amazon_EventBridge_Scheduler_SQS_${local.arn_prefix}"
    ]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["scheduler.amazonaws.com"]
    }
  }

  statement {
    sid       = "SchedulerListSchedules"
    actions   = ["scheduler:ListSchedules"]
    resources = ["*"]
  }

  statement {
    sid       = "AssumeCustomerCloudWatchRole"
    actions   = ["sts:AssumeRole"]
    resources = ["arn:aws:iam::*:role/EwakeCloudWatchReadOnly*"]
  }

  # Backs `aws ecs execute-command --interactive`. The SSM messages API is
  # account-scoped only — Amazon does not expose a per-resource ARN for it.
  statement {
    sid = "ECSExecuteCommandChannel"
    actions = [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "task" {
  name   = "${local.arn_prefix}-task-policy"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task.json
}

resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.task.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_insights" {
  role       = aws_iam_role.task.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchLambdaInsightsExecutionRolePolicy"
}
