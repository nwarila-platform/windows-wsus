# Operations

This repository is designed to be quiet when healthy. Pull requests prove source quality without
cloud credentials; protected `main` performs the disposable AWS proof. Each recurring in-repository
workflow opens one durable incident per failing subsystem rather than one issue per run.

## Assurance contract

| Control | Trigger | Authority | Expected result |
|---|---|---|---|
| `CI / required` | every pull request, merge queue, and `main` push | repository read only | source contracts, the pinned Terraform framework and consumer plan, and composed Ansible are valid |
| `AWS Deploy` | protected `main` push, weekly schedule, or main-only manual dispatch | GitHub OIDC deploy role | apply, configure, verify, destroy, then report the aggregate result |
| `AWS Reaper` | hourly fallback and main-only manual dispatch | GitHub OIDC deploy role (temporary shared boundary) | ignore active/fresh runs; remove only stale repository-owned resources with an exact same-run dependency graph |
| `IAM Drift Attestation` | daily schedule or main-only manual dispatch | dedicated read-only GitHub OIDC audit role | live policies, trusts, role attachments/tags, inverse policy consumers/boundary uses, role metadata, and bidirectional instance-profile membership exactly match source |
| `Framework Pin Discovery` | weekly schedule | repository write only | update one reviewable framework-pin PR; never execute candidate workflow code with AWS credentials |

The AWS proof uses a dedicated state key and a singleton deploy concurrency group. It generates an
ephemeral RSA key for the run, gives Terraform only the public half, and deletes the EC2 key pair
with the stack. The private half exists only in the hosted runner's temporary directory. Before
each apply, the workflow destroys any interrupted predecessor state under the Terraform lock and
proves the repository-owned inventory is empty; an old instance cannot be adopted because its
one-time private key is intentionally gone.

The proof inventory is generated from Terraform's `aws_instances` output and checked against live
EC2 ownership and run tags. A broad `Function=wsus` discovery result is not accepted as proof.
Before either Terraform destroy, before guest disk discovery, and before fallback reaper mutation,
attached ENIs, EBS volumes, and both sides of every EIP association must carry the same exact
repository, stack, environment, and run identity. The guest preflight additionally requires exactly
one attached `WSUSDB`, `WSUSDATA`, and `WSUSIIS` volume. A cross-run, foreign, or ambiguous
dependency makes the operation fail closed and leaves an incident for review.

## What the proof means

A successful AWS proof establishes that the pinned Terraform framework can provision the declared
Windows host; the pinned Ansible framework can compose and run this role; WSUS, WID, IIS, disk
placement, and the pinned TLS endpoint satisfy the verifier; and Terraform cleanup completed.

The public AWS proof deliberately has no route to the placeholder corporate upstream. Category
synchronization is therefore disabled in that play and **is not** part of its success claim. A real
functional synchronization claim requires a separate environment with a reachable upstream and
`wsus.sync.bootstrap_enabled: true`; the role then records its marker only after terminal success.

## Healthy-state objectives

- Required quality reports on every pull request and completes without secrets or AWS calls.
- The latest scheduled AWS proof is no more than eight days old.
- The latest daily IAM attestation is green and no more than two days old.
- No repository-owned test resource remains after a successful lifecycle.
- Stale-resource cleanup never acts on the current run or on a fresh run.
- The delivered certificate has at least 45 days of validity remaining.
- One incident is open per failing recurring in-repository workflow; a healthy run closes it.

## Responding to an incident

1. Follow the run URL in the automation issue and identify whether failure occurred before apply,
   during configuration, in verification, or during destroy.
2. Check for another active `AWS Deploy` run before taking cleanup action.
3. Inspect the fixed S3 state key and its `.tflock`; never delete a lock until the owning run is
   confirmed absent.
4. Use the reaper's `workflow_dispatch` only from `main`. It must remain age- and ownership-gated.
5. For an IAM drift incident, inspect the read-only comparison output, review the source and live
   difference, and use an administrative profile only after deciding which side is authoritative.
6. Close nothing manually merely because a rerun started. Recovery automation closes the incident
   only after the subsystem reports success.

Do not run the Terraform deployment locally while GitHub has an active or queued lifecycle. The S3
lock protects Terraform state, but it does not make out-of-band EC2 deletion safe.

## IAM changes and drift

