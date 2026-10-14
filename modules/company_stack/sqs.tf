resource "aws_sqs_queue" "lambda" {
  name = "${local.arn_prefix}-lambda"
  # The 900s Lambda timeout plus one minute. Lambda stops a run at 900s, so when the
  # message reappears nothing is still working on it, and a run that timed out or failed
  # is retried about a minute later. The minute covers the gap between receiving the
  # message and the invocation starting; equal to the timeout left no margin for it.
  # AWS's 6x guidance (5400s) suits batched or throttled consumers. With batch_size 1 it
  # only made every retry wait 90 minutes.
  visibility_timeout_seconds = 960
  message_retention_seconds  = 345600

  # The application sets its own delay before each retry of a failed run (1 min, 5 min, 90 min,
  # then 6 h), one per receive this count allows. The 960 s above applies to a run that crashed
  # or timed out before it could set one.
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
