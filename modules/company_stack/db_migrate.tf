# The only thing that applies the Postgres chains in either deployment mode — reactive's
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
# across the whole company path, S3 delete, SQS send, unscoped Bedrock invoke and
# the cross-account BYOC assume — none of which this task needs to read one
# secret, run three chains and exit. Anything pulled into the image's dependency
# tree would otherwise inherit the lot.
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
    # The one secret the container definition references, and nothing else.
    resources = [aws_secretsmanager_secret.company_db.arn]
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
      # Order is load-bearing: mastra's 0000 moves a table the common chain creates (42P01).
      command = ["sh", "-c", "node dist/common/db/migrate.js && node dist/reactive/db/migrate.js && node dist/mastra/db/migrate.js"]
      } : {}, {
      name = "db-migrate"
      # CI overrides this per deploy; only a new company's first apply uses it.
      image     = var.db_migrate_image_uri
      essential = true
      environment = [
        { name = "NODE_ENV", value = "production" },
        { name = "AWS_REGION", value = var.aws_region },
        { name = "CLIENT", value = var.company.name },
        { name = "TENANT", value = terraform.workspace },
        # Not 1: each chain probes the migrations table on one connection while
        # drizzle opens another for CREATE SCHEMA, so a pool of 1 deadlocks.
        { name = "POSTGRES_POOL_MAX", value = "5" },
      ]
      secrets = [
        { name = "POSTGRES_HOST", valueFrom = "${aws_secretsmanager_secret.company_db.arn}:host::" },
        { name = "POSTGRES_PORT", valueFrom = "${aws_secretsmanager_secret.company_db.arn}:port::" },
        { name = "POSTGRES_DB", valueFrom = "${aws_secretsmanager_secret.company_db.arn}:database::" },
        { name = "POSTGRES_USER", valueFrom = "${aws_secretsmanager_secret.company_db.arn}:username::" },
        { name = "POSTGRES_PASSWORD", valueFrom = "${aws_secretsmanager_secret.company_db.arn}:password::" },
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

# Byoc only: SaaS runs this task from .github/workflows/migrate-tenant.yml, and a customer
# account has no CI to do that. local-exec appears nowhere else in this repo; it is acceptable
# here because a byoc install already requires an operator with the AWS CLI (see the bootstrap
# in roots/byoc/README.md).
resource "terraform_data" "db_migrate" {
  count = local.is_byoc ? 1 : 0

  # Re-running is safe, but costs a Fargate cold start — keep a no-op apply a no-op.
  triggers_replace = [aws_ecs_task_definition.db_migrate.arn]

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
