# ECS service for the reactive dashboard (the long-running web app).
# The task pulls its image from the "reactive" ECR repo and connects to
# RDS through the DB credentials secret. Terraform pins a
# channel tag; CI owns the deployed tag.

locals {
  _admin_notify_env = !local.is_byoc && var.admin_notify_url != null ? [
    { name = "EWAKE_ADMIN_NOTIFY_URL", value = var.admin_notify_url }
  ] : []

  orchestrator_secret_value_from = local.is_byoc ? "${one(aws_secretsmanager_secret.app[*].arn)}:ORCHESTRATOR_SECRET::" : var.orchestrator_internal_token_secret_arn

  reactive_container_env = local.is_byoc ? [
    # Stated, not omitted: the tracer defaults to enabled and agentless, so silence buys a 30s stall on every boot.
    { name = "DD_FEATURE_FLAGS_ENABLED", value = "false" },
    # No agent sidecar here, so an initialised tracer would export to a refused localhost:8126 for the life of the task.
    { name = "DD_TRACE_ENABLED", value = "false" },
    ] : [
    { name = "GRAFANA_ENABLED", value = "true" },
    { name = "DD_ENV", value = "production" },
    # Per-container env: the sidecar's DD_SITE does not reach here, and agentless builds its endpoint from it.
    { name = "DD_SITE", value = "datadoghq.eu" },
    { name = "DD_AGENT_HOST", value = "localhost" },
    { name = "DD_LOGS_INJECTION", value = "true" },
    # Loads dd-trace at startup; without the agent sidecar it would retry a
    # refused localhost:8126 for the life of the task.
    { name = "NODE_OPTIONS", value = "-r dd-trace/init" },
    # The flag provider is a tracer feature, so turning tracing off here would disable flags with no error.
    { name = "DD_TRACE_ENABLED", value = "true" },
    { name = "DD_FEATURE_FLAGS_ENABLED", value = "true" },
    { name = "DD_FEATURE_FLAGS_CONFIGURATION_SOURCE", value = "agentless" },
    { name = "DD_FEATURE_FLAGS_CONFIGURATION_SOURCE_AGENTLESS_POLL_INTERVAL_SECONDS", value = "300" },
    # NODE_OPTIONS above inits the tracer first, so the provider is built before app code can pass its own timeout.
    { name = "DD_EXPERIMENTAL_FLAGGING_PROVIDER_INITIALIZATION_TIMEOUT_MS", value = "3000" },
    { name = "LANGSMITH_TRACING", value = "true" },
  ]

  _dbm_agent_extra_secrets = var.datadog_pg_secret_arn != null ? [
    { name = "DD_PG_PASSWORD", valueFrom = "${var.datadog_pg_secret_arn}:password::" }
  ] : []

  _dbm_agent_docker_labels = var.datadog_pg_secret_arn != null ? {
    "com.datadoghq.ad.checks" = jsonencode({
      postgres = {
        init_config = {}
        instances = [{
          dbm      = true
          host     = var.rds_endpoint
          port     = var.rds_port
          username = "datadog"
          password = "%%env_DD_PG_PASSWORD%%"
          dbname   = var.company.public_id
        }]
      }
    })
  } : {}
}

# Reactive-Lambda env injection can't use ECS secrets syntax, so we read the value here.
data "aws_secretsmanager_secret_version" "orchestrator_internal_token" {
  count     = var.orchestrator_internal_token_secret_arn != null ? 1 : 0
  secret_id = var.orchestrator_internal_token_secret_arn
}

resource "aws_cloudwatch_log_group" "ecs_reactive" {
  name              = "/${local.ssm_path}/reactive"
  retention_in_days = 14
  tags = merge(local.tags, {
    service = "reactive"
    env     = "production"
  })
}

