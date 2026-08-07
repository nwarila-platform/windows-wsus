# Operations

This repository is designed to be quiet when healthy. Pull requests prove source quality without
cloud credentials; protected `main` performs the disposable AWS proof. Automation opens one durable
incident per failing subsystem rather than one issue per run.

## Assurance contract

| Control | Trigger | Authority | Expected result |
|---|---|---|---|
| `CI / required` | every pull request, merge queue, and `main` push | repository read only | source, IAM structure, workflow contracts, pins, and composed Ansible are valid |
| `AWS Deploy` | protected `main` push, weekly schedule, or main-only manual dispatch | GitHub OIDC deploy role | apply, configure, verify, destroy, then report the aggregate result |
| `AWS Reaper` | hourly fallback and main-only manual dispatch | GitHub OIDC deploy role (temporary shared boundary) | ignore active/fresh runs; remove only stale repository-owned resources |
| `Framework Pin Discovery` | weekly schedule | repository write only | update one reviewable framework-pin PR; never execute candidate workflow code with AWS credentials |

The AWS proof uses a dedicated state key and a singleton deploy concurrency group. It generates an
ephemeral RSA key for the run, gives Terraform only the public half, and deletes the EC2 key pair
with the stack. The private half exists only in the hosted runner's temporary directory.

The proof inventory is generated from Terraform's `aws_instances` output and checked against live
EC2 ownership and run tags. A broad `Function=wsus` discovery result is not accepted as proof.

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
- No repository-owned test resource remains after a successful lifecycle.
- Stale-resource cleanup never acts on the current run or on a fresh run.
- The delivered certificate has at least 45 days of validity remaining.
- One incident is open per failing automation class; a healthy run closes it.

## Responding to an incident

1. Follow the run URL in the automation issue and identify whether failure occurred before apply,
   during configuration, in verification, or during destroy.
2. Check for another active `AWS Deploy` run before taking cleanup action.
3. Inspect the fixed S3 state key and its `.tflock`; never delete a lock until the owning run is
   confirmed absent.
4. Use the reaper's `workflow_dispatch` only from `main`. It must remain age- and ownership-gated.
5. Close nothing manually merely because a rerun started. Recovery automation closes the incident
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

`--check-drift` verifies exact trust, managed attachments, absence of inline policies, session
duration, and instance-profile membership. `--apply` reconciles that exact model, including
detaching unexpected policies, so inspect the source and plan before granting its administrative
profile. IAM and the playbook derive the same `<account-id>-ansible` artifact bucket.

## Dependency updates

Dependabot opens grouped GitHub Actions and Python quality-tool updates. Those pull requests receive
only the credential-free required check. Framework-pin automation opens or refreshes a reviewable
pin-only pull request; it does not dispatch a privileged branch workflow or auto-merge arbitrary
upstream `main` code.

## Decommissioning

1. Disable the recurring deploy and updater workflows.
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
