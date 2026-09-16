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

variable "cloudwatch_mcp_url" {
  description = "Base URL of the CloudWatch MCP sidecar, or null when the feature is off. The CloudWatch survey reads it, and treats an unset URL as no connected region — so without this the survey skips every run."
  type        = string
}

variable "internal_sg_id" {
  description = "Security group reaching the log-clustering sidecar on 8000 and the CloudWatch MCP sidecar on 8931, or null when neither feature is on. Either sidecar needs the Lambdas inside it."
  type        = string
}

variable "langsmith_enabled" {
  description = "Whether LangSmith tracing is enabled."
  type        = bool
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

variable "tenant_name" {
  type = string
}

variable "internal_reactive_base_url" {
  description = "In-VPC base URL of the reactive task (Cloud Map name, port 3000). Injected as INTERNAL_BASE_URL on knowledge-graph alone, which is the only scheduled Lambda that reads GitHub and so the only one that has to ask reactive for an installation token."
  type        = string
}

variable "orchestrator_secret" {
  description = "Bearer token the knowledge-graph Lambda signs its internal-API calls with, so reactive answers its request for a GitHub installation token. Scoped to that one function rather than the whole scheduled fleet: nothing else calls the internal API."
  type        = string
  sensitive   = true
}

variable "lambda_queue_url" {
  description = "URL of the deployment's Lambda SQS queue. release-watch and incident-follow-up publish onto it, and so does the consolidated scheduled function."
  type        = string
}
