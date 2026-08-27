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

# The customer's own "tenant" identity — used in resource names and log prefixes.
# Kept
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
  description = "Public root domain the customer owns and delegates to Route53 in this AWS account. The reactive dashboard is served at var.company_host, which defaults to <company.name>.<root_domain>."
  type        = string
}

variable "company_host" {
  description = <<-EOT
    Fully-qualified host the dashboard is served on. Defaults to
    <company.name>.<root_domain> — the shape saas uses, and what every existing
    deployment already has, so leaving it unset is a no-op.

    Set it to var.root_domain to serve the zone apex instead. That is the byoc
    case where the customer delegates a subdomain of a domain they own (e.g.
    ewake.qonto.co) and wants to be reached at exactly that name, with no
    further prefix in front of it.

    Constrained to root_domain or a single label under it because acm.tf issues
    one cert for root_domain + *.root_domain, and a wildcard matches one label
    only: a.b.root_domain would resolve and then fail the TLS handshake.
  EOT
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

# Both default to today's public shape, so an existing deployment sees no diff.
# Set them together: an internal ALB still needs the ingress rule narrowed, since
# the security group is what actually refuses the packet — `internal` only removes
# the public IPs.
# Attaching to a customer-owned transit gateway is how a private deployment is
# reached from their corporate network, and it replaces the SSM port-forward in
# the README once it is up.
variable "transit_gateway_id" {
  description = "Transit gateway to attach this VPC to, e.g. a customer's org-level TGW shared into the account via RAM. Null (default) creates no attachment. The TGW must already be shared with this account; check `aws ec2 describe-transit-gateways` can see it before setting this."
  type        = string
  default     = null
}

variable "transit_gateway_routes" {
  description = "CIDRs reached through var.transit_gateway_id, added to every private route table (e.g. [\"10.38.0.0/23\"] for a VPN range). Ignored when transit_gateway_id is null. Return traffic depends on the TGW's own route table propagating this VPC's CIDR, which is the TGW owner's side unless DefaultRouteTablePropagation is enabled."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.transit_gateway_routes) == 0 || var.transit_gateway_id != null
    error_message = "transit_gateway_routes needs transit_gateway_id set; a route to no gateway cannot be created."
  }
}

variable "alb_internal" {
  description = "Whether the tenant ALB is internal (private IPs, no public listener). Default false keeps the internet-facing shape. When true the ALB also moves to the private subnets, and the dashboard is reachable only from inside the VPC — over VPN, a peered network, or an SSM port-forward (see the README)."
  type        = bool
  default     = false
}

variable "alb_ingress_cidrs" {
  description = "CIDRs allowed to reach the ALB on 443 and 80. Default is the public internet. Narrow this to the VPC CIDR (or a VPN range) for a private deployment; ACM validation is unaffected either way, since it reads DNS rather than connecting to the load balancer."
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition     = length(var.alb_ingress_cidrs) > 0
    error_message = "alb_ingress_cidrs must list at least one CIDR; an empty list makes the dashboard unreachable by anything, including a port-forward."
  }
}

variable "hosted_zone_id" {
  description = <<-EOT
    Route53 hosted zone for var.root_domain, in this account. Terraform writes
    the ACM validation records and the dashboard's A alias here, so the zone must
    exist before apply and be reachable from the public internet — ACM resolves
    validation over public DNS and cannot see a private hosted zone.

    Null hands DNS back to the customer: no zone is touched and no A record is
    created. That is the shape for an organisation whose hostname lives in a
    private zone, or in a parent zone in an account we have no access to. It
    requires acm_certificate_arn, since without a writable public zone Terraform
    has nowhere to prove domain control. After apply, point the hostname at the
    `alb_dns_name` output; `dns_wiring` prints exactly what to create.
  EOT
  type        = string
  default     = null
}

