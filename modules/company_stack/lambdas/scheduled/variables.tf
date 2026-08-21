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
  description = "Datadog env shared by every Lambda in company_stack, computed once by the parent so the two child modules cannot drift. Empty in byoc. Per-runtime keys are merged on top by the Lambda that needs them."
  type        = map(string)
}

variable "deployment_mode" {
  description = "saas or byoc. No default: a default could only ever fail open."
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
  description = "Consolidated image holding all nine scheduled handlers; each function selects its own via image_config. Replaces the nine ewake-lambda-<name> repos retired in ewake-ai/back#3124."
  type        = string
}

variable "tags" {
  type = map(string)
}

variable "log_clustering_function_name" {
  type = string
}

variable "log_clustering_sidecar_url" {
  description = "Base URL of this company's log-clustering sidecar, or null when the feature is off. Null means the agent runtime keeps invoking the per-tenant Lambda."
  type        = string
}

variable "internal_sg_id" {
  description = "Per-company security group reaching the log-clustering sidecar on 8000, or null when the feature is off — passing it unconditionally would attach it to every company's scheduled Lambdas and change companies that never opted in. Held alongside the tenant-wide ecs_task SG, which must not carry that rule: it is shared by every company in the tenant."
  type        = string
}

variable "langsmith_enabled" {
  description = "False in byoc, where the Ewake-owned \"langsmith\" secret does not exist and no trace may leave the customer account."
  type        = bool
}

variable "github_app_enabled" {
  description = "True when the shared GitHub App secret is provisioned. Same bool-gate-not-secret-gate pattern as langsmith_enabled — only knowledge-graph.tf reads it."
  type        = bool
}

variable "github_app_secret_string" {
  description = "Raw JSON of the shared GitHub App secret (CLIENT_ID, CLIENT_SECRET, APP_PRIVATE_KEY). Decoded inside knowledge-graph.tf and injected as env vars. Nullable — read only when github_app_enabled is true."
  type        = string
  sensitive   = true
}

variable "datadog_enabled" {
  description = "False in byoc: Ewake's own telemetry (agent, Lambda extension, forwarder) must not run in a customer account. The customer-facing Datadog *integration* is unaffected."
  type        = bool
}

variable "datadog_api_key" {
  description = "Raw Datadog API key for the knowledge-graph Lambda's agentless feature-flag source. Plaintext, not JSON, so it needs no jsondecode. Nullable — null in byoc, where flags stay off."
  type        = string
  sensitive   = true
}
