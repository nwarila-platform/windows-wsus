#!/usr/bin/env bash
# Assert the split workflow contract: unprivileged PR quality, protected-main AWS proof.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUALITY="${ROOT}/.github/workflows/quality.yml"
DEPLOY="${ROOT}/.github/workflows/aws-deploy.yml"

fail() { printf 'check-workflow-trigger: FAIL — %s\n' "$1" >&2; exit 1; }
[ -f "${QUALITY}" ] || fail "missing ${QUALITY}"
[ -f "${DEPLOY}" ] || fail "missing ${DEPLOY}"

python3 - "${QUALITY}" "${DEPLOY}" <<'PYEOF'
from __future__ import annotations

import re
import sys

try:
    import yaml
except ModuleNotFoundError as exc:
    print(
        "check-workflow-trigger: FAIL — PyYAML is required; install requirements-quality.txt",
        file=sys.stderr,
    )
    raise SystemExit(2) from exc


quality_path, deploy_path = sys.argv[1:3]
failures: list[str] = []


def load(path: str) -> dict:
    with open(path, encoding="utf-8") as handle:
        document = yaml.safe_load(handle)
    if not isinstance(document, dict):
        failures.append(f"{path} is not a workflow mapping")
        return {}
    return document


def triggers(workflow: dict, path: str) -> dict:
    # PyYAML intentionally implements YAML 1.1 and reads a bare `on` key as True.
    value = workflow.get("on", workflow.get(True))
    if not isinstance(value, dict):
        failures.append(f"{path} has no mapping-valued on: block")
        return {}
    return value


def mapping(value) -> dict:
    return value if isinstance(value, dict) else {}


def exact_types(path: str, event: str, config, expected: set[str]) -> None:
    values = mapping(config).get("types", [])
    if not isinstance(values, list) or set(values) != expected or len(values) != len(expected):
        failures.append(f"{path} {event}.types must be exactly {sorted(expected)!r}; got {values!r}")


def no_path_filters(path: str, event: str, config) -> None:
    config = mapping(config)
    for key in ("paths", "paths-ignore"):
        if key in config:
            failures.append(f"{path} {event} must not use {key}; the required check must always report")


quality = load(quality_path)
quality_on = triggers(quality, quality_path)
if quality.get("name") != "CI":
    failures.append(f"{quality_path} name must be 'CI' so the required context remains stable")

required_quality_events = {"pull_request", "push", "merge_group", "workflow_dispatch"}
if set(quality_on) != required_quality_events:
    failures.append(
        f"{quality_path} events must be exactly {sorted(required_quality_events)!r}; "
        f"got {sorted(str(key) for key in quality_on)!r}"
    )

exact_types(
    quality_path,
    "pull_request",
    quality_on.get("pull_request"),
    {"opened", "reopened", "ready_for_review", "synchronize"},
)
no_path_filters(quality_path, "pull_request", quality_on.get("pull_request"))

quality_push = mapping(quality_on.get("push"))
if quality_push.get("branches") != ["main"]:
    failures.append(f"{quality_path} push.branches must be exactly ['main']")
no_path_filters(quality_path, "push", quality_push)

exact_types(quality_path, "merge_group", quality_on.get("merge_group"), {"checks_requested"})
no_path_filters(quality_path, "merge_group", quality_on.get("merge_group"))

if quality.get("permissions") != {"contents": "read"}:
    failures.append(f"{quality_path} top-level permissions must be exactly contents: read")

quality_jobs = mapping(quality.get("jobs"))
required_job = mapping(quality_jobs.get("required"))
if required_job.get("name") != "required":
    failures.append(f"{quality_path} must expose job id/name 'required' (stable context: CI / required)")
for job_name, job in quality_jobs.items():
    job = mapping(job)
    if "permissions" in job and job.get("permissions") != {"contents": "read"}:
        failures.append(f"{quality_path} job {job_name!r} broadens the read-only permission boundary")


def audit_quality_boundary(value, location: str) -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            child_location = f"{location}.{key}"
            if str(key) == "id-token":
                failures.append(f"{quality_path} must not request id-token permission ({child_location})")
            if str(key) == "secrets":
                failures.append(f"{quality_path} must not declare or pass secrets ({child_location})")
            if str(key) == "uses" and isinstance(child, str):
                action = child.split("@", 1)[0].lower()
                if action == "aws-actions/configure-aws-credentials":
                    failures.append(
                        f"{quality_path} must not use the AWS credential action ({child_location})"
                    )
            audit_quality_boundary(child, child_location)
    elif isinstance(value, list):
        for index, child in enumerate(value):
            audit_quality_boundary(child, f"{location}[{index}]")
    elif isinstance(value, str) and re.search(r"\bsecrets(?:\.|\[)", value, re.IGNORECASE):
        failures.append(f"{quality_path} must not reference the secrets context ({location})")


audit_quality_boundary(quality, "workflow")


deploy = load(deploy_path)
deploy_on = triggers(deploy, deploy_path)
for forbidden in ("pull_request", "pull_request_target", "merge_group"):
    if forbidden in deploy_on:
        failures.append(f"{deploy_path} must not run privileged AWS code for {forbidden}")

required_deploy_events = {"push", "schedule", "workflow_dispatch"}
if set(deploy_on) != required_deploy_events:
    failures.append(
        f"{deploy_path} events must be exactly {sorted(required_deploy_events)!r}; "
        f"got {sorted(str(key) for key in deploy_on)!r}"
    )

deploy_push = mapping(deploy_on.get("push"))
if deploy_push.get("branches") != ["main"]:
    failures.append(f"{deploy_path} push.branches must be exactly ['main']")
no_path_filters(deploy_path, "push", deploy_push)

schedules = deploy_on.get("schedule")
if schedules != [{"cron": "17 9 * * 1"}]:
    failures.append(f"{deploy_path} schedule must be the single off-minute cron '17 9 * * 1'")
if "workflow_dispatch" not in deploy_on:
    failures.append(f"{deploy_path} must retain workflow_dispatch for protected break-glass execution")
if deploy.get("permissions") != {}:
    failures.append(f"{deploy_path} top-level permissions must remain empty")

deploy_jobs = mapping(deploy.get("jobs"))
guard = mapping(deploy_jobs.get("main-ref"))
if not guard:
    failures.append(f"{deploy_path} must contain the unprivileged main-ref guard job")
elif guard.get("permissions") not in (None, {}, {"contents": "read"}):
    failures.append(f"{deploy_path} main-ref guard must not hold write permissions")

privileged = mapping(deploy_jobs.get("aws-deploy"))
needs = privileged.get("needs", [])
needs = [needs] if isinstance(needs, str) else needs
if "main-ref" not in (needs or []):
    failures.append(f"{deploy_path} aws-deploy must depend on the main-ref guard")
condition = str(privileged.get("if", ""))
if "github.ref" not in condition or "refs/heads/main" not in condition:
    failures.append(f"{deploy_path} aws-deploy must independently require refs/heads/main")

for job_name, job in deploy_jobs.items():
    job = mapping(job)
    permissions = mapping(job.get("permissions"))
    if permissions.get("id-token") == "write" and job_name != "aws-deploy":
        failures.append(f"{deploy_path} only aws-deploy may receive id-token: write (found on {job_name})")

for failure in failures:
    print(f"check-workflow-trigger: FAIL — {failure}", file=sys.stderr)
if failures:
    raise SystemExit(1)

print(
    "check-workflow-trigger: OK — CI is universal/read-only and AWS deploy is protected-main only"
)
PYEOF
