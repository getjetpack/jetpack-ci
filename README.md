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
