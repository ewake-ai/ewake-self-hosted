variable "company" {
  description = "One company entry from the deployment configuration, with `name` merged in from its map key. image_tag is intentionally NOT here — the reactive image tag is resolved from ECR at plan time (see ecs_task.tf)."
  type = object({
    name          = string
    public_id     = string
    domain        = string
    cpu           = number
    memory        = number
    desired_count = number
    # Connector ids this deployment can log in with — "google", "okta", one per provider. Each
    # gets its own secret at <ssm_path>/sso/<id>, and dex.tf compiles them into the one
    # DEX_CONNECTORS array both containers read. Empty means no SSO: Dex refuses to start, so
    # the sidecar restart-loops while reactive keeps serving.
    sso_connectors = optional(list(string), [])
    features = object({
      elasticsearch        = bool
      langsmith            = bool
      ambient              = bool
      cloudwatchMcpSidecar = optional(bool, false)
      logClusteringSidecar = optional(bool, false)
    })
  })

  validation {
    condition     = trimspace(var.company.domain) != ""
    error_message = "company.domain must be a non-empty email domain."
  }
}

variable "project_name" {
  type = string
}

variable "tenant_name" {
  type = string
}

variable "root_domain" {
  description = "Root domain the public hostname is built on top of (e.g. example.com). The host header matches var.company_host, which defaults to <company>.<root_domain>."
  type        = string
}

variable "company_host" {
  description = "Fully-qualified host this deployment answers on. Null keeps the default <company>.<root_domain>; set it explicitly to serve at a delegated zone's apex."
  type        = string
  default     = null
}

variable "sso_base_url" {
  description = <<-EOT
    Origin the browser drives the OIDC hops against, and what a provider's redirect URI is
    registered against. Null falls through to this deployment's own host. Set it to pin a
    specific origin.
  EOT
  type        = string
  default     = null
}

variable "orchestrator_url" {
  description = "Optional external service URL for managing Slack team routes. Null for this deployment."
  type        = string
  default     = null
  nullable    = true
}

variable "orchestrator_internal_token_secret_arn" {
  description = "Secrets Manager ARN of a bearer token that authenticates the reactive Lambda's calls to the reactive server. Null for this deployment, which generates its own into the `app` secret."
  type        = string
  default     = null
  nullable    = true
}

variable "admin_notify_url" {
  description = "Optional URL that collects operational Slack notifications (admin, playground, sentinel). Null for this deployment: an absent value disables it and stops mounting the receiving routes."
  type        = string
  default     = null
  nullable    = true
}

variable "aws_region" {
  type = string
}

variable "common_tags" {
  type = map(string)
}

variable "vpc_id" {
  type = string
}

variable "private_subnets" {
  type = list(string)
}

variable "ecs_cluster_arn" {
  type = string
}

variable "alb_arn" {
  type = string
}

variable "alb_dns_name" {
  description = "DNS name of the ALB, used as the alias target of the A record."
  type        = string
}

variable "alb_zone_id" {
  description = "Hosted zone ID of the ALB, paired with alb_dns_name in the A record alias."
  type        = string
}

variable "alb_listener_arn" {
  type = string
}

variable "hosted_zone_id" {
  description = "Route53 zone ID for var.root_domain, used for the A record. Null skips the record entirely, for a deployment whose DNS the customer owns — the caller is then responsible for pointing var.company_host at the ALB."
  type        = string
  default     = null
}

variable "extra_host_headers" {
  description = "Additional Host values the reactive listener rule matches, alongside var.company_host. Empty (default) matches company_host alone. Used during a hostname cutover, where both names must serve at once; each also needs a certificate on the listener, which is the caller's side."
  type        = list(string)
  default     = []
}

variable "ecs_task_sg_id" {
  type = string
}

variable "rds_endpoint" {
  type = string
}

