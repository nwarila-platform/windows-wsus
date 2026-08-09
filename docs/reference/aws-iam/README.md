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
| `<region>` | normalized deploy region | the sole `region` in `terraform/aws.tfvars` (`us_east_1` → `us-east-1`) | fail-closed if a shell/workflow override diverges |
| `<vpc-id>` | VPC containing the declared deploy subnet | live `DescribeSubnets` result for the tfvars subnet | fail-closed if the subnet does not resolve |
| `<subnet-id>` | exact deploy subnet | `terraform/aws.tfvars` | fail-closed at launch; parsed from the same file Terraform consumes |
| `<ebs-kms-key-id>` | the key `alias/aws/ebs` resolves to **in this account** | `aws kms describe-key --key-id alias/aws/ebs` | fail-closed. Account-wide and AWS-managed, so **siblings legitimately share the same key id** |
| `<owner-id>` | the GitHub organization's numeric id | `gh api orgs/nwarila-platform --jq .id` | fail-closed — the ID-embedded OIDC `sub` form never matches |
| `<key-pair-name>` | the standing launch key name (`nwarila-ec2-key`) | `terraform/aws.tfvars` | fail-closed at launch |
| `<artifact-bucket>` | the S3 bucket holding deploy artifacts | the shared `<account-id>-ansible` playbook/bootstrap convention | fail-closed if the naming contract diverges; the object-key prefix remains the repository boundary |

The VPC and subnet constrain network placement, but **the immutable repository identity tag is the
authorization boundary between repositories.** A network-placement pin is not an ownership pin.

**`<artifact-bucket>` behaves the same way, and its failure mode is quieter.** The artifact bucket
is shared across applications, so substituting it correctly grants nothing by itself. The read
grant is scoped by the **object-key
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
| `github_nwarila-platform_windows-wsus` | `roles/github_nwarila-platform_windows-wsus.trust.json` | `github_nwarila-platform_windows-wsus` · `windows-wsus_deploy-ec2-launch` · `windows-wsus_deploy-ec2-lifecycle` · `windows-wsus_deploy-sg-ssm-kms` · `windows-wsus_deploy-discovery-iam` · `windows-wsus_artifact-assume` | Protected-main lifecycle and conservative fallback cleanup; assumes the artifact-reader to deliver the TLS PFX at configure time |
| `github_nwarila-platform_windows-wsus-admin` | `roles/github_nwarila-platform_windows-wsus-admin.trust.json` | `github_nwarila-platform_windows-wsus` · the same four deploy policies · `windows-wsus_artifact-folder` (write is admin-only) · `windows-wsus_artifact-assume` | Operator break-glass and local deploy |
| `github_nwarila-platform_windows-wsus-iam-audit` | `roles/github_nwarila-platform_windows-wsus-iam-audit.trust.json` | `github_nwarila-platform_windows-wsus_iam-audit` **only** | Daily protected-main comparison of live IAM with reviewed source; read-only and cannot self-apply |
| `windows-wsus-artifact-reader` | `roles/windows-wsus-artifact-reader.trust.json` | `windows-wsus_artifact-read` | Controller-assumed, read-only artifact delivery |
| `windows-wsus-poc-role` | `roles/windows-wsus-poc-role.trust.json` | `AmazonSSMManagedInstanceCore` (AWS-managed) **only** | EC2 instance profile `windows-wsus-poc-profile` |

The `-admin` role carries the state policy as well as the four deploy policies: a local
`deploy -> test -> destroy` cannot read or write Terraform state without it, and the row above
claims that capability. Detach the deploy policies when the local path is retired.
The protected lifecycle role has `MaxSessionDuration=7200`, covering either 100-minute Ansible
converge and its late controller-side artifact fetch. The admin, IAM-audit, artifact-reader, and
instance roles remain exactly 3600 seconds. `bootstrap-iam.sh --check-drift` verifies each role's
exact managed-policy set, absence of inline policies, trust document, root (`/`) path, absence of a
permissions boundary, exact empty role-tag set, duration, and instance-profile membership. It also
proves both inverses: every tracked customer-managed policy is attached only to its declared roles
and is not used as any user/role permissions boundary; the POC role is associated only with
`windows-wsus-poc-profile`, while the other four modeled roles have no instance profile. `--apply`
enforces source digests, quarantines every existing modeled role by detaching all managed and
inline policies, removes unexpected inverse consumers, and only then restores exact trusts,
publishes tracked policy versions, and reattaches exact sets.
Bounded read-back proves each trust and live default document matches source before attachment.
An interrupted apply therefore leaves automation disabled instead of exposing a stale policy. A
tracked policy used as a boundary on an unmodeled user/role is restrictive, so
apply refuses every write rather than risk activating that principal's unrelated Allows; only a
fully modeled role boundary is removed after its other over-grants are gone. New roles are created
at `/`; because IAM cannot update an existing role path, apply fails before its first write if a
tracked role has another path. Recreating that identity requires an explicit operator migration.
Role tags can participate in ABAC or restrictive policy conditions, so any tag on a modeled role
also fails the apply preflight with a manual-migration instruction; apply never removes it. A
modeled role attached to a foreign instance profile, or a foreign role attached to the named
profile, likewise fails before the first write and is never detached automatically. Once those
inverse associations are clean, apply creates a missing named profile at `/` and proves its path
and bidirectional membership with bounded read-back. A wrong existing profile path is also a
manual migration: the profile may be attached to an out-of-scope EC2 instance, so apply refuses
before its first write and never detaches or recreates it. Tags on managed policies and the
instance profile remain intentionally outside this metadata contract and are never mutated.
Review the plan and source diff before using apply mode.

