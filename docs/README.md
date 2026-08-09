# Documentation

Documentation for this repository follows the [Diátaxis framework](https://diataxis.fr/) per
[org ADR-0002](https://github.com/nwarila-platform/.github/blob/main/docs/decision-records/0002-adopt-diataxis-documentation-framework.md).

| Quadrant  | Path         | Purpose                                                        |
| --------- | ------------ | -------------------------------------------------------------- |
| How-to    | `how-to/`     | Task-oriented procedures for running and repairing the system   |
| Reference | `reference/`  | Authoritative source of record: IAM documents, authoring rules  |
| Explanation | `explanation/` | Why the system is shaped this way, and what it does not cover |
| Decisions | `decision-records/` | ADR index: org-mirrored, template-mirrored, and repository-specific |

Tutorials are deliberately absent. Nothing here is learning-oriented: the lifecycle runs
unattended, and the only human entry points are responding to an incident and reviewing a change.

## How-to guides

- [Operations](how-to/operations.md) — the assurance contract, what a green proof does and does
  not establish, responding to an incident, IAM changes and drift, and decommissioning.

## Reference

- [AWS IAM](reference/aws-iam/README.md) — the reviewed trust boundary: every policy and role
  document, the placeholder substitution contract, and the residual risks each grant carries.
- [Ansible style guide](reference/ansible-style-guide.md) — the authoring rules the WSUS role is
  written to, and the reasoning behind the ones that are not obvious.

## Decisions

- [Architecture Decision Records](decision-records/README.md) — the org and template ADRs this
  repository inherits, mirrored byte-identically, plus any repository-specific decisions.

## Explanation

- [Technical debt](explanation/technical-debt.md) — every known gap with its containment and its
  exit criteria. Entries are closed only when the exit criteria are met, not when they stop being
  inconvenient.
