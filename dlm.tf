# AWS Data Lifecycle Manager role for the Neo4j EBS snapshots. The name must be
# exactly AWSDataLifecycleManagerDefaultRole, which neo4j.tf refers to.

resource "aws_iam_role" "dlm_default" {
  name = "AWSDataLifecycleManagerDefaultRole"
  path = "/service-role/"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "dlm.amazonaws.com" }
    }]
  })

  description = "Default role for AWS Data Lifecycle Manager, managed by this deployment."

  # Account-global name. If the customer has any unrelated DLM policy in this
  # account (an EBS backup lifecycle set up outside this deployment), destroying
  # this role silently stops those snapshots too. Force `terraform state rm` before
  # destroy so the removal is a deliberate act, not a side effect of tearing this down.
  lifecycle {
    prevent_destroy = true
    # description is applied state; ignore drift so a wording change is never a plan diff
    # on an existing deployment.
    ignore_changes = [description]
  }
}

resource "aws_iam_role_policy_attachment" "dlm_default" {
  role       = aws_iam_role.dlm_default.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}