resource "aws_ecs_task_definition" "reactive" {
  family                   = "${local.arn_prefix}-reactive"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.company.cpu
  memory                   = var.company.memory
  execution_role_arn       = aws_iam_role.task.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode(concat([
    {
      name = "reactive"
      # A channel pointer, not the newest ECR tag: resolving the real tag made every plan after a code deploy replace this revision.
      image     = var.reactive_service_image_uri
      essential = true
      portMappings = [
        { containerPort = 3000, protocol = "tcp" }
      ]
      environment = concat([
        { name = "NODE_ENV", value = "production" },
        { name = "PORT", value = "3000" },
        { name = "AWS_REGION", value = var.aws_region },
        # Scheduler role ARNs are built from it.
        { name = "AWS_ACCOUNT_ID", value = data.aws_caller_identity.current.account_id },
        { name = "CLIENT", value = var.company.name },
        { name = "COMPANY_DOMAIN", value = var.company.domain },
        # var.tenant_name, not terraform.workspace. This deployment uses no workspaces, so
        # the workspace is the literal "default". TENANT is half the key the application uses
        # to resolve frontend assets and integration secrets, so a wrong value here reads from
        # a path that was never written and that iam.tf does not grant.
        { name = "TENANT", value = var.tenant_name },
        # Absent, the application falls back to a default hostname it does not serve.
        { name = "EWAKE_BASE_URL", value = local.company_base_url },
        # Required at config import, and named for who reaches each. Identical behind a public
        # ALB; a private one moves only the first onto its public entry point.
        { name = "PUBLIC_INBOUND_BASE_URL", value = local.public_inbound_base_url },
        { name = "DASHBOARD_BASE_URL", value = local.company_base_url },
        { name = "INTERNAL_BASE_URL", value = local.company_base_url },
        { name = "DD_SERVICE", value = "reactive" },
        { name = "LAMBDA_QUEUE_URL", value = aws_sqs_queue.lambda.url },
        { name = "LOG_CLUSTERING_FUNCTION_NAME", value = var.log_clustering_function_name },
        ], local.log_clustering_sidecar_enabled ? [
        { name = "LOG_CLUSTERING_SIDECAR_URL", value = local.log_clustering_sidecar_url },
        ] : [], [
        # Dashboard API — low usage, and its ceiling doubles during a rolling
        # deploy. The connection budget is shared across all runtimes.
        { name = "POSTGRES_POOL_MAX", value = "3" },
        # Reactive is an OIDC client of the dex sidecar; the id has to be the same one
        # dex.tf registers as the static client.
        { name = "DEX_CLIENT_ID", value = local.dex_client_id },
        # The same origin the dex sidecar receives. Reactive sends the matching redirect_uri
        # and verifies the issuer against it, and Dex compares the two byte-for-byte — one
        # local feeding both containers is what keeps them from drifting apart.
        { name = "SSO_BASE_URL", value = local.dex_base_url },
        # Compiled from the per-connector secrets in dex.tf, identical to what the sidecar
        # gets, so the login page and Dex cannot disagree about which SSOs exist.
        { name = "DEX_CONNECTORS", value = local.dex_connectors },
        ],
        var.orchestrator_url != null ? [
          { name = "EWAKE_ORCHESTRATOR_URL", value = var.orchestrator_url }
        ] : [],
        local.reactive_container_env,
      local._admin_notify_env)
      secrets = concat([
        { name = "DEX_CLIENT_SECRET", valueFrom = local.dex_client_secret_value_from },
        { name = "POSTGRES_HOST", valueFrom = "${aws_secretsmanager_secret.company_db.arn}:host::" },
        { name = "POSTGRES_PORT", valueFrom = "${aws_secretsmanager_secret.company_db.arn}:port::" },
        { name = "POSTGRES_DB", valueFrom = "${aws_secretsmanager_secret.company_db.arn}:database::" },
        { name = "POSTGRES_USER", valueFrom = "${aws_secretsmanager_secret.company_db.arn}:username::" },
        { name = "POSTGRES_PASSWORD", valueFrom = "${aws_secretsmanager_secret.company_db.arn}:password::" },
        { name = "NEO4J_URI", valueFrom = "${aws_secretsmanager_secret.company_neo4j.arn}:NEO4J_URI::" },
        { name = "NEO4J_USERNAME", valueFrom = "${aws_secretsmanager_secret.company_neo4j.arn}:NEO4J_USERNAME::" },
        { name = "NEO4J_PASSWORD", valueFrom = "${aws_secretsmanager_secret.company_neo4j.arn}:NEO4J_PASSWORD::" },
        ],
        local.is_byoc ? [
          { name = "JWT_SECRET", valueFrom = "${one(aws_secretsmanager_secret.app[*].arn)}:JWT_SECRET::" },
          ] : [
          { name = "GRAFANA_USER_ID", valueFrom = "${one(data.aws_secretsmanager_secret.grafana[*].arn)}:grafana_user_id::" },
          { name = "GRAFANA_API_KEY", valueFrom = "${one(data.aws_secretsmanager_secret.grafana[*].arn)}:grafana_api_key::" },
          { name = "LANGSMITH_ENDPOINT", valueFrom = "${one(data.aws_secretsmanager_secret.langsmith[*].arn)}:ENDPOINT::" },
          { name = "LANGSMITH_PROJECT", valueFrom = "${one(data.aws_secretsmanager_secret.langsmith[*].arn)}:PROJECT::" },
          { name = "LANGSMITH_API_KEY", valueFrom = "${one(data.aws_secretsmanager_secret.langsmith[*].arn)}:API_KEY::" },
          { name = "DD_API_KEY", valueFrom = var.datadog_api_key_secret_arn },
        ],
        var.jwt_secret_arn != null ? [
          { name = "JWT_SECRET", valueFrom = "${var.jwt_secret_arn}:SECRET::" },
        ] : [],
        local.orchestrator_secret_value_from != null ? [
          { name = "ORCHESTRATOR_SECRET", valueFrom = local.orchestrator_secret_value_from },
        ] : [],
        var.github_app_secret_arn != null ? [
          { name = "GITHUB_CLIENT_ID", valueFrom = "${var.github_app_secret_arn}:CLIENT_ID::" },
          { name = "GITHUB_CLIENT_SECRET", valueFrom = "${var.github_app_secret_arn}:CLIENT_SECRET::" },
          { name = "GITHUB_APP_PRIVATE_KEY", valueFrom = "${var.github_app_secret_arn}:APP_PRIVATE_KEY::" },
        ] : [],
        var.notion_secret_arn != null ? [
          { name = "NOTION_CLIENT_ID", valueFrom = "${var.notion_secret_arn}:CLIENT_ID::" },
          { name = "NOTION_CLIENT_SECRET", valueFrom = "${var.notion_secret_arn}:CLIENT_SECRET::" },
        ] : [],
        var.slack_secret_arn != null ? [
          { name = "SLACK_CLIENT_ID", valueFrom = "${var.slack_secret_arn}:CLIENT_ID::" },
          { name = "SLACK_CLIENT_SECRET", valueFrom = "${var.slack_secret_arn}:CLIENT_SECRET::" },
          { name = "SLACK_AUTH_URL", valueFrom = "${var.slack_secret_arn}:AUTH_URL::" },
      ] : [])
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.ecs_reactive.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "reactive"
        }
      }
    }
    ],
    local.is_byoc ? [] : [
      {
        name      = "datadog-agent"
        image     = "public.ecr.aws/datadog/agent:7"
        essential = false
        environment = [
          { name = "ECS_FARGATE", value = "true" },
          { name = "DD_APM_ENABLED", value = "true" },
          { name = "DD_APM_NON_LOCAL_TRAFFIC", value = "true" },
          { name = "DD_DOGSTATSD_NON_LOCAL_TRAFFIC", value = "true" },
          { name = "DD_SITE", value = "datadoghq.eu" }
        ]
        secrets      = concat([{ name = "DD_API_KEY", valueFrom = var.datadog_api_key_secret_arn }], local._dbm_agent_extra_secrets)
        dockerLabels = local._dbm_agent_docker_labels
        logConfiguration = {
          logDriver = "awslogs"
          options = {
            awslogs-group         = aws_cloudwatch_log_group.ecs_reactive.name
            awslogs-region        = var.aws_region
            awslogs-stream-prefix = "datadog-agent"
          }
        }
      }
    ],
    local.dex_containers,
    local.cloudwatch_mcp_containers,
  local.log_clustering_sidecar_containers))

  tags = local.tags

  # Precondition (not `check`) so a missing token ARN fails at plan; the sidecar's EWAKE_INTERNAL_TOKEN sources from orchestrator_internal_token_secret_arn.
  lifecycle {
    precondition {
      condition     = !(var.company.features.cloudwatchMcpSidecar && var.orchestrator_internal_token_secret_arn == null)
      error_message = "features.cloudwatchMcpSidecar cannot be true without orchestrator_internal_token_secret_arn: the sidecar's EWAKE_INTERNAL_TOKEN sources from that secret."
    }

    # Agentless resolves its endpoint from DD_SITE and authenticates with DD_API_KEY, and a missing or
    # wrong one fails terminally and silently: 401/403 is never retried and nothing is logged. Env is
    # per-container, so the agent sidecar carrying both does not help this one.
    precondition {
      condition = !contains([for e in local.reactive_container_env : lookup(e, "value", "")], "agentless") || (
        # The value, not just the name: an empty DD_SITE fails at runtime exactly like a missing one.
        anytrue([for e in local.reactive_container_env : lookup(e, "name", "") == "DD_SITE" && trimspace(lookup(e, "value", "")) != ""]) &&
        var.datadog_api_key_secret_arn != null
      )
      error_message = "The reactive container sets agentless feature flags without a non-empty DD_SITE beside them, or without a Datadog API key secret to reference."
    }
  }
}

