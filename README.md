# jetpack-ci — Reusable GitHub Actions workflows

Shared CI/CD pipelines used by every Jetpack-generated repo (foundation, bootstrap, services). Hosted as a separate repo so a single workflow update lands in every consumer.

## Workflows

### Infrastructure layer

| File | Purpose |
|---|---|
| `terraform-ci.yml` | Run `init/plan/apply/destroy` against any TF working directory using OIDC auth. Bootstrap repos use this. |
| `terraform-management.yml` | Run TF against the management/bootstrap account with static credentials. Foundation repo uses this on first apply. |

### Service layer (per stack)

| File | Stack | Status |
|---|---|---|
| `py-ci.yml` | Python (FastAPI, Django, Flask, …) | ✅ |
| `nodejs-ci.yml` | Node.js (Express, NestJS, Fastify, …) | TODO |
| `java-ci.yml` | Java (Spring Boot, Quarkus, Micronaut, …) | TODO |
| `go-ci.yml` | Go (Gin, Echo, Fiber, …) | TODO |

All four service pipelines follow the same skeleton — only the language-setup + dependency-install + test-runner steps differ. Adding a stack is a copy of `py-ci.yml` with the language step swapped in.

---

## Service pipeline architecture

```
   ┌───────────────────────────────────────────────────────────────┐
   │  Caller — service repo (.github/workflows/deploy.yml)         │
   │   • Decides cloud / env / cluster / image-repo                │
   │   • Calls the reusable per-stack workflow with those inputs   │
   └─────────────────────────────┬─────────────────────────────────┘
                                 │ uses: getjetpack/jetpack-ci/...
                                 ▼
   ┌───────────────────────────────────────────────────────────────┐
   │  Reusable (py-ci.yml / nodejs-ci.yml / java-ci.yml / go-ci.yml)│
   │                                                               │
   │   1. Checkout + language setup     ← stack-specific           │
   │   2. Install deps + run tests       ← stack-specific          │
   │   3. Cloud auth via OIDC            ← `case "$cloud"`         │
   │   4. Build + push image             ← cloud-aware registry    │
   │   5. Terraform apply (./infra)      ← provider in TF itself   │
   │   6. Update kubeconfig              ← `case "$cloud"`         │
   │   7. helm upgrade --install         ← identical for all       │
   │   8. Verify rollout                 ← identical for all       │
   └───────────────────────────────────────────────────────────────┘
```

### Design principles

1. **One reusable per stack, not per cloud.** The same `py-ci.yml` handles AWS + GCP + Azure via a `cloud` input. The cloud-specific bits are encapsulated in three `case` switches: auth, registry login, kubeconfig.

2. **Generic CLIs do the heavy lifting.** Terraform, kubectl, and helm are identical across clouds. They take all the work after auth.

3. **OIDC for everything, no static keys.** Each cloud's reusable auth action takes a role/SA/identity passed in by the caller. The deploy SA's IAM bindings come from the foundation layer.

4. **The caller is dumb.** Service repos pass simple scalars (cloud name, region, image repo URL, cluster name) and let the reusable workflow figure out the rest. A service repo never has cloud-specific YAML — it just changes `cloud: gcp` → `cloud: aws` to retarget.

5. **Service Terraform is per-service.** A `./infra/` directory in the service repo creates per-service infra (DB instances, secret manager entries, GCS buckets, …). The pipeline runs `terraform apply` on it before deploying. Bootstrap-layer infra (VPC, cluster, NAT, VPN) is handled separately by the bootstrap repo — see `docs/bootstrap-vs-service-boundary.md` in jetpack.

---

## Per-cloud knobs

A caller workflow passes only the inputs for its own cloud. Example: Python service deploying to GCP.

