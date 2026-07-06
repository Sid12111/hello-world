# Hello World on EKS — Terraform, Kubernetes, Helm & Observability

This repo provisions an Amazon EKS cluster with Terraform, deploys a Go
"Hello World" HTTP microservice packaged as a Helm chart, and stands up a
Prometheus + Grafana observability stack that monitors both the cluster and
the application. A GitHub Actions pipeline builds, pushes, and deploys the
app on every change.

## Architecture

```
                          Internet
                             │
              ┌──────────────┴──────────────┐
              │        Public ALBs           │
              │  (provisioned by ALB ctrl)   │
              │   hello-world-alb  grafana-alb│
              └──────┬────────────────┬──────┘
                     │                │
                ┌────────────────────────────────────────────┐
                │                 AWS VPC                   │
                │   2 AZs · public + private subnets · NAT   │
                │                                             │
                │        ┌───────────────────────────┐        │
                │        │      EKS Cluster (1.29)    │        │
                │        │                             │        │
                │        │  ns: kube-system             │        │
                │        │   └─ AWS LB Controller (IRSA)│        │
                │        │                             │        │
                │        │  ns: hello-world            │        │
                │        │   ├─ Deployment (2-6 pods)  │        │
                │        │   ├─ Service (ClusterIP)    │        │
                │        │   ├─ Ingress (ALB, class=alb)│        │
                │        │   ├─ HPA (CPU 70%)          │        │
                │        │   └─ ServiceMonitor         │        │
                │        │                             │        │
                │        │  ns: monitoring              │        │
                │        │   ├─ Prometheus (kube-prom-stack)     │
                │        │   ├─ Alertmanager             │        │
                │        │   ├─ node-exporter (DaemonSet)│        │
                │        │   ├─ kube-state-metrics       │        │
                │        │   └─ Grafana (standalone release,     │
                │        │       Ingress -> ALB, datasource +    │
                │        │       dashboard auto-provisioned)     │
                │        └───────────────────────────┘        │
                └─────────────────────────────────────────┘
                         ▲
                         │ build & deploy
                GitHub Actions (on push to main)
```

## Repo layout

```
terraform/          # EKS cluster, VPC, node group, ALB controller (IRSA), kube-prometheus-stack + Grafana
terraform/iam/       # AWS Load Balancer Controller IAM policy document
app/                 # Go Hello World service (+ Prometheus metrics + Dockerfile)
helm/hello-world/    # Helm chart for the application (Deployment, Service, Ingress, HPA, ServiceMonitor)
monitoring/          # Prometheus/Grafana values + a sample Grafana dashboard JSON
.github/workflows/   # CI/CD pipeline (build image -> push to GHCR -> helm upgrade)
```

## Prerequisites

- AWS account with credentials configured (`aws configure`) and permission to
  create VPCs, EKS clusters, IAM roles, and EC2 instances
- Terraform >= 1.5
- kubectl >= 1.33
- Helm >= 3.14
- Docker (to build the app image)
- Go >= 1.22 (only needed if you want to run/build the app locally outside Docker)

## 1. Provision the EKS cluster

```bash
cd terraform
terraform init
terraform plan
terraform apply
```

This creates:
- A VPC with public + private subnets across 2 AZs and a single NAT gateway
  (cost-optimized for a demo cluster — see Limitations below); public
  subnets are tagged `kubernetes.io/role/elb=1` so the ALB controller can
  place load balancers in them
- An EKS cluster (`hello-world-eks`, Kubernetes 1.29) with a managed node
  group (2–4 × `your-instance type` nodes)
- An IAM OIDC provider for the cluster + an IRSA role/policy for the AWS
  Load Balancer Controller, and the controller itself (installed into
  `kube-system` via Helm) — this is what turns Kubernetes `Ingress` objects
  into real, internet-facing Application Load Balancers
- Two namespaces: `hello-world` and `monitoring`
- The `kube-prometheus-stack` Helm chart (Prometheus, Alertmanager,
  node-exporter, kube-state-metrics) plus a standalone Grafana release,
  both installed straight from Terraform via the `helm` provider

When it finishes, point kubectl at the new cluster:

```bash
aws eks update-kubeconfig --region ap-south-1 --name hello-world-eks
kubectl get nodes
```

## 2. Build and push the application image

```bash
cd app
docker build -t ghcr.io/<your-username>/hello-world:latest .
docker push ghcr.io/<your-username>/hello-world:latest
```

