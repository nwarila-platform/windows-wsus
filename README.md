# windows-wsus

Deploys an **ephemeral WSUS server backed by WID** (Windows Internal Database) onto Windows
Server 2025 in AWS — a full **deploy → configure → prove → destroy** lifecycle that runs on
every pull request, on a weekly schedule, and on demand. Proven green end to end; each cycle
costs about $0.09 and leaves nothing standing.

This is a `nwarila-platform` single-purpose application repo: it carries one Ansible role
(`ansible/applications/wsus/`), its playbook, a dynamic inventory, and a plain tfvars. At run
time the role is composed into a version-pinned checkout of
[ansible-framework](https://github.com/nwarila-platform/ansible-framework), and the tfvars
drives a version-pinned checkout of
[aws-terraform-framework](https://github.com/nwarila-platform/aws-terraform-framework) — the
frameworks own the *how*, this repo owns only the *what*.

## How it runs

Nothing here needs an operator. `.github/workflows/aws-deploy.yml` runs the whole lifecycle:
`terraform apply` inside an audited IAM boundary → Ansible over **SSH-in-SSM** (zero-ingress
security group; the Elastic IP exists only so the SSM agent has an egress route) → WSUS
serving HTTPS on 8531 with a delivered, thumbprint-pinned certificate → `terraform destroy`,
always. `aws-reaper.yml` sweeps anything a hard-killed run leaves behind every 15 minutes,
`pin-bump.yml` tracks the framework mains and merges bumps only after the lifecycle passes
against them, and Dependabot does the same for action pins. Unattended failures file issues.

Manual run: **Actions → AWS Deploy → Run workflow**.

## Layout

| Path | Purpose |
|---|---|
| `ansible/applications/wsus/` | The role: WSUS on WID, SUSDB on E:, content on F:, IIS on G:, TLS on 8531 |
| `ansible/playbooks/wsus-aws.yml` | Readiness play (SSM-SSH wait) + the composed WSUS play |
| `ansible/inventory/aws_ec2.yml` | Dynamic inventory: finds the instance by Function tag, targets it as its instance id through SSM |
| `terraform/aws.tfvars` | The one system, as framework input; single source of truth for the deploy subnet |
| `.github/ansible-framework-pin` / `.github/terraform-framework-pin` | The framework checkouts, pinned by commit SHA |
| `.github/workflows/` | `aws-deploy` (the lifecycle + required PR check), `aws-reaper` (15-min teardown sweep), `pin-bump` (self-validating pin tracking) |
| `docs/reference/aws-iam/` | The audited IAM boundary as source documents; applied by `scripts/bootstrap-iam.sh` |
| `docs/ansible-style-guide.md` | The org style & design guide |
| `docs/TECH-DEBT.md` | Known debt, each entry with its exit criteria |

## Operational notes

- GitHub pauses scheduled workflows on public repos after ~60 days without repo activity;
  pin-bump commits normally reset that clock, and GitHub emails a warning before pausing.
- IAM changes are operator-applied: edit `docs/reference/aws-iam/`, then
  `BOOTSTRAP_ARTIFACT_BUCKET=<bucket> ./scripts/bootstrap-iam.sh --apply <profile>` and
  `--check-drift`. CI proves the boundary on every run; it cannot widen it.