# Changes when the instance is rebuilt, unlike the endpoint, which a same-identifier
# replacement leaves untouched. Used to re-trigger db-migrate.
variable "rds_resource_id" {
  type = string
}

variable "rds_port" {
  type = number
}

variable "rds_master_secret_arn" {
  description = "ARN of the RDS master-credentials Secrets Manager secret. Read by the bootstrap Lambda."
  type        = string
}

variable "bootstrap_lambda_function_name" {
  description = "Name of the RDS bootstrap Lambda. Invoked on create/update to create the role + database + pgvector extension inside the VPC."
  type        = string
}

variable "datadog_forwarder_arn" {
  nullable = true
  type     = string
}

variable "datadog_api_key_secret_arn" {
  type     = string
  default  = null
  nullable = true
}

variable "github_app_secret_arn" {
  description = "Secrets Manager ARN of GitHub App credentials (JSON with CLIENT_ID, CLIENT_SECRET, APP_PRIVATE_KEY). Null for this deployment."
  type        = string
  default     = null
  nullable    = true
}

variable "notion_secret_arn" {
  description = "Secrets Manager ARN of Notion OAuth credentials (JSON object with CLIENT_ID + CLIENT_SECRET). Null for this deployment."
  type        = string
  default     = null
  nullable    = true
}

variable "dex_secret_arn" {
  description = "Secrets Manager ARN of a Dex OIDC client secret (JSON with SECRET). Null here, which uses the `app` secret's random DEX_CLIENT_SECRET."
  type        = string
  default     = null
  nullable    = true
}

variable "jwt_secret_arn" {
  description = "Secrets Manager ARN of a JWT signing secret (JSON with SECRET). Null here, which uses the `app` secret's random JWT_SECRET."
  type        = string
  default     = null
  nullable    = true
}

variable "slack_secret_arn" {
  description = "Secrets Manager ARN of Slack app credentials for the OAuth install flow (JSON with CLIENT_ID, CLIENT_SECRET, AUTH_URL, SIGNING_SECRET). Null for this deployment, which installs its own Slack app from a generated manifest and supplies the bot token + signing secret directly."
  type        = string
  default     = null
  nullable    = true
}

variable "datadog_pg_secret_arn" {
  description = "ARN of the Datadog Postgres monitoring user secret. Non-null enables DBM on the agent sidecar and bootstrap lambda."
  type        = string
  default     = null
}

# DBM already switches off wherever this is null — the agent secret, the docker
# labels, pg_stat_statements and the datadog role all key off it. This turns that
# from a coincidence into a contract.
check "dbm_off_in_byoc" {
  assert {
    condition     = !(var.deployment_mode == "byoc" && var.datadog_pg_secret_arn != null)
    error_message = "datadog_pg_secret_arn must be null when deployment_mode is byoc: DBM ships query samples to an external Datadog account."
  }
}

variable "ecr_repository_urls" {
  type = map(string)
}

variable "reactive_service_image_uri" {
  description = "Fully-qualified image for the reactive ECS service, tagged with this deployment's channel. Distinct from lambdas/variables.tf's reactive_image_uri, which is the reactive Lambda. Only a brand-new deployment ever boots on it — CI owns the tag from the first deploy on."
  type        = string
}

variable "db_migrate_image_uri" {
  description = "Fully-qualified image for the one-off migration task, tagged with this deployment's channel. CI overrides the tag per deploy; this value only decides what a brand-new deployment's first revision points at."
  type        = string
}

variable "log_clustering_function_name" {
  description = "Name of the log-clustering Lambda. Injected as LOG_CLUSTERING_FUNCTION_NAME into every runtime that clusters logs."
  type        = string
}

variable "log_clustering_function_arn" {
  description = "ARN of the same Lambda, used to scope the task role's lambda:InvokeFunction grant."
  type        = string
}

variable "lambda_image_uris" {
  description = "Map of <lambda-directory-name> => fully-qualified ECR image URI (with tag). Only the reactive Lambda still has its own repository; the scheduled ones share lambda_bundle_image_uri."
  type        = map(string)
}