(Or let the GitHub Actions pipeline in step 4 do this for you automatically.)

## 3. Deploy the app with Helm

```bash
helm upgrade --install hello-world ./helm/hello-world \
  --namespace hello-world \
  --create-namespace \
  -f ./helm/hello-world/values.yaml
```

Verify it's up and serving:

```bash
kubectl -n hello-world get pods
kubectl -n hello-world get ingress hello-world   # ADDRESS column = public ALB DNS name
curl http://<the-alb-address-from-above>/
curl http://<the-alb-address-from-above>/metrics
```

It can take 2-3 minutes after the first `helm upgrade --install` for the ALB
controller to provision the load balancer and for its `ADDRESS` to populate.

## 4. Public access via ALB (no port-forward needed)

Both the app and Grafana are exposed to the internet through real Application
Load Balancers, provisioned automatically by the AWS Load Balancer Controller
whenever a Kubernetes `Ingress` resource exists — no manual ALB setup, and no
`kubectl port-forward` needed for day-to-day access.

**Without a domain or ACM certificate** (the default), everything still
works over plain HTTP at the ALB's auto-generated DNS name:
```bash
kubectl -n hello-world get ingress hello-world
kubectl -n monitoring get ingress grafana
# ADDRESS column, e.g. k8s-helloworld-xxxx.ap-south-1.elb.amazonaws.com
```

**With a custom domain + HTTPS** (recommended for anything beyond a demo):
1. Request/validate an ACM certificate for your domain in the same region as
   the cluster.
2. Pass it to Terraform (for Grafana) and to Helm (for the app):
   ```bash
   # terraform/terraform.tfvars
   acm_certificate_arn = "arn:aws:acm:ap-south-1:123456789012:certificate/xxxx"
   grafana_domain       = "grafana.example.com"
   ```
   ```bash
   helm upgrade --install hello-world ./helm/hello-world \
     --set ingress.host=hello.example.com \
     --set ingress.certificateArn=arn:aws:acm:ap-south-1:123456789012:certificate/xxxx
   ```
