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

  # Shared env vars across the scheduled fleet. DD_SERVICE is set per-Lambda
  # in each <lambda>.tf — these used to share "ambient" as their DD_SERVICE,
  # we now split per-Lambda.
  scheduled_lambda_env_common = merge({
    NODE_ENV = "production"
    # DEP0040: transitive node-fetch@2 (via @google-cloud/logging and @datadog/datadog-api-client)
    # requires the deprecated punycode builtin at init; the warning hits stderr on every cold start
    # and lands in Datadog as an error-status log. Suppress until the dependency chain drops it.
    NODE_OPTIONS      = "--enable-source-maps --disable-warning=DEP0040"
    CLIENT            = var.company.name
    TENANT            = terraform.workspace
    POSTGRES_HOST     = var.rds_endpoint
    POSTGRES_PORT     = tostring(var.rds_port)
    POSTGRES_DB       = var.company.public_id
    POSTGRES_USER     = "${var.company.name}_app"
    POSTGRES_PASSWORD = var.postgres_password
    # Background work — smallest pool of the three runtimes so the reactive
    # Lambda keeps slots available. Budget lives in src/core/db.
    POSTGRES_POOL_MAX            = "2"
    NEO4J_URI                    = var.neo4j_uri
    NEO4J_USERNAME               = var.neo4j_username
    NEO4J_PASSWORD               = var.neo4j_password
    AMBIENT_AGENT_PERIOD_MINUTES = 15
    LOG_CLUSTERING_FUNCTION_NAME = var.log_clustering_function_name
    }, var.log_clustering_sidecar_url != null ? {
    LOG_CLUSTERING_SIDECAR_URL = var.log_clustering_sidecar_url
  } : {}, var.datadog_base_env, local.langsmith_env)
}