```yaml
# user-service/.github/workflows/deploy-dev.yml
name: Deploy to Dev (GCP)
on:
  push:
    branches: [main]

permissions:
  id-token: write
  contents: read

jobs:
  deploy:
    uses: getjetpack/jetpack-ci/.github/workflows/py-ci.yml@main
    with:
      cloud: gcp
      env: dev
      region: us-west2
      service_name: user-service
      image_repo: us-west2-docker.pkg.dev/gcp-dev-abc1/user-service/user-service
      cluster_name: gcp-dev
      cluster_location: us-west2-a
      gcp_workload_identity_provider: ${{ vars.GCP_WIF_PROVIDER_DEV }}
      gcp_service_account: ${{ vars.GCP_DEPLOY_SA_DEV }}
```

Same service redeployed to AWS — only the inputs change:

```yaml
    with:
      cloud: aws
      env: dev
      region: us-west-2
      service_name: user-service
      image_repo: 123456789.dkr.ecr.us-west-2.amazonaws.com/user-service
      cluster_name: company-dev
      cluster_location: us-west-2
      aws_role_arn: arn:aws:iam::123456789:role/github-oidc-role-dev
```

Same skeleton, different cloud.

---

## How Jetpack generates the caller

When a user creates a service in Jetpack:

1. The service generator emits the service repo with:
   - Application code + Dockerfile + `helm/` chart
   - `infra/` Terraform for per-service resources (DB, secrets, bucket, …)
   - `.github/workflows/deploy.yml` calling the matching `*-ci.yml`
2. The caller workflow's `with:` block is filled in from the project config:
   - `cloud` ← `project_configs.cloud_provider`
   - `cluster_name`, `cluster_location` ← `bootstrap-<env>` terraform outputs
   - `aws_role_arn` / `gcp_workload_identity_provider` + `gcp_service_account` / `azure_*` ← foundation outputs
   - `image_repo` ← per-service Artifact Registry / ECR / ACR (created by `infra/`)

Swapping the entire project from AWS to GCP requires **no code changes in any service repo** — just regenerating the caller workflow with the new `with:` values.

---

## Adding a new stack

1. Copy `py-ci.yml` → `nodejs-ci.yml`.
2. Replace steps 1–2 (setup-python / pip install / pytest) with the language equivalents (setup-node / npm ci / npm test).
3. Everything else stays the same.

---

## Adding a new cloud

1. Add a new `case "$cloud"` branch in three steps of every `*-ci.yml`:
   - Cloud auth (an `if: inputs.cloud == 'oracle'` step with the right auth action)
   - Registry login case
   - Update-kubeconfig case
2. Add corresponding `*_*` inputs (e.g. `oci_user_ocid`, `oci_tenancy_ocid`, …) to the `workflow_call.inputs` block.
3. Jetpack's `cloud-labels.ts` registry already has a row for the new cloud — name parity is automatic in diagrams + monitoring.

No service repo changes required — they just start passing `cloud: oracle`.

---

## ⛵ Helm charts library — `helms/`

Shared, opinionated charts kept here so service repos don't carry boilerplate. The per-stack pipelines pick one via the `helm_type` input and clone the chart at deploy time (`actions/checkout` of this repo, sparse `helms/` only).

| Chart | When to use | Renders |
|---|---|---|
| `helms/app` | Long-running services (HTTP / gRPC / consumers staying up) | Deployment + Service + ServiceAccount + optional HPA + ConfigMap + ExternalSecret |
| `helms/job` | Batch workloads (one-shot scripts, scheduled cleanups, ETL) | Job *or* CronJob (auto-switched by `schedule:` value) + ServiceAccount + ConfigMap + ExternalSecret |

Both charts share the same `envLiterals` / `envParams` / `envSecrets` / `secretStoreRefs` value shape, so the same `parse-env-schema` action drives either.

### Picking a chart from the pipeline

```yaml
# Long-running web service — the default
with:
  helm_type: app

# Batch / cron job
with:
  helm_type: job
  # Then in service's own values file (passed via helm_values_file):
  #   schedule: "0 3 * * *"       # daily 03:00 → CronJob; omit for one-shot Job
```

### Overriding the chart entirely

If you need something the library doesn't cover, ship a chart inside the service repo and point at it:

```yaml
with:
  helm_chart_override: ./deploy/custom-chart
```

The library is ignored and `./deploy/custom-chart` is used as-is.

### Layering extra values

The schema-derived values from `parse-env-schema` always go in first. Pass `helm_values_file: ./deploy/extras.yaml` to layer additional service-specific values on top — they win over chart defaults but lose to `--set` flags from the pipeline (image, tag, environment, service.name).

---

## Composite actions

Reusable steps that the per-stack pipelines (and any caller) drop in directly:

| Action | Purpose |
|---|---|
| `.github/actions/parse-env-schema` | Composes one helm values file with service identity (`service.name`, `image.*`, `environment`, `replicaCount`) **and** schema-derived ConfigMap + ExternalSecret values from `.env.example`. Stack-agnostic — same step in `py-ci.yml`, `nodejs-ci.yml`, `java-ci.yml`, `go-ci.yml`. Lets the helm step drop **every `--set` flag**. |

Usage from any workflow:

```yaml
- uses: getjetpack/jetpack-ci/.github/actions/parse-env-schema@main
  id: values
  with:
    organization:     testa
    project_name:     gcp
    domain:           users
    service_name:     user-service
    env:              dev
    image_repository: us-west2-docker.pkg.dev/testa/gcp/users/user-service
    image_tag:        ${{ github.sha }}
    # Optional:
    schema_file:  .env.example         # default; pass '' to emit identity only
    service_port: 8080
    replicas:     1
    secret_store: cloud-default
    param_store:  param-default
    vault_store:  vault-default
    extra_store_map: '{"doppler":"doppler-default"}'

- run: helm upgrade --install svc ./helm --values ${{ steps.values.outputs.values_file }}
```

Outputs: `values_file`, `skipped`, `literal_count`, `param_count`, `secret_count`, `stores`.

---

## 🔐 Secrets & config schema (`.env.example`)

Every service repo declares its env vars in **one schema file** — `.env.example` — using source-prefixed references. The deploy job parses it, composes the cloud-specific paths, and feeds the result into helm as `--values`.

### Schema syntax

```bash
# .env.example  (the contract — committed to git, no real values)

# ── Runtime env vars (injected via ConfigMap / ExternalSecret at pod start)
DATABASE_URL=${secret:db/url}              # whole opaque secret
JWT_SIGNING=${secret:auth/jwt#signing-key} # one field from a structured secret
API_KEY=${vault:secret/data/stripe}        # HashiCorp Vault — path passed through
LOG_LEVEL=${param:log-level}               # non-sensitive — Parameter Store / ConfigMap
SERVICE_PORT=8080                          # literal default — goes into ConfigMap

# ── Chart-value overrides (resolved at CI time, injected into helm values)
K8S_OVERRIDE_REPLICAS=3                                    # literal
K8S_OVERRIDE_REPLICAS=${ssm:test-service/k8s#replicas}     # from SSM at CI time
K8S_OVERRIDE_NAMESPACE=team-x                              # routed to helm --namespace
K8S_OVERRIDE_RESOURCES_LIMITS_CPU=500m                     # nested chart value
K8S_OVERRIDE_AUTOSCALING_MAX=${param:hpa/max-replicas}     # from Parameter Store
K8S_OVERRIDE_SCHEDULE="0 3 * * *"                          # CronJob schedule (job chart)
```

**Two distinct mechanisms in one schema file:**

1. **Runtime env vars** — anything else. Lands in ConfigMap (literals + `${param:…}`) or ExternalSecret (`${secret:…}` / `${vault:…}`). Materialised by External Secrets Operator inside the cluster.
2. **`K8S_OVERRIDE_*` chart values** — resolved at CI time by the action calling the cloud's CLI (`aws ssm get-parameter`, `gcloud secrets versions access`, etc.), then injected into the helm values file at the mapped path. Used to tune chart behaviour (replica count, resources, schedule) without touching the deploy workflow.

