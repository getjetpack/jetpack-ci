# Jetpack CI

Reusable GitHub Actions workflows for Jetpack infrastructure projects.

## Workflows

### `terraform-ci.yml`

Reusable Terraform CI workflow. Handles init, validate, format check, plan, and apply.

**Features:**
- Automatic token generation for private TF modules (`getjetpack/jetpack-tf-modules`)
- S3 backend configuration via inputs
- Optional `.tfvars` file support
- GitHub environment protection (approval gates)
- Plan summary in job output

**Usage in caller workflow:**

```yaml
jobs:
  oidc:
    uses: getjetpack/jetpack-ci/.github/workflows/terraform-ci.yml@main
    with:
      working_directory: oidc
      action: ${{ github.event.inputs.action }}
      backend_bucket: my-project-tfstate
      backend_key: oidc/terraform.tfstate
      backend_region: us-west-2
      aws_region: us-west-2
      var_file: env/dev/us-west-2.tfvars
    secrets:
      AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
      AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
      JETPACK_APP_ID: ${{ secrets.JETPACK_APP_ID }}
      JETPACK_APP_PRIVATE_KEY: ${{ secrets.JETPACK_APP_PRIVATE_KEY }}
```

## Required Secrets

| Secret | Required | Description |
|--------|----------|-------------|
| `AWS_ACCESS_KEY_ID` | Yes | AWS credentials for Terraform |
| `AWS_SECRET_ACCESS_KEY` | Yes | AWS credentials for Terraform |
| `JETPACK_APP_ID` | No | GitHub App ID for private module access |
| `JETPACK_APP_PRIVATE_KEY` | No | GitHub App private key for private module access |
