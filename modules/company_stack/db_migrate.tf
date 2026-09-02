# The only thing that applies the Postgres chains — reactive's
# entrypoint deliberately does not migrate at boot.

resource "aws_cloudwatch_log_group" "ecs_db_migrate" {
  name              = "/${local.ssm_path}/db-migrate"
  retention_in_days = 14
  tags = merge(local.tags, {
    service = "db-migrate"
    env     = "production"
  })
}

# Its own execution role rather than reactive's: that one carries secrets CRUD
# across the whole deployment path, S3 delete, SQS send and unscoped Bedrock
# invoke — none of which this task needs to read one secret, run three chains
# and exit. Anything pulled into the image's dependency tree would otherwise
# inherit the lot.
data "aws_iam_policy_document" "db_migrate_execution_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "db_migrate_execution" {
  name               = "${local.arn_prefix}-db-migrate-execution"
  assume_role_policy = data.aws_iam_policy_document.db_migrate_execution_assume.json

  tags = local.tags
}

# Everything here is the ECS agent's, not the migration process's: pulling the
# image, resolving the `secrets` block into the environment, and opening the log
# stream. The process itself makes no AWS calls, which is why there is no task
# role below.
data "aws_iam_policy_document" "db_migrate_execution" {
  statement {
    sid       = "ECRPull"
    actions   = ["ecr:GetAuthorizationToken", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
    resources = ["*"] # ECR auth takes no resource qualifier.
  }

  statement {
    sid     = "MigrationLogsWrite"
    actions = ["logs:CreateLogStream", "logs:PutLogEvents"]
    # Only its own group — terraform creates it above, so no CreateLogGroup.
    resources = ["${aws_cloudwatch_log_group.ecs_db_migrate.arn}:*"]
  }

  statement {
    sid     = "CompanyDatabaseSecretRead"
    actions = ["secretsmanager:GetSecretValue"]
    # Only what the container definition references: the database credential, and the app
    # secret holding ADMIN_PASSWORD for the seed step. Without the second, the agent cannot
    # resolve the `secrets` entry and the task never starts — the plan still reads fine.
    resources = [
      aws_secretsmanager_secret.company_db.arn,
      aws_secretsmanager_secret.app[0].arn
    ]
  }
}

resource "aws_iam_role_policy" "db_migrate_execution" {
  name   = "${local.arn_prefix}-db-migrate-execution-policy"
  role   = aws_iam_role.db_migrate_execution.id
  policy = data.aws_iam_policy_document.db_migrate_execution.json
}

resource "aws_ecs_task_definition" "db_migrate" {
  family                   = "${local.arn_prefix}-db-migrate"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  # Smallest Fargate size; the chains are seconds of DDL, not a workload.
  cpu                = 256
  memory             = 512
  execution_role_arn = aws_iam_role.db_migrate_execution.arn
  # No task_role_arn on purpose: the chains reach Postgres over env the agent
  # injected and call no AWS API, so the container is handed no credentials at
  # all. Adding a call here means adding a task role with exactly its grants.

  container_definitions = jsonencode([
    merge(local.is_byoc ? {
      # The image's own migrate entrypoint rather than an inline chain. It runs the three
      # migrations in their load-bearing order (mastra's 0000 moves a table the common chain
      # creates) and then dist/common/db/seed.js, which seeds the company row, the system
      # user and the ADMIN_PASSWORD hash. Reactive used to seed itself and no longer
      # does, so spelling the chains out here would silently skip all three.
      command = ["sh", "src/reactive/docker-migrate.sh"]
      } : {}, {
      name = "db-migrate"
      # CI overrides this per deploy; only the first apply uses it.
      image     = var.db_migrate_image_uri
      essential = true
      environment = [
        { name = "NODE_ENV", value = "production" },
        { name = "AWS_REGION", value = var.aws_region },
        { name = "CLIENT", value = var.company.name },
        { name = "TENANT", value = var.tenant_name },
        # The seed step refuses to create a company row without this; reactive supplied it
        # when it did its own seeding.
        { name = "COMPANY_DOMAIN", value = var.company.domain },
        # Not 1: each chain probes the migrations table on one connection while
        # drizzle opens another for CREATE SCHEMA, so a pool of 1 deadlocks.
        { name = "POSTGRES_POOL_MAX", value = "5" },
        # This task resolves no URL, but the application requires them at startup in every
        # runtime. Without them it exits before the first migration chain runs,
        # which fails the gate in front of every deploy.
        { name = "PUBLIC_INBOUND_BASE_URL", value = local.public_inbound_base_url },
        { name = "DASHBOARD_BASE_URL", value = local.company_base_url },
        { name = "INTERNAL_BASE_URL", value = local.company_base_url },
        { name = "SSO_BASE_URL", value = local.dex_base_url },
      ]
      secrets = [
        { name = "POSTGRES_HOST", valueFrom = "${aws_secretsmanager_secret.company_db.arn}:host::" },
        { name = "POSTGRES_PORT", valueFrom = "${aws_secretsmanager_secret.company_db.arn}:port::" },
        { name = "POSTGRES_DB", valueFrom = "${aws_secretsmanager_secret.company_db.arn}:database::" },
        { name = "POSTGRES_USER", valueFrom = "${aws_secretsmanager_secret.company_db.arn}:username::" },
        { name = "POSTGRES_PASSWORD", valueFrom = "${aws_secretsmanager_secret.company_db.arn}:password::" },
        { name = "ADMIN_PASSWORD", valueFrom = "${aws_secretsmanager_secret.app[0].arn}:ADMIN_PASSWORD::" },
        # This task authenticates nothing, but the application requires both at startup —
        # the same reason the base URLs are set above.
        { name = "JWT_SECRET", valueFrom = "${aws_secretsmanager_secret.app[0].arn}:JWT_SECRET::" },
        { name = "ORCHESTRATOR_SECRET", valueFrom = local.orchestrator_secret_value_from },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.ecs_db_migrate.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "db-migrate"
        }
      }
    })
  ])

  tags = local.tags
}

