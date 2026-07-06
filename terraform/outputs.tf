output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  value     = module.eks.cluster_certificate_authority_data
  sensitive = true
}

output "region" {
  value = var.aws_region
}

output "configure_kubectl" {
  description = "Run this to update your local kubeconfig"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "grafana_port_forward" {
  description = "Run this to reach Grafana at http://localhost:3000 (user: admin)"
  value       = "kubectl -n monitoring port-forward svc/grafana 3000:80"
}