variable "acm_certificate_arn" {
  description = <<-EOT
    Existing ACM certificate for var.company_host, in var.aws_region. Null
    (default) makes acm.tf issue and DNS-validate one in var.hosted_zone_id,
    which is what every deployment that delegates a zone to us should do —
    renewal is then automatic and nobody has to remember a record.

    Set it when the customer owns DNS: they issue the certificate (or import
    one from their own CA) and hand us the ARN. Two things become theirs to
    keep alive — the certificate's renewal validation record, and the A record
    for company_host. Neither failure is visible from this stack.

    The certificate must cover var.company_host exactly; a wildcard reaches one
    label only, so a cert for *.example.com does not serve a.b.example.com.
  EOT
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
  description = <<-EOT
    Additional ACM certificates attached to the HTTPS listener as SNI
    certificates, beyond the default one. Empty (default) is the normal shape.

    This exists for hostname cutovers: serve the old name and the new one at the
    same time, move traffic, then drop the old entry. Attaching a certificate
    here does not route anything — the listener rule matches var.company_host,
    so a request arriving on one of these names completes the TLS handshake and
    then gets the listener's 404. Pair it with alb_extra_host_headers.
  EOT
  type        = list(string)
  default     = []
}

variable "alb_extra_host_headers" {
  description = "Extra Host values routed to the dashboard alongside var.company_host. Empty (default) matches company_host only. Set during a hostname migration so both names serve, and remember each one also needs a certificate the listener can present — see extra_certificate_arns."
  type        = list(string)
  default     = []
}

variable "ewake_aws_account_id" {
  description = "AWS account ID that owns the Ewake ECRs. Used to build every image URI (reactive, cloudwatch-mcp, log-clustering-sidecar, the ewake-lambdas bundle, every remaining ewake-lambda-*). Pull is authorized by the aws_ecr_repository_policy Ewake attaches to those repos via terraform/shared/byoc_customers.tf — note the bundle is granted by its own byoc_lambda_bundle resource, so an account cleared for the per-Lambda repos is not automatically cleared for it. Defaults to Ewake's production account — override only if Ewake has told you a different one."
  type        = string
  default     = "058264427976"

  validation {
    condition     = can(regex("^\\d{12}$", var.ewake_aws_account_id))
    error_message = "ewake_aws_account_id must be a 12-digit AWS account ID."
  }
}

variable "release_channel" {
  description = "Which Ewake release stream the Lambda images follow: 'stable' (default; released images) or 'latest' (main-merge, dogfood). Reactive and db-migrate are not affected — they run app_image_tag, which is required."
  type        = string
  default     = "stable"

  validation {
    condition     = contains(["latest", "stable"], var.release_channel)
    error_message = "release_channel must be 'latest' or 'stable'."
  }
}

# Lambda images only, since the dashboard stopped being served from S3: the reactive
# image now carries its own frontend, so there is no channel pointer to resolve and
# no artifacts bucket to read. Lambda tags do not exist for every commit, which is
# why they still follow a channel rather than app_image_tag.

variable "app_image_tag" {
  description = "Immutable ECR tag the reactive service and its db-migrate task run, e.g. \"ewake-v0.153.0\". Required: a deployment must state which build it runs. Does not affect the Lambda images, which follow release_channel."
  type        = string
  nullable    = false

  # Required, and a channel name is refused. Both rules exist for the same reason:
  # nothing migrates a byoc database except an apply from this repo, and the image
  # refuses to serve a schema behind it (assertSchemaIsCurrent). Following a mutable
  # channel therefore means a release retagging it turns the NEXT task replacement —
  # a deploy, a scale event, a Fargate host retirement — into an outage at a moment
  # nobody chose, with no migration having run. Naming a version instead makes the
  # upgrade an act: bump this, plan, apply. reactive_deploy depends_on db_migrate,
  # so the migration always lands before the new image serves.
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
  description = "IPv4 CIDR block for the VPC. /16 gives room for the subnets and NAT gateways. AWS cannot change a VPC's primary CIDR, so on an existing deployment set subnet_cidr instead and leave this alone."
  type        = string
  default     = "10.10.0.0/16"
}

# Editing vpc_cidr on a live deployment replaces the VPC and everything in it,
# including the ALB — whose DNS name the customer owns a record for and would have
# to repoint by hand. This exists so the subnets can move to a new range without
# that: AWS lets a VPC carry secondary CIDRs, and aws_lb.subnets is mutable, so the
# load balancer moves with its ARN and DNS name intact.
variable "subnet_cidr" {
  description = "IPv4 CIDR the subnets are carved from. Defaults to vpc_cidr. Set it to a different range to move the subnets there: it is associated to the VPC as a secondary CIDR and the primary is left in place (AWS cannot remove a primary). Must be at least a /20 — the subnets are /24s carved with cidrsubnet(_, 4, n)."
  type        = string
  default     = null

  validation {
    condition     = var.subnet_cidr == null || can(cidrsubnet(coalesce(var.subnet_cidr, "10.0.0.0/20"), 4, 3))
    error_message = "subnet_cidr must be a valid CIDR no smaller than a /20."
  }
}

