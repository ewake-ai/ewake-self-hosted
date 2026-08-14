# Adding a region takes an aws_ecr_replication_configuration in terraform/shared — registry-level,
# so it covers every repository at once — and an entry in the list below.
variable "aws_region" {
  description = "AWS region for this deployment. Limited to the regions Ewake replicates its images into — ask your Ewake contact if you need another."
  type        = string
  default     = "eu-west-3"

  validation {
    condition     = contains(["eu-west-3"], var.aws_region)
    error_message = "aws_region must be one of: eu-west-3. Ewake's container images are only published there, so any other region fails at image pull with a hostname that does not exist. Ask your Ewake contact to add the region you need."
  }
}

# The customer's own "tenant" identity — used in resource names, log prefixes and
# the pointer key under s3://ewake-frontend-artifacts/pointers/<tenant>/... Kept
# distinct from `company.name` because the SaaS shape has one tenant to many
# companies; in byoc they usually collapse (tenant_name == company.name), but the
# separation stays so ARN prefixes look the same as SaaS and code that reads them
# doesn't need a special case.
variable "tenant_name" {
  description = "Identifier for this deployment. Lowercase alphanumeric; used in resource names and S3 pointer paths. Typically the customer's short name (e.g. \"acme\"). Capped at 21 chars because it feeds into the ALB name `$${tenant_name}-tenant-alb`, and AWS caps ALB names at 32 — a longer value fails deep into the plan, after RDS's 20-minute create."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{0,20}$", var.tenant_name))
    error_message = "tenant_name must be lowercase alphanumeric, start with a letter, and be at most 21 chars (so the ALB name stays under the 32-char AWS limit)."
  }
}

variable "company" {
  description = "The single company this deployment serves. Same shape as one entry in tenants/registry.json's companies map."
  type = object({
    name          = string
    public_id     = string
    domain        = string
    cpu           = optional(number, 1024)
    memory        = optional(number, 2048)
    desired_count = optional(number, 1)
    # Empty is a trap: Dex refuses to start with no connectors, so the sidecar dies on boot
    # while reactive keeps serving — a healthy-looking deployment nobody can sign in to.
    # Each redirect URI is this deployment's own host, not the orchestrator's as on saas.
    sso_connectors = optional(list(string), [])
    features = optional(object({
      elasticsearch        = optional(bool, false)
      langsmith            = optional(bool, false)
      ambient              = optional(bool, true)
      cloudwatchMcpSidecar = optional(bool, false)
      logClusteringSidecar = optional(bool, false)
    }), {})
  })

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{0,32}$", var.company.name))
    error_message = "company.name must be lowercase alphanumeric, start with a letter, and be at most 33 chars."
  }

  validation {
    condition     = trimspace(var.company.domain) != ""
    error_message = "company.domain must be a non-empty email domain."
  }
}

variable "root_domain" {
  description = "Public root domain the customer owns and delegates to Route53 in this AWS account. The reactive dashboard is served at <company.name>.<root_domain>."
  type        = string
}

variable "hosted_zone_id" {
  description = "Route53 hosted zone ID for var.root_domain. Must exist before apply — Terraform creates the ACM cert with DNS validation records here."
  type        = string
}

variable "ewake_aws_account_id" {
  description = "AWS account ID that owns the Ewake ECRs. Used to build every image URI (reactive, cloudwatch-mcp, log-clustering-sidecar, every ewake-lambda-*). Pull is authorized by the aws_ecr_repository_policy Ewake attaches to those repos via terraform/shared/byoc_customers.tf. Defaults to Ewake's production account — override only if Ewake has told you a different one."
  type        = string
  default     = "058264427976"

  validation {
    condition     = can(regex("^\\d{12}$", var.ewake_aws_account_id))
    error_message = "ewake_aws_account_id must be a 12-digit AWS account ID."
  }
}

variable "ewake_frontend_artifacts_bucket_name" {
  description = "Name of the Ewake-owned S3 bucket holding frontend static exports. Cross-account read is granted by terraform/shared/byoc_customers.tf (aws_s3_bucket_policy). Defaults to the well-known name — override only if Ewake has told you a different one."
  type        = string
  default     = "ewake-frontend-artifacts"
}

