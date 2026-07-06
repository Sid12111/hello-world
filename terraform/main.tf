resource "kubernetes_namespace" "app" {
  metadata {
    name = "hello-world"
  }

  depends_on = [module.eks]
}

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
  }

  depends_on = [module.eks]
}

# EKS clusters can come with a stale default "gp2" StorageClass pointing at
# the removed in-tree EBS provisioner. This one uses the CSI driver
# (installed in ebs-csi.tf) and is marked as the cluster default, so PVCs
# like Grafana's (in monitoring/grafana-values.yaml.tpl) provision correctly.
resource "kubernetes_storage_class" "gp3_default" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner = "ebs.csi.aws.com"
  reclaim_policy      = "Delete"
  volume_binding_mode = "WaitForFirstConsumer"

  parameters = {
    type = "gp3"
  }

  depends_on = [aws_eks_addon.ebs_csi_driver]
}

# Installs Prometheus + Grafana + Alertmanager + node-exporter + kube-state-metrics
# in one shot via the community kube-prometheus-stack chart. Values file lives in
# ../monitoring/prometheus-values.yaml.
resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = "58.2.1"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  values = [
    file("${path.module}/../monitoring/prometheus-values.yaml")
  ]

  timeout = 600

  depends_on = [module.eks, kubernetes_namespace.monitoring]
}

# ConfigMap holding the hello-world app dashboard JSON, mounted into Grafana
# via the dashboardsConfigMaps setting in monitoring/grafana-values.yaml.tpl, so
# it's provisioned automatically on install with no manual UI import step.
resource "kubernetes_config_map" "grafana_dashboard_hello_world" {
  metadata {
    name      = "grafana-dashboard-hello-world"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      grafana_dashboard = "1"
    }
  }

  data = {
    "hello-world.json" = file("${path.module}/../monitoring/grafana-dashboard.json")
  }

  depends_on = [module.eks, kubernetes_namespace.monitoring]
}

# Standalone Grafana release, kept independent of kube-prometheus-stack so its
# chart version/upgrades can be managed on their own cadence. Pre-wired (via
# monitoring/grafana-values.yaml.tpl) with Prometheus as a datasource and the
# hello-world dashboard above as a provisioned dashboard.
resource "helm_release" "grafana" {
  name       = "grafana"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "grafana"
  version    = "8.5.1"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  values = [
    templatefile("${path.module}/../monitoring/grafana-values.yaml.tpl", {
      acm_certificate_arn = var.acm_certificate_arn
      grafana_domain      = var.grafana_domain
    })
  ]

  timeout = 300

  depends_on = [
    module.eks,
    kubernetes_namespace.monitoring,
    helm_release.kube_prometheus_stack,
    kubernetes_config_map.grafana_dashboard_hello_world,
    helm_release.aws_load_balancer_controller,
    aws_eks_addon.ebs_csi_driver,
    kubernetes_storage_class.gp3_default,
  ]
}
