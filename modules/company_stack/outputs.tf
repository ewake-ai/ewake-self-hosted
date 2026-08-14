output "name" {
  value = var.company.name
}

output "ecs_service_name" {
  value = aws_ecs_service.reactive.name
}

output "lambda_function_names" {
  value = {
    reactive_processor   = module.lambdas.reactive_function_name
    datadog_log_analysis = module.scheduled_lambdas.datadog_log_analysis_function_name
    loki_log_analysis    = module.scheduled_lambdas.loki_log_analysis_function_name
    knowledge_graph      = module.scheduled_lambdas.knowledge_graph_function_name
    incident_indexing    = module.scheduled_lambdas.incident_indexing_function_name
    release_watch        = module.scheduled_lambdas.release_watch_function_name
  }
}

output "db_credentials_secret_arn" {
  value = aws_secretsmanager_secret.company_db.arn
}

output "target_group_arn" {
  value = aws_lb_target_group.reactive.arn
}