variable "release_channel" {
  description = "Which Ewake release stream this deployment tracks: 'stable' (default; released images) or 'latest' (main-merge, dogfood). Selects the frontend channel pointer (channels/<name>.json) and the Lambda image tags. Also the default tag for reactive and db-migrate, unless app_image_tag overrides those."
  type        = string
  default     = "stable"

  validation {
    condition     = contains(["latest", "stable"], var.release_channel)
    error_message = "release_channel must be 'latest' or 'stable'."
  }
}

# release_channel is overloaded: it is simultaneously the ECR tag for every Ewake
# image AND the name of the frontend channel pointer the app reads
# (channels/<name>.json in the artifacts bucket). Only latest, main and stable exist
# as channels, so setting release_channel to a version or commit tag resolves no
# channel — the dashboard falls back to last-known-good, or 503s on a cold task —
# and nothing fails at plan time to tell you. Its validation blocks that today.
#
# This variable is the way to run a specific build without touching the channel:
# release_channel keeps selecting the frontend, app_image_tag pins the containers.
#
# Covers reactive and db-migrate together, deliberately. db-migrate applies the
# schema the running reactive image expects, so pinning one and not the other boots
# a container against migrations it does not have. Lambda images are NOT covered —
# they follow release_channel, because they version independently of a reactive build
# and their tags do not exist for every commit.
variable "app_image_tag" {
  description = "Pins the reactive service and its db-migrate task to a specific ECR tag (e.g. \"ewake-v0.145.0\" or \"sha-1a2b3c4d\"). Leave null to follow release_channel. Does not affect the frontend channel or the Lambda images."
  type        = string
  default     = null
  nullable    = true

  # Empty string is rejected rather than tolerated. coalesce() already skips it and
  # falls through to release_channel, so an accidental "" — a CI variable that did
  # not expand, say — would silently deploy the channel instead of the pin the
  # operator thought they had set. Null is the way to say "follow the channel".
  validation {
    condition     = var.app_image_tag == null || trimspace(coalesce(var.app_image_tag, " ")) != ""
    error_message = "app_image_tag must be null (follow release_channel) or a non-empty tag; an empty string is almost always an unexpanded variable."
  }
}

variable "azs" {
  description = "Availability zones for the VPC, e.g. [\"us-east-1a\", \"us-east-1b\"]. Two is the minimum for the ALB and RDS multi-AZ. Required, because a default would silently belong to one region while aws_region says another."
  type        = list(string)

  validation {
    condition     = length(var.azs) >= 2
    error_message = "At least two AZs are required for the ALB and RDS multi-AZ."
  }

  validation {
    # Anchored regex, not startswith — startswith("eu-west-3", "eu-west-3") is
    # true (bare region string with no zone letter), and startswith("us-east-11a", "us-east-1")
    # would be true too if AWS ever ships a us-east-11. The plan fails deep inside
    # subnet creation with an opaque API error either way, so gate at plan.
    condition     = alltrue([for az in var.azs : length(regexall("^${var.aws_region}[a-z]$", az)) > 0])
    error_message = "Every entry in azs must be an availability zone of aws_region (they are named <region><letter>, e.g. \"eu-west-3a\")."
  }
}

variable "vpc_cidr" {
  description = "IPv4 CIDR block for the VPC. /16 gives room for the subnets and NAT gateways."
  type        = string
  default     = "10.10.0.0/16"
}

variable "rds_instance_class" {
  description = "RDS Postgres instance class. db.t4g.small is the SaaS default and fits comfortably up to ~50 employees; upsize for larger orgs."
  type        = string
  default     = "db.t4g.small"
}

variable "rds_storage_gb" {
  description = "RDS Postgres allocated storage in gigabytes."
  type        = number
  default     = 50
}

variable "rds_multi_az" {
  description = "Provision RDS in multi-AZ mode for failover. True by default; set false for a low-cost single-AZ install if you're comfortable with the tradeoff."
  type        = bool
  default     = true
}

