locals {
  # An opt-in, off by default: the sidecar is a permanent container in the dashboard task, and not
  # every deployment reads CloudWatch.
  #
  # Connect a CloudWatch integration in the dashboard *before* setting this, not after. The sidecar
  # asks the dashboard for the roles to assume when it starts, and gives up if the answer is that
  # none exist — so one started first retries a few times and then stays down, and connecting an
  # integration later does not bring it back. Nothing else is affected, since the container is
  # non-essential; the recovery is a forced new deployment of the service. See README.md.
  cloudwatch_mcp_enabled = var.company.features.cloudwatchMcpSidecar

  cloudwatch_mcp_url = local.cloudwatch_mcp_enabled ? "http://${local.task_host}:8931/mcp" : null

  cloudwatch_mcp_containers = local.cloudwatch_mcp_enabled ? [{
    name      = "cloudwatch-mcp"
    image     = "${var.ecr_repository_urls["cloudwatch-mcp"]}:latest"
    essential = false
    restartPolicy = {
      enabled              = true
      restartAttemptPeriod = 60
    }
    portMappings = [{ containerPort = 8931, protocol = "tcp" }]
    environment  = [{ name = "REACTIVE_CONFIG_URL", value = "http://localhost:3000/internal/cloudwatch-mcp-config" }]
    # The same value the dashboard container gets as ORCHESTRATOR_SECRET, which is what it checks
    # this against: the sidecar polls the dashboard's own internal API for the roles to assume.
    secrets = [
      { name = "EWAKE_INTERNAL_TOKEN", valueFrom = local.orchestrator_secret_value_from }
    ]
    dependsOn = [{ containerName = "reactive", condition = "START" }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.ecs_reactive.name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = "cloudwatch-mcp"
      }
    }
  }] : []
}

resource "aws_vpc_security_group_ingress_rule" "cloudwatch_mcp_self" {
  count                        = local.cloudwatch_mcp_enabled ? 1 : 0
  security_group_id            = aws_security_group.internal.id
  referenced_security_group_id = aws_security_group.internal.id
  from_port                    = 8931
  to_port                      = 8931
  ip_protocol                  = "tcp"
  description                  = "cloudwatch-mcp sidecar on 8931, from this deployment's Lambdas only"
}
