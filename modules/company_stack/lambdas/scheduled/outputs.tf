output "datadog_log_analysis_function_name" {
  value = aws_lambda_function.datadog_log_analysis.function_name
}

output "loki_log_analysis_function_name" {
  value = aws_lambda_function.loki_log_analysis.function_name
}

output "knowledge_graph_function_name" {
  value = aws_lambda_function.knowledge_graph.function_name
}

output "incident_indexing_function_name" {
  value = aws_lambda_function.incident_indexing.function_name
}

output "datadog_metric_analysis_function_name" {
  value = aws_lambda_function.datadog_metric_analysis.function_name
}

output "datadog_span_analysis_function_name" {
  value = aws_lambda_function.datadog_span_analysis.function_name
}

output "release_watch_function_name" {
  value = aws_lambda_function.release_watch.function_name
}

output "custom_mcp_discovery_function_name" {
  value = aws_lambda_function.custom_mcp_discovery.function_name
}

output "kubernetes_discovery_function_name" {
  value = aws_lambda_function.kubernetes_discovery.function_name
}
