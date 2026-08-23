# windows-wsus

[![CI](https://github.com/nwarila-platform/windows-wsus/actions/workflows/quality.yml/badge.svg?branch=main)](https://github.com/nwarila-platform/windows-wsus/actions/workflows/quality.yml)
[![AWS lifecycle proof](https://github.com/nwarila-platform/windows-wsus/actions/workflows/aws-deploy.yml/badge.svg?branch=main)](https://github.com/nwarila-platform/windows-wsus/actions/workflows/aws-deploy.yml)
[![IAM drift](https://github.com/nwarila-platform/windows-wsus/actions/workflows/iam-drift.yml/badge.svg?branch=main)](https://github.com/nwarila-platform/windows-wsus/actions/workflows/iam-drift.yml)

Disposable AWS proof for a Windows Server 2025 WSUS server backed by Windows Internal Database
(WID). The repository owns the application inputs and WSUS role; version-pinned platform
frameworks own the Terraform and Ansible chassis.

The normal operating state is unattended:

- pull requests run the credential-free `CI / required` gate;
- every protected-`main` change and a weekly schedule provision one host, configure and verify it,
  destroy it, and prove cleanup;
- an hourly, age-gated reaper is a fallback for interrupted lifecycles;
- a daily read-only attestation proves live IAM still exactly equals the reviewed source;
- Renovate and framework-pin automation open grouped, reviewable pull requests without
  auto-merge; and
- each recurring in-repository workflow maintains one durable incident issue and closes it on recovery.

No AWS credential is available to pull-request code. The privileged lifecycle accepts only the
protected `main` ref through its workflow guard and OIDC trust policy.

## What a green proof establishes

The AWS lifecycle proves the pinned Terraform framework can create the declared ephemeral host,
the pinned Ansible framework can compose this role, and the target converges with healthy WSUS,
WID, IIS, disk placement, and a thumbprint-pinned TLS endpoint. It also proves that no
repository-owned EC2 resource or Terraform lock remains after destroy.

The public proof intentionally cannot reach the placeholder corporate upstream, so category
synchronization is disabled there. It proves the desired downstream configuration, not a
successful upstream synchronization. See [Operations](docs/how-to/operations.md) for the precise
assurance boundary.

## Repository layout

| Path | Purpose |
|---|---|
| `ansible/applications/aws_windows_disk_manager/` | Repository-owned AWS-only Windows disk provisioning (Function-tag identity) |
| `ansible/applications/wsus/` | WSUS/WID role, validation, convergence, and independent verifier |
| `ansible/playbooks/wsus-aws.yml` | Exact inventory preflight, Windows readiness, disk provisioning, and role invocation |
| `terraform/aws.tfvars` | Data-only input for the pinned Terraform framework |
| `.github/*-framework-pin` | Reviewed, immutable framework commit pins |
| `.github/renovate.json5` | Thin review-only dependency policy extending the canonical org preset |
| `.github/workflows/quality.yml` | Required credential-free source and composed-Ansible gate |
| `.github/workflows/aws-deploy.yml` | Protected-main deploy, configure, verify, destroy lifecycle |
| `.github/workflows/aws-reaper.yml` | Conservative fallback cleanup for old terminal runs |
| `.github/workflows/iam-drift.yml` | Protected-main, read-only live IAM drift attestation |
| `.github/workflows/pin-bump.yml` | Framework update discovery; opens one PR and never auto-merges |
| `docs/reference/aws-iam/` | Reviewed IAM source documents and trust boundary |
| `scripts/verify.sh` | Single local/CI verification entry point |

The workflow builds its target inventory from Terraform output and verifies the live EC2
repository/run identity before Ansible can mutate it. `ansible/inventory/aws_ec2.yml` remains a
human-operated discovery aid; it is not the lifecycle's authority for target selection.

## Working on the repository

Run the same gate as CI with the exact versions in `quality-tools.env`,
`requirements-quality.txt`, and `requirements-quality.yml` installed:

```bash
QUALITY_ANSIBLE_FRAMEWORK=/path/to/pinned/ansible-framework \
  QUALITY_TERRAFORM_FRAMEWORK=/path/to/pinned/terraform-framework \
  QUALITY_REQUIRE_COMPOSED=1 \
  QUALITY_REQUIRE_TERRAFORM=1 \
  ./scripts/verify.sh
```

Both framework paths must be checkouts at the SHAs in `.github/ansible-framework-pin` and
`.github/terraform-framework-pin`, respectively. CI installs the complete pinned toolchain and is
the canonical clean-runner result.

The installed organization Renovate app reads `.github/renovate.json5` after it lands on `main`.
It groups the bounded GitHub Actions, Python, and Ansible Galaxy manifests for review while the
framework updater exclusively owns `.github/*framework-pin`. Exact version/checksum tuples in
`quality-tools.env` remain deliberate manual debt under TD-007.

Do not run the Terraform deployment locally while a GitHub lifecycle is nonterminal. To run an
on-demand proof, use **Actions → AWS Deploy → Run workflow** on `main`.

## IAM changes

The deploy role cannot widen its own boundary. After reviewing a source-policy or OIDC change,
materialize and apply it with an administrative profile, then check drift:

```bash
./scripts/bootstrap-iam.sh --apply <profile>
./scripts/bootstrap-iam.sh --check-drift <profile>
```

The bootstrap and playbook both derive the artifact bucket as `<account-id>-ansible`; an optional
legacy `BOOTSTRAP_ARTIFACT_BUCKET` value is accepted only when it equals that derived name.

Apply IAM changes before merging a commit that depends on them. The first protected-main
lifecycle is the acceptance test for that rollout. The daily attestation never self-applies; it
updates one durable incident when any policy document, trust, attachment, inline-policy absence,
role path, permissions-boundary or role-tag absence, session duration, named-profile path, or
bidirectional instance-profile membership differs. Policy and instance-profile tags are not part
of the attested metadata contract.

## Operating and support references

- [Operations, incidents, IAM drift, dependency policy, and decommissioning](docs/how-to/operations.md)
- [WSUS role inputs and invariants](ansible/applications/wsus/README.md)
- [Known debt and explicit exit criteria](docs/explanation/technical-debt.md)
- [Security reporting](SECURITY.md)
- [IAM source-document contract](docs/reference/aws-iam/README.md)

Licensed under the [MIT License](LICENSE).
