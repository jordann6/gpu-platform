output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "kubeconfig_command" {
  description = "Point kubectl at the cluster."
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region}"
}

output "costs_table_name" {
  description = "DynamoDB table holding per-second GPU cost attribution."
  value       = aws_dynamodb_table.gpu_costs.name
}

output "collector_repository_url" {
  description = "ECR repository for the FinOps collector image."
  value       = aws_ecr_repository.collector.repository_url
}

output "grafana_port_forward" {
  description = "Reach Grafana without exposing it."
  value       = "kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80"
}

output "fis_template_id" {
  description = "FIS experiment that delivers a real spot interruption notice."
  value       = aws_fis_experiment_template.spot_interruption.id
}

output "reaper_mode" {
  description = "Whether the idle-GPU reaper will actually terminate nodes."
  value       = var.reaper_dry_run ? "DRY RUN (logs only, terminates nothing)" : "LIVE (will delete idle NodeClaims)"
}