3. Create a Route 53 (or your DNS provider's) `A`/`ALIAS` record pointing
   `hello.example.com` / `grafana.example.com` at the ALB's DNS name from
   the `get ingress` output above.

With a cert configured, both Ingresses listen on 80 and 443 and redirect
HTTP → HTTPS automatically (`alb.ingress.kubernetes.io/ssl-redirect: "443"`).

## 5. CI/CD (optional bonus — implemented)

`.github/workflows/deploy.yml` runs on every push to `main` that touches
`app/`, `helm/`, or the workflow itself:

1. Builds the Docker image and pushes it to GHCR, tagged with the short SHA
2. Configures AWS credentials and updates kubeconfig for the EKS cluster
3. Runs `helm upgrade --install` with the new image tag
4. Waits for the rollout to complete and fails the job if it doesn't

**Required repo secrets:** `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
`AWS_REGION`, `EKS_CLUSTER_NAME`. `GITHUB_TOKEN` for GHCR push is provided
automatically by Actions. **Optional:** `APP_DOMAIN` and `ACM_CERT_ARN` if
you want the pipeline to deploy the app's Ingress with a custom domain and
HTTPS instead of the ALB's default HTTP/auto-generated DNS name.

## 6. Observability

Prometheus (+ Alertmanager, node-exporter, kube-state-metrics) is installed
via the `kube-prometheus-stack` chart. **Grafana is installed as its own,
separate Helm release** (`monitoring/grafana-values.yaml.tpl`) rather than using
that chart's bundled Grafana sub-chart — this keeps Grafana's version/upgrade
cadence independent of the rest of the stack. Both are Terraform-managed, so
`terraform apply` gives you a fully wired stack with no manual setup:

- Grafana comes up with **Prometheus pre-configured as its default datasource**
  (pointed at `kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090`)
- The **hello-world dashboard is auto-provisioned** from a Terraform-managed
  ConfigMap (`kubernetes_config_map.grafana_dashboard_hello_world`, sourced
  from `monitoring/grafana-dashboard.json`) — no manual "import dashboard"
  click needed
- Grafana data persists across pod restarts via a 5Gi PVC

**Access Grafana:**
```bash
kubectl -n monitoring get ingress grafana   # ADDRESS = public ALB DNS name
# open http://<that-address>/  (or https://grafana.example.com if you
# configured grafana_domain + acm_certificate_arn — see section 4)
# user: admin / password: value of adminPassword in monitoring/grafana-values.yaml.tpl

# Fallback if you'd rather not expose it publicly right now:
kubectl -n monitoring port-forward svc/grafana 3000:80   # -> http://localhost:3000
```
The Hello World Service dashboard should already be visible under Dashboards
on first login — no import step required.

**What's monitored:**
- *Cluster-level:* node CPU/memory/disk (node-exporter), pod/deployment
  status and resource usage (kube-state-metrics + cAdvisor), all with the
  default kube-prometheus-stack alerting rules loaded.
- *Application-level:* the Go service exposes custom Prometheus metrics at
  `/metrics` — `hello_world_http_requests_total` (counter, by path/status)
  and `hello_world_http_request_duration_seconds` (histogram). The Helm
  chart ships a `ServiceMonitor` so Prometheus Operator auto-discovers and
  scrapes the app without manual `scrape_configs` edits. The dashboard
  (request rate, p95 latency, per-pod CPU/memory, ready-pod count) is
  provisioned automatically as described above.

## Tear down

```bash
helm uninstall hello-world -n hello-world
cd terraform
terraform destroy
```
(`terraform destroy` also removes the kube-prometheus-stack release since
it's managed as a Terraform resource.)

## Design notes

- **Language/runtime:** Go, chosen per the assignment's stated preference —
  compiles to a single static binary, so the final container image is a
  distroless, non-root, few-MB image with a minimal attack surface.
- **Cluster:** EKS (over AKS) since the provided resume/background is
  AWS-and-GCP-centric; the Terraform is modular enough that swapping in
  `Azure/aks` via the `Azure/aks/azurerm` module would mainly mean
  replacing `eks.tf`/`vpc.tf` and the provider block.
- **Public access via AWS Load Balancer Controller + Ingress**, not
  `Service type: LoadBalancer`: gives path-based routing, a single ALB per
  app instead of one classic ELB per Service, native ACM/HTTPS integration,
  and is the AWS-recommended pattern for EKS. IRSA (IAM Roles for Service
  Accounts) is used for the controller's AWS permissions rather than
  attaching a broad policy to the node IAM role, so only the controller's
  own pod can create/manage load balancers.
- **Grafana as a standalone Helm release** rather than kube-prometheus-stack's
  bundled sub-chart: decouples Grafana's version/upgrade cycle from the rest
  of the monitoring stack, which is closer to how you'd manage it in a real
  multi-team environment. It's still fully automated — datasource and
  dashboard are provisioned via Terraform, so there's no manual click-ops.
- **Monitoring installed via Terraform, not a separate manual step:** keeps
  "provision cluster" and "make it observable" as one reproducible
  `terraform apply`, matching the SRE/observability-as-code practice
  described in the assignment.
- **HPA + resource requests/limits** are set on the app deployment so it
  demonstrates autoscaling behavior under load, not just a static
  Hello World pod.

## Known limitations / what I'd do differently for production

- **Single NAT gateway** (`single_nat_gateway = true`) is a cost optimization
  for a take-home assignment; production would use one NAT gateway per AZ
  for high availability.
- **No remote Terraform state backend configured** (S3 + DynamoDB lock table
  commented out in `terraform/versions.tf`) — trivial to enable, left out so
  the project runs standalone without pre-existing infra.
- **Grafana admin password is a plaintext default in `monitoring/grafana-values.yaml.tpl`.**
  In production this should come from AWS Secrets Manager / an External
  Secrets Operator, not a values file.
- **ACM certificate must be requested/validated manually** — Terraform
  accepts an existing cert ARN (`acm_certificate_arn`) but doesn't request
  one itself, since that requires DNS validation against a domain this repo
  doesn't own. A production setup would add an `aws_acm_certificate` +
  `aws_route53_record` for automatic validation.
- **No WAF attached to the ALBs.** `wafv2:Associate/DisassociateWebACL`
  permissions are already in the controller's IAM policy, so attaching an
  AWS WAFv2 Web ACL to either Ingress is just an annotation away
  (`alb.ingress.kubernetes.io/wafv2-acl-arn`) — left out here to keep the
  assignment's scope focused.
- **Both ALBs are wide open on 80/443 to `0.0.0.0/0`** (the ALB controller's
  default) with no rate limiting — fine for a demo, but a public-facing
  production deployment would pair this with the WAF above and/or
  `alb.ingress.kubernetes.io/inbound-cidrs` restrictions.