resource "aws_ecs_service" "reactive" {
  name            = var.company.name
  cluster         = var.ecs_cluster_arn
  task_definition = aws_ecs_task_definition.reactive.arn
  desired_count   = var.company.desired_count
  launch_type     = "FARGATE"

  # Enables `aws ecs execute-command … --interactive --command "/bin/bash"` on
  # this service's tasks. Paired with the ssmmessages:* grants on the task role
  # (see iam.tf).
  enable_execute_command = true

  # Block the apply until the new task set is steady. Paired with create_before_destroy,
  # this keeps a `name` change (the -reactive → plain rename) from tearing down the old
  # service before the new one is serving healthy targets.
  wait_for_steady_state = true

  network_configuration {
    subnets         = var.private_subnets
    security_groups = [var.ecs_task_sg_id, aws_security_group.internal.id]
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.reactive.arn
    container_name   = "reactive"
    container_port   = 3000
  }

  service_registries {
    registry_arn = aws_service_discovery_service.reactive.arn
  }

  # Task references neo4j and db secrets by ARN — terraform auto-tracks the
  # secret dependency, but not the secret VERSION. If a version's write is
  # delayed (neo4j_secret_version depends_on volume_attachment → EC2 → cloud-init),
  # ECS starts pulling the task early and every attempt fails with
  # `ResourceNotFoundException: no AWSCURRENT staging label`, then the service
  # hangs in wait_for_steady_state forever. Explicit depends_on closes the race.
  #
  # db_migrate keeps a fresh install from serving an empty schema.
  depends_on = [
    aws_secretsmanager_secret_version.company_neo4j,
    aws_secretsmanager_secret_version.company_db,
    terraform_data.db_migrate,
  ]

  # CI owns the image tag — it registers a new task definition revision on each
  # deploy (`aws ecs register-task-definition`) and points the service at it.
  # Terraform stays on its own revision; ignore_changes prevents it from reverting
  # the service back. Infra changes terraform makes to container_definitions
  # (env vars, log config) take effect on the next CI deploy, because CI bases
  # its new revision on the latest one (which IS terraform's by then).
  #
  # create_before_destroy keeps a `name` change non-disruptive: the new service
  # registers with the (unchanged) target group and reaches steady state before
  # the old service is torn down, so the listener rule always has a healthy target.
  lifecycle {
    ignore_changes        = [task_definition]
    create_before_destroy = true

    # The log-clustering sidecar keeps its drain3 miner in process memory, and the
    # discovery record is MULTIVALUE — a second task would hand consecutive requests
    # to a second miner and make the templates a query returns depend on which one
    # answered. Scaling reactive out means giving that sidecar shared state first.
    precondition {
      condition     = !local.log_clustering_sidecar_enabled || var.company.desired_count == 1
      error_message = "features.logClusteringSidecar requires desired_count = 1 (got ${var.company.desired_count}): the sidecar's drain3 miner is per-process state."
    }
  }

  tags = { for k, v in local.tags : k => v if k != "Tenant" }
}