Because apply temporarily quarantines all modeled roles, it is maintenance-window-only. Its
mandatory preflight proves Deploy, Reaper, and IAM attestation have no nonterminal run and that the
repository has no live EC2 resource or Terraform lock before the first detach; a busy boundary is
never overridden.

The instance role carries **exactly one** AWS-managed policy and no inline policy. It holds no S3
access of any kind; TLS artifacts are fetched by the controller through the reader role.

The IAM-audit role can read only the nine tracked customer-managed policies (documents and attached
entities), five tracked roles (including their tags and instance-profile associations), and one
tracked instance profile. Its remaining permissions are the
read-only resolvers required to materialize the expected documents (`DescribeSubnets`,
`DescribeKey`) and Access Analyzer's `ValidatePolicy`. Region conditions constrain the
account-wide APIs. Its OIDC trust accepts only `iam-drift.yml` from this repository at
`refs/heads/main`; it is separate from the deploy trust and has no IAM, EC2, KMS, S3, or SSM
mutation action. The scheduled workflow reports drift but never runs `--apply`.

## Hardening applied during the clone

These close audit findings that are **still open in the source repository**. They are not optional
polish; each one is a finding both auditors raised.

- **Every environment literal is a placeholder** (R3-1/2/3/7, R4-1). All nine required values are
  substituted in one pass, so an incomplete materialization fails closed.
- **`ec2:Encrypted: true` is required** on `RunInstancesVolumeCapped` and `CreateDataVolumeCapped`
  (R3-6). The source permits EBS encryption but never requires it, so omitting the KMS alias
  silently creates unencrypted volumes. WSUS carries the WID database and update content; encryption
  at rest is not optional here.
- **Network supporting legs are separated by resource type.** The pre-created ENI is pinned to the
  exact deploy subnet and VPC. Existing security groups used by either `RunInstances` or
  `CreateNetworkInterface` must carry this repository's exact resource tag; untagged and foreign
  groups fail closed. The shared subnet leg remains an exact ARN/VPC check without a repository
  tag, because the subnet is platform-owned rather than application-owned.
- **The SSO trust is bounded to the permission-set hash**, `AWSReservedSSO_github_nwarila-platform_`
  + sixteen `?` (R3-8). The source uses a trailing `*`, which also matches any future permission set
  named `github_nwarila-platform_<something>` — including a low-privilege one.
- **`job_workflow_ref` lists exactly this repository's two deploy-boundary workflows at
  `refs/heads/main`** —
  `aws-deploy.yml` (the lifecycle) and `aws-reaper.yml` (the scheduled teardown safety net) —
  and nothing else (R3-2). The rule for cloners is unchanged in spirit: never *append* to an
  inherited list (an appended trust leaves the sibling repository trusted) — replace it
  wholesale with your own repository's workflow paths, and keep every entry pointing at THIS
  repository. Feature-branch workflow code cannot match either workflow ref, and each exact `sub`
  suffix is also `ref:refs/heads/main`. check-iam-literals.sh verifies each listed workflow file
  exists.
  **`sub` deliberately lists BOTH subject forms.** GitHub emits the ID-embedded subject
  `repo:<owner>@<owner-id>/<repo>@<repository-id>:<context>` for repositories created after roughly
  2026-07-15 — proven from the CloudTrail `userName` on a real denied `AssumeRoleWithWebIdentity`,
  not inferred. An earlier audit finding called that subject dead and a single-valued `sub`
  de-credentialed CI in all three repositories until it was corrected. `repository_id` with
  `StringEquals` is the immutable identity boundary, and the two forms preserve compatibility with
  either currently observed subject template; the separate exact `ref` condition prevents a
  subject-template change from weakening the protected-main boundary. Only `repository_id` itself
  survives a repository transfer. Both exact subject forms, the owner identity, repository slug,
  and `job_workflow_ref` deliberately fail closed after a transfer until this source is
  rematerialized and applied for the new owner/path.
