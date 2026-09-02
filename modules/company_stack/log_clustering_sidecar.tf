locals {
  log_clustering_sidecar_enabled = var.company.features.logClusteringSidecar

  log_clustering_sidecar_url = local.log_clustering_sidecar_enabled ? "http://${local.task_host}:8000" : null

  # A single process, deliberately: the miner keeps state across requests, so
  # sharing one between separate workloads silently rewrote up to 100% of one's
  # templates.
  log_clustering_sidecar_containers = local.log_clustering_sidecar_enabled ? [{
    name      = "log-clustering"
    image     = "${var.ecr_repository_urls["log-clustering-sidecar"]}:latest"
    essential = false
    restartPolicy = {
      enabled              = true
      restartAttemptPeriod = 60
    }
    portMappings = [{ containerPort = 8000, protocol = "tcp" }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.ecs_reactive.name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = "log-clustering"
      }
    }
  }] : []
}

# No discovery service of its own: task_discovery.tf already registers the task, and every
# container shares its single awsvpc ENI, so this sidecar is reachable at that same name on
# its own port. ECS accepts exactly one service_registries entry per service anyway.
resource "aws_vpc_security_group_ingress_rule" "log_clustering_self" {
  count                        = local.log_clustering_sidecar_enabled ? 1 : 0
  security_group_id            = aws_security_group.internal.id
  referenced_security_group_id = aws_security_group.internal.id
  from_port                    = 8000
  to_port                      = 8000
  ip_protocol                  = "tcp"
  description                  = "log-clustering sidecar on 8000, from this deployment's Lambdas only"
}
