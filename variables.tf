# Contact Ewake to add a region: the images must be replicated there first.
variable "aws_region" {
  description = "AWS region to deploy into. Only eu-west-3 is supported."
  type        = string
  default     = "eu-west-3"

  validation {
    condition     = contains(["eu-west-3"], var.aws_region)
    error_message = "aws_region must be one of: eu-west-3. Ewake's container images are only published there, so any other region fails at image pull with a hostname that does not exist. Ask your Ewake contact to add the region you need."
  }
}

# Usually the same as company.name. The two stay separate so resource and ARN
# prefixes keep one shape.
variable "tenant_name" {
  description = "Identifier for this deployment. Lowercase letters and digits, starting with a letter, 21 characters maximum. Used in resource names."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{0,20}$", var.tenant_name))
    error_message = "tenant_name must be lowercase alphanumeric, start with a letter, and be at most 21 chars (so the ALB name stays under the 32-char AWS limit)."
  }
}

variable "company" {
  description = "The company served by this deployment: name, public_id, domain, and the SSO connector IDs to enable."
  type = object({
    name          = string
    public_id     = string
    domain        = string
    cpu           = optional(number, 1024)
    memory        = optional(number, 2048)
    desired_count = optional(number, 1)
    # Empty is a trap: Dex refuses to start with no connectors, so the sidecar dies on boot
    # while reactive keeps serving — a healthy-looking deployment nobody can sign in to.
    # Each redirect URI is this deployment's own host.
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
  description = "Domain you own and have delegated to a Route53 hosted zone in this account."
  type        = string
}

variable "company_host" {
  description = "Host the dashboard is served on. Defaults to <company.name>.<root_domain>. Must be root_domain itself or one label under it, unless you supply your own certificate."
  type        = string
  default     = null

  validation {
    # Only binding while acm.tf issues the cert. A customer-supplied certificate
    # carries whatever names they put on it, so the wildcard's one-label reach
    # stops being our constraint to enforce.
    condition = (
      var.acm_certificate_arn != null ||
      var.company_host == null ||
      var.company_host == var.root_domain ||
      (
        endswith(var.company_host, ".${var.root_domain}") &&
        !strcontains(trimsuffix(var.company_host, ".${var.root_domain}"), ".")
      )
    )
    error_message = "company_host must be root_domain itself or exactly one label under it; the ACM cert covers only root_domain and *.root_domain. Set acm_certificate_arn to bring your own certificate instead."
  }
}

# Set alb_internal and alb_ingress_cidrs together: `internal` only removes the
# public addresses, the security group is what refuses a packet.
variable "transit_gateway_id" {
  description = "Transit gateway to attach this VPC to. It must already be shared with this account. Null creates no attachment."
  type        = string
  default     = null
}

variable "transit_gateway_routes" {
  description = "CIDRs reached through the transit gateway, added to every private route table. The gateway owner must route back to this VPC's CIDR."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.transit_gateway_routes) == 0 || var.transit_gateway_id != null
    error_message = "transit_gateway_routes needs transit_gateway_id set; a route to no gateway cannot be created."
  }
}

variable "alb_internal" {
  description = "Give the load balancer private addresses only. Cannot be changed after the first apply."
  type        = bool
  default     = false
}

variable "alb_ingress_cidrs" {
  description = "CIDRs allowed to reach the load balancer on 443 and 80. Editable at any time."
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition     = length(var.alb_ingress_cidrs) > 0
    error_message = "alb_ingress_cidrs must list at least one CIDR; an empty list makes the dashboard unreachable by anything, including a port-forward."
  }
}

variable "hosted_zone_id" {
  description = "Route53 hosted zone for root_domain, in this account. Terraform creates the DNS record and the certificate. Set to null to own both yourself, and supply acm_certificate_arn."
  type        = string
  default     = null
}

variable "acm_certificate_arn" {
  description = "Your own certificate for company_host, in aws_region. Required when hosted_zone_id is null. You own its renewal."
  type        = string
  default     = null

  validation {
    condition     = var.acm_certificate_arn != null || var.hosted_zone_id != null
    error_message = "Set hosted_zone_id (so Terraform can issue and validate a certificate) or acm_certificate_arn (to supply your own). With neither, the HTTPS listener has no certificate and there is no way to obtain one."
  }

  validation {
    condition     = var.acm_certificate_arn == null || can(regex("^arn:aws[a-z-]*:acm:", var.acm_certificate_arn))
    error_message = "acm_certificate_arn must be an ACM certificate ARN. An IAM server certificate or a bare certificate ID will not attach to the listener."
  }
}

variable "extra_certificate_arns" {
  description = "Extra certificates on the HTTPS listener. Used during a hostname change to serve the old and new names at once."
  type        = list(string)
  default     = []
}

variable "alb_extra_host_headers" {
  description = "Extra hostnames the listener routes. Used with extra_certificate_arns during a hostname change."
  type        = list(string)
  default     = []
}

variable "ewake_aws_account_id" {
  description = "AWS account that owns the Ewake image repositories. Override only if Ewake tells you to."
  type        = string
  default     = "058264427976"

  validation {
    condition     = can(regex("^\\d{12}$", var.ewake_aws_account_id))
    error_message = "ewake_aws_account_id must be a 12-digit AWS account ID."
  }
}



