#!/usr/bin/env python3
"""Offline structural assertions for the repository's IAM trust documents."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
ROLES = ROOT / "docs" / "reference" / "aws-iam" / "roles"
OWNER = "nwarila-platform"
REPOSITORY = "windows-wsus"

EXPECTED_SUBJECTS = {
    f"repo:{OWNER}@<owner-id>/{REPOSITORY}@<repository-id>:ref:refs/heads/main",
    f"repo:{OWNER}/{REPOSITORY}:ref:refs/heads/main",
}
EXPECTED_WORKFLOW_REFS = {
    f"{OWNER}/{REPOSITORY}/.github/workflows/aws-deploy.yml@refs/heads/main",
    f"{OWNER}/{REPOSITORY}/.github/workflows/aws-reaper.yml@refs/heads/main",
}


class Assertions:
    def __init__(self) -> None:
        self.count = 0
        self.failures: list[str] = []

    def equal(self, name: str, actual: Any, expected: Any) -> None:
        self.count += 1
        if actual != expected:
            self.failures.append(f"{name}: got {actual!r}; expected {expected!r}")

    def exact_string_set(self, name: str, actual: Any, expected: set[str]) -> None:
        self.count += 1
        if not isinstance(actual, list) or len(actual) != len(set(actual)) or set(actual) != expected:
            self.failures.append(
                f"{name}: got {actual!r}; expected a duplicate-free list containing {sorted(expected)!r}"
            )


def load(name: str) -> dict[str, Any]:
    with (ROLES / name).open(encoding="utf-8") as handle:
        return json.load(handle)


def only_statement(assertions: Assertions, name: str, document: dict[str, Any]) -> dict[str, Any]:
    statements = document.get("Statement")
    assertions.equal(f"{name} has exactly one statement", len(statements or []), 1)
    if not isinstance(statements, list) or len(statements) != 1 or not isinstance(statements[0], dict):
        return {}
    return statements[0]


def main() -> int:
    assertions = Assertions()

    ci = load(f"github_{OWNER}_{REPOSITORY}.trust.json")
    ci_statement = only_statement(assertions, "CI trust", ci)
    assertions.equal("CI trust version", ci.get("Version"), "2012-10-17")
    assertions.equal("CI trust effect", ci_statement.get("Effect"), "Allow")
    assertions.equal("CI trust action", ci_statement.get("Action"), "sts:AssumeRoleWithWebIdentity")
    assertions.equal(
        "CI trust provider",
        ci_statement.get("Principal", {}).get("Federated"),
        "arn:aws:iam::<account-id>:oidc-provider/token.actions.githubusercontent.com",
    )
    conditions = ci_statement.get("Condition", {})
    exact = conditions.get("StringEquals", {})
    assertions.equal("OIDC condition operators", set(conditions), {"StringEquals"})
    assertions.equal("OIDC audience", exact.get("token.actions.githubusercontent.com:aud"), "sts.amazonaws.com")
    assertions.equal(
        "OIDC repository id",
        exact.get("token.actions.githubusercontent.com:repository_id"),
        "<repository-id>",
    )
    assertions.equal(
        "OIDC protected ref",
        exact.get("token.actions.githubusercontent.com:ref"),
        "refs/heads/main",
    )
    assertions.exact_string_set(
        "OIDC subjects",
        exact.get("token.actions.githubusercontent.com:sub"),
        EXPECTED_SUBJECTS,
    )
    assertions.exact_string_set(
        "OIDC workflow refs",
        exact.get("token.actions.githubusercontent.com:job_workflow_ref"),
        EXPECTED_WORKFLOW_REFS,
    )

    for workflow_ref in EXPECTED_WORKFLOW_REFS:
        workflow_path = workflow_ref.split("/", 2)[2].rsplit("@", 1)[0]
        assertions.equal(
            f"trusted workflow exists ({workflow_path})",
            (ROOT / workflow_path).is_file(),
            True,
        )

    admin = load(f"github_{OWNER}_{REPOSITORY}-admin.trust.json")
    admin_statement = only_statement(assertions, "admin trust", admin)
    assertions.equal("admin trust effect", admin_statement.get("Effect"), "Allow")
    assertions.equal("admin trust action", admin_statement.get("Action"), "sts:AssumeRole")
    assertions.equal(
        "admin trust principal",
        admin_statement.get("Principal", {}).get("AWS"),
        "arn:aws:iam::<account-id>:root",
    )
    assertions.equal(
        "admin SSO principal pattern",
        admin_statement.get("Condition", {}).get("ArnLike", {}).get("aws:PrincipalArn"),
        "arn:aws:iam::<account-id>:role/aws-reserved/sso.amazonaws.com/"
        "AWSReservedSSO_github_nwarila-platform_????????????????",
    )

    artifact = load(f"{REPOSITORY}-artifact-reader.trust.json")
    artifact_statement = only_statement(assertions, "artifact-reader trust", artifact)
    assertions.equal("artifact-reader effect", artifact_statement.get("Effect"), "Allow")
    assertions.equal("artifact-reader action", artifact_statement.get("Action"), "sts:AssumeRole")
    assertions.exact_string_set(
        "artifact-reader principals",
        artifact_statement.get("Principal", {}).get("AWS"),
        {
            "arn:aws:iam::<account-id>:role/github_nwarila-platform_windows-wsus",
            "arn:aws:iam::<account-id>:role/github_nwarila-platform_windows-wsus-admin",
        },
    )

    instance = load(f"{REPOSITORY}-poc-role.trust.json")
    instance_statement = only_statement(assertions, "instance trust", instance)
    assertions.equal("instance trust effect", instance_statement.get("Effect"), "Allow")
    assertions.equal("instance trust action", instance_statement.get("Action"), "sts:AssumeRole")
    assertions.equal(
        "instance trust service",
        instance_statement.get("Principal", {}).get("Service"),
        "ec2.amazonaws.com",
    )
    assertions.equal(
        "instance SourceAccount",
        instance_statement.get("Condition", {}).get("StringEquals", {}).get("aws:SourceAccount"),
        "<account-id>",
    )

    for failure in assertions.failures:
        print(f"test-iam-structure: FAIL — {failure}", file=sys.stderr)
    if assertions.failures:
        return 1

    print(f"test-iam-structure: OK — {assertions.count} offline trust assertion(s) passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
