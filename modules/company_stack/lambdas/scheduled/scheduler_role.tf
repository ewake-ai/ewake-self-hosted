# Role assumed by EventBridge Scheduler when a /lambda-schedules entry fires.
# The parent company_stack iam.tf allows the task role to pass this exact
# role to scheduler.amazonaws.com when /lambda-schedules creates or
# updates a schedule.

data "aws_iam_policy_document" "scheduler_lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "scheduler_lambda_invoke" {
  name               = "Amazon_EventBridge_Scheduler_LAMBDA_${var.arn_prefix}"
  assume_role_policy = data.aws_iam_policy_document.scheduler_lambda_assume.json
  tags               = local.scheduled_tags
}

data "aws_iam_policy_document" "scheduler_lambda_invoke" {
  statement {
    actions = ["lambda:InvokeFunction"]
    resources = [
      aws_lambda_function.scheduled.arn,
      "${aws_lambda_function.scheduled.arn}:*"
    ]
  }
}

resource "aws_iam_role_policy" "scheduler_lambda_invoke" {
  name   = "Amazon_EventBridge_Scheduler_LAMBDA_${var.arn_prefix}-invoke"
  role   = aws_iam_role.scheduler_lambda_invoke.id
  policy = data.aws_iam_policy_document.scheduler_lambda_invoke.json
}
