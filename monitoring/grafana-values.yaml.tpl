# Values for the grafana/grafana chart, installed as its own release
# (independent of kube-prometheus-stack) so its version/upgrades can be
# managed separately from the rest of the monitoring stack.

replicas: 1

adminUser: admin
adminPassword: "changeme-in-prod"  # override via --set or a Kubernetes Secret in real use

service:
  type: ClusterIP
  port: 80

persistence:
  enabled: true
  size: 5Gi

resources:
  requests:
    cpu: 50m
    memory: 128Mi
  limits:
    cpu: 200m
    memory: 256Mi

# Auto-provision Prometheus (from kube-prometheus-stack, same "monitoring"
# namespace) as a datasource, so it's ready to query without any manual
# UI clicking after install.
datasources:
  datasources.yaml:
    apiVersion: 1
    datasources:
      - name: Prometheus
        type: prometheus
        access: proxy
        url: http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090
        isDefault: true
        editable: true

# Auto-provision the hello-world application dashboard from a ConfigMap
# (populated below) instead of requiring a manual import in the UI.
dashboardProviders:
  dashboardproviders.yaml:
    apiVersion: 1
    providers:
      - name: default
        orgId: 1
        folder: ""
        type: file
        disableDeletion: false
        editable: true
        options:
          path: /var/lib/grafana/dashboards/default

dashboardsConfigMaps:
  default: "grafana-dashboard-hello-world"

sidecar:
  dashboards:
    enabled: false  # not needed; we provision via dashboardsConfigMaps above

# Public ALB Ingress. When acm_certificate_arn is set (via the Terraform
# variable of the same name), the ALB listens on 443 with that cert and
# redirects 80 -> 443. Without a cert it listens on 80 only, reachable at
# the ALB's own DNS name (find it with `kubectl -n monitoring get ingress`).
ingress:
  enabled: true
  ingressClassName: alb
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/healthcheck-path: /api/health
%{ if acm_certificate_arn != "" ~}
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'
    alb.ingress.kubernetes.io/certificate-arn: ${acm_certificate_arn}
    alb.ingress.kubernetes.io/ssl-redirect: "443"
%{ else ~}
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80}]'
%{ endif ~}
%{ if grafana_domain != "" ~}
  hosts:
    - ${grafana_domain}
%{ endif ~}
  path: /
  pathType: Prefix
