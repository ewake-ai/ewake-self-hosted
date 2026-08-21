variable "company" {
  description = "One company entry from tenants/registry.json, with `name` merged in from its map key. image_tag is intentionally NOT here — the reactive image tag is resolved from ECR at plan time (see ecs_task.tf)."
  type = object({
    name          = string
    public_id     = string
    domain        = string
    cpu           = number
    memory        = number
    desired_count = number
    # Connector ids this company can log in with — "google", "okta", one per provider. Each
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
  description = "Root domain the public hostname is built on top of (e.g. ewake.ai). The per-company host header matches <company>.<root_domain>."
  type        = string
}

variable "sso_base_url" {
  description = <<-EOT
    Origin the browser drives the OIDC hops against, and what a provider's redirect URI is
    registered against. Null falls through to orchestrator_url, so one registration serves the
    fleet and login depends on the orchestrator being reachable; in byoc, where there is no
    orchestrator, it falls through again to this company's own host. Set it to pin either.
  EOT
  type        = string
  default     = null
}

# "Standalone mode" is what an absent EWAKE_ORCHESTRATOR_URL puts the app in, and
# it is the normal byoc shape rather than a degraded one. What actually changes:
#   - Inbound Slack events are signature-verified locally against the per-company
#     integration secret instead of being pre-verified by the orchestrator. The
#     /api/v1/slack route stays mounted either way.
#   - API-key callers authenticate against this instance directly instead of the
#     orchestrator resolving the key and forwarding a tenant. /api/v1/events stays
#     mounted either way.
#   - The OAuth *connect* routers under /auth (slack, github, notion) unmount, because
#     each completes on an Ewake-hosted callback. Manifest-based Slack install is
#     unaffected, and login is unaffected: that is the Dex sidecar on this origin.
#   - Slack team-route registration against the orchestrator is skipped.
# See src/reactive/server/routers/api/v1/index.ts for the branch points.
variable "orchestrator_url" {
  description = "Public HTTPS URL of the shared orchestrator service (terraform/shared orchestrator module 'url' output). The reactive admin API calls it to list/remove Slack team routes. Null in byoc — there is no orchestrator, and the app runs in standalone mode (see the comment above for exactly what that changes)."
  type        = string
  default     = null
  nullable    = true
}

variable "orchestrator_internal_token_secret_arn" {
  description = "Secrets Manager ARN of the dedicated reactive⇄orchestrator bearer token. Injected as ORCHESTRATOR_SECRET on the reactive task, Lambda, and cloudwatch-mcp sidecar so none of them fetches the value from the ewake-secrets blob at runtime. Null in byoc, which has no orchestrator to mint it — but the same header also authenticates the reactive Lambda's calls to its own reactive server, so byoc generates its own into the per-company `app` secret instead of going without."
  type        = string
  default     = null
  nullable    = true
}

variable "admin_notify_url" {
  description = "Ewake's own instance, which collects operational Slack notifications (admin, playground, sentinel) from every tenant. Null in byoc, where that reporting must not leave the customer's account: the app treats an absent value as 'disabled' and stops mounting the receiving routes."
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
  description = "DNS name of the tenant ALB, used as the alias target of the per-company A record."
  type        = string
}

variable "alb_zone_id" {
  description = "Hosted zone ID of the tenant ALB, paired with alb_dns_name in the A record alias."
  type        = string
}

variable "alb_listener_arn" {
  type = string
}

variable "hosted_zone_id" {
  description = "Route53 zone ID for var.root_domain. Used for the per-company A record."
  type        = string
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

variable "rds_master_secret_arn" {
  description = "ARN of the tenant RDS master-credentials Secrets Manager secret. Read by the bootstrap Lambda."
  type        = string
}

variable "bootstrap_lambda_function_name" {
  description = "Name of the tenant's RDS bootstrap Lambda (terraform/tenants/bootstrap_lambda.tf). Invoked once per company create/update to create the role + database + pgvector extension inside the VPC."
  type        = string
}

variable "datadog_forwarder_arn" {
  # Null in byoc — the forwarder is an Ewake-account Lambda, so there is nothing
  # for a customer's log groups to subscribe to.
  nullable = true
  type     = string
}

variable "datadog_api_key_secret_arn" {
  # Null in byoc; local.shared_secret_arns compact()s it out of the SharedSecretsReadOnly IAM statement.
  type     = string
  default  = null
  nullable = true
}

# github_app_secret_arn and notion_secret_arn are Ewake-account OAuth client credentials,
# null in byoc for one shared reason: an authorization-code flow needs a callback URL
# registered with the provider, and ours is Ewake-hosted, so a customer deployment can't
# complete the round trip. That is a property of OAuth *connect* flows only, not of the
# integration behind them — Slack is fully available in byoc via manifest install.
#
# The operator-login providers that used to sit here are gone: login is the Dex sidecar
# now, on both SaaS and byoc.

variable "github_app_secret_arn" {
  description = "Secrets Manager ARN of Ewake's GitHub App credentials (JSON with CLIENT_ID, CLIENT_SECRET, APP_PRIVATE_KEY). Null in byoc: the GitHub App install is an OAuth flow whose callback is Ewake-hosted, so a customer deployment can't complete it."
  type        = string
  default     = null
  nullable    = true
}

variable "notion_secret_arn" {
  description = "Secrets Manager ARN of Ewake's Notion OAuth credentials (JSON object with CLIENT_ID + CLIENT_SECRET). Null in byoc: the Notion connect flow is OAuth with an Ewake-hosted callback, so a customer deployment can't complete it."
  type        = string
  default     = null
  nullable    = true
}

variable "dex_secret_arn" {
  description = "Secrets Manager ARN of the SaaS Dex OIDC client secret (JSON with SECRET). Null in byoc, which uses the per-company `app` secret's random DEX_CLIENT_SECRET."
  type        = string
  default     = null
  nullable    = true
}

variable "jwt_secret_arn" {
  description = "Secrets Manager ARN of the SaaS JWT signing secret (JSON with SECRET). Null in byoc, which uses the per-company `app` secret's random JWT_SECRET."
  type        = string
  default     = null
  nullable    = true
}

variable "slack_secret_arn" {
  description = "Secrets Manager ARN of Ewake's own Slack app credentials, used for the hosted OAuth install flow (JSON with CLIENT_ID, CLIENT_SECRET, AUTH_URL, SIGNING_SECRET). Null in byoc — NOT because Slack is unavailable there, but because a byoc customer installs their own Slack app from a generated manifest and supplies its bot token + signing secret directly (src/reactive/server/routers/api/v1/integration/slack.ts). Those land in the per-company integration secret, and inbound events are signature-verified against it locally, so no orchestrator is involved on either the install or the receive path."
  type        = string
  default     = null
  nullable    = true
}

variable "datadog_pg_secret_arn" {
  description = "ARN of the tenant-level Datadog Postgres monitoring user secret. Non-null enables DBM on the agent sidecar and bootstrap lambda."
  type        = string
  default     = null
}

# DBM already switches off wherever this is null — the agent secret, the docker
# labels, pg_stat_statements and the datadog role all key off it. This turns that
# from a coincidence into a contract, since byoc has no agent to feed.
check "dbm_off_in_byoc" {
  assert {
    condition     = !(var.deployment_mode == "byoc" && var.datadog_pg_secret_arn != null)
    error_message = "datadog_pg_secret_arn must be null when deployment_mode is byoc: DBM ships query samples to Ewake's Datadog."
  }
}

# The cloudwatch-mcp sidecar isn't part of the byoc v0 surface — its EWAKE_INTERNAL_TOKEN sources from the shared orchestrator_internal_token secret, which byoc doesn't provision. Blocked at plan time by a precondition on the always-created reactive task definition (see ecs_task.tf). Revisit if a customer needs it.

variable "ecr_repository_urls" {
  type = map(string)
}

variable "frontend_artifacts_bucket" {
  description = "Shared S3 bucket holding frontend static exports and version pointers (terraform/shared/frontend_artifacts.tf). Injected as FRONTEND_ARTIFACTS_BUCKET; the task role gets read access scoped to this company's pointer."
  type        = string
}

variable "frontend_artifacts_region" {
  description = "Region the frontend artifacts bucket lives in — Ewake's, not the deployment's, so it is deliberately not aws_region. Only differs if the bucket moves."
  type        = string
  default     = "eu-west-3"
}

variable "release_channel" {
  description = "Build stream this company falls back to before it has a per-company frontend pointer: 'latest' (dogfood, follows main merges) or 'stable' (follows releases). Spelled the same as the ECR tag, so the caller uses it verbatim for reactive_service_image_uri and lambda_image_uris and a first boot cannot pair a stable frontend with a dogfood backend."
  type        = string
  default     = "stable"

  validation {
    condition     = contains(["latest", "stable"], var.release_channel)
    error_message = "release_channel must be 'latest' or 'stable'."
  }
}

variable "reactive_service_image_uri" {
  description = "Fully-qualified image for the reactive ECS service, tagged with this tenant's channel. Distinct from lambdas/variables.tf's reactive_image_uri, which is the reactive Lambda. Only a brand-new company ever boots on it — CI owns the tag from the first deploy on."
  type        = string
}

variable "db_migrate_image_uri" {
  description = "Fully-qualified image for the one-off migration task, tagged with this tenant's channel. CI overrides the tag per deploy; this value only decides what a brand-new company's first revision points at."
  type        = string
}

variable "log_clustering_function_name" {
  description = "Name of the tenant's shared log-clustering Lambda (terraform/tenants/log_clustering.tf). Injected as LOG_CLUSTERING_FUNCTION_NAME into every runtime that clusters logs."
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
  description = "Fully-qualified ECR image URI (with tag) of the consolidated scheduled-Lambda image (ewake-lambdas). Pulled cross-account from the Ewake registry, so it needs the byoc_lambda_bundle repository policy on the Ewake side."
  type        = string
}

# ARM-only: the al2023_arm64 AMI in neo4j.tf is fixed to `arm64`, so this must
# be a Graviton family (t4g.*, c7g.*, m7g.*, etc.). Picking an x86 type here
# fails at RunInstances with an AMI/arch mismatch.
variable "neo4j_instance_type" {
  description = "EC2 instance type for the per-company Neo4j box. Must be a Graviton (arm64) family since the AMI is arm64-only. Default t4g.small is enough for early-stage graphs; step up to t4g.medium/large as the graph grows or if the region has patchy t4g.small capacity."
  type        = string
  default     = "t4g.small"
}

# No default, here or in the child modules: with one, a byoc root that omitted
# the argument would silently get saas egress. Without one, the plan fails.
variable "deployment_mode" {
  description = "saas = Ewake's multi-tenant infrastructure. byoc = a single-company stack in a customer's own AWS account."
  type        = string

  validation {
    condition     = contains(["saas", "byoc"], var.deployment_mode)
    error_message = "deployment_mode must be \"saas\" or \"byoc\"."
  }
}

locals {
  is_byoc = var.deployment_mode == "byoc"

  # Two gates, deliberately together. The feature flag says this company wants
  # Elasticsearch; the byoc check says it may not have it here, because the cluster
  # is Ewake's — /${project}/global/prod/*, one shared instance, not per-company.
  # Indexing a customer's content into it from their own account is exactly what
  # byoc exists to prevent.
  elasticsearch_enabled = var.company.features.elasticsearch && var.deployment_mode != "byoc"

  # ${tenant}-${company}-<resource> for everything named in AWS.
  # Reads `ewake-ewake-reactive` / `ewake-ewake-knowledge-graph`.
  # ssm_path keeps the ${project} prefix to stay consistent with the legacy
  # SSM hierarchy (/ewake/<tenant>/<company>/...).
  arn_prefix = "${var.tenant_name}-${var.company.name}"
  ssm_path   = "${var.project_name}/${var.tenant_name}/${var.company.name}"

  # This deployment's own public origin — every absolute URL the app hands to a browser,
  # a provider, or Slack. Stated here rather than left to src/core/config, whose fallback
  # is `https://${CLIENT}.ewake.ai` with our domain hardcoded: right by luck on saas, and
  # in byoc a URL on Ewake's domain that the customer does not own and DNS cannot resolve.
  company_base_url = "https://${var.company.name}.${var.root_domain}"

  tags = merge(var.common_tags, {
    Company = var.company.name
  })

  # Fleet-wide (Ewake-account) secrets the task role needs read on. `compact`
  # drops absent ones — in byoc every entry is null, and iam.tf's dynamic block
  # then omits the whole SharedSecretsReadOnly statement.
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