IAM source documents live under `docs/reference/aws-iam/` and are intentionally not self-applied by
the deploy role. After reviewing a policy change:

```bash
./scripts/bootstrap-iam.sh --apply <profile>
./scripts/bootstrap-iam.sh --check-drift <profile>
```

The first protected-main proof after an OIDC or EC2 permission change is an acceptance test, not a
substitute for reviewing the materialized IAM diff.

`--check-drift` verifies exact trust, managed attachments, absence of inline policies, root role
paths, absence of role permissions boundaries and role tags, session duration, the named profile's
root path and membership, the inverse profile associations for all five roles, and the inverse
consumer set for all nine customer-managed policies (including zero boundary uses).
`--apply` first enforces the tracked source digests, quarantines existing modeled roles by removing
all managed and inline policies, removes unexpected inverse-policy consumers, and only then
restores exact trusts and publishes the tracked policy versions. Exact attachments are added only
after bounded read-back proves both trust documents and policy default versions match source, so
an interrupted apply fails closed with automation disabled rather than exposing a stale policy. An
unmodeled user/role using a tracked policy as a restrictive
boundary is a manual migration: apply refuses before its first write rather than delete it and
potentially activate unrelated permissions. IAM cannot change an existing role path, so apply
likewise fails before its first write when a tracked role is not at `/`; role recreation is an
explicit operator migration. Role tags can affect ABAC or restrictive policy behavior; apply
therefore refuses every write when a modeled role has any tag and requires a reviewed manual
migration instead of calling `UntagRole`. It similarly refuses unexpected role-to-profile
associations rather than detaching foreign profiles. A wrong path on the named profile also stops
before every write because that profile may serve an out-of-scope EC2 instance; path migration is
manual. Apply creates a missing profile at `/` and reconciles exact POC-role membership only when
the inverse preflight is clean. Policy and instance-profile tags are outside this metadata contract
and are never mutated. Inspect the source and plan before granting its administrative
profile. The daily `IAM Drift Attestation` runs the same exact comparison with a dedicated role
whose policy contains only the required Get/List/Describe/Validate actions; it cannot reconcile or
otherwise mutate IAM. IAM and the playbook derive the same `<account-id>-ansible` artifact bucket.

Apply mode is a maintenance-window operation: it temporarily detaches every modeled role so a
partial reconciliation fails closed. Before its first write, the script checks every nonterminal
Deploy, Reaper, and IAM-attestation run and proves that no repository-owned EC2 resource or
Terraform lock exists. It refuses a busy boundary; do not bypass that preflight.

## Dependency updates

Dependency automation is Renovate-only; this repository carries no Dependabot configuration
(TD-008). The installed organization app reads the thin `.github/renovate.json5`, which extends the
canonical Terraform-runner preset and adds native Ansible Galaxy coverage. GitHub Actions and the
bounded Python/Galaxy manifests are grouped into reviewable, non-auto-merged pull requests that
receive only the credential-free required check. Framework-pin automation exclusively owns
`.github/*framework-pin`; Renovate ignores those files. Exact version/checksum tuples in
`quality-tools.env` still require an atomic, primary-source-backed updater (TD-007).

Framework-pin automation opens or refreshes one reviewable pin-only pull request. It does not
dispatch a privileged branch workflow or auto-merge arbitrary upstream `main` code.

## Decommissioning

1. Disable the recurring deploy, reaper, IAM-attestation, and updater workflows.
2. Confirm no lifecycle is active, then run the protected cleanup path and verify zero tagged
   resources in every resource class used by the stack.
3. Remove the application IAM roles, policies, and instance profile through their owning Layer-0 or
   bootstrap process.
4. Remove certificate artifacts only after confirming no supported deployment consumes them.
5. Preserve or deliberately retire the Terraform state according to the platform retention policy;
   the deploy role intentionally cannot delete the state object.
6. Archive the repository only after schedules and external alarms no longer expect its heartbeat.

## Remaining external control

GitHub can delay scheduled workflows and can disable schedules in an inactive public repository.
The GitHub reaper is therefore a fallback, not a complete independent safety boundary. The durable
target is an AWS-native conditional lease, dedicated least-privilege cleanup role, expiry janitor,
and proof-freshness alarms. Until those guardrails are deployed, an operator should treat an
eight-day-old proof as an incident.
