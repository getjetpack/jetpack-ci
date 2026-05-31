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

## 🔐 Secrets & config schema (`.env.example`)

Every service repo declares its env vars in **one schema file** — `.env.example` — using source-prefixed references. The deploy job parses it, composes the cloud-specific paths, and feeds the result into helm as `--values`.

### Schema syntax

```bash
# .env.example  (the contract — committed to git, no real values)
DATABASE_URL=${secret:db/url}              # whole opaque secret
JWT_SIGNING=${secret:auth/jwt#signing-key} # one field from a structured secret
API_KEY=${vault:secret/data/stripe}        # HashiCorp Vault — path passed through
LOG_LEVEL=${param:log-level}               # non-sensitive — Parameter Store / ConfigMap
SERVICE_PORT=8080                          # literal default — goes into ConfigMap
```

The **source prefix is the backend** — extensible to anything ESO supports (1Password, Doppler, Infisical, …). Add a new prefix → add a row to the workflow's `*_store_default` inputs and ESO does the rest.

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
