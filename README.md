# windows-wsus

[![AWS lifecycle proof](https://github.com/nwarila-platform/windows-wsus/actions/workflows/aws-deploy.yml/badge.svg?branch=main)](https://github.com/nwarila-platform/windows-wsus/actions/workflows/aws-deploy.yml)

A `nwarila-platform` application repository for WSUS on SQL Server, converged on Windows Server
2019, 2022 and 2025 and proven by a disposable AWS lifecycle. The repository owns the application
inputs and roles; version-pinned platform frameworks own the Terraform and Ansible chassis, and
the play is composed into the pinned
[`ansible-framework`](https://github.com/nwarila-platform/ansible-framework) checkout at
execution time.

The repository follows the same Windows SSH/PowerShell and three-disk conventions as the sibling
reference [`pdq-deploy-inventory`](https://github.com/nwarila-platform/pdq-deploy-inventory).

## What it deploys

Three WSUS servers, all on every run — one each on Windows Server 2019, 2022 and 2025:

| Host | Image | Release |
|---|---|---|
| `tcnaw-wsus01` | `Windows_Server-2025-English-Full-SQL_2022_Standard-2026.09.17` | 2025 |
| `tcnaw-wsus02` | `Windows_Server-2022-English-Full-SQL_2022_Standard-2026.09.17` | 2022, the production target |
| `tcnaw-wsus03` | `Windows_Server-2019-English-Full-SQL_2022_Standard-2026.09.17` | 2019 |

All three take license-included SQL Server images, so the database engine arrives licensed by AWS
rather than installed here, and all three take the same publication date, so a difference between
them is a difference the operating system makes rather than one the images arrived with.

The fleet used to be a single 2025 server plus a client, because 2025 was the only generation that
ships OpenSSH and the deployment had no way onto the others. It now installs the capability at
boot from a staged Feature-on-Demand cab, which is what makes 2022 and 2019 reachable at all —
see [TD-012](docs/explanation/technical-debt.md).

Each server carries three volumes:

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
| `ansible/playbooks/wsus-aws.yml` | Composed plays: inventory contract, then every server — readiness, preparation, storage, WSUS |
| `ansible/applications/wsus/` | The WSUS role. The only thing here that transfers to production |
| `ansible/applications/wsus_client/` | Proof-of-concept role. Retained but NOT called by the play: the fleet is three servers and no client |
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

What the run proves, and what it no longer proves, both changed when the fleet went to three
servers. It now shows the role converging on 2019, 2022 and 2025 in one lifecycle, and re-runs the
whole playbook and fails if any host reports a change. The inventory contract refuses a run that
does not hold exactly three servers, one per release, so a partial fleet cannot pass while proving
less than it claims.

It no longer builds a client, and that is a real subtraction, not a tidy-up. Until 2026-09-22 every
run stood up a second guest with no egress to 80 or 443, refused to proceed unless `WUServer` named
this deployment's server and the expected trust anchor was in a root store, and then took an update
from it. An installed update on that guest was evidence about which server answered. Nothing in the
current run replaces that: three healthy servers prove WSUS is configured on three generations, not
that any of them serves a client. `wsus_client` is retained, uncalled, so the proof can be restored
without rebuilding it.

Two things are deliberately not here. STIG hardening of the SQL database and of IIS is out of
scope for now. And only `ansible/applications/wsus/` transfers to production — `wsus_client` is a
proof-of-concept, and the play, the tfvars, the `remote_client` role and the certificates are all
artifacts of this disposable environment, which is more configuration-divergent than production by
nature.
