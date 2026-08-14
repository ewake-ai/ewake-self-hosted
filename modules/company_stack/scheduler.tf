resource "aws_scheduler_schedule_group" "company" {
  name = local.arn_prefix

  tags = local.tags
}
