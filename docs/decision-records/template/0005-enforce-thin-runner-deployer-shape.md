# ADR-template/0005: Enforce Thin Runner Deployer Shape

| Field          | Value                                   |
| -------------- | --------------------------------------- |
| Status         | Accepted                                |
| Date           | 2026-06-02                              |
| Authors        | Nick Warila (@NWarila)                  |
| Decision-maker | Nick Warila (sole portfolio maintainer) |
| Consulted      | Runner contract review and github-terraform-runner cleanup findings. |
| Informed       | Terraform runner consumers via template contract and docs. |
| Reversibility  | Medium                                  |
| Review-by      | N/A (Accepted)                          |

## TL;DR

Terraform runner consumers are data-only deployers. They own repository
inventory, caller workflows, deploy inputs, public-safe private fixtures, and
repo-specific documentation. They do not own template-maintainer tooling,
policy suites, contract fixtures, local reusable workflow implementations, or a
local Terraform module. Those surfaces stay in the runner template and the
framework repositories, then are consumed by immutable refs.

## Context and Problem Statement

The Terraform runner pattern exists so a repository can deploy a Terraform
framework with local data. The canonical example is a GitHub inventory runner:
the runner owns YAML repo definitions under `terraform/public/` and
`terraform/private/`, while the framework owns the Terraform implementation
that plans and applies those definitions.

Earlier runner consumers carried template-maintainer files that did not do a
concrete job in the runner itself: local validators, OPA policies, contract
fixtures, and reusable workflow bodies. That made a runner look like a
framework even though it only needed to provide data and thin callers. The
result was harder review, stale copied logic, and weaker confidence that a
runner was actually small by design.

## Decision Drivers

1. **Repository responsibility.** A runner should prove the behavior it owns:
   inventory shape, caller pins, deploy wiring, and public-safe fixtures.
2. **Review clarity.** A maintainer should be able to inspect a runner without
   auditing template internals copied into the tree.
3. **Drift control.** Template-owned validators and policies should update in
   the template, not through local copies.
4. **Security.** Local reusable workflow implementations in a runner hide
   privileged or security-sensitive behavior where the template contract cannot
   maintain it consistently.
5. **End-to-end validation.** PR validation should assemble the runner data
   with the pinned framework and run the framework checks over the assembled
   tree.

## Considered Options

1. Enforce a thin runner deployer shape.
2. Allow runner consumers to mirror the full template tooling and fixtures.
3. Keep only documentation guidance and avoid machine enforcement.

## Decision Outcome

Chosen option: **Option 1, enforce a thin runner deployer shape.**

Runner consumers must keep the following local surface:

- root community and governance files required by the contract;
- `.github/workflows/pr-validation.yaml`, `drift-gate.yaml`, `security.yaml`,
  `repo-hygiene.yaml`, `terraform-deploy.yaml`, `release.yaml`, and
  `auto-merge.yaml` as thin callers (a consumer that mirrors org ADRs may
  additionally carry the scheduled `org-adr-auto-sync.yaml` caller; see
  `docs/reference/mirroring.md`);
- `terraform/public/` and `terraform/private/` inventory directories;
- public-safe private fixtures under `tests/fixtures/terraform/private/`;
- repository documentation and repo-scoped ADRs.

Runner consumers must not carry:

- `tools/`;
- `policies/`;
- `Makefile`;
- local `.github/workflows/reusable-*.yaml` or `.yml` implementations;
- a local executable Terraform module that replaces the framework.

Validation stays in the template/framework layer. The runner's PR validation
caller invokes `reusable-terraform-validation.yaml` from this template by SHA,
passes `mode: runner`, passes `run_contract_check: true`, and provides the
pinned framework repo/ref plus overlay paths. The reusable assembles the
framework and runner data before running checks.

## Pros and Cons of the Options

### Option 1: Thin runner deployer shape (chosen)

