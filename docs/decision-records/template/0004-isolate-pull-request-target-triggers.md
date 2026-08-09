# ADR-template/0004: Isolate Pull Request Target Triggers

| Field          | Value                                   |
| -------------- | --------------------------------------- |
| Status         | Accepted                                |
| Date           | 2026-05-11                              |
| Authors        | Nick Warila (@NWarila)                  |
| Decision-maker | Nick Warila (sole portfolio maintainer) |
| Consulted      | zizmor findings and OPA policy review.  |
| Informed       | Trusted-bot auto-merge consumers via workflow docs. |
| Reversibility  | Medium                                  |
| Review-by      | N/A (Accepted)                          |

## TL;DR

`pull_request_target` is allowed only for the narrow trusted-bot auto-merge
surface. Release publication, release evidence, runner validation, and
Terraform deploy caller workflows must stay on ordinary trusted events.
`release.yaml` must never add `pull_request_target`.

## Context and Problem Statement

`pull_request_target` runs in the security context of the base repository. That
is useful for trusted-bot auto-merge because the workflow must enable GitHub
auto-merge without checking out PR code. It is a poor fit for release
publishing, release evidence, runner validation, or Terraform deploy callers,
which touch artifacts, workflow inputs, framework refs, and runtime validation
paths.

The runner template is mirrored into consumers. If the template mixes release
or validation logic with a privileged PR trigger, every downstream runner
inherits that risk. The safer rule is simple: the exceptional trigger exists
only for the exceptional auto-merge job.

## Decision Drivers

1. **Least privilege.** Runner workflows should use privileged PR events only
   when ordinary events cannot do the job.
2. **Consumer inheritance.** A mistake in this template becomes a mistake in
   every consumer through the baseline manifest.
3. **Release integrity.** Evidence bundles and attestations should be produced
   from trusted release/dispatch paths.
4. **Validation clarity.** Runner validation must reason about pinned refs and
   overlays, not privileged PR metadata.
5. **Machine enforcement.** OPA should reject the most important forbidden
   trigger directly.

## Considered Options

1. Keep auto-merge, release, validation, and deploy concerns in one workflow.
2. Split the workflows but allow `pull_request_target` in release if needed.
3. Isolate `pull_request_target` to `auto-merge.yaml` and forbid it from
   `release.yaml`.
4. Remove `pull_request_target` and require manual merges for dependency PRs.

## Decision Outcome

Chosen option: **Option 3, isolate `pull_request_target` to auto-merge and
forbid it from release.**

Runner templates keep trusted-bot auto-merge in `auto-merge.yaml`, a small
caller of `reusable-auto-merge.yaml`. Release publication and release evidence
stay in `release.yaml`, triggered by `push`, `release`, or
`workflow_dispatch`. PR validation stays in `pr-validation.yaml`; deploy
caller behavior stays in `terraform-deploy.yaml`.

## Pros and Cons of the Options

### Option 1: Keep all behavior together

- **Good, because** there is one workflow file to inspect.
- **Bad, because** release or validation edits can inherit privileged PR
  behavior accidentally.
- **Bad, because** consumers inherit a wider trust boundary than they need.

### Option 2: Split workflows but allow release `pull_request_target`

- **Good, because** it keeps today's files organized.
- **Neutral, because** it leaves room for future release designs.
- **Bad, because** the rule cannot be enforced cleanly.
- **Bad, because** release evidence does not need PR-controlled metadata.

### Option 3: Isolate `pull_request_target` to auto-merge (chosen)

- **Good, because** the privileged PR trigger has exactly one purpose.
- **Good, because** release and evidence behavior stays on trusted events.
- **Good, because** OPA can reject `pull_request_target` in every workflow except the explicit auto-merge allowlist entry.
- **Bad, because** a future exception requires an ADR update.

### Option 4: Remove `pull_request_target` entirely

- **Good, because** the privileged PR event disappears.
- **Bad, because** trusted dependency bots lose safe auto-merge ergonomics.
- **Bad, because** it discards a narrow two-job design instead of enforcing its
  boundary.

## Confirmation

Adherence to this ADR is confirmed by the following mechanisms. The wording
`MUST`, `SHOULD`, and `MAY` follows RFC 2119 conventions.

1. **Privileged trigger allowlist.** `.github/workflows/auto-merge.yaml` is the
   only workflow allowed to use `pull_request_target`. The OPA `repo_hygiene`
   policy enforces this against real workflow files.
2. **Release trigger policy.** `.github/workflows/release.yaml` MUST NOT contain
   a `pull_request_target` trigger.
3. **Auto-merge reusable guard.** `reusable-auto-merge.yaml` MUST NOT read
   PR-controlled content or check out PR code. The OPA `repo_hygiene` policy
   enforces those content boundaries; the trusted-author list is maintained by
   convention and branch protection.
4. **Runner validation separation.** `pr-validation.yaml` and
   `reusable-terraform-validation.yaml` MUST remain outside
   `pull_request_target`.
5. **Human review.** Any PR that adds `pull_request_target` to a new workflow
   MUST explain why ordinary events are insufficient and SHOULD include a
   superseding ADR.

## Consequences

### Positive

- Release maintenance no longer touches the privileged PR trigger surface.
- Runner consumers inherit a smaller workflow trust boundary.
- OPA can enforce the full allowlist with a direct rule.

### Negative

- A future workflow that genuinely needs `pull_request_target` requires an ADR
  update before implementation.
- Auto-merge and release surfaces remain split across two caller workflows.

### Neutral

- The reusable auto-merge workflow remains privileged for trusted-bot merge
  enablement only.
- Release evidence still supports both `release` and `workflow_dispatch` paths
  because `GITHUB_TOKEN`-created release events do not cascade.

## Assumptions

1. Release publication and release evidence do not require PR-controlled
   content.
2. Runner validation can operate on ordinary `pull_request` and dispatch events.
3. Trusted dependency bots remain the only principals eligible for auto-merge.

## Supersedes

None.

## Superseded by

None (current).

## Implementing PRs

- [`7400021`](https://github.com/NWarila/terraform-runner-template/commit/7400021e15fad6a47c1afdaf904e4dcf0d5f6eb0) added the pull-request-target OPA allowlist and runner contract gates.
- [`b269b3c`](https://github.com/NWarila/terraform-runner-template/commit/b269b3cb0cc897ddb684a3ac0f98ab38839e1d42) documented the scoped zizmor waiver for the isolated auto-merge caller.

## Related ADRs

- [ADR-template/0001](0001-pin-terraform-and-provider-versions-exactly.md)
  establishes exact toolchain pinning.
- [ADR-template/0002](0002-mandate-s3-state-backend.md) defines the runner
  state backend posture for real consumers.
- `tools/check_template_contract.py --type runner|template` keeps the validated
  contract surface explicit at each call site.

## Compliance Notes

None.
