# windows-wsus

[![AWS lifecycle proof](https://github.com/nwarila-platform/windows-wsus/actions/workflows/aws-deploy.yml/badge.svg?branch=main)](https://github.com/nwarila-platform/windows-wsus/actions/workflows/aws-deploy.yml)

A `nwarila-platform` application repository for a Windows Server 2022 WSUS server backed by SQL
Server, proven by a disposable AWS lifecycle. The repository owns the application inputs and
roles; version-pinned platform frameworks own the Terraform and Ansible chassis, and the play is
composed into the pinned [`ansible-framework`](https://github.com/nwarila-platform/ansible-framework)
checkout at execution time.

The repository follows the same Windows SSH/PowerShell and three-disk conventions as the sibling
reference [`pdq-deploy-inventory`](https://github.com/nwarila-platform/pdq-deploy-inventory).

## What it deploys

One host from a license-included `Windows_Server-2025-English-Full-SQL_2022_Standard` image, so
SQL Server arrives licensed by AWS rather than installed and licensed here. The image is Server
2025, not the target's 2022, because only 2025 ships OpenSSH — see
[TD-012](docs/explanation/technical-debt.md).

| Drive | Label | Purpose |
|---|---|---|
| E: | `WSUSDB` | SUSDB on SQL Server |
| F: | `WSUSDATA` | WSUS content store |
| G: | `WSUSIIS` | IIS root |

## Lifecycle

`AWS Deploy` runs on protected `main` — on push, on a weekly schedule, and on manual dispatch.
It applies the pinned Terraform framework against `terraform/aws.tfvars`, converges the play,
proves the second converge is a no-op, and attempts destroy after any successful init,
including on a handled failure. A job that exhausts its budget or is cancelled can still strand
resources. A dispatched run can hold the provisioned guest for up to four hours first, so an
operator can inspect it before teardown.

No AWS credential reaches pull-request code: the workflow guard and the OIDC trust both admit
only `refs/heads/main`.

## Layout

| Path | Purpose |
|---|---|
| `ansible/playbooks/wsus-aws.yml` | Composed play: inventory contract, host readiness, then guest storage |
| `ansible/inventory/aws_ec2.yml` | Dynamic EC2 inventory filtered to one run |
| `terraform/aws.tfvars` | Data-only input for the pinned Terraform framework |
| `scripts/compose-and-run.sh` | Local composition and execution |
| `docs/reference/aws-iam/` | The IAM the lifecycle assumes, and how to apply it |
| `docs/reference/ansible-style-guide.md` | Ansible design and authoring rules |
| `docs/explanation/wsus-role-migration-contract.md` | Contracts the rebuilt WSUS role must satisfy |

## Status

Rebuilding. The WID-backed WSUS role was removed on 2026-08-23 because WSUS on SQL Server
differs at the postinstall boundary; its contracts are recorded in the migration contract
above. What the lifecycle does today is the bare host: provision, reach it over direct SSH, and
provision the three guest volumes. WSUS and SQL Server configuration is the next work, one
action at a time.
