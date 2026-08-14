resource "aws_sqs_queue" "lambda" {
  name = "${local.arn_prefix}-lambda"
  # 6x the 900s Lambda timeout, per AWS's guidance for SQS-triggered functions. Equal to
  # it left no buffer at all: a run that used its full budget released the message the
  # instant it finished, so a redelivery could land while the agent was still working.
  visibility_timeout_seconds = 5400
  message_retention_seconds  = 345600

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.lambda_dlq.arn
    maxReceiveCount     = 5
  })

  tags = local.tags
}

resource "aws_sqs_queue" "lambda_dlq" {
  name                      = "${local.arn_prefix}-lambda-dlq"
  message_retention_seconds = 1209600

  tags = local.tags
}
