# ADR-template/0002: Mandate S3 as the State Backend for Terraform-Runner Consumers

| Field          | Value                                    |
| -------------- | ---------------------------------------- |
| Status         | Accepted (partial enforcement)           |
| Date           | 2026-05-09                               |
| Authors        | Nick Warila (@NWarila)                   |
| Decision-maker | Nick Warila (sole portfolio maintainer)  |
| Consulted      | AWS bootstrap requirements and runner contract rules. |
| Informed       | Terraform-runner consumers via content rules. |
| Reversibility  | Medium                                   |
| Review-by      | 2026-06-11                               |

## TL;DR

Every Terraform-runner consumer derived from `NWarila/terraform-runner-template` MUST use the S3 backend (`backend "s3" {}`) for state. Local state, Terraform Cloud / HCP, GCS, and azurerm are forbidden by this template tier. The bucket is operationally separate from the consumer's repo (provisioned out-of-band, managed via its own Terraform), and the consumer references it via `-backend-config` (bucket/key/region kept out of source). Authentication MUST be OIDC via `aws-actions/configure-aws-credentials` — no static AWS keys. State locking uses S3 native `use_lockfile = true` (Terraform 1.10+) — no separate DynamoDB lock table required. Encryption-at-rest, versioning, and access logging on the bucket are non-optional; they're configured on the bucket itself, not in the consumer's `backend "s3" {}` block.

## Context and Problem Statement

The `terraform-framework-template` reference framework intentionally ships with the `local` backend so the example always works without external setup. But every real Terraform-runner consumer eventually needs to manage state somewhere. Without a template-tier rule, each consumer chooses independently:

- A consumer that picks the local backend has no concurrency protection — two CI jobs running `terraform apply` in parallel race on `terraform.tfstate` and silently corrupt it.
- A consumer that picks Terraform Cloud introduces a paid third-party SaaS dependency that's outside the SHA-pinned supply chain enforced by the rest of this template (`repo_hygiene.rego`, `drift-gate`, etc.).
- A consumer that picks GCS or azurerm fragments the operational surface across cloud providers — reviewing one consumer's state operations doesn't transfer to reviewing another's.

A template-tier rule moves this decision out of "every consumer chooses" into "the template prescribes; consumers comply." Same character as ADR-template/0001 (Pin Terraform and Provider Versions Exactly) — uniformity at the stack tier is worth more than per-consumer flexibility.

The Terraform-runner shape is also operationally specific in a way that makes S3 the natural default:

- Runners always run in GitHub Actions (the contract requires `pr-validation.yaml` + `terraform-deploy.yaml`). GitHub Actions has first-class OIDC trust with AWS — no static credentials need to be stored as secrets.
- Runners deploy frameworks that may themselves manage AWS resources. Co-locating the runner's state on the same AWS account simplifies the IAM trust story.
- S3 native state locking (`use_lockfile = true`, available since Terraform 1.10) eliminates the historical DynamoDB lock-table coupling that made S3-backend setup more complex than it needed to be.

## Decision Drivers

The following forces shaped this decision:

1. **Concurrency safety.** The state backend MUST provide locking. Local state has none. S3 with `use_lockfile = true` has it natively without an additional service.
2. **Uniform operational surface across consumers.** A reviewer or oncall responder reading any consumer's state operations should see the same patterns. Template-tier prescription delivers this.
3. **Encryption at rest, versioning, audit log.** All three are S3 bucket properties (`aws_s3_bucket_server_side_encryption_configuration`, `aws_s3_bucket_versioning`, `aws_s3_bucket_logging`). Real frameworks managing real infrastructure need them; lab-grade backends don't supply them by default.
4. **OIDC-only authentication.** Static AWS keys in CI secrets are a continuous compromise surface. OIDC trust between GitHub Actions and AWS replaces that with per-job short-lived credentials. S3 supports OIDC natively via the standard provider chain.
5. **Co-location with managed resources.** Runners that consume AWS-shaped frameworks already authenticate against AWS for the apply itself; reusing the same auth path for state is operationally simpler than splitting state and resources across two clouds.
6. **No paid dependencies.** Terraform Cloud / HCP free tier is real but bounded; production usage requires payment. S3 + native locking has no per-run cost beyond storage and request fees, which are negligible for state files.
7. **No DynamoDB coupling.** Pre-1.10, S3 backend required a DynamoDB lock table. Native S3 locking removes that historical drag and is now the recommended HashiCorp pattern.