# The database migration runs from terraform because this deployment has no CI of its own to
# run it. local-exec appears nowhere else in this repo; it is acceptable here because the
# install already requires an operator with the AWS CLI.
resource "terraform_data" "db_migrate" {
  count = local.is_byoc ? 1 : 0

  # Re-running is safe, but costs a Fargate cold start — keep a no-op apply a no-op.
  #
  # rds_resource_id, not just the task definition: a recreated instance keeps its
  # identifier, so its endpoint and this task definition are byte-identical and
  # nothing here would re-run — leaving an empty database and an image that refuses
  # to serve with "Database schema is behind this image". The DbiResourceId is the
  # one value that changes when the instance is rebuilt.
  triggers_replace = [aws_ecs_task_definition.db_migrate.arn, var.rds_resource_id]

  provisioner "local-exec" {
    interpreter = ["/bin/sh", "-c"]
    environment = {
      CLUSTER         = var.ecs_cluster_arn
      TASK_DEF        = aws_ecs_task_definition.db_migrate.arn
      SUBNETS         = join(",", var.private_subnets)
      SECURITY_GROUPS = join(",", [var.ecs_task_sg_id, aws_security_group.internal.id])
      AWS_REGION      = var.aws_region
    }
    command = <<-EOT
      set -eu
      started=$(aws ecs run-task \
        --cluster "$CLUSTER" \
        --task-definition "$TASK_DEF" \
        --launch-type FARGATE \
        --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$SECURITY_GROUPS],assignPublicIp=DISABLED}" \
        --query '{arn:tasks[0].taskArn,failure:failures[0].reason}' --output text)
      task_arn=$(echo "$started" | cut -f1)
      # RunTask reports capacity and subnet problems in failures[] with an HTTP 200 and an
      # empty tasks[], which the wait below would read as success.
      if [ "$task_arn" = "None" ]; then
        echo "db-migrate did not start: $(echo "$started" | cut -f2)" >&2
        exit 1
      fi
      echo "db-migrate task $task_arn"
      aws ecs wait tasks-stopped --cluster "$CLUSTER" --tasks "$task_arn"
      # A pull failure or OOM kill leaves exitCode null, so compare against a literal 0.
      exit_code=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$task_arn" \
        --query 'tasks[0].containers[0].exitCode' --output text)
      if [ "$exit_code" != "0" ]; then
        aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$task_arn" \
          --query 'tasks[0].[stoppedReason,containers[0].reason]' --output text >&2
        echo "db-migrate exited $exit_code — see /$${TASK_DEF##*/} logs" >&2
        exit 1
      fi
    EOT
  }

  # bootstrap_db CREATEs the database these chains connect to; sharing its secret dependency
  # does not order against it.
  depends_on = [
    aws_secretsmanager_secret_version.company_db,
    aws_lambda_invocation.bootstrap_db,
  ]
}