variable "lambda_bundle_image_uri" {
  description = "Fully-qualified ECR image URI (with tag) of the consolidated scheduled-Lambda image (ewake-lambdas)."
  type        = string
}

# ARM-only: the al2023_arm64 AMI in neo4j.tf is fixed to `arm64`, so this must
# be a Graviton family (t4g.*, c7g.*, m7g.*, etc.). Picking an x86 type here
# fails at RunInstances with an AMI/arch mismatch.
variable "neo4j_instance_type" {
  description = "EC2 instance type for the Neo4j box. Must be a Graviton (arm64) family since the AMI is arm64-only. Default t4g.small is enough for early-stage graphs; step up to t4g.medium/large as the graph grows or if the region has patchy t4g.small capacity."
  type        = string
  default     = "t4g.small"
}

# No default, here or in the child modules: a default could only ever fail open.
variable "deployment_mode" {
  description = "Deployment mode for this stack."
  type        = string

  validation {
    condition     = contains(["saas", "byoc"], var.deployment_mode)
    error_message = "deployment_mode must be \"saas\" or \"byoc\"."
  }
}

locals {
  is_byoc = var.deployment_mode == "byoc"

  # Elasticsearch is gated off here: the cluster it would index into is not part
  # of this deployment.
  elasticsearch_enabled = var.company.features.elasticsearch && var.deployment_mode != "byoc"

  # ${tenant}-${company}-<resource> for everything named in AWS.
  # Reads `ewake-ewake-reactive` / `ewake-ewake-knowledge-graph`.
  # ssm_path keeps the ${project} prefix to stay consistent with the legacy
  # SSM hierarchy (/ewake/<tenant>/<company>/...).
  arn_prefix = "${var.tenant_name}-${var.company.name}"
  ssm_path   = "${var.project_name}/${var.tenant_name}/${var.company.name}"

  # The one name this deployment answers on. Route53, the listener rule and every
  # absolute URL below read this, so they cannot drift apart. Stated here rather
  # than left to the application's fallback, which is on a domain you do not own.
  company_host = coalesce(var.company_host, "${var.company.name}.${var.root_domain}")

  company_base_url = "https://${local.company_host}"

  # Where third parties reach this deployment. The same host as the dashboard whenever the
  # ALB is public, which is why it defaults to it. A private ALB splits them: Slack and
  # Datadog cannot route to an internal name, so they need a public entry point in front,
  # and only this value moves — the dashboard stays on the private host.
  public_inbound_base_url = coalesce(var.public_inbound_base_url, local.company_base_url)

  tags = merge(var.common_tags, {
    Company = var.company.name
  })

  # Optional external secrets the task role needs read on. `compact` drops absent
  # ones — here every entry is null, and iam.tf's dynamic block then omits the
  # whole SharedSecretsReadOnly statement.
  shared_secret_arns = compact([
    one(data.aws_secretsmanager_secret.grafana[*].arn),
    one(data.aws_secretsmanager_secret.langsmith[*].arn),
    var.datadog_api_key_secret_arn,
    var.datadog_pg_secret_arn,
    var.orchestrator_internal_token_secret_arn,
    var.github_app_secret_arn,
    var.notion_secret_arn,
    var.jwt_secret_arn,
    var.slack_secret_arn,
    var.dex_secret_arn,
  ])
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

variable "public_inbound_base_url" {
  description = "Public https base URL third parties (Slack, Datadog) use to reach this deployment, when that is not the dashboard host. Only needed behind a private ALB, where an entry point in front of it terminates the call. Null serves both from the company host."
  type        = string
  default     = null

  validation {
    condition     = var.public_inbound_base_url == null || can(regex("^https://", var.public_inbound_base_url))
    error_message = "public_inbound_base_url must be an https:// URL; Slack and Datadog refuse to deliver to anything else."
  }
}
