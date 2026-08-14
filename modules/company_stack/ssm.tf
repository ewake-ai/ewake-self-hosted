# Per-company SSM parameter scaffolding lives here. Most parameter VALUES are
# managed outside Terraform (set manually or via deploy pipelines); the module
# only needs to know the paths so IAM policies can be tight (see iam.tf).
#
# If a parameter is created by Terraform itself in the future, add it here under
# /${var.project_name}/${var.tenant_name}/${var.company.name}/...

data "aws_ssm_parameter" "elasticsearch_url" {
  count = local.elasticsearch_enabled ? 1 : 0
  name  = "/${var.project_name}/global/prod/elasticsearch-url"
}

data "aws_ssm_parameter" "elasticsearch_api_key" {
  count = local.elasticsearch_enabled ? 1 : 0
  name  = "/${var.project_name}/global/prod/elasticsearch-api-key"
}
