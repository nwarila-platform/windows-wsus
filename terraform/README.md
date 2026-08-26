# terraform/ — input layer for the pinned aws-terraform-framework

**Type**: Reference (Diátaxis). This directory carries **data, not resources**: the repo ships
no `.tf` files. The resource logic lives in
[aws-terraform-framework](https://github.com/nwarila-platform/aws-terraform-framework), a
*deployment root* checked out at the commit pinned in `.github/terraform-framework-pin`
and driven with `-var-file` pointing back at this directory's `aws.tfvars`.
Same consumption shape as the Ansible side (`.github/ansible-framework-pin` + compose), same reason: the
framework owns the how, this repo owns only the what.

| File | Purpose |
|---|---|
| `aws.tfvars` | The one ephemeral system (`tcnaw-wsus01`) as framework `all_systems` input; passed to terraform verbatim |
| `../.github/terraform-framework-pin` | 40-char commit SHA of the framework (release 3.1.1 plus #120); pin the SHA, not a tag — release tags land after the fact |

## How a deploy runs

`.github/workflows/aws-deploy.yml`, the one workflow the OIDC trust admits, does per run:

1. Checks out the framework at the pinned commit (`actions/checkout` fails on a bad SHA).
2. Passes `aws.tfvars` to terraform verbatim.
3. `terraform -chdir=<framework>/terraform init` with partial backend config:
   bucket `<account-id>-terraform`, key `nwarila-platform/windows-wsus/aws-poc.tfstate`,
   region `us-east-1`. `encrypt` and `use_lockfile` come from the framework's `backend.tf`;
   the state policy reaches exactly the state object and its lock, and nothing else in the
   bucket — see `docs/reference/aws-iam/README.md`.
4. Stages the standing launch key's private half from an organization secret, then runs
   apply → configure (Ansible) → destroy. Destroy is attempted after any successful init,
   including on a handled failure; a job that exhausts its budget or is cancelled can still
   strand resources.
5. One fixed state key is protected by the deploy workflow's singleton concurrency group and
   Terraform's S3 lockfile.

## Assumptions this layer does not (cannot) verify

- **Reachability is direct SSH admitted by two groups:** the runner dials sshd at the instance's
  auto-assigned public IPv4. The framework's `runner_ip` group carries tcp/22 from that one
  runner's `/32`, created for the run and destroyed with it, and is passed as an apply-time
  `-var` because the address belongs to a single run; the interface's own group carries the
  temporary development-cycle rules that open tcp/22 to the whole IPv4 space. This depends on the
  shared deploy subnet keeping `MapPublicIpOnLaunch`, which `ec2:DescribeSubnets` does report; the
  route from that subnet to the internet gateway is what cannot be verified, because
  `ec2:DescribeRouteTables` is not granted. Either way the play fails on an inventory that yields
  no reachable host rather than hanging.
- The deploy role launches with the standing `nwarila-ec2-key` pair; it never creates key pairs.
  The private half lives in the `AWS_EC2_SSH_PRIVATE_KEY` organization secret, is staged into
  the runner's temporary directory at mode 0600 for the life of one job, and never enters
  Terraform state (`readiness_gate = false`, `readiness_private_key_path = null`).

## Local (break-glass) run

The `-admin` role would run the identical flow by hand — check out the framework at the pin, init
with the same backend config, apply with `-var-file` pointing at `aws.tfvars` plus the same
`-var` identity flags, destroy — and state and lock live under the same key, so a local run and
CI cannot race past the S3 lockfile. That path is unavailable today: the Identity Center
permission set's assume allowlist does not name the role
(`docs/reference/aws-iam/README.md`).

**Stuck lock recovery** (killed run left `aws-poc.tfstate.tflock` behind): confirm no run is
live, then `aws s3 rm s3://<account-id>-terraform/nwarila-platform/windows-wsus/aws-poc.tfstate.tflock`.
CI never auto-deletes the lock.