# ARM-only: the Neo4j AMI is arm64-fixed, so this must be a Graviton family
# (t4g.*, c7g.*, m7g.*). t4g.small can be capacity-constrained in secondary
# regions (eu-west-3 in particular hangs RunInstances) — bump to t4g.medium
# or larger if the first apply stalls on Neo4j.
variable "neo4j_instance_type" {
  description = "EC2 instance type for the Neo4j box. Must be a Graviton (arm64) family. Default t4g.small is enough for early-stage graphs; step up to t4g.medium/large as the graph grows or if the region has patchy t4g.small capacity."
  type        = string
  default     = "t4g.small"
}

# NOT WIRED UP YET — a byoc install currently has no working login.
#
# Nothing in company_stack reads this variable today: it is accepted at plan time
# and then dropped. Byoc authentication is being built on a Dex sidecar in the
# reactive task (PRs #3097-#3101), and the final shape of the input — whether it
# stays a single secret ARN of this form, or Dex takes its connector config some
# other way — is decided by that stack, not here.
#
# Setting it is therefore harmless but does nothing. Leave it null until the Dex
# work lands, then re-read this block: it will either be repurposed or removed.
#
# The intent it encodes still holds: OIDC/IdP client credentials never travel
# through Ewake. The customer creates the app in their own IdP, stores the
# credentials in a Secrets Manager entry in THEIR OWN AWS account, and passes only
# an ARN. Ewake never sees the client secret.
variable "oidc_secret_arn" {
  description = "Reserved for byoc login; NOT consumed by any resource today. Byoc auth arrives with the Dex sidecar stack (#3097-#3101), which owns the final input shape. Leave null — setting it has no effect at plan or runtime."
  type        = string
  default     = null
  nullable    = true
}

locals {
  common_tags = {
    Project    = "ewake"
    Tenant     = var.tenant_name
    ManagedBy  = "terraform"
    Deployment = "byoc"
  }

  # Falls back to release_channel so the default install still tracks a channel.
  app_image_tag = coalesce(var.app_image_tag, var.release_channel)

  # Every Ewake image lives in Ewake's account. Constructed here (not via
  # terraform_remote_state) because a byoc root cannot read Ewake's state.
  ewake_ecr_registry = "${var.ewake_aws_account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
  # Mirrors terraform/shared/outputs.tf's ecr_repository_urls, minus orchestrator.
  # SaaS reads that output through terraform_remote_state and picks up new repos for
  # free; byoc hand-writes the map, so anything added there has to be added here too
  # or company_stack fails on a missing key.
  ecr_repository_urls = {
    reactive                 = "${local.ewake_ecr_registry}/ewake-reactive"
    "db-migrate"             = "${local.ewake_ecr_registry}/ewake-db-migrate"
    "cloudwatch-mcp"         = "${local.ewake_ecr_registry}/ewake-cloudwatch-mcp"
    "dex-sidecar"            = "${local.ewake_ecr_registry}/ewake-dex-sidecar"
    "log-clustering-sidecar" = "${local.ewake_ecr_registry}/ewake-log-clustering-sidecar"
  }

  # Container-image Lambdas company_stack consumes via var.lambda_image_uris.
  # Names match src/lambdas/<dir>/Dockerfile in the ewake-ai/back repo and are
  # pinned here because the byoc root has no way to introspect the Ewake-side
  # ECRs. rds-bootstrap and log-clustering are NOT here — they are pinned to
  # :latest in their own tf files (Ewake CI only publishes them under :latest).
  lambda_names = toset([
    "reactive",
    "datadog-log-analysis",
    "loki-log-analysis",
    "datadog-metric-analysis",
    "datadog-span-analysis",
    "knowledge-graph",
    "incident-indexing",
    "release-watch",
    "custom-mcp-discovery",
    "kubernetes-discovery",
  ])
  lambda_image_uris = {
    for name in local.lambda_names : name => "${local.ewake_ecr_registry}/ewake-lambda-${name}:${var.release_channel}"
  }
}
