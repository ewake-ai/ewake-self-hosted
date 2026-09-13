output "name" {
  value = var.company.name
}

output "ecs_service_name" {
  value = aws_ecs_service.reactive.name
}

output "lambda_function_names" {
  value = {
    reactive_processor = module.lambdas.reactive_function_name
    scheduled          = module.scheduled_lambdas.scheduled_function_name
  }
}

output "db_credentials_secret_arn" {
  value = aws_secretsmanager_secret.company_db.arn
}

output "target_group_arn" {
  value = aws_lb_target_group.reactive.arn
}
