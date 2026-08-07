# AWS IAM — roles and policies (windows-wsus)

**Type**: Reference (Diátaxis). The IAM used by this repository's ephemeral AWS PoC. An operator
provisions the roles and policies; Terraform does not manage them.

Cloned from `secure-wazuh` and **hardened during the clone** against four rounds of dual independent
audit of a sibling repository's IAM. This document's most important section is the
[substitution contract](#substitution-contract) — read it before applying anything.

## Substitution contract

Every per-environment value in these sources is a `<placeholder>`. **Nothing here is a real
identifier.** That is deliberate: a `<...>` token can never match a real tag value, ARN, subject or
account, so an unsubstituted placeholder **fails closed** — the API rejects it and you find out
immediately.

The failure this contract exists to prevent is the opposite one. A *partial* substitution — the
right value in the Allows, a stale sibling value left in one condition or Deny — **fails open and
silently**: this repo's deploy still works while it holds authority over a sibling repository's live
resources in the shared account. Reading the applied policy back and diffing it against your
materialized copy **cannot** catch that, because the materialized copy is what is wrong.

| Placeholder | Substitute with | Source of truth | If you miss it |
|---|---|---|---|
| `<account-id>` | the 12-digit AWS account id | `aws sts get-caller-identity` | **fail-closed** — non-matching ARNs, or `MalformedPolicyDocument` at apply |
| `<repository-id>` | this repo's **immutable** GitHub repository id | `gh api repos/nwarila-platform/windows-wsus --jq .id` | **fail-closed** if wholly absent — **FAIL-OPEN if a sibling's id is left in even one statement** (see below) |
| `<region>` | the deploy region | the deploy plan (`us-east-1`) | fail-closed |
| `<vpc-id>` | the deploy VPC | Layer-0 bootstrap output | fail-closed if absent. **Verified 2026-07-29: this account has ONE VPC**, so every sibling materializes the same value — it is shared infrastructure, not a per-repo literal |
| `<subnet-id>` | the deploy subnet | Layer-0 bootstrap output | as above — **one subnet account-wide**, shared by all siblings |
| `<ebs-kms-key-id>` | the key `alias/aws/ebs` resolves to **in this account** | `aws kms describe-key --key-id alias/aws/ebs` | fail-closed. Account-wide and AWS-managed, so **siblings legitimately share the same key id** |
| `<owner-id>` | the GitHub organization's numeric id | `gh api orgs/nwarila-platform --jq .id` | fail-closed — the ID-embedded OIDC `sub` form never matches |
| `<key-pair-name>` | this repo's EC2 key pair | Layer-0 bootstrap output | fail-closed at launch |
| `<artifact-bucket>` | the S3 bucket holding the deploy artifacts | the deploy plan / Layer-0 bootstrap output | fail-closed — `s3:GetObject` on a `<...>` bucket name is denied. **But see below: the object-key prefix, not the bucket, is what separates the siblings** |

Because the VPC, subnet and EBS key are account-wide, **the identity tag is the only thing separating
the sibling repositories from each other.** The `ec2:Subnet` pin bounds every repo to the same deploy
subnet; it does not hold them apart. That raises the stakes on the next paragraph rather than easing
them.

**`<artifact-bucket>` behaves the same way, and its failure mode is quieter.** If the artifact bucket
is shared across siblings — the likely arrangement, since it is Layer-0 infrastructure — then
substituting it correctly grants nothing by itself. The read grant is scoped by the **object-key
prefix**, `applications/windows-wsus/tls/*`, not by the bucket name. Widen that prefix, or paste a
sibling's prefix into it, and this repository gains read access to another repository's private key
material with every placeholder correctly substituted and the gate green. The gate proves no literal
leaked; it cannot prove the prefix is the right one. Treat the prefix as load-bearing and read it
back at apply time.

The write grant is the same prefix boundary read backwards. `windows-wsus_artifact-folder` is scoped
to `applications/windows-wsus/tls/*` and carries no `s3:ListBucket`, so a wrong prefix cannot be
discovered by enumeration — it simply writes this repository's private key material into a location
another repository is authorized to read. Substituting `<artifact-bucket>` correctly does not make
the prefix correct. Read the prefix back at apply time, on both policies.

**`<repository-id>` is the one that can hurt you.** It is the sole authorization key for
`LifecycleOnlyOnOurTaggedResources` (terminate / delete-volume / detach) and
`SsmSessionOnlyToOurTaggedInstances` (an interactive shell). A sibling's id left in either statement
gives this repository's CI role destroy authority and a shell over that sibling's running
infrastructure. Substitute it everywhere in one operation and let the gate prove it.

### The gate — run it, do not eyeball it

```bash
./scripts/check-iam-literals.sh                      # CI: sources carry placeholders, no foreign literals
./scripts/check-iam-literals.sh --materialized DIR   # pre-apply: DIR is fully substituted
```

Materialize into one untracked directory, substitute every placeholder in a single pass, run the
gate in `--materialized` mode, and only then apply. **A non-zero exit means do not apply.** The gate
also refuses any twelve-digit value in the tracked sources, which is what keeps a real account id
out of git.

## Role-to-policy map

| Role | Trust source | Policies | Purpose |
|---|---|---|---|
| `github_nwarila-platform_windows-wsus` | `roles/github_nwarila-platform_windows-wsus.trust.json` | `github_nwarila-platform_windows-wsus` · `windows-wsus_deploy-ec2-launch` · `windows-wsus_deploy-ec2-lifecycle` · `windows-wsus_deploy-sg-ssm-kms` · `windows-wsus_deploy-discovery-iam` · `windows-wsus_artifact-assume` | CI state, deploy, prove, destroy; assumes the artifact-reader to deliver the TLS PFX at configure time |
| `github_nwarila-platform_windows-wsus-admin` | `roles/github_nwarila-platform_windows-wsus-admin.trust.json` | `github_nwarila-platform_windows-wsus` · the same four deploy policies · `windows-wsus_artifact-folder` (write is admin-only) · `windows-wsus_artifact-assume` | Operator break-glass and local deploy |
| `windows-wsus-artifact-reader` | `roles/windows-wsus-artifact-reader.trust.json` | `windows-wsus_artifact-read` | Controller-assumed, read-only artifact delivery |
| `windows-wsus-poc-role` | `roles/windows-wsus-poc-role.trust.json` | `AmazonSSMManagedInstanceCore` (AWS-managed) **only** | EC2 instance profile `windows-wsus-poc-profile` |

The `-admin` role carries the state policy as well as the four deploy policies: a local
`deploy -> test -> destroy` cannot read or write Terraform state without it, and the row above
claims that capability. Detach the deploy policies when the local path is retired.
`MaxSessionDuration` is 3600 seconds on all four roles — the AWS default, materialized as a
role property rather than inside any document here.

The instance role carries **exactly one** AWS-managed policy and no inline policy. It holds no S3
access of any kind — see [what this clone deliberately drops](#what-this-clone-deliberately-drops).

## Hardening applied during the clone

These close audit findings that are **still open in the source repository**. They are not optional
polish; each one is a finding both auditors raised.

- **Every literal is a placeholder** (R3-1/2/3/7, R4-1). The source repo placeholders only the
  account id; this clone placeholders all seven, so partial substitution becomes fail-closed.
- **`ec2:Encrypted: true` is required** on `RunInstancesVolumeCapped` and `CreateDataVolumeCapped`
  (R3-6). The source permits EBS encryption but never requires it, so omitting the KMS alias
  silently creates unencrypted volumes. WSUS carries the WID database and update content; encryption
  at rest is not optional here.
- **The ENI leg is subnet-pinned** via `ArnLike ec2:Subnet` (R3-4). VPC-pinning alone left a
  same-VPC foreign network interface attachable at launch, which would hand the instance another
  workload's address and security groups.
- **The SSO trust is bounded to the permission-set hash**, `AWSReservedSSO_github_nwarila-platform_`
  + sixteen `?` (R3-8). The source uses a trailing `*`, which also matches any future permission set
  named `github_nwarila-platform_<something>` — including a low-privilege one.
- **`job_workflow_ref` lists exactly this repository's two deploy-boundary workflows** —
  `aws-deploy.yml` (the lifecycle) and `aws-reaper.yml` (the scheduled teardown safety net) —
  and nothing else (R3-2). The rule for cloners is unchanged in spirit: never *append* to an
  inherited list (an appended trust leaves the sibling repository trusted) — replace it
  wholesale with your own repository's workflow paths, and keep every entry pointing at THIS
  repository. check-iam-literals.sh verifies each listed workflow file exists.
  **`sub` deliberately lists BOTH subject forms.** GitHub emits the ID-embedded subject
  `repo:<owner>@<owner-id>/<repo>@<repository-id>:<context>` for repositories created after roughly
  2026-07-15 — proven from the CloudTrail `userName` on a real denied `AssumeRoleWithWebIdentity`,
  not inferred. An earlier audit finding called that subject dead and a single-valued `sub`
  de-credentialed CI in all three repositories until it was corrected. `repository_id` with
  `StringEquals` is the actual identity boundary, so carrying both forms costs nothing and survives
  a repository transfer.
- **IMDS hop limit pinned to 1** at launch and on modify (R3-14), so IMDS cannot be extended past
  the host network stack.
- **Denies carry no substitutable narrowing** (R3 F11). The state Denies dropped
  `aws:ResourceAccount`; the resource ARN already pins the bucket, and a Deny that depends on a
  second substitution is a Deny that can be switched off by a typo.
- **`aws-marketplace` is not a trusted image owner** (R4-2). It is an open publisher namespace.
  This repo launches Windows Server images published under the `amazon` alias, so the owner list is
  `amazon` plus this account — no marketplace entry, and the finding closes for free.
  **Trap:** do not write `self` for images this account builds. `self` is a `DescribeImages`
  *request parameter*; the `ec2:Owner` condition key accepts only `amazon`, `aws-marketplace`, or an
  account id. A policy containing `self` does not error — it silently never matches.
- **`env:/*` is not in the state-bucket list prefix** (R3 LOW). Terraform runs in the default
  workspace here, and that prefix would enumerate every other repository's workspace keys.
- **IAM ARNs name the account** rather than `*`, so a mis-materialized reference fails closed.
- **The EC2 policy ships split** into `-launch` (authorizing new resources into existence) and
  `-lifecycle` (tagging, the identity Denies, and mutation of resources we already own). Combined and
  materialized it measured 5,900 of the 6,144-character managed-policy limit — 96%, against a house
  rule of *split at 85%, never trim a control*. The source repo carries it combined at ~92% and has
  already had to defer fixes for want of room. Split now, before either clone extends it: the halves
  measure ~2.6 KB and ~3.3 KB, and the role has ten managed-policy slots of which this uses four.
  Attach both; they are one boundary in two documents. Do not recombine them.

## Elastic IP grants (added 2026-08-07)

The full ephemeral lifecycle runs from a GitHub-hosted runner. The terraform framework attaches
pre-created ENIs, a launch path AWS never auto-assigns a public IP to — and the account has no
NAT and no VPC endpoints — so without an EIP the instance is both unreachable and route-less.
Four actions were added for it, all inside the existing identity boundary:

- `ec2:AllocateAddress` (`-launch`, Sid `AllocateTaggedElasticIp`) requires the repo identity tag
  **at create time** via `aws:RequestTag` — same shape as every other create in that policy. The
  framework's provider `default_tags` supply the tag.
- `ec2:AssociateAddress` / `ec2:ReleaseAddress` (`-lifecycle`) are `ec2:ResourceTag`-gated,
  deliberately **not** `IfExists`. `ec2:DisassociateAddress` alone is region-only (see the
  residual below): Terraform disassociates by association-id, a request form EC2 resolves to no
  taggable resource, so a tag condition there fails closed and blocks every destroy.
- `ec2:DescribeAddresses` / `ec2:DescribeAddressesAttribute` join the discovery describes (the
  provider reads both; describe stays account-wide like every other describe).

The EIP is pure EGRESS enablement: the shipped security group allows **zero ingress** — the
runner's SSH rides the SSM agent's own outbound 443 session — and egress is HTTPS only, which
is what lets the agent register through the internet gateway. Nothing on the internet can dial
the instance; the EIP just gives its outbound packets a route home.

## What this clone deliberately drops

> **Superseded 2026-08-07:** the artifact path described below was re-added and is now LIVE —
> the TLS certificate is delivered through `windows-wsus-artifact-reader` at configure time
> (see the role-to-policy map). This section stays as the audit trail of the original
> decision; the instance profile remains S3-free either way.

Both auditors, independently, recommended that the Windows consumers drop the artifact-delivery path
entirely. WSUS installs from a Windows Server role and Microsoft Update; it has no S3-delivered
artifact. Dropping it removes **the artifact-reader role, its trust, the artifact-read policy, the
presigned-URL signer and its fetch tasks** — and with them every finding R4-3 through R4-9.

The consequence worth stating: the instance profile is `AmazonSSMManagedInstanceCore` and nothing
else, so **no credential on the target can reach S3 at all.** If a future piece genuinely needs a
controller-delivered artifact, copy the source repo's presigned pattern *then* — with its own audit
findings applied first — rather than carrying the surface now for a need that does not exist.

## Values re-derived for this repository (never copied)

| Value | This repo | Why not the source's |
|---|---|---|
| Instance types | `t3.medium`, `t3.large` | Locked in the deploy plan. The source's `m6i.xlarge` is a 4-vCPU SIEM node; WSUS does not need it |
| Volume cap | 64 GiB | Largest single volume is the ~50 GiB Windows root, plus headroom. The three data disks are 20 GiB WSUSDB / 30 GiB WSUSDATA / 20 GiB WSUSIIS. The source's 100 GiB over-grants ~5× against these |
| IOPS / throughput | 3000 / 125 | gp3 defaults; `NumericLessThanEqualsIfExists` is intentional so an unspecified input inherits the default rather than failing |
| Ingress | **none** (SSH rides the SSM agent's outbound session) | The source's 1514/1515/443 are Wazuh agent and dashboard ports; this repo ships a zero-ingress group |
| State prefix | `nwarila-platform/windows-wsus/` | Per repository, in Allows **and** Denies together |

**IAM does not enforce the ingress ports.** Security-group *rules* are Terraform configuration; IAM
governs who may manage the groups. Treat the rule set as code-reviewed, not policy-enforced.

## Known residuals (accepted, recorded rather than hidden)

- **Public IP association is not denied — and since 2026-08-07 the role holds tag-gated EIP
  actions** (see [Elastic IP grants](#elastic-ip-grants-added-2026-08-07)): the hosted-runner
  lifecycle needs a public address on a pre-created-ENI launch in an account with no NAT and no
  VPC endpoints. SSM session transport already ships; the remaining structural
  fix is a private subnet with VPC interface endpoints, which would retire the EIP statements. The role still holds
  no internet-gateway or route-table actions.
- **`security-group-rule/*` is region-scoped.** Every rule action also authorizes against the parent
  `security-group/*` leg, which is tag- and VPC-pinned, so a foreign rule cannot be reached without
  its foreign parent. EC2 exposes VPC context on the parent group, not the rule resource — this is
  why it looks loose and is not.
- **`ec2:DisassociateAddress` is region-scoped only** (proven live, run 31183916280): Terraform
  disassociates by association-id, and EC2 then resolves no taggable resource — the request
  authorizes against `*/*`, so a `ResourceTag` condition fails closed and blocks every destroy.
  The exposure is disruption-only (a sibling's EIP could be detached, not released or stolen);
  Release/Associate stay tag-gated.
- **SSM session teardown is region-scoped.** An assumed role's `${aws:userid}` is
  `<role-id>:<session-name>`, which is not an SSM session-id prefix, so using it to narrow the ARN
  would silently deny legitimate teardown.
- **IAM cannot cap instance count or total spend.** A service quota and a budget alarm are separate
  account-side backstops and must exist before they can be relied on. Derive the vCPU quota from
  this repo's actual instance set — do not copy a number from another repository's README.
