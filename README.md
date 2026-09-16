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

Two guests, both on every run. The server comes from a license-included
`Windows_Server-2025-English-Full-SQL_2022_Standard` image, so SQL Server arrives licensed by AWS
rather than installed and licensed here. The client comes from the Base image and exists only to
prove the server answers. Both are Server 2025, not the target's 2022, because only 2025 ships
OpenSSH — see [TD-012](docs/explanation/technical-debt.md).

The server carries three volumes:

| Drive | Label | Purpose |
|---|---|---|
| E: | `WSUSDB` | SUSDB on SQL Server |
| F: | `WSUSDATA` | WSUS content store |
| G: | `WSUSIIS` | Formatted and labelled; consumed by nothing yet, reserved for the deferred IIS work |

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
| `ansible/playbooks/wsus-aws.yml` | Composed plays: inventory contract, then the server — readiness, preparation, storage, WSUS — then the client that proves it |
| `ansible/applications/wsus/` | The WSUS role. The only thing here that transfers to production |
| `ansible/applications/wsus_client/` | Proof-of-concept role: triggers a client's update scan against the server just built and reports what arrived |
| `ansible/inventory/aws_ec2.yml` | Dynamic EC2 inventory filtered to one run |
| `terraform/aws.tfvars` | Data-only input for the pinned Terraform framework |
| `scripts/compose-and-run.sh` | Local composition and execution |
| `docs/reference/aws-iam/` | The IAM the lifecycle assumes, and how to apply it |
| `docs/reference/ansible-style-guide.md` | Ansible design and authoring rules |
| `docs/explanation/wsus-role-migration-contract.md` | Contracts the rebuilt WSUS role must satisfy |

## Status

Built, and exercised end to end on the disposable lifecycle. The WID-backed role was removed on
2026-08-23 because WSUS on SQL Server differs at the postinstall boundary; it was rebuilt one
action at a time against the migration contract above.

That rebuild covers everything below. It does NOT yet close the records that track it: the
migration contract still lists the IIS actors as to-be-reproduced, and TD-005 still asks for
durable live evidence. Both are waiting on a scope decision being written down, not on code.

One converge now places SUSDB on its own volume before anything can create it, installs the WSUS
features, completes post-installation against the SQL instance, serves clients over TLS with a
certificate delivered through the controller, scopes the host firewall by port and program and
removes the wide-open rules WSUS opens for itself, reconciles the content store and its
permissions, restricts the update languages, points the server at its upstream, and synchronises
the catalogue and the files behind it.

The lifecycle proves it rather than asserting it. Every run builds a second guest, joins it to the
directory, and runs `wsus_client` against it. That client has no direct egress to 80 or 443 — its
security group admits the tunnel and WSUS's two ports and nothing else — and before it asks for
anything it refuses unless `WUServer` names this deployment's server, `UseWUServer` is 1, and the
expected trust anchor is in a root store. It then asks that policy-configured server by
`server_selection: managed_server`. Those assertions, not the network rules, are what make an
installed update evidence about which server answered: a security group cannot see inside the
tunnel this client is also connected to. The same run then re-runs the whole playbook and fails if
any host reports a change.

Two things are deliberately not here. STIG hardening of the SQL database and of IIS is out of
scope for now. And only `ansible/applications/wsus/` transfers to production — `wsus_client` is a
proof-of-concept, and the play, the tfvars, the `remote_client` role and the certificates are all
artifacts of this disposable environment, which is more configuration-divergent than production by
nature.