# AWS will not move a DB instance between subnet groups inside one VPC
# (InvalidVPCNetworkStateFault), so a subnet_cidr move recreates it from a
# snapshot rather than relocating it — which needs this off for one apply.
variable "rds_deletion_protection" {
  description = "Guards the database against terraform destroying it. Leave true. Set false only for the single apply that recreates the instance during a subnet_cidr move, and put it back afterwards."
  type        = bool
  default     = true
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

locals {
  common_tags = {
    Project    = "ewake"
    Tenant     = var.tenant_name
    ManagedBy  = "terraform"
    Deployment = "byoc"
  }

  # No coalesce onto release_channel: app_image_tag is required and refuses a channel name,
  # so there is nothing to fall back to. release_channel still selects the Lambda images.
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

  # Every Ewake image lives in Ewake's account. Constructed here (not via
  # terraform_remote_state) because a byoc root cannot read Ewake's state.
  ewake_ecr_registry = "${var.ewake_aws_account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
  # Mirrors terraform/shared/outputs.tf's ecr_repository_urls, minus orchestrator.
  # SaaS reads that output through terraform_remote_state and picks up new repos for
  # free; byoc hand-writes the map, so anything added there has to be added here too
  # or company_stack fails on a missing key.
  ecr_repository_urls = {
    reactive                 = "${local.ewake_ecr_registry}/ewake-reactive"
    "cloudwatch-mcp"         = "${local.ewake_ecr_registry}/ewake-cloudwatch-mcp"
    "dex-sidecar"            = "${local.ewake_ecr_registry}/ewake-dex-sidecar"
    "log-clustering-sidecar" = "${local.ewake_ecr_registry}/ewake-log-clustering-sidecar"
  }

  # Container-image Lambdas company_stack consumes via var.lambda_image_uris.
  # Only reactive is left: ewake-ai/back#3124 folded the nine scheduled Lambdas
  # into the single ewake-lambdas bundle below and deleted their per-Lambda
  # ECR repos, so pinning them here would resolve to tags CI no longer moves.
  # rds-bootstrap and log-clustering are NOT here — they are pinned to :latest
  # in their own tf files (Ewake CI only publishes them under :latest).
  lambda_names = toset([
    "reactive",
  ])
  lambda_image_uris = {
    for name in local.lambda_names : name => "${local.ewake_ecr_registry}/ewake-lambda-${name}:${var.release_channel}"
  }

  # The nine scheduled Lambdas all run from this one image, each picking its
  # handler via image_config. Follows release_channel like the rest of the
  # fleet — app_image_tag does not pin it (see the image-pinning note in the
  # README).
  lambda_bundle_image_uri = "${local.ewake_ecr_registry}/ewake-lambdas:${var.release_channel}"
}

variable "public_inbound_base_url" {
  description = <<-EOT
    Public https base URL that Slack and Datadog use to reach this deployment, when that is
    not the dashboard host.

    Only needed with alb_internal = true. A private ALB has no route from the internet, so
    inbound webhooks need a public entry point in front of it; set this to that entry point's
    URL and the Slack manifest and Datadog webhook are registered against it. The dashboard
    keeps answering on the private host either way.

    Leave null when the ALB is public — both roles are then the same name.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.public_inbound_base_url == null || can(regex("^https://", var.public_inbound_base_url))
    error_message = "public_inbound_base_url must be an https:// URL; Slack and Datadog refuse to deliver to anything else."
  }
}

variable "public_inbound_gateway" {
  description = <<-EOT
    Put a public API Gateway in front of the private ALB so inbound webhooks can
    reach this deployment.

    Only meaningful with alb_internal = true; a public ALB already answers these
    paths itself. Slack and Datadog cannot route to an internal load balancer, so
    without this their integrations install cleanly and then never deliver.

    Four paths are routed and nothing else: the two Slack callbacks, the Datadog
    webhook, and the icon Slack fetches to render a message block. The dashboard,
    the API and SSO stay unreachable from the internet.

    Requests are authenticated by the caller, not by the network: Slack signs
    every request and the deployment verifies the signature against a five-minute
    replay window, and the Datadog webhook carries a per-integration token in its
    path. Set public_inbound_base_url instead if you already run your own entry
    point and would rather keep it.
  EOT
  type        = bool
  default     = false
}
