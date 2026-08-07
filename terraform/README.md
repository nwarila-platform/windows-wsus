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
| `aws.tfvars` | The one ephemeral system (`wsus-poc-01`) as framework `all_systems` input; passed to terraform verbatim |
| `../.github/terraform-framework-pin` | 40-char commit SHA of the framework (its `main` after the flat-identity-variables PR #105); pin the SHA, not a tag — release tags land after the fact |

## How a deploy runs

`.github/workflows/aws-deploy.yml` (one of the two workflows the OIDC trust admits — the
other is the reaper) does, per run:

1. Checks out the framework at the pinned commit (`actions/checkout` fails on a bad SHA).
2. Passes `aws.tfvars` to terraform verbatim. That file is the single source of truth for
   the deploy subnet: `bootstrap-iam.sh` parses `subnet_id` out of it (and derives the VPC
   from the subnet) to materialize the IAM pin, so the tfvars and the launch policy cannot
   disagree.
3. `terraform -chdir=<framework>/terraform init` with partial backend config:
   bucket `<account-id>-terraform`, key `nwarila-platform/windows-wsus/aws-poc.tfstate`,
   region `us-east-1`. `encrypt` and `use_lockfile` come from the framework's `backend.tf`;
   the state policy denies unencrypted puts and tfstate deletion, and grants lock-object
   (`*.tfstate.tflock`) delete — see `docs/reference/aws-iam/README.md`.
4. Generates an ephemeral RSA key, passes only its public half through the framework's
   `managed_keypairs` input, then runs apply → configure (Ansible) → **destroy, always**.
5. One fixed state key is protected by the deploy workflow's singleton concurrency group and
   Terraform's S3 lockfile. The separately serialized reaper is a conservative stale-resource
   fallback; it is not part of the deploy queue.

## Assumptions this layer does not (cannot) verify

- **Reachability is zero-inbound SSH over SSM:** the SG allows no ingress; the runner
  tunnels through an SSM session riding the agent's own outbound 443. The EIP exists purely
  to give that outbound path a route (pre-created ENIs never get auto public IPs; the account
  has no NAT and no VPC endpoints). The deploy subnet must route through an internet gateway;
  the deploy role cannot probe that (`ec2:DescribeRouteTables` is not granted).
- The deploy role can create and delete only the repository's `windows-wsus-ci` key pair.
  The private half remains in the runner's temporary directory and never enters Terraform
  state or GitHub secrets (`readiness_gate = false`, `readiness_private_key_paths = {}`).

## Local (break-glass) run

Operators holding the `-admin` role can run the identical flow by hand: check out the
framework at the pin, init with the same backend config, apply with `-var-file` pointing at
`aws.tfvars` plus the same `-var` identity flags, destroy. State and lock live under the same
key, so a local run and CI cannot race each other past the S3 lockfile.

**Stuck lock recovery** (killed run left `aws-poc.tfstate.tflock` behind): confirm no run is
live, then `aws s3 rm s3://<account-id>-terraform/nwarila-platform/windows-wsus/aws-poc.tfstate.tflock`.
The state policy grants exactly that delete and denies deleting the state object itself.
CI never auto-deletes the lock.
