# terraform/ — input layer for the pinned aws-terraform-framework

**Type**: Reference (Diátaxis). This directory carries **data, not resources**: the repo ships
no `.tf` files. The resource logic lives in
[aws-terraform-framework](https://github.com/nwarila-platform/aws-terraform-framework), a
*deployment root* checked out at the commit pinned in `.terraform-framework-pin` (repo root)
and driven with `-var-file` pointing back at a rendered copy of this directory's template.
Same consumption shape as the Ansible side (`.framework-pin` + compose), same reason: the
framework owns the how, this repo owns only the what.

| File | Purpose |
|---|---|
| `environments/aws-test.tfvars` | The one ephemeral system (`wsus-poc-01`) as framework `all_systems` input; passed to terraform verbatim |
| `../.terraform-framework-pin` | 40-char commit SHA of the framework (currently `fa3908c…` = release **2.2.0**; pin the SHA, not a tag — release tags land after the fact) |

## How a deploy runs

`.github/workflows/aws-deploy.yml` (the only workflow the OIDC trust lets assume the deploy
role) does, per run:

1. Checks out the framework at the pin and asserts `git rev-parse HEAD` matches it.
2. Passes `environments/aws-test.tfvars` to terraform verbatim. That file is the single
   source of truth for the deploy subnet: `bootstrap-iam.sh` parses `subnet_id` out of it
   (and derives the VPC from the subnet) to materialize the IAM pin, so the tfvars and the
   launch policy cannot disagree.
4. `terraform -chdir=<framework>/terraform init` with partial backend config:
   bucket `<account-id>-terraform`, key `nwarila-platform/windows-wsus/aws-poc.tfstate`,
   region `us-east-1`. `encrypt` and `use_lockfile` come from the framework's `backend.tf`;
   the state policy denies unencrypted puts and tfstate deletion, and grants lock-object
   (`*.tfstate.tflock`) delete — see `docs/reference/aws-iam/README.md`.
5. plan → apply → configure (Ansible) → prove → **destroy, always**. One fixed state key is
   correct because the workflow's concurrency group serializes every run; the first step of
   each run destroys any partial state a killed predecessor left behind.

## Assumptions this layer does not (cannot) verify

- **Reachability is the EIP:** the framework attaches pre-created ENIs, a launch path AWS
  never auto-assigns a public IP to, and the account has no NAT and no VPC endpoints — so the
  EIP (~$0.005/h while the instance lives) is the runner's only path in AND the instance's
  only route anywhere. The SG admits key-authenticated SSH only and allows no egress. The
  deploy subnet must route through an internet gateway; the deploy role cannot probe that
  (`ec2:DescribeRouteTables` is not granted).
- The org-shared `nwarila-ec2-key` key pair exists (secure-wazuh pattern). Its private half is
  the `AWS_EC2_SSH_PRIVATE_KEY` Actions secret — used only by CI's own readiness/Ansible SSH
  stages, never by Terraform (`readiness_gate = false`, `readiness_private_key_paths = {}`).

## Local (break-glass) run

Operators holding the `-admin` role can run the identical flow by hand: check out the
framework at the pin, render the template (subnet/AZ/VPC-CIDR via the same describe calls),
init with the same backend config, apply, destroy. State and lock live under the same key, so
a local run and CI cannot race each other past the S3 lockfile.

**Stuck lock recovery** (killed run left `aws-poc.tfstate.tflock` behind): confirm no run is
live, then `aws s3 rm s3://<account-id>-terraform/nwarila-platform/windows-wsus/aws-poc.tfstate.tflock`.
The state policy grants exactly that delete and denies deleting the state object itself.
CI never auto-deletes the lock.