## Considered Options

1. **No constraint** (current state — every consumer chooses).
2. **Mandate local backend** for runners in this template.
3. **Mandate Terraform Cloud / HCP Terraform.**
4. **Mandate S3** with native locking via `use_lockfile = true` (Terraform 1.10+) — chosen.
5. **Mandate S3** with the pre-1.10 DynamoDB-lock-table pattern.
6. **Mandate GCS or azurerm.**
7. **Allow S3, GCS, azurerm, or HCP — caller's choice.**

## Decision Outcome

Chosen option: **Option 4, mandate S3 with native locking.**

In every Terraform-runner consumer derived from this template:

- `terraform/backend.tf` MUST contain exactly one `terraform { backend "s3" { ... } }` block.
- The block MUST set `encrypt = true`, `use_lockfile = true`, and `use_fips_endpoint = true` (the last so endpoint selection is FIPS 140-2-validated where available; falls back transparently to non-FIPS regions).
- `bucket`, `key`, and `region` are passed via `-backend-config` arguments (or a `backend-config` file referenced in CI) so they're not committed to source. Keeping them out of source lets the same consumer code be initialized against dev, staging, and prod buckets without source mutation.
- Authentication uses OIDC via `aws-actions/configure-aws-credentials` with `role-to-assume:` populated from a repository-level secret naming the IAM role ARN. Static keys (`aws_access_key_id` + `aws_secret_access_key` in workflow secrets) are forbidden.
- The S3 bucket itself is provisioned out-of-band (typically by a "bootstrap" Terraform configuration that's NOT a runner — the bucket can't be created by the runner whose state lives in it; that's circular). The bucket MUST have versioning enabled, server-side encryption (SSE-S3 or SSE-KMS), and either access logging to a separate logging bucket or CloudTrail data-events on the bucket.
- Per-environment isolation uses distinct `key` values (e.g. `runners/<repo-name>/<environment>/terraform.tfstate`), not Terraform workspaces. Workspaces share the same backend config and are easy to confuse; explicit per-env keys are unambiguous.

The framework being deployed (e.g. `NWarila/terraform-framework-template` for the do-nothing reference) declares its own `backend "s3" {}` block. The runner's PR-validation workflow checks out the framework, overlays the runner's `terraform/{public,private}` inventory, and runs `terraform init` against the framework's backend with the consumer's `-backend-config`. That backend block is what this ADR governs.

## Pros and Cons of the Options

### Option 1: No constraint

- **Good, because** every consumer is free to pick the backend matching its operational context.
- **Bad, because** different consumers diverge — reviewers can't carry mental models across repos.
- **Bad, because** a consumer that picks the local backend has no concurrency protection and silently breaks the moment two CI jobs race.
- **Bad, because** the lack of constraint is the current state, and the current state has produced inconsistency across the portfolio.

### Option 2: Mandate local backend

- **Good, because** zero external setup; works offline.
- **Bad, because** no concurrency protection. Any production runner deploys regularly; concurrent runs are not theoretical.
- **Bad, because** state lives in CI ephemeral storage by default, lost between runs unless explicitly persisted.
- **Bad, because** state is not encrypted at rest, has no versioning, no audit trail.
- **Disqualifying.** Local backend is for the do-nothing reference framework only.

### Option 3: Mandate Terraform Cloud / HCP

- **Good, because** managed locking, encryption, versioning, run history all built in.
- **Good, because** UI for state inspection is convenient.
- **Bad, because** introduces a paid SaaS dependency in the supply chain. The free tier is bounded (5 users, etc.).
- **Bad, because** adds a third-party authentication surface (HCP API tokens) outside the OIDC-everywhere pattern this template otherwise enforces.
- **Bad, because** vendor lock-in to HashiCorp's commercial offering. Migration off TFC requires state export and backend reconfiguration across every consumer.

### Option 4: Mandate S3 with native locking (chosen)

- **Good, because** S3 is the most widely used Terraform state backend; team-mobility and hiring familiarity is highest.
- **Good, because** native locking (Terraform 1.10+) eliminates the DynamoDB coupling. One service for state, one for locks via the same service.
- **Good, because** OIDC-via-`aws-actions/configure-aws-credentials` is the GitHub Actions canonical pattern; no static credentials.
- **Good, because** encryption at rest (SSE-KMS or SSE-S3), versioning, and access logging are all native S3 features configured on the bucket.
- **Good, because** S3 cost at state-file scale is negligible (a few cents/month per consumer).
- **Good, because** state can be inspected with the AWS CLI / console without any Terraform-specific tooling installed.
- **Neutral, because** ties this template's runners to AWS as the auth + backend provider. Consumers that want to manage non-AWS resources still work fine — the S3 backend doesn't constrain what the consumer's framework deploys.
- **Bad, because** requires AWS account access for every runner, even runners that don't otherwise touch AWS.
- **Bad, because** S3 native locking is Terraform 1.10+; older Terraform versions can't use this option. ADR-template/0001 already pins to a single recent Terraform version, so this is not an active concern.

### Option 5: Mandate S3 with DynamoDB lock table (legacy)

- **Good, because** widely documented, widely understood pattern.
- **Bad, because** two services for what one now does. Higher operational surface, higher IAM policy complexity, more moving parts.
- **Bad, because** DynamoDB lock tables are an extra resource to provision per backend; native locking removes them entirely.
- **Bad, because** no benefit over Option 4 unless Terraform version is pinned below 1.10, which it isn't.

### Option 6: Mandate GCS or azurerm

- **Good, because** functionally equivalent to S3 within their respective clouds.
- **Bad, because** consumers that don't already have GCP / Azure footprints would need to provision and authenticate against an additional cloud purely for state.
- **Bad, because** GitHub Actions OIDC trust to GCP / Azure is supported but less universally documented than the AWS path.
- **Bad, because** no portfolio reason to pick these over S3 absent a specific cloud-strategy decision; choosing one would be arbitrary.

### Option 7: Allow any of S3 / GCS / azurerm / HCP — caller's choice

- **Good, because** maximum consumer flexibility.
- **Bad, because** identical to Option 1 in the divergence cost it imposes on reviewers.
- **Bad, because** the constraint that delivers the value of this ADR is uniformity. Allowing a menu of choices is no constraint.

## Confirmation

Adherence to this ADR is confirmed by the following mechanisms. The wording `MUST`, `SHOULD`, and `MAY` follows [RFC 2119](https://www.rfc-editor.org/rfc/rfc2119) conventions.

1. **Backend-block check.** Every adopting consumer's `terraform/backend.tf` MUST contain a `backend "s3" {}` block. A CI script or `tflint` rule MAY assert this. The OPA `repo_hygiene` policy SHOULD be extended in a follow-up commit to enforce backend-block presence and provider.
2. **Required-attribute check.** The `backend "s3" {}` block MUST set `encrypt = true`, `use_lockfile = true`, and `use_fips_endpoint = true`. Other attributes (`bucket`, `key`, `region`) are passed via `-backend-config` and are not asserted by this rule.
3. **No-static-credentials check.** Every adopting consumer's `terraform-deploy.yaml` MUST NOT contain static AWS access key names (`AWS_ACCESS_KEY_ID` or `AWS_SECRET_ACCESS_KEY`). Workflow secrets with those names MUST NOT exist on adopting repositories. A repository-settings audit MAY assert secret absence. Positive OIDC wiring (`aws-actions/configure-aws-credentials` with `role-to-assume:`) remains an ADR requirement, but mechanical enforcement belongs with the framework deploy reusable and is a deferred follow-up control.
4. **Per-env-key check.** Multi-environment runners MUST use distinct `-backend-config=key=...` values per environment, NOT Terraform workspaces. A CI script that diffs the workflow's `terraform init` invocations across environments MAY assert this.
5. **Bucket-property check.** The S3 bucket(s) used by adopting consumers MUST have versioning, server-side encryption, and access logging enabled. These are bucket-side properties, not consumer-side; verification happens in the bootstrap configuration that provisions the bucket(s), not in this template's CI.
6. **Editorial rule.** A relaxation of the S3 mandate (e.g., a runner that legitimately needs Terraform Cloud) is itself an architectural decision and MUST be recorded as a repository-level superseding ADR in that consumer's `docs/decision-records/repo/`.

This ADR is accepted with partial enforcement as of 2026-05-11. The runner
contract currently enforces the negative authentication rule (no static AWS key
names in `terraform-deploy.yaml`) and the pinned framework reusable deploy
call. Positive OIDC enforcement moved out of this thin caller in commit
`2f18490`; a framework-side reusable deploy rule that asserts
`aws-actions/configure-aws-credentials` and `role-to-assume:` remains a
follow-up control. The OPA backend-block check also remains a follow-up control
and is tracked here rather than treated as already implemented.

## Consequences

### Positive

- Every Terraform-runner consumer's state lives in S3 with the same access pattern, lockable by the same mechanism, encrypted by the same default. Reviewers carry one mental model.
- No paid SaaS dependency. No vendor lock-in beyond AWS itself.
- OIDC-only authentication eliminates static-credential storage as a continuous compromise surface.
- State versioning means a destructive `terraform apply` can be recovered from the previous state version without reaching for backups.
- Terraform 1.10+ native locking eliminates the DynamoDB lock-table chore.
- Co-location with managed AWS resources (when relevant) simplifies IAM trust paths.

### Negative

- Consumers that don't otherwise touch AWS now require AWS account access purely for state. Cost is negligible but the operational surface is real.
- The S3 bucket(s) used for state are themselves a bootstrap problem — they can't be provisioned by a runner whose state lives in them. A separate "bootstrap" Terraform configuration is needed.
- This ADR ties Terraform-runner consumers to AWS at the state tier. A future portfolio-wide decision to abandon AWS would require migrating every consumer's state, which is a coordinated multi-PR effort.
- Migration of existing consumers from local state to S3 requires per-consumer `terraform init -migrate-state` runs, executed in order with no concurrent runs. Multi-day rollout.

### Neutral

- Buckets / keys / regions are runtime configuration via `-backend-config`; they're not source-controlled. This is the recommended pattern but means CI configuration carries that data.
- The do-nothing `terraform-framework-template` keeps its `local` backend (per its own ADR text — it explicitly disclaims production use). This ADR governs the runners that consume it and any other framework, not the framework example itself.

## Assumptions

This decision rests on the following assumptions. If any becomes false, this ADR should be revisited:

1. The portfolio continues to use AWS for at least one stack, justifying the AWS-account presence S3 state requires.
2. Terraform 1.10+ remains the pinned version (per ADR-template/0001 + the org Renovate baseline). Pre-1.10 Terraform cannot use native S3 locking.
3. GitHub Actions remains the CI substrate. OIDC trust between Actions and AWS is the canonical authentication path.
4. AWS continues to charge negligible amounts for state-file storage and request volumes at this scale.

## Supersedes

None.

## Superseded by

None (current).

## Implementing PRs

- [#6](https://github.com/NWarila/terraform-runner-template/issues/6) / [`8a92b91`](https://github.com/NWarila/terraform-runner-template/commit/8a92b915a47cfc1dd9d27d29e30bb0f1ee046a8a) recorded the S3 backend mandate.
- [`7400021`](https://github.com/NWarila/terraform-runner-template/commit/7400021e15fad6a47c1afdaf904e4dcf0d5f6eb0) added runner contract and policy gates, including the deploy-workflow authentication content rules.
- [`2f18490`](https://github.com/NWarila/terraform-runner-template/commit/2f184908773b13e335c347d10cc605761bd5655c) moved positive OIDC ownership out of the runner's thin deploy caller and into the deferred framework-reusable enforcement path; the runner contract now retains only the no-static-key negative rule plus the framework reusable pin.
- The remaining implementing change is the OPA backend-block rule. Framework consumers still need their `terraform/backend.tf` migration from `local` to `s3` after the state bucket is provisioned. Subsequent consumer migrations will be listed here as they land.

The concrete IAM role and policy this template itself uses for its own state backend are documented as a worked example in [`docs/reference/aws-bootstrap-requirements.md`](https://github.com/NWarila/terraform-runner-template/blob/main/docs/reference/aws-bootstrap-requirements.md#worked-example-this-templates-own-state-backend). The defensive patterns demonstrated there — `repository_id` claim, explicit `Deny` on state deletion, dual encryption guards (`StringNotEquals` + `Null` header), per-object ACLs splitting state from lockfile — apply to every adopting consumer and are the form the OPA backend rule (deferred per the Confirmation note below) will eventually enforce mechanically.

## Related ADRs

- [`ADR-template/0001`](0001-pin-terraform-and-provider-versions-exactly.md) — establishes exact-pinning of the Terraform CLI and provider versions. This ADR's reliance on Terraform 1.10+ native S3 locking depends on that pin.
- [Org ADR-0004 (Renovate)](../org/0004-use-renovate-for-dependency-updates.md) — establishes Renovate as the dependency-update mechanism for every adopting repository. Renovate keeps Terraform CLI versions current; the 1.10+ native-locking guarantee comes from the Renovate-managed pin staying within the supported range.

## Compliance Notes

None.
