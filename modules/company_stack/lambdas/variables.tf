variable "company" {
  type = object({
    name      = string
    public_id = string
    domain    = string
    features = object({
      elasticsearch        = bool
      langsmith            = bool
      ambient              = bool
      cloudwatchMcpSidecar = optional(bool, false)
    })
  })
}

variable "arn_prefix" {
  type = string
}

variable "ssm_path" {
  type = string
}

variable "task_role_arn" {
  type = string
}

variable "private_subnets" {
  type = list(string)
}

variable "ecs_task_sg_id" {
  type = string
}

variable "rds_endpoint" {
  type = string
}

variable "rds_port" {
  type = number
}

variable "postgres_password" {
  type      = string
  sensitive = true
}

variable "neo4j_uri" {
  type = string
}

variable "neo4j_username" {
  type = string
}

variable "neo4j_password" {
  type      = string
  sensitive = true
}

variable "datadog_base_env" {
  description = "Datadog env shared by every Lambda in company_stack, computed once by the parent so the two child modules cannot drift. Per-runtime keys are merged on top by the Lambda that needs them."
  type        = map(string)
}

variable "datadog_api_key" {
  description = "Raw Datadog API key for the reactive Lambda's agentless feature-flag source. Plaintext, not JSON, so it needs no jsondecode. Nullable — null when flags are off."
  type        = string
  sensitive   = true
}

variable "deployment_mode" {
  description = "No default: a default could only ever fail open."
  type        = string
}

variable "datadog_forwarder_arn" {
  type = string
}

variable "reactive_image_uri" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "sqs_queue_arn" {
  type = string
}

variable "langsmith_secret_string" {
  type      = string
  sensitive = true
}

variable "orchestrator_secret" {
  type      = string
  sensitive = true
}

# Unread here — required at config import. See the scheduled submodule's copy.
variable "jwt_secret" {
  type      = string
  sensitive = true
}

variable "elasticsearch_url" {
  type = string
}

variable "elasticsearch_api_key" {
  type      = string
  sensitive = true
}

variable "cloudwatch_mcp_url" {
  type = string
}

variable "log_clustering_sidecar_url" {
  description = "Base URL of the log-clustering sidecar, or null when the feature is off. Null means the agent runtime keeps invoking the Lambda."
  type        = string
}

variable "tags" {
  type = map(string)
}

variable "log_clustering_function_name" {
  type = string
}

variable "langsmith_enabled" {
  description = "Whether LangSmith tracing is enabled."
  type        = bool
}

variable "github_app_enabled" {
  description = "True when the GitHub App secret is provisioned. Same bool-gate-not-secret-gate pattern as langsmith_enabled."
  type        = bool
}

variable "github_app_secret_string" {
  description = "Raw JSON of the GitHub App secret (CLIENT_ID, CLIENT_SECRET, APP_PRIVATE_KEY). Decoded inside the module and injected as env vars. Nullable — read only when github_app_enabled is true."
  type        = string
  sensitive   = true
}

variable "datadog_enabled" {
  description = "Whether the Datadog agent, Lambda extension, and forwarder run."
  type        = bool
}

variable "elasticsearch_enabled" {
  description = "Whether Elasticsearch indexing is enabled."
  type        = bool
}

variable "internal_reactive_base_url" {
  description = "In-VPC base URL of the reactive task (Cloud Map name, port 3000). Injected as EWAKE_BASE_URL so internal calls do not resolve the public ALB and hairpin through NAT."
  type        = string
}

variable "internal_sg_id" {
  description = "Security group granting access to the reactive task's internal ports. Every Lambda that calls the internal API joins it."
  type        = string
}

variable "company_base_url" {
  description = "The deployment's own https URL. Not read by these functions, but the application requires the base URLs at startup in every runtime."
  type        = string
}

variable "public_inbound_base_url" {
  description = "Public https base URL third parties reach this deployment on. Same as company_base_url unless a private ALB puts an entry point in front. Not read by these functions; required at config import."
  type        = string
}

variable "sso_base_url" {
  description = "The origin the browser drives the OIDC hops against. Not read by these functions; required at config import."
  type        = string
}

variable "tenant_name" {
  type = string
}
