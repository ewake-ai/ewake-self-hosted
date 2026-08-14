# AWS Data Lifecycle Manager role for the per-company Neo4j EBS snapshots.
# company_stack's neo4j.tf hardcodes the role name
# "AWSDataLifecycleManagerDefaultRole" (matching what the AWS console's "Create
# default IAM role" flow uses), so the role must exist under that exact name.
# In the SaaS shape this lives in terraform/shared/dlm.tf; in byoc every
# customer account creates its own.

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

  description = "Default role for AWS Data Lifecycle Manager. Managed by terraform/roots/byoc/dlm.tf."

  # Account-global name. If the customer has any unrelated DLM policy in this
  # account (an EBS backup lifecycle set up outside byoc), destroying this role
  # silently stops those snapshots too. Force `terraform state rm` before destroy
  # so the removal is a deliberate act, not a side effect of tearing down byoc.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_iam_role_policy_attachment" "dlm_default" {
  role       = aws_iam_role.dlm_default.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}
