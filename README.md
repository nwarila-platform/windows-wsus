# windows-wsus

[![AWS lifecycle proof](https://github.com/nwarila-platform/windows-wsus/actions/workflows/aws-deploy.yml/badge.svg?branch=main)](https://github.com/nwarila-platform/windows-wsus/actions/workflows/aws-deploy.yml)

A `nwarila-platform` application repository for WSUS on SQL Server, proven against Windows Server
2019, 2022 and 2025 clients by a disposable AWS lifecycle. The repository owns the application
inputs and roles; version-pinned platform frameworks own the Terraform and Ansible chassis, and
the play is composed into the pinned
[`ansible-framework`](https://github.com/nwarila-platform/ansible-framework) checkout at
execution time.

The repository follows the same Windows preparation and three-disk conventions as the sibling
reference [`pdq-deploy-inventory`](https://github.com/nwarila-platform/pdq-deploy-inventory).

## What it deploys

Every run builds one WSUS server and three clients:

| Host | Image | Role | Transport | Logon before join → after join |
|---|---|---|---|---|
| `tcnaw-wsus01` | `Windows_Server-2022-English-Full-SQL_2022_Standard-2026.09.17` | WSUS server | SSH, key | `Administrator` (launch key) → `tcn\jenkins_runner` (automation key) |
| `tcnaw-wsusc01` | `EC2LaunchV2-Windows_Server-2019-English-Full-Base-2026.09.17` | client | WinRM HTTPS 5986, NTLM | `Administrator` (launch password) → `tcn\jenkins_runner` (password) |
| `tcnaw-wsusc02` | `Windows_Server-2022-English-Full-Base-2026.09.17` | client | SSH, password | `Administrator` (launch password) → `tcn\jenkins_runner` (password) |
| `tcnaw-wsusc03` | `Windows_Server-2025-English-Full-Base-2026.09.17` | client | SSH, key | `Administrator` (launch key) → `tcn\jenkins_runner` (automation key) |

The framework's `credential_resolver` selects the image identity on a fresh host and
`tcn\jenkins_runner` after the domain join. That transition is required because the domain's STIG
denies local accounts network logon. The 2019 client uses the EC2Launch v2 image because the pinned
readiness check requires EC2Launch v2.

The server takes a license-included SQL Server image, so the database engine arrives licensed by
AWS rather than being installed here. Only the two Server 2022 hosts install OpenSSH from the
staged Feature-on-Demand cab; the 2019 client is reached over WinRM and installs none. See
[TD-012](docs/explanation/technical-debt.md).

The server carries three volumes:

| Drive | Label | Purpose |
|---|---|---|
| E: | `WSUSDB` | SUSDB on SQL Server |
| F: | `WSUSDATA` | WSUS content store |
| G: | `WSUSIIS` | IIS request logs |

## Lifecycle

`AWS Deploy` runs on protected `main` — on push, on a weekly schedule, and on manual dispatch.
It applies the pinned Terraform framework against `terraform/aws.tfvars`, converges the play,
proves the second converge is a no-op, and attempts destroy after any successful init,
including on a handled failure. A job that exhausts its budget or is cancelled can still strand
resources. A dispatched run can hold the provisioned guests for up to four hours first, so an
operator can inspect them before teardown.

No AWS credential reaches pull-request code: the workflow guard and the OIDC trust both admit
only `refs/heads/main`.

## Layout

| Path | Purpose |
|---|---|
| `ansible/playbooks/wsus-aws.yml` | Composed plays: inventory contract, parallel host preparation, WSUS, then client proof |
| `ansible/applications/wsus/` | The WSUS role; with its PowerShell under `scripts/`, the only thing here that transfers to production |
| `ansible/applications/wsus_client/` | Proof-of-concept role called by the play for all three clients |
| `ansible/inventory/aws_ec2.yml` | Dynamic EC2 inventory filtered to one run |
| `terraform/aws.tfvars` | Data-only input for the pinned Terraform framework |
| `scripts/compose-and-run.sh` | Local composition and execution |
| `scripts/<Name>.ps1` | The wsus role's PowerShell, each beside its Pester spec; the role carries stubs |
| `docs/reference/aws-iam/` | The IAM the lifecycle assumes, and how to apply it |
| `docs/reference/ansible-style-guide.md` | Ansible design and authoring rules |
| `docs/explanation/wsus-role-migration-contract.md` | Contracts the rebuilt WSUS role must satisfy |

## Status

Built, and exercised end to end on the disposable lifecycle. The WID-backed role was removed on
2026-08-23 because WSUS on SQL Server differs at the postinstall boundary; it was rebuilt one
action at a time against the migration contract above.

That rebuild covers everything below. It does NOT yet close the records that track it: the IIS
rows of the migration contract still owe their runtime-verifier re-checks, which wait on GATE-01,
and TD-005 still asks for durable live evidence.

One converge now places SUSDB on its own volume before anything can create it, installs the WSUS
features, completes post-installation against the SQL instance, serves clients over TLS with a
certificate delivered through the controller, scopes the host firewall by port and program and
removes the wide-open rules WSUS opens for itself, reconciles the content store and its
permissions, restricts the update languages, points the server at its upstream, synchronises the
catalogue and the files behind it, and then tunes the WSUS application pool, removes the Default
Web Site and the pools nothing else uses, and writes IIS request logs to their own volume.

Every run proves one WSUS server plus the three clients running `wsus_client`. The client role
refuses a host whose Group Policy does not name this deployment's server or whose expected trust
anchor is absent, requests updates, installs what WSUS offers, and fails on any failed update. The
workflow then converges the whole playbook a second time and fails if any host reports a change.
The inventory contract refuses any topology other than exactly one server and three clients.

Two things are deliberately not here. STIG hardening of the SQL database, and of IIS beyond the
pool, site and logging work above, is out of scope for now. And only `ansible/applications/wsus/`,
with its PowerShell under `scripts/`, transfers to production — `wsus_client` is a
proof-of-concept, and the play, the tfvars, the `remote_client` role and the certificates are all
artifacts of this disposable environment, which is more configuration-divergent than production by
nature.
