resource "aws_scheduler_schedule_group" "company" {
  name = local.arn_prefix

  tags = local.tags
}

data "aws_iam_policy_document" "scheduler_sqs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "scheduler_sqs" {
  name               = "Amazon_EventBridge_Scheduler_SQS_${local.arn_prefix}"
  assume_role_policy = data.aws_iam_policy_document.scheduler_sqs_assume.json

  tags = local.tags
}

data "aws_iam_policy_document" "scheduler_sqs" {
  statement {
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.lambda.arn]
  }
}

resource "aws_iam_role_policy" "scheduler_sqs" {
  name   = "Amazon_EventBridge_Scheduler_SQS_${local.arn_prefix}-send"
  role   = aws_iam_role.scheduler_sqs.id
  policy = data.aws_iam_policy_document.scheduler_sqs.json
}