variable "app_image_tag" {
  description = "Application version this deployment runs. Required. A moving tag such as \"stable\" is rejected, because only an apply from this repository migrates the database."
  type        = string
  nullable    = false

  # A moving channel would let an unrelated task replacement pick up a new image
  # with no migration having run.
  validation {
    condition     = !contains(["stable", "latest", "main"], var.app_image_tag)
    error_message = "app_image_tag must name a specific build (e.g. \"ewake-v0.153.0\"), not a channel. A channel tag moves under a running deployment and nothing here would migrate the database to match it."
  }

  validation {
    condition     = trimspace(var.app_image_tag) != ""
    error_message = "app_image_tag must not be empty; an empty string is almost always an unexpanded variable."
  }
}

variable "azs" {
  description = "Availability zones to use, two or more, all in aws_region."
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
  description = "CIDR for the VPC. Changing it later requires a rebuild, not an apply."
  type        = string
  default     = "10.10.0.0/16"
}

variable "rds_subnet_group_name" {
  description = "Existing DB subnet group name to keep, for a deployment created before this repository generated the name. Leave unset otherwise. See UPGRADING.md."
  type        = string
  default     = null
}

variable "rds_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.small"
}

variable "rds_storage_gb" {
  description = "RDS allocated storage, in GB."
  type        = number
  default     = 50
}

variable "rds_multi_az" {
  description = "Run RDS across two availability zones."
  type        = bool
  default     = true
}

# The Neo4j AMI is arm64, so this must be a Graviton family (t4g.*, c7g.*, m7g.*).
# or larger if the first apply stalls on Neo4j.
variable "neo4j_instance_type" {
  description = "EC2 instance type for Neo4j. Must be a Graviton (arm64) type."
  type        = string
  default     = "t4g.small"
}

locals {
  common_tags = {
    Project    = "ewake"
    Tenant     = var.tenant_name
    ManagedBy  = "terraform"
    Deployment = "byoc"
  }

  # No coalesce onto a channel: app_image_tag is required and refuses a channel name,
  # so there is nothing to fall back to. It now pins the Lambda images too.
  app_image_tag = var.app_image_tag

  # Resolved once here and passed down, so the root output and the module cannot
  # disagree about which name this deployment answers on.
  company_host = coalesce(var.company_host, "${var.company.name}.${var.root_domain}")

  # The two halves of the edge are owned independently. A customer can hand us a
  # zone and no cert, a cert and no zone, both, or — the common case — just the
  # zone. Everything downstream reads these rather than re-deriving the test.
  manage_dns         = var.hosted_zone_id != null
  manage_certificate = var.acm_certificate_arn == null
  certificate_arn    = local.manage_certificate ? aws_acm_certificate_validation.this[0].certificate_arn : var.acm_certificate_arn

  # Every Ewake image lives in Ewake's account.
  ewake_ecr_registry = "${var.ewake_aws_account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
  ecr_repository_urls = {
    reactive                 = "${local.ewake_ecr_registry}/ewake-reactive"
    "cloudwatch-mcp"         = "${local.ewake_ecr_registry}/ewake-cloudwatch-mcp"
    "dex-sidecar"            = "${local.ewake_ecr_registry}/ewake-dex-sidecar"
    "log-clustering-sidecar" = "${local.ewake_ecr_registry}/ewake-log-clustering-sidecar"
  }

  # Container-image Lambdas company_stack consumes via var.lambda_image_uris.
  # Only reactive is left: the nine scheduled Lambdas are folded
  # into the single ewake-lambdas bundle below and deleted their per-Lambda
  # ECR repos, so pinning them here would resolve to tags CI no longer moves.
  # rds-bootstrap and log-clustering are NOT here — they are pinned to :latest
  # in their own tf files (Ewake CI only publishes them under :latest).
  lambda_names = toset([
    "reactive",
  ])
  lambda_image_uris = {
    for name in local.lambda_names : name => "${local.ewake_ecr_registry}/ewake-lambda-${name}:${local.app_image_tag}"
  }

  # The nine scheduled Lambdas all run from this one image, each picking its
  # handler via image_config. Pinned to app_image_tag for the same reason the
  # server is: a channel tag moves in ECR under a running deployment, and
  # nothing here would migrate the database to match it. Lambda resolves a tag
  # to a digest once, at deploy time, so a retag does not move a running
  # function — it moves at the *next* unrelated update, to whatever the channel
  # points at then, with no migration having run. Naming the version makes the
  # whole deployment advance as one act.
  lambda_bundle_image_uri = "${local.ewake_ecr_registry}/ewake-lambdas:${local.app_image_tag}"
}

variable "public_inbound_base_url" {
  description = "Public URL that Slack and Datadog use to reach this deployment, when the load balancer is private and you run your own entry point in front of it."
  type        = string
  default     = null

  validation {
    condition     = var.public_inbound_base_url == null || can(regex("^https://", var.public_inbound_base_url))
    error_message = "public_inbound_base_url must be an https:// URL; Slack and Datadog refuse to deliver to anything else."
  }
}

variable "public_inbound_gateway" {
  description = "Create an API Gateway in front of a private load balancer, routing only the paths third parties call."
  type        = bool
  default     = false
}
