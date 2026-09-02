variable "company" {
  type = object({
    name      = string
    public_id = string
    features = object({
      elasticsearch = bool
      langsmith     = bool
      ambient       = bool
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

variable "deployment_mode" {
  description = "No default: a default could only ever fail open."
  type        = string
}

variable "datadog_forwarder_arn" {
  type = string
}

variable "langsmith_secret_string" {
  description = "JSON-encoded LangSmith secret value."
  type        = string
  sensitive   = true
}

variable "lambda_bundle_image_uri" {
  description = "Consolidated image holding all nine scheduled handlers; each function selects its own via image_config."
  type        = string
}

variable "tags" {
  type = map(string)
}

variable "log_clustering_function_name" {
  type = string
}

variable "log_clustering_sidecar_url" {
  description = "Base URL of the log-clustering sidecar, or null when the feature is off. Null means the agent runtime keeps invoking the Lambda."
  type        = string
}

variable "internal_sg_id" {
  description = "Security group reaching the log-clustering sidecar on 8000, or null when the feature is off."
  type        = string
}

variable "langsmith_enabled" {
  description = "Whether LangSmith tracing is enabled."
  type        = bool
}

variable "github_app_enabled" {
  description = "True when the GitHub App secret is provisioned. Same bool-gate-not-secret-gate pattern as langsmith_enabled — only knowledge-graph.tf reads it."
  type        = bool
}

variable "github_app_secret_string" {
  description = "Raw JSON of the GitHub App secret (CLIENT_ID, CLIENT_SECRET, APP_PRIVATE_KEY). Decoded inside knowledge-graph.tf and injected as env vars. Nullable — read only when github_app_enabled is true."
  type        = string
  sensitive   = true
}

variable "datadog_enabled" {
  description = "Whether the Datadog agent, Lambda extension, and forwarder run."
  type        = bool
}

variable "datadog_api_key" {
  description = "Raw Datadog API key for the knowledge-graph Lambda's agentless feature-flag source. Plaintext, not JSON, so it needs no jsondecode. Nullable — null when flags are off."
  type        = string
  sensitive   = true
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

# Neither is read by these functions. The application requires both at startup in
# every runtime, so a missing one exits the
# handler before it runs — the same shape as the base URLs above.
variable "jwt_secret" {
  type      = string
  sensitive = true
}

variable "orchestrator_secret" {
  type      = string
  sensitive = true
}
