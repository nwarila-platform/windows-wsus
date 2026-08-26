# AWS IAM — roles and policies (windows-wsus)

The IAM this repository's ephemeral AWS lifecycle assumes. An operator provisions it with the
`mgmt-admin` profile; Terraform does not manage it. Cloned on 2026-08-25 from the live roles of
`pdq-deploy-inventory` with the repository name and immutable id substituted. Four grant sets
were dropped as unreachable from this lifecycle: that product's S3 installers, licences, and
service-account secret; its network and directory artifacts; and the whole SSM policy, because
the transport is direct SSH and the image is a literal `ami-` id, so the framework never resolves
a catalog parameter. Grants are added here as this repository needs them, never copied ahead of
need — the network and directory artifacts arrived with the host-preparation roles that read
them.

## Substitution

These are the only `<...>` substitution tokens; IAM policy variables and wildcard characters —
the sixteen `?` matching the broker's permission-set hash — are retained as written.

| Token | Substitute with |
|---|---|
| `<account-id>` | the 12-digit AWS account id (`aws sts get-caller-identity`) |
| `<owner-id>` | the `nwarila-platform` organization id (`gh api orgs/nwarila-platform --jq .id`) |
| `<repository-id>` | this repository's immutable id (`gh api repos/nwarila-platform/windows-wsus --jq .id`) |

Ownership conditions on taggable EC2 resources carry the concrete repository name and id, so a
document copied into a sibling without substitution fails closed against that sibling's tags.

## Role-to-policy map

| Role | Trust | Session | Policies |
|---|---|---|---|
| `nwarila-platform_windows-wsus_runner` | `roles/nwarila-platform_windows-wsus_runner.trust.json` — GitHub OIDC, bound by `ref`, `sub`, and `job_workflow_ref` to `refs/heads/main` of this repository's `aws-deploy.yml` | 7800 s | the seven `nwarila-platform_windows-wsus_runner_*` policies |
| `nwarila-platform_windows-wsus_admin` | `roles/nwarila-platform_windows-wsus_admin.trust.json` — Identity Center broker | 3600 s | the same seven |
| `nwarila-ec2-role` | `roles/nwarila-ec2-role.trust.json` | default | `AmazonSSMManagedInstanceCore` (AWS-managed); instance profile `nwarila-ec2-profile`, shared across the organization and passed by both repository roles |

The `_admin` role cannot yet be assumed, and its trust is not the reason: the
`github_nwarila-platform` permission set is provisioned to this account and its broker role
matches the trust's `ArnLike`. That permission set's inline policy allows `sts:AssumeRole` on a
fixed list of repo-admin ARNs which names the pre-clone `github_nwarila-platform_windows-wsus-admin`
and not `nwarila-platform_windows-wsus_admin`. Adding the ARN is an Identity Center change
outside every repository. CI is unaffected; it uses the runner role.

## What the seven policies grant

The suffixes are policy domains, not services — `ebs`, `eni`, and `sg` all authorize EC2 actions.

- **Tagged creation.** The instance and volume legs of `RunInstances`, and explicit
  `CreateVolume`, `CreateNetworkInterface`, and `CreateSecurityGroup`, require this repository's
  identity tags in the request.
- **Tagged lifecycle.** Terminate, stop, start, modify, attach, detach, delete, and tagging of
  those instances and volumes require the resource to already carry those tags.
- **Untagged supporting legs.** A create call must also be authorized against the resources it
  references — images, subnets, key pairs, placement groups, the VPC, referenced security groups,
  the pre-created primary network interface passed to `RunInstances`, and security-group rules. These are
  ARN-scoped to the region and, except for images, the account, with no tag condition.
  `ec2:CreateTags` is additionally allowed on `*` when the call is one of the four tagged create
  actions, and tagging security-group-rule resources is scoped only to account and region.
- **Unconditional reads.** The EC2 `Describe` actions each policy enumerates — planning reads in
  `_ec2`, volumes in `_ebs`, interfaces in `_eni`, groups and rules in `_sg` — plus
  `kms:ListAliases`, `kms:DescribeKey`, and `iam:GetInstanceProfile` on the shared profile. No
  `ec2:Describe*` wildcard is granted.

Outside EC2: S3 reaches this repository's two Terraform state keys, and read-only the three
host-preparation artifacts — the connection profile and the directory join password by exact
key, and the OpenVPN installer by a key whose trailing segment is fixed and whose prefix is a
wildcard, so that one file name is readable wherever it sits under the product prefix; KMS keys are usable only `ViaService` EC2 in
the region; `iam:PassRole` passes only `nwarila-ec2-role`, only to EC2.

## Applying

Materialize the documents into an untracked directory with every token substituted. For each
policy, create it or publish the document as its default version; create or update both
repository roles with their trust documents and session durations; reconcile attachments to
exactly the seven policies. Then read back and compare with the materialized copy: both roles'
trust documents, session durations, and attachments, every policy's default version, and that
neither role carries an inline policy; and for the shared role, that its trust matches
`roles/nwarila-ec2-role.trust.json`, `AmazonSSMManagedInstanceCore` is its only policy, and
`nwarila-ec2-profile` contains it. Source and live must not diverge. Verified 2026-08-25.

The pre-clone IAM (`github_nwarila-platform_windows-wsus`, `-admin`, `-iam-audit`,
`windows-wsus-artifact-reader`, `windows-wsus-poc-role`, their nine policies, and the
`windows-wsus-poc-profile` instance profile) is still live and out of scope here. It is not
replaced by applying this set and must not be deleted without a separate decision.
