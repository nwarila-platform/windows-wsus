# Architecture Decision Records

This directory holds the Architecture Decision Records (ADRs) governing this
repository, split into three scopes per [ADR-0001](org/0001-use-architecture-decision-records.md):

- [`org/`](org/) - byte-identical mirrors of the org-baseline ADRs whose
  master copies live in [`nwarila-platform/.github`](https://github.com/nwarila-platform/.github/tree/main/docs/decision-records).
- [`template/`](template/) - byte-identical mirrors of the Terraform runner
  template ADRs inherited from [`NWarila/terraform-runner-template`](https://github.com/NWarila/terraform-runner-template/tree/main/docs/decision-records/template).
- `repo/` *(empty)* - repository-specific ADRs that apply only to this repo.

## Index

### Org-Mirrored

| # | Title | Status | Date | Summary |
| --- | --- | --- | --- | --- |
| [org/0001](org/0001-use-architecture-decision-records.md) | Use Architecture Decision Records to Document Design Rationale | Accepted | 2026-06-02 | We will use `docs/decision-records/` as the conventional home for architecturally significant decisions across the `nwarila-platform` organization. |
| [org/0002](org/0002-adopt-diataxis-documentation-framework.md) | Adopt Diátaxis as the Documentation Framework | Accepted | 2026-04-24 | We will use the Diátaxis documentation framework for all non-ADR documentation in repositories that adopt this baseline. |
| [org/0003](org/0003-use-deny-all-gitignore-strategy.md) | Use a Deny-All `.gitignore` Strategy | Accepted | 2026-04-25 | In repositories that adopt this baseline, `.gitignore` is structured as **deny-all by default** with an **explicit allowlist** of files and... |
| [org/0004](org/0004-use-renovate-for-dependency-updates.md) | Use Renovate for Dependency Updates with Per-Template Baselines | Accepted | 2026-06-02 | All `nwarila-platform/*` repositories track dependency updates via Renovate. |
| [org/0005](org/0005-keep-github-control-planes-namespace-local.md) | Keep GitHub Control Planes Namespace-Local | Accepted | 2026-06-02 | Repositories under `nwarila-platform` use `nwarila-platform/.github` as their org control plane for org-baseline ADRs, community-health files, org... |

### Template-Mirrored

| # | Title | Status | Date | Summary |
| --- | --- | --- | --- | --- |
| [template/0001](template/0001-pin-terraform-and-provider-versions-exactly.md) | Pin Terraform and Provider Versions Exactly | Accepted | 2026-05-05 | Every repository derived from `NWarila/terraform-runner-template` that contains Terraform configuration pins both the Terraform CLI version (via... |
| [template/0002](template/0002-mandate-s3-state-backend.md) | Mandate S3 as the State Backend for Terraform-Runner Consumers | Accepted (partial enforcement) | 2026-05-09 | Every Terraform-runner consumer derived from `NWarila/terraform-runner-template` MUST use the S3 backend (`backend "s3" {}`) for state. |
| [template/0004](template/0004-isolate-pull-request-target-triggers.md) | Isolate Pull Request Target Triggers | Accepted | 2026-05-11 | `pull_request_target` is allowed only for the narrow trusted-bot auto-merge surface. |
| [template/0005](template/0005-enforce-thin-runner-deployer-shape.md) | Enforce Thin Runner Deployer Shape | Accepted | 2026-06-02 | Terraform runner consumers are data-only deployers. |

### Repository-Specific

None yet. The first repository-specific ADR will live at
`repo/0001-short-kebab-title.md` and a row will be added here.

## Authoring Rules

- Org-baseline and template ADRs are mirrors only. Do not edit files under
  `org/` or `template/`; change the master copy and re-mirror, so a reader can
  trust that a mirror says exactly what the authority says.
- Repository-specific decisions go in `repo/`, numbered independently, and are
  added to the index above in the same change.
- ADRs are not subject to the Diátaxis quadrant rule (org ADR-0002); they live
  in this subtree and are governed by ADR-0001.
