variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "ap-south-1"
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "hello-world-eks"
}

variable "cluster_version" {
  description = <<-EOT
    Kubernetes version for EKS. AWS only supports each minor version for ~26
    months total (14 standard + 12 extended support), so this default will
    eventually age out — if `terraform apply` fails with
    "InvalidParameterException: unsupported Kubernetes version", check
    https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html
    or run `aws eks describe-cluster-versions` for what's currently valid,
    and bump this value (or pass -var="cluster_version=X.Y").
  EOT
  type    = string
  default = "1.33"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "azs" {
  description = "Availability zones to spread subnets across"
  type        = list(string)
  default     = ["ap-south-1a", "ap-south-1b"]
}

variable "node_instance_types" {
  description = "Instance types for the EKS managed node group"
  type        = list(string)
  default     = ["c7i-flex.large"]
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 4
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "acm_certificate_arn" {
  description = "ACM certificate ARN to enable HTTPS on the ALBs. Leave empty to expose over plain HTTP via the ALB's own DNS name."
  type        = string
  default     = ""
}

variable "grafana_domain" {
  description = "Optional custom hostname for Grafana's Ingress (e.g. grafana.example.com). Leave empty to accept any host."
  type        = string
  default     = ""
}