The **source prefix is the backend** — extensible to anything ESO supports (1Password, Doppler, Infisical, …). Add a new prefix → add a row to the workflow's `*_store_default` inputs and ESO does the rest.

### `K8S_OVERRIDE_*` mapping

| `.env.example` key | Helm value path |
|---|---|
| `K8S_OVERRIDE_REPLICAS` | `replicaCount` |
| `K8S_OVERRIDE_NAMESPACE` | (passes to `helm --namespace`, not values) |
| `K8S_OVERRIDE_IMAGE_TAG` | `image.tag` |
| `K8S_OVERRIDE_IMAGE_REPOSITORY` | `image.repository` |
| `K8S_OVERRIDE_IMAGE_PULL_POLICY` | `image.pullPolicy` |
| `K8S_OVERRIDE_SERVICE_PORT` | `service.port` |
| `K8S_OVERRIDE_SCHEDULE` | `schedule` |
| `K8S_OVERRIDE_TIMEZONE` | `timeZone` |
| `K8S_OVERRIDE_AUTOSCALING_ENABLED` | `autoscaling.enabled` |
| `K8S_OVERRIDE_AUTOSCALING_MIN` | `autoscaling.minReplicas` |
| `K8S_OVERRIDE_AUTOSCALING_MAX` | `autoscaling.maxReplicas` |
| `K8S_OVERRIDE_AUTOSCALING_CPU` | `autoscaling.targetCPUUtilizationPercentage` |
| `K8S_OVERRIDE_RESOURCES_REQUESTS_CPU` | `resources.requests.cpu` |
| `K8S_OVERRIDE_RESOURCES_REQUESTS_MEMORY` | `resources.requests.memory` |
| `K8S_OVERRIDE_RESOURCES_LIMITS_CPU` | `resources.limits.cpu` |
| `K8S_OVERRIDE_RESOURCES_LIMITS_MEMORY` | `resources.limits.memory` |
| `K8S_OVERRIDE_PRIORITY_CLASS` | `priorityClassName` |
| `K8S_OVERRIDE_REFRESH_INTERVAL` | `externalSecretRefreshInterval` |

Unknown `K8S_OVERRIDE_*` keys emit a warning and are ignored.

### Path composition

For `${secret:NAME}` and `${param:NAME}`, the workflow expands `NAME` into the project-wide convention:

```
{org}/{project}/{env}/{domain}/{service}/{name}
       testa/gcp/dev/users/user-service/db-url
```

For `${vault:PATH}`, the path is passed through verbatim (Vault paths are arbitrary).

### The generated `values-env.yaml`

```yaml
envLiterals:
  SERVICE_PORT: "8080"

envParams:
  - { key: LOG_LEVEL, source: param, path: testa/gcp/dev/users/user-service/log-level, store: param-default }

envSecrets:
  - { key: DATABASE_URL, source: secret, path: testa/gcp/dev/users/user-service/db/url, store: cloud-default }
  - { key: JWT_SIGNING,  source: secret, path: testa/gcp/dev/users/user-service/auth/jwt, field: signing-key, store: cloud-default }
  - { key: API_KEY,      source: vault,  path: secret/data/stripe, store: vault-default }

secretStoreRefs: [cloud-default, param-default, vault-default]
```

### What the helm chart in the service repo must support

The chart's `values.yaml` declares these as empty defaults; templates iterate over them:

```yaml
# helm/values.yaml
envLiterals: {}
envParams: []
envSecrets: []
secretStoreRefs: []
```

Three templates:

```yaml
# helm/templates/configmap.yaml — literals + non-sensitive params
{{- if or .Values.envLiterals .Values.envParams }}
apiVersion: v1
kind: ConfigMap
metadata: { name: {{ .Release.Name }}-config }
data:
  {{- range $k, $v := .Values.envLiterals }}
  {{ $k }}: {{ $v | quote }}
  {{- end }}
{{- end }}

# helm/templates/externalsecret.yaml — one per unique store
{{- range $store := .Values.secretStoreRefs }}
  {{- $bucket := list }}
  {{- range $.Values.envSecrets }}{{ if eq .store $store }}{{ $bucket = append $bucket . }}{{ end }}{{ end }}
  {{- if $bucket }}
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata: { name: {{ $.Release.Name }}-{{ $store }} }
spec:
  refreshInterval: 1h
  secretStoreRef: { name: {{ $store }}, kind: ClusterSecretStore }
  target: { name: {{ $.Release.Name }}-{{ $store }}-env, creationPolicy: Owner }
  data:
    {{- range $bucket }}
    - secretKey: {{ .key }}
      remoteRef:
        key: {{ .path }}
        {{- if .field }}property: {{ .field }}{{- end }}
    {{- end }}
  {{- end }}
{{- end }}

# helm/templates/deployment.yaml — envFrom both
spec:
  template:
    spec:
      containers:
      - name: {{ .Values.service.name }}
        image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
        envFrom:
        {{- if or .Values.envLiterals .Values.envParams }}
        - configMapRef: { name: {{ .Release.Name }}-config }
        {{- end }}
        {{- range .Values.secretStoreRefs }}
        - secretRef: { name: {{ $.Release.Name }}-{{ . }}-env }
        {{- end }}
```

### What the bootstrap layer must provide

In each cluster (per env), three `ClusterSecretStore` resources — installed once by the bootstrap addon and shared by every service:

| Name | Backend |
|---|---|
| `cloud-default` | AWS Secrets Manager / GCP Secret Manager / Azure Key Vault (whichever cloud the project runs on) |
| `param-default` | AWS Parameter Store / GCP Secret Manager (cheap tier) / Azure App Configuration |
| `vault-default` | HashiCorp Vault (only if the project uses it) |

The deploy SA is bound to those backends via Workload Identity (GCP) / IRSA (AWS) / Workload Identity (Azure) so ESO authenticates without static keys.

### What the service's `infra/` Terraform creates

For each `${secret:NAME}` / `${param:NAME}` reference in `.env.example`, the service-scaffold-generated `infra/secrets.tf` declares a secret-store entry with a placeholder value:

```hcl
resource "google_secret_manager_secret" "db_url" {
  secret_id = "testa-gcp-dev-users-user-service-db-url"
  replication { auto {} }
}
resource "google_secret_manager_secret_version" "db_url_initial" {
  secret = google_secret_manager_secret.db_url.id
  secret_data = "REPLACE_ME"
  lifecycle { ignore_changes = [secret_data] }   # never overwrite once a real value is set
}
```

Devs fill the real value via console / `gcloud secrets versions add` / `aws secretsmanager put-secret-value`.

### Why this works for any backend

| Need | Solution |
|---|---|
| Add HashiCorp Vault | Schema uses `${vault:…}`, bootstrap adds the `vault-default` `ClusterSecretStore`, ESO does the rest. No CI change. |
| Add Doppler / Infisical / 1Password / AWS KMS / GCP Cloud KMS | Same recipe — new source prefix, new `ClusterSecretStore`, optional new `*_store_default` input. |
| Mix backends in one service | Already works — each entry routes to its own store; helm template renders one `ExternalSecret` per store. |
| Local dev | A small CLI (`jp env load`) reads the same `.env.example`, dispatches the right SDK based on the prefix, writes a real `.env` file for `docker-compose up`. |

---

## Terraform infrastructure workflows

### `terraform-ci.yml`

Reusable Terraform CI workflow. Handles init, validate, format check, plan, apply, destroy via OIDC.

**Features:**
- Automatic token generation for private TF modules (`getjetpack/jetpack-tf-modules`)
- S3/GCS backend configuration via inputs
- Optional `.tfvars` file support
- GitHub environment protection (approval gates)
- Plan summary in job output

### `terraform-management.yml`

Same shape as `terraform-ci.yml` but uses static credentials for the management account. Foundation repo uses this on first apply (chicken-and-egg: OIDC doesn't exist until foundation creates it).