- **Good, because** the runner tree shows only the data and callers it owns.
- **Good, because** template policies and validators cannot drift as dead local
  copies.
- **Good, because** the contract can reject forbidden paths and required caller
  wiring mechanically.
- **Good, because** validation remains end-to-end: runner data is checked
  against the pinned framework, not only against local file shape.
- **Bad, because** a consumer that wants to debug template tooling must inspect
  the template repository rather than a local copy.
- **Bad, because** moving logic out of a runner can feel less self-contained.

### Option 2: Full tooling mirror in every runner

- **Good, because** every runner has a local copy of the validators.
- **Bad, because** those validators can go stale or remain uninvoked.
- **Bad, because** the runner becomes harder to distinguish from a framework.
- **Bad, because** copied policy creates extra review surface without adding
  enforcement.

### Option 3: Documentation only

- **Good, because** it avoids strict contract failures during migration.
- **Bad, because** stale local tooling can return without failing CI.
- **Bad, because** each reviewer has to re-litigate whether the runner is
  intentionally thin.

## Confirmation

Adherence to this ADR is confirmed by the following mechanisms:

1. `contract/runner-template-contract.yaml` lists required runner paths and
   forbidden runner paths.
2. `tools/check_template_contract.py --type runner` fails when a runner lacks
   required callers or carries forbidden local tooling, policies, Makefiles, or
   reusable workflow implementations.
3. Runner `pr-validation.yaml` callers pass `mode: runner` and
   `run_contract_check: true` to the template-owned reusable validation
   workflow.
4. Security, release, repo-hygiene, and auto-merge callers use centrally owned
   reusable workflows by immutable refs rather than local reusable bodies.
5. Runner-specific scope decisions belong in `docs/decision-records/repo/` of
   the runner repository, not in template tooling copied into the runner.

## Consequences

### Positive

- Runner repositories are smaller and easier to review.
- The template remains the source of truth for runner validation.
- Security-sensitive reusable workflow implementations are not duplicated into
  runner repos.
- Future consumers get a clearer starting point.

### Negative

- Contract bumps can require coordinated cleanup in older runners.
- Local debugging sometimes requires opening the template or framework repo.

### Neutral

- Runner docs may still explain the template contract and link to template
  ADRs.
- Repo-specific ADRs remain available for decisions that apply only to one
  runner.

## Assumptions

1. Terraform runner repositories remain deployers of framework-owned Terraform,
   not publishers of local framework modules.
2. The template-owned validation reusable remains available to runner
   consumers by immutable ref.
3. Runner consumers can provide public-safe private fixtures for PR validation
   when production private inventory is sourced outside the repository.

## Supersedes

None.

## Superseded by

None (current).

## Implementing PRs

- `contract/runner-template-contract.yaml` enforces the runner required and
  forbidden path shape.
- `tools/check_template_contract.py` and `tools/run_contract_tests.py` verify
  the contract and fixture behavior in template CI.
- PR #49 introduces this ADR, which records the rationale for the
  already-enforced thin runner shape.

## Related ADRs

- [ADR-template/0001](0001-pin-terraform-and-provider-versions-exactly.md)
  establishes exact Terraform and provider pinning.
- [ADR-template/0002](0002-mandate-s3-state-backend.md) defines the runner
  backend posture.
- [ADR-template/0004](0004-isolate-pull-request-target-triggers.md) isolates
  privileged PR triggers.
- [ADR-0008 (org)](../org/0008-enforce-repo-hygiene-by-repo-type.md) explains
  why data-only runners use a repo-hygiene caller instead of local policy
  tooling.
- [ADR-0009 (org)](../org/0009-classify-baseline-manifest-byte-identity.md)
  explains why consumers should not mirror template-internal files.

## Compliance Notes

This ADR does not require consumers to mirror template ADRs byte-identically.
The binding enforcement is the runner contract and the caller workflows that
invoke it.