# lifecycle takes no expressions, so ignore_changes above cannot be conditional.
# Without this an apply registers a revision nobody rolls onto: the migration runs
# and the old image keeps serving.
resource "terraform_data" "reactive_deploy" {
  count = local.is_byoc ? 1 : 0

  triggers_replace = [aws_ecs_task_definition.reactive.arn]

  provisioner "local-exec" {
    interpreter = ["/bin/sh", "-c"]
    environment = {
      CLUSTER    = var.ecs_cluster_arn
      SERVICE    = aws_ecs_service.reactive.name
      TASK_DEF   = aws_ecs_task_definition.reactive.arn
      AWS_REGION = var.aws_region
    }
    command = <<-EOT
      set -eu
      current=$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
        --query 'services[0].taskDefinition' --output text)
      # A fresh install is created on this revision already, and update-service would still
      # start a second deployment of the identical task.
      if [ "$current" = "$TASK_DEF" ]; then
        echo "reactive already on $${TASK_DEF##*/}"
        exit 0
      fi
      aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" \
        --task-definition "$TASK_DEF" >/dev/null
      echo "reactive rolling onto $${TASK_DEF##*/}"
      aws ecs wait services-stable --cluster "$CLUSTER" --services "$SERVICE"
    EOT
  }

  # Ordered behind the migration, not just the service: the point is that the new image never
  # serves before the schema it expects exists.
  depends_on = [
    aws_ecs_service.reactive,
    terraform_data.db_migrate,
  ]
}

resource "aws_cloudwatch_log_subscription_filter" "reactive_ecs_to_datadog" {
  count           = local.is_byoc ? 0 : 1
  name            = "${local.arn_prefix}-reactive-ecs-to-datadog"
  log_group_name  = aws_cloudwatch_log_group.ecs_reactive.name
  filter_pattern  = ""
  destination_arn = var.datadog_forwarder_arn
}
