locals {
  # Every Lambda in this submodule inherits Type = "Scheduled". Each Lambda
  # still adds its own Service = "<name>" tag in its own file.
  scheduled_tags = merge(var.tags, { Type = "Scheduled" })

  vpc_security_group_ids = compact([var.ecs_task_sg_id, var.internal_sg_id])

  # Gate on the bool, never on the secret: a condition over a sensitive value marks the
  # whole env map sensitive, redacting all 25 vars from every plan instead of the four.
  langsmith_secret = var.langsmith_enabled ? jsondecode(var.langsmith_secret_string) : null

  langsmith_env = var.langsmith_enabled ? {
    LANGSMITH_TRACING  = "true"
    LANGSMITH_ENDPOINT = local.langsmith_secret["ENDPOINT"]
    LANGSMITH_PROJECT  = local.langsmith_secret["PROJECT"]
    LANGSMITH_API_KEY  = local.langsmith_secret["API_KEY"]
  } : {}

  # Shared env vars across the scheduled Lambdas. DD_SERVICE is set per-Lambda
  # in each <lambda>.tf.
  scheduled_lambda_env_common = merge({
    NODE_ENV = "production"
    # DEP0040: transitive node-fetch@2 (via @google-cloud/logging and @datadog/datadog-api-client)
    # requires the deprecated punycode builtin at init; the warning hits stderr on every cold start
    # and lands in Datadog as an error-status log. Suppress until the dependency chain drops it.
    NODE_OPTIONS      = "--enable-source-maps --disable-warning=DEP0040"
    CLIENT            = var.company.name
    TENANT            = var.tenant_name
    POSTGRES_HOST     = var.rds_endpoint
    POSTGRES_PORT     = tostring(var.rds_port)
    POSTGRES_DB       = var.company.public_id
    POSTGRES_USER     = "${var.company.name}_app"
    POSTGRES_PASSWORD = var.postgres_password
    # Background work — smallest pool of the three runtimes so the reactive
    # Lambda keeps slots available. The connection budget is shared across all runtimes.
    POSTGRES_POOL_MAX            = "2"
    NEO4J_URI                    = var.neo4j_uri
    NEO4J_USERNAME               = var.neo4j_username
    NEO4J_PASSWORD               = var.neo4j_password
    AMBIENT_AGENT_PERIOD_MINUTES = 15
    LOG_CLUSTERING_SIDECAR_URL   = var.log_clustering_sidecar_url
    }, var.cloudwatch_mcp_url != null ? {
    # The CloudWatch survey is the second consumer of a sidecar after the dashboard, and reads
    # this exact variable name. Null already means the feature is off, so nothing is re-tested
    # here — and without it the survey treats the estate as having no connected region and skips
    # every run.
    CLOUDWATCH_MCP_SERVER_URL = var.cloudwatch_mcp_url
  } : {}, var.datadog_base_env, local.langsmith_env)

  # Agentless because this is the one runtime with neither an agent nor an extension to carry remote config.
  # Gated on the bool, never on the key: a condition over a sensitive value marks the whole env map sensitive.
  flag_env = var.datadog_enabled ? {
    DD_FEATURE_FLAGS_ENABLED                                              = "true"
    DD_FEATURE_FLAGS_CONFIGURATION_SOURCE                                 = "agentless"
    DD_FEATURE_FLAGS_CONFIGURATION_SOURCE_AGENTLESS_POLL_INTERVAL_SECONDS = "300"
    DD_API_KEY                                                            = var.datadog_api_key
    } : {
    # Stated, not omitted: the tracer defaults to enabled and agentless, so silence buys a 30s stall on every cold start.
    DD_FEATURE_FLAGS_ENABLED = "false"
    # With no agent to receive spans, an initialised tracer would export to a port nothing listens on.
    DD_TRACE_ENABLED = "false"
  }
}