- **The read-only IAM-audit trust is independent.** Its `job_workflow_ref` is exactly
  `iam-drift.yml@refs/heads/main`, with the same immutable repository id, exact ref, audience, and
  dual exact subject forms. Adding the attestation workflow to the deploy role would unnecessarily
  give a read-only check lifecycle mutation authority; adding deploy workflows to the audit role
  would broaden who can inspect IAM without improving the proof.
- **The EC2 login key is ephemeral.** The lifecycle generates an RSA key on the hosted runner,
  names the standing `nwarila-ec2-key` pair, whose public half Windows user_data installs from
  instance metadata. The pinned framework consumes key pairs and never creates them. Launch use,
  and `DeleteKeyPair` are all scoped to the materialized key name and repository identity. No
  long-lived SSH private key is required in GitHub Actions.
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
Four mutation actions and two read-only discovery actions were added for it, all inside the existing
identity boundary:

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

## Values re-derived for this repository (never copied)

| Value | This repo | Why not the source's |
|---|---|---|
| Instance types | `t3.medium`, `t3.large` | Locked in the deploy plan. The source's `m6i.xlarge` is a 4-vCPU SIEM node; WSUS does not need it |
| Volume cap | 64 GiB | Largest declared volume is the 30 GiB Windows root/WSUSDATA size; the cap leaves bounded growth headroom. The other data disks are 20 GiB WSUSDB / 20 GiB WSUSIIS. The source's 100 GiB cap is unnecessary for this workload |
| IOPS / throughput | 3000 / 125 | gp3 defaults; `NumericLessThanEqualsIfExists` is intentional so an unspecified input inherits the default rather than failing |
| Ingress | **none** (SSH rides the SSM agent's outbound session) | The source's 1514/1515/443 are Wazuh agent and dashboard ports; this repo ships a zero-ingress group |
| State prefix | `nwarila-platform/windows-wsus/` | Per repository, in Allows **and** Denies together |

**IAM does not enforce the ingress ports.** Security-group *rules* are Terraform configuration; IAM
governs who may manage the groups. Treat the rule set as code-reviewed, not policy-enforced.

## Known residuals (accepted, recorded rather than hidden)

- **The GitHub lifecycle and fallback currently share one AWS role.** Exact protected-main OIDC
  trust removes arbitrary-ref access, and deletion remains tag-scoped, but a dedicated janitor role
  with no launch, state-write, SSM-session, or artifact-assume capability is the next Layer-0 IAM
  change. The fallback's GitHub run/age checks are deliberately not described as an atomic lock;
  replace them with an AWS-native lease and EventBridge janitor before relying on hard cleanup SLAs.
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
- **The pre-created ENI launch leg cannot enforce its resource tag.** The
  [EC2 authorization table](https://docs.aws.amazon.com/service-authorization/latest/reference/list_ec2.html)
  exposes request-tag keys, subnet, and VPC for the `RunInstances` `network-interface` leg, but not
  a resource-tag condition key. The pinned framework creates and tags the ENI before launch, so a
  request-tag condition is unavailable at attachment time. Exact subnet and VPC pins prevent an
  ENI from elsewhere in the VPC, but a foreign ENI in the same shared subnet remains attachable.
  Close this by changing the framework to create the interface in a request where the repository
  tag is bindable, or by feeding its exact ENI id into a per-run session policy. Prove that path
  live before making an exact resource-tag or id condition mandatory.
- **`ec2:DisassociateAddress` is region-scoped only** (proven live, run 31183916280): Terraform
  disassociates by association-id, and EC2 then resolves no taggable resource — the request
  authorizes against `*/*`, so a `ResourceTag` condition fails closed and blocks every destroy.
  The exposure is disruption-only (a sibling's EIP could be detached, not released or stolen);
  Release/Associate stay tag-gated.
- **SSM session teardown is region- and caller-session-scoped.** For an assumed role,
  `${aws:userid}` resolves to `<role-id>:<caller-specified-role-session-name>`. The AWS Session
  Manager [assumed-role pattern](https://docs.aws.amazon.com/systems-manager/latest/userguide/getting-started-restrict-access-examples.html)
  `session/${aws:userid}-*` therefore permits `TerminateSession` and `ResumeSession` only for
  sessions created by that same assumed-role session in the pinned region.
- **IAM cannot cap instance count or total spend.** A service quota and a budget alarm are separate
  account-side backstops and must exist before they can be relied on. Derive the vCPU quota from
  this repo's actual instance set — do not copy a number from another repository's README.
