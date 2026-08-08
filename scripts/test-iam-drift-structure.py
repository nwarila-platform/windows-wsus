#!/usr/bin/env python3
"""Offline contract tests for the read-only IAM drift attestation boundary."""

from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
import tempfile
import re
from pathlib import Path
from typing import Any

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "iam-drift.yml"
POLICY = (
    ROOT
    / "docs"
    / "reference"
    / "aws-iam"
    / "policies"
    / "github_nwarila-platform_windows-wsus_iam-audit.json"
)
TRUST = (
    ROOT
    / "docs"
    / "reference"
    / "aws-iam"
    / "roles"
    / "github_nwarila-platform_windows-wsus-iam-audit.trust.json"
)
BOOTSTRAP = ROOT / "scripts" / "bootstrap-iam.sh"
IAM_POLICY_TEST = ROOT / "scripts" / "test-iam-policies.sh"

failures: list[str] = []
assertions = 0


def expect(name: str, actual: Any, expected: Any) -> None:
    global assertions
    assertions += 1
    if actual != expected:
        failures.append(f"{name}: got {actual!r}; expected {expected!r}")


def mapping(value: Any) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


with POLICY.open(encoding="utf-8") as handle:
    policy = json.load(handle)

policy_statements = mapping(
    {statement.get("Sid"): statement for statement in policy.get("Statement", [])}
)
expect("audit policy version", policy.get("Version"), "2012-10-17")
expect(
    "audit policy effects",
    {statement.get("Effect") for statement in policy_statements.values()},
    {"Allow"},
)
expect(
    "audit policy exact actions by Sid",
    {sid: statement.get("Action") for sid, statement in policy_statements.items()},
    {
        "ReadTrackedManagedPolicyDocuments": [
            "iam:GetPolicy",
            "iam:GetPolicyVersion",
            "iam:ListEntitiesForPolicy",
        ],
        "ReadTrackedRoleContracts": [
            "iam:GetRole",
            "iam:ListAttachedRolePolicies",
            "iam:ListRolePolicies",
            "iam:ListRoleTags",
        ],
        "ReadTrackedInstanceProfile": "iam:GetInstanceProfile",
        "ReadTrackedRoleInstanceProfiles": "iam:ListInstanceProfilesForRole",
        "ResolveDeploySubnet": "ec2:DescribeSubnets",
        "ResolveEbsKey": "kms:DescribeKey",
        "ValidateTrackedDocuments": "access-analyzer:ValidatePolicy",
    },
)
expect(
    "audit policy exact resources by Sid",
    {sid: statement.get("Resource") for sid, statement in policy_statements.items()},
    {
        "ReadTrackedManagedPolicyDocuments": [
            "arn:aws:iam::<account-id>:policy/github_nwarila-platform_windows-wsus",
            "arn:aws:iam::<account-id>:policy/github_nwarila-platform_windows-wsus_iam-audit",
            "arn:aws:iam::<account-id>:policy/windows-wsus_artifact-assume",
            "arn:aws:iam::<account-id>:policy/windows-wsus_artifact-folder",
            "arn:aws:iam::<account-id>:policy/windows-wsus_artifact-read",
            "arn:aws:iam::<account-id>:policy/windows-wsus_deploy-discovery-iam",
            "arn:aws:iam::<account-id>:policy/windows-wsus_deploy-ec2-launch",
            "arn:aws:iam::<account-id>:policy/windows-wsus_deploy-ec2-lifecycle",
            "arn:aws:iam::<account-id>:policy/windows-wsus_deploy-sg-ssm-kms",
        ],
        "ReadTrackedRoleContracts": [
            "arn:aws:iam::<account-id>:role/github_nwarila-platform_windows-wsus",
            "arn:aws:iam::<account-id>:role/github_nwarila-platform_windows-wsus-admin",
            "arn:aws:iam::<account-id>:role/github_nwarila-platform_windows-wsus-iam-audit",
            "arn:aws:iam::<account-id>:role/windows-wsus-artifact-reader",
            "arn:aws:iam::<account-id>:role/windows-wsus-poc-role",
        ],
        "ReadTrackedInstanceProfile": (
            "arn:aws:iam::<account-id>:instance-profile/windows-wsus-poc-profile"
        ),
        "ReadTrackedRoleInstanceProfiles": [
            "arn:aws:iam::<account-id>:role/github_nwarila-platform_windows-wsus",
            "arn:aws:iam::<account-id>:role/github_nwarila-platform_windows-wsus-admin",
            "arn:aws:iam::<account-id>:role/github_nwarila-platform_windows-wsus-iam-audit",
            "arn:aws:iam::<account-id>:role/windows-wsus-artifact-reader",
            "arn:aws:iam::<account-id>:role/windows-wsus-poc-role",
        ],
        "ResolveDeploySubnet": "*",
        "ResolveEbsKey": "arn:aws:kms:<region>:<account-id>:key/<ebs-kms-key-id>",
        "ValidateTrackedDocuments": "*",
    },
)
expect(
    "audit policy exact conditions by Sid",
    {sid: statement.get("Condition") for sid, statement in policy_statements.items()},
    {
        "ReadTrackedManagedPolicyDocuments": None,
        "ReadTrackedRoleContracts": None,
        "ReadTrackedInstanceProfile": None,
        "ReadTrackedRoleInstanceProfiles": None,
        "ResolveDeploySubnet": {
            "StringEquals": {"aws:RequestedRegion": "<region>"}
        },
        "ResolveEbsKey": None,
        "ValidateTrackedDocuments": {
            "StringEquals": {"aws:RequestedRegion": "<region>"}
        },
    },
)

with TRUST.open(encoding="utf-8") as handle:
    trust = json.load(handle)

expect(
    "audit trust entire document",
    trust,
    {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Sid": "GitHubActionsForWindowsWsusIamDrift",
                "Effect": "Allow",
                "Principal": {
                    "Federated": "arn:aws:iam::<account-id>:oidc-provider/token.actions.githubusercontent.com"
                },
                "Action": "sts:AssumeRoleWithWebIdentity",
                "Condition": {
                    "StringEquals": {
                        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
                        "token.actions.githubusercontent.com:repository_id": "<repository-id>",
                        "token.actions.githubusercontent.com:ref": "refs/heads/main",
                        "token.actions.githubusercontent.com:sub": [
                            "repo:nwarila-platform@<owner-id>/windows-wsus@<repository-id>:ref:refs/heads/main",
                            "repo:nwarila-platform/windows-wsus:ref:refs/heads/main",
                        ],
                        "token.actions.githubusercontent.com:job_workflow_ref": (
                            "nwarila-platform/windows-wsus/.github/workflows/"
                            "iam-drift.yml@refs/heads/main"
                        ),
                    }
                },
            }
        ],
    },
)

with WORKFLOW.open(encoding="utf-8") as handle:
    workflow = yaml.safe_load(handle)
workflow_on = workflow.get("on", workflow.get(True))
expect("workflow name", workflow.get("name"), "IAM Drift Attestation")
expect(
    "workflow exact triggers",
    workflow_on,
    {"schedule": [{"cron": "37 6 * * *"}], "workflow_dispatch": None},
)
expect("workflow top-level permissions", workflow.get("permissions"), {})
expect(
    "workflow concurrency",
    workflow.get("concurrency"),
    {
        "group": "iam-drift-${{ github.repository }}",
        "cancel-in-progress": False,
    },
)

jobs = mapping(workflow.get("jobs"))
expect("workflow exact jobs", set(jobs), {"main-ref", "attest", "report"})
guard = mapping(jobs.get("main-ref"))
expect("main guard permissions", guard.get("permissions"), {})
expect("main guard runner", guard.get("runs-on"), "ubuntu-24.04")
guard_step = mapping(guard.get("steps", [{}])[0])
guard_run = guard_step.get("run", "")
expect("main guard expected ref", guard_step.get("env"), {"EXPECTED_REF": "refs/heads/main"})
expect("main guard checks GITHUB_REF", "${GITHUB_REF}" in guard_run, True)
expect("main guard compares expected ref", "${EXPECTED_REF}" in guard_run, True)

attest = mapping(jobs.get("attest"))
expect("attestation depends on guard", attest.get("needs"), "main-ref")
expect("attestation main-only condition", attest.get("if"), "github.ref == 'refs/heads/main'")
expect(
    "attestation permissions",
    attest.get("permissions"),
    {"contents": "read", "id-token": "write"},
)
expect(
    "attestation environment",
    attest.get("env"),
    {
        "AWS_REGION": "us-east-1",
        "AUDIT_ROLE": "github_nwarila-platform_windows-wsus-iam-audit",
    },
)
attest_steps = mapping(
    {step.get("name"): step for step in attest.get("steps", []) if isinstance(step, dict)}
)
credential_step = mapping(attest_steps.get("Configure read-only AWS credentials (OIDC)"))
expect(
    "credential action pin",
    credential_step.get("uses"),
    "aws-actions/configure-aws-credentials@e6de054238d6b7531b4efff3b6587d9aade6a06c",
)
expect(
    "credential configuration",
    credential_step.get("with"),
    {
        "role-to-assume": (
            "arn:aws:iam::${{ secrets.AWS_ACCOUNT_ID }}:role/${{ env.AUDIT_ROLE }}"
        ),
        "aws-region": "${{ env.AWS_REGION }}",
        "allowed-account-ids": "${{ secrets.AWS_ACCOUNT_ID }}",
        "role-session-name": "iam-drift-${{ github.run_id }}",
        "role-duration-seconds": 1800,
    },
)
compare_step = mapping(attest_steps.get("Compare live IAM with tracked source"))
expect(
    "exact read-only drift command",
    compare_step.get("run"),
    "./scripts/bootstrap-iam.sh --check-drift --ambient",
)
expect("drift command receives only GitHub token", compare_step.get("env"), {"GH_TOKEN": "${{ github.token }}"})

report = mapping(jobs.get("report"))
expect("report permissions", report.get("permissions"), {"issues": "write"})
expect(
    "report condition",
    report.get("if"),
    "always() && needs.main-ref.result == 'success'",
)
report_run = mapping(report.get("steps", [{}])[0]).get("run", "")
for description, fragment in (
    ("incident exact-title filtering", ".title == $title"),
    ("incident app-author filtering", '.author.login == "app/github-actions"'),
    ("incident stable-marker filtering", "contains($marker)"),
    ("incident automation label filtering", '--label "${INCIDENT_LABEL}"'),
    ("incident deterministic canonical selection", "sort_by(.number)"),
    ("incident duplicate closure", 'for duplicate in "${issue_numbers[@]:1}"'),
    ("incident recovery closure", 'if [ "${ATTESTATION_RESULT}" = success ]'),
):
    expect(description, fragment in report_run, True)

bootstrap_text = BOOTSTRAP.read_text(encoding="utf-8")
policy_test_text = IAM_POLICY_TEST.read_text(encoding="utf-8")
expect(
    "profile option appears only in the profile-argument constructor",
    [
        line.strip()
        for line in bootstrap_text.splitlines()
        if '--profile "${PROFILE}"' in line
    ],
    ['AWS_PROFILE_ARGS=(--profile "${PROFILE}")'],
)
expect(
    "trust validation rejects security warnings",
    "findingType==`SECURITY_WARNING`" in bootstrap_text,
    True,
)
expect(
    "policy drift compares complete normalized documents",
    bootstrap_text.count("norm(l)==norm(s)"),
    1,
)
expect(
    "trust drift compares complete normalized documents",
    bootstrap_text.count(
        "norm(json.load(open(sys.argv[1])))==norm(json.load(open(sys.argv[2])))"
    ),
    1,
)
expect("drift never compares Statement alone", "['Statement']" in bootstrap_text, False)
source_literal_gate = bootstrap_text.find('"${ROOT}/scripts/check-iam-literals.sh" > /dev/null')
source_semantic_gate = bootstrap_text.find('python3 "${ROOT}/scripts/test-iam-structure.py" > /dev/null')
apply_section = bootstrap_text.find('echo "== apply =="')
expect(
    "source literal gate precedes every apply write",
    0 <= source_literal_gate < apply_section,
    True,
)
expect(
    "source semantic/digest gate precedes every apply write",
    0 <= source_semantic_gate < apply_section,
    True,
)
expect(
    "bootstrap does not recursively invoke its drift integration test",
    'python3 "${ROOT}/scripts/test-iam-drift-structure.py"' in bootstrap_text,
    False,
)
expect("role drift reads Path", 'role.get("Path", "")' in bootstrap_text, True)
expect("role drift reads exact tag set", 'aws iam list-role-tags' in bootstrap_text, True)
expect("apply never auto-removes role tags", "aws iam untag-role" in bootstrap_text, False)
expect(
    "post-write attachment proof rechecks empty role tags",
    'tags="$(role_tags_json "${role}")"' in bootstrap_text
    and "[ \"${tags}\" = '[]' ]" in bootstrap_text,
    True,
)
expect(
    "role drift reads PermissionsBoundary",
    'role.get("PermissionsBoundary", {})' in bootstrap_text,
    True,
)
expect("new roles use exact root path", "--path / --max-session-duration" in bootstrap_text, True)
expect(
    "apply removes an unexpected permissions boundary",
    "aws iam delete-role-permissions-boundary" in bootstrap_text,
    True,
)
expect(
    "apply fails closed instead of attempting an unsupported role path update",
    "IAM cannot update role paths in place" in bootstrap_text and "--new-path" not in bootstrap_text,
    True,
)
expect(
    "drift enumerates both permissions-policy and boundary consumers",
    'policy_entities "${arn}" PermissionsPolicy' in bootstrap_text
    and 'policy_entities "${arn}" PermissionsBoundary' in bootstrap_text,
    True,
)
for command in (
    "aws iam detach-role-policy",
    "aws iam detach-user-policy",
    "aws iam detach-group-policy",
    "aws iam delete-role-permissions-boundary",
):
    expect(f"apply reconciles inverse policy use with {command}", command in bootstrap_text, True)
expect(
    "inverse policy consumers derive from declared attachment arrays",
    all(
        fragment in bootstrap_text
        for fragment in (
            'for arn in "${CI_ATTACHMENTS[@]}"',
            'for arn in "${ADMIN_ATTACHMENTS[@]}"',
            'for arn in "${AUDIT_ATTACHMENTS[@]}"',
            'for arn in "${READER_ATTACHMENTS[@]}"',
        )
    ),
    True,
)
expect(
    "apply never removes a boundary from an unmodeled IAM user",
    "aws iam delete-user-permissions-boundary" in bootstrap_text,
    False,
)
policy_version_write = bootstrap_text.find("aws iam create-policy-version")
trust_reconcile = bootstrap_text.find('apply_role "${CI_ROLE}"')
policy_quarantine_proof = bootstrap_text.find('wait_for_policy_no_consumers "${p}"')
policy_source_proof = bootstrap_text.find('wait_for_live_policy_source "${p}" "${new_version}"')
trust_source_proof = bootstrap_text.find(
    'wait_for_live_role_source "${name}" "${trust}" "${duration}"'
)
attachment_restore = bootstrap_text.find('reconcile_role_policies "${CI_ROLE}"')
role_overgrant_removal = bootstrap_text.find(
    'strip_unexpected_role_policies "${CI_ROLE}"\n'
)
inverse_overgrant_removal = bootstrap_text.find(
    'remove_unexpected_policy_entities "${p}"'
)
foreign_boundary_guard = bootstrap_text.find(
    "is a boundary on unmodeled ${entity}; refusing every apply write"
)
role_tag_guard = bootstrap_text.find(
    "review and migrate any tag-based ABAC or restrictive policy dependency manually"
)
foreign_profile_guard = bootstrap_text.find(
    "detach or migrate that foreign profile manually"
)
profile_path_guard = bootstrap_text.find(
    "an instance profile can be attached to out-of-scope EC2"
)
metadata_preflight_call = bootstrap_text.find("\n    preflight_modeled_role_metadata\n")
lifecycle_idle_guard = bootstrap_text.find("\n    assert_no_active_lifecycle_runs\n")
aws_empty_guard = bootstrap_text.find('bash "${ROOT}/scripts/assert-aws-clean.sh"')
expect(
    "foreign boundary preflight precedes every apply write",
    0 <= foreign_boundary_guard < trust_reconcile,
    True,
)
expect(
    "tag-based ABAC preflight precedes every apply write",
    0 <= role_tag_guard < trust_reconcile,
    True,
)
expect(
    "unexpected role-to-profile association preflight precedes every apply write",
    0 <= foreign_profile_guard < metadata_preflight_call < trust_reconcile,
    True,
)
expect(
    "wrong instance-profile path preflight precedes every apply write",
    0 <= profile_path_guard < metadata_preflight_call < trust_reconcile,
    True,
)
expect(
    "apply proves deploy and reaper nonterminal statuses idle before trust writes",
    0 <= lifecycle_idle_guard < trust_reconcile
    and all(
        fragment in bootstrap_text
        for fragment in (
            '"repos/${OWNER}/${REPO}/actions/runs?per_page=100"',
            "(aws-deploy|aws-reaper|iam-drift)",
            "select(.status != \"completed\")",
        )
    ),
    True,
)
expect(
    "apply proves repository resources and Terraform lock absent before trust writes",
    0 <= aws_empty_guard < trust_reconcile
    and "CLEAN_PROOF_ATTEMPTS=1" in bootstrap_text,
    True,
)
expect(
    "apply corrects trust before publishing policy versions",
    0 <= trust_reconcile < policy_version_write,
    True,
)
expect(
    "apply quarantines every existing role before making it assumable",
    0 <= role_overgrant_removal < trust_reconcile,
    True,
)
expect(
    "role quarantine detaches even expected-but-drifted policies before trust activation",
    'strip_unexpected_role_policies "${CI_ROLE}" "${CI_ATTACHMENTS[@]}"' in bootstrap_text,
    False,
)
expect(
    "role quarantine waits for empty attachment and inline-policy reads",
    'wait_for_role_policy_boundary "${role}" "$@"' in bootstrap_text
    and "for attempt in 1 2 3 4 5 6 7 8 9 10" in bootstrap_text,
    True,
)
expect(
    "apply removes unexpected inverse consumers before making roles assumable",
    0 <= inverse_overgrant_removal < trust_reconcile,
    True,
)
expect(
    "inverse-consumer quarantine is re-read before trust activation",
    'unexpected="$(unexpected_policy_consumers "${policy}")"' in bootstrap_text,
    True,
)
expect(
    "every tracked policy reaches zero consumers before trust activation",
    0 <= policy_quarantine_proof < trust_reconcile,
    True,
)
expect(
    "IAM existence probes distinguish NoSuchEntity from API failure",
    all(
        fragment in bootstrap_text
        for fragment in (
            'iam_lookup() {',
            '"(NoSuchEntity)"',
            "could not determine whether IAM ${kind} ${name} exists",
        )
    ),
    True,
)
expect(
    "new policy version and exact source are re-read before any attachment restore",
    0 <= policy_source_proof < attachment_restore
    and "Policy.DefaultVersionId" in bootstrap_text
    and "PolicyVersion.Document" in bootstrap_text,
    True,
)
expect(
    "create-policy-version captures the nested VersionId returned by IAM",
    "--query PolicyVersion.VersionId --output text" in bootstrap_text,
    True,
)
expect(
    "exact live trust and metadata settle before policy publication and attachment restore",
    0 <= trust_source_proof < policy_version_write < attachment_restore
    and 'live_role["AssumeRolePolicyDocument"]' in bootstrap_text,
    True,
)
expect(
    "post-write role and inverse attachment reads use bounded retries",
    "role attachment/boundary reconciliation did not settle" in bootstrap_text
    and "policy consumer/boundary reconciliation did not settle" in bootstrap_text,
    True,
)
expect(
    "instance-profile path and bidirectional membership use bounded exact retries",
    "wait_for_instance_profile_roles ''" in bootstrap_text
    and 'wait_for_instance_profile_roles "${POC_ROLE}"' in bootstrap_text
    and 'wait_for_instance_profile_path \'/\'' in bootstrap_text
    and 'wait_for_role_instance_profiles "${role}" "${expected_profiles}"' in bootstrap_text
    and "instance-profile associations did not settle" in bootstrap_text,
    True,
)
expect(
    "profile reconciliation never detaches a role from a foreign profile",
    "aws iam remove-role-from-instance-profile" not in bootstrap_text
    and 'gained unexpected membership after preflight; refusing to detach it' in bootstrap_text,
    True,
)
expect(
    "instance-profile path is never auto-recreated or retagged",
    "aws iam delete-instance-profile" not in bootstrap_text
    and "aws iam tag-instance-profile" not in bootstrap_text
    and "aws iam untag-instance-profile" not in bootstrap_text,
    True,
)

ci_policy_match = re.search(
    r"ci_policy_names = \[(.*?)\]\njson\.dump", policy_test_text, flags=re.DOTALL
)
ci_policy_names = (
    re.findall(r'"([^"]+\.json)"', ci_policy_match.group(1)) if ci_policy_match else []
)
expect(
    "deploy simulation uses the exact CI attachment policy documents",
    ci_policy_names,
    [
        "github_nwarila-platform_windows-wsus.json",
        "windows-wsus_artifact-assume.json",
        "windows-wsus_deploy-discovery-iam.json",
        "windows-wsus_deploy-ec2-launch.json",
        "windows-wsus_deploy-ec2-lifecycle.json",
        "windows-wsus_deploy-sg-ssm-kms.json",
    ],
)
deploy_simulation = policy_test_text.split("simulate()", 1)[1].split("assert()", 1)[0]
expect("deploy simulation never globs every policy", "glob" in deploy_simulation, False)
audit_simulation = policy_test_text.split("simulate_audit()", 1)[1].split("assert_audit()", 1)[0]
expect(
    "audit simulation uses only the audit policy document",
    "github_nwarila-platform_windows-wsus_iam-audit.json" in audit_simulation,
    True,
)

# Exercise the exact existence helper in isolation. A real NoSuchEntity is the only missing-object
# result; an authorization/transient failure must exit instead of taking the quarantine's absent
# branch and later restoring trust over stale attachments.
lookup_start = bootstrap_text.index("iam_lookup() {")
lookup_end = bootstrap_text.index("\n\nfor p in", lookup_start)
lookup_functions = bootstrap_text[lookup_start:lookup_end]
lookup_harness = f"""
set -u
ACCOUNT=123456789012
AWS_PROFILE_ARGS=()
die() {{ printf '%s\\n' "$1" >&2; exit 1; }}
aws() {{
  if [ "${{LOOKUP_MODE}}" = missing ]; then
    printf '%s\\n' 'An error occurred (NoSuchEntity) when calling GetRole' >&2
    return 254
  fi
  printf '%s\\n' 'An error occurred (AccessDenied) when calling GetRole' >&2
  return 55
}}
{lookup_functions}
if exists_role example; then printf '%s\\n' exists; else printf '%s\\n' absent; fi
"""
missing_lookup = subprocess.run(
    ["/bin/bash", "-c", lookup_harness],
    env={**os.environ, "LOOKUP_MODE": "missing"},
    capture_output=True,
    check=False,
    text=True,
)
expect("NoSuchEntity is the only absent lookup", (missing_lookup.returncode, missing_lookup.stdout), (0, "absent\n"))
failed_lookup = subprocess.run(
    ["/bin/bash", "-c", lookup_harness],
    env={**os.environ, "LOOKUP_MODE": "failure"},
    capture_output=True,
    check=False,
    text=True,
)
expect("lookup API failure blocks quarantine", failed_lookup.returncode, 1)
expect("lookup API failure is never reported absent", "absent" in failed_lookup.stdout, False)
expect("lookup API failure retains diagnostics", "AccessDenied" in failed_lookup.stderr, True)

# Exercise the apply metadata preflight without AWS. Missing desired state is repairable, but tags,
# foreign profile associations, and read failures must all stop before a caller could perform its
# first write. The harness records a sentinel only after the preflight returns successfully.
preflight_start = bootstrap_text.index("preflight_modeled_role_metadata() {")
preflight_end = bootstrap_text.index(
    "\n\n# IAM does not support changing an existing role or instance-profile Path", preflight_start
)
preflight_function = bootstrap_text[preflight_start:preflight_end]
preflight_harness = f"""
set -u
CI_ROLE=ci
ADMIN_ROLE=admin
AUDIT_ROLE=audit
POC_ROLE=poc
READER_ROLE=reader
POC_PROFILE=owned-profile
die() {{ printf '%s\\n' "$1" >&2; exit 1; }}
exists_role() {{ return 0; }}
role_contract_values() {{ printf '/\\n\\n3600\\n'; }}
role_tags_json() {{
  if [ "${{PREFLIGHT_MODE}}" = tag ] && [ "$1" = "${{CI_ROLE}}" ]; then
    printf '%s\\n' '[{{"Key":"boundary","Value":"restricted"}}]'
  elif [ "${{PREFLIGHT_MODE}}" = tag-read-failure ] && [ "$1" = "${{CI_ROLE}}" ]; then
    return 70
  else
    printf '%s\\n' '[]'
  fi
}}
expected_instance_profiles_for_role() {{
  if [ "$1" = "${{POC_ROLE}}" ]; then printf '%s\\n' "${{POC_PROFILE}}"; fi
  return 0
}}
instance_profiles_for_role() {{
  if [ "${{PREFLIGHT_MODE}}" = profile-read-failure ] && [ "$1" = "${{CI_ROLE}}" ]; then
    return 71
  fi
  if [ "${{PREFLIGHT_MODE}}" = foreign-profile ] && [ "$1" = "${{CI_ROLE}}" ]; then
    printf '%s\\n' foreign-profile
  elif [ "$1" = "${{POC_ROLE}}" ]; then
    printf '%s\\n' "${{POC_PROFILE}}"
  fi
}}
exists_instance_profile() {{ return 0; }}
instance_profile_path() {{
  if [ "${{PREFLIGHT_MODE}}" = wrong-profile-path ]; then
    printf '%s\n' /legacy
  else
    printf '%s\n' /
  fi
}}
instance_profile_roles() {{
  if [ "${{PREFLIGHT_MODE}}" = foreign-role ]; then
    printf '%s\\n' intruder
  else
    printf '%s\\n' "${{POC_ROLE}}"
  fi
}}
{preflight_function}
preflight_modeled_role_metadata
printf '%s\\n' WRITE_SENTINEL
"""

for mode, expected_return, diagnostic in (
    ("clean", 0, ""),
    ("tag", 1, "tag-based ABAC"),
    ("tag-read-failure", 1, "could not preflight tags"),
    ("foreign-profile", 1, "foreign profile manually"),
    ("profile-read-failure", 1, "could not preflight instance profiles"),
    ("foreign-role", 1, "foreign association manually"),
    ("wrong-profile-path", 1, "out-of-scope EC2"),
):
    result = subprocess.run(
        ["/bin/bash", "-c", preflight_harness],
        env={**os.environ, "PREFLIGHT_MODE": mode},
        capture_output=True,
        check=False,
        text=True,
    )
    expect(f"{mode} metadata preflight exit", result.returncode, expected_return)
    expect(
        f"{mode} metadata preflight write reachability",
        "WRITE_SENTINEL" in result.stdout,
        expected_return == 0,
    )
    if diagnostic:
        expect(f"{mode} metadata preflight diagnostic", diagnostic in result.stderr, True)

# Exercise the ambient argument path without network access. The AWS stub records the very first
# invocation; GitHub then fails deliberately so the test cannot progress to any live resolver.
with tempfile.TemporaryDirectory(
    prefix=".quality-local.iam-drift-test.", dir=ROOT
) as temporary:
    temporary_path = Path(temporary)
    bin_path = temporary_path / "bin"
    bin_path.mkdir()
    log_path = temporary_path / "aws.log"
    aws_stub = bin_path / "aws"
    aws_stub.write_text(
        "#!/bin/bash\n"
        "printf '%s\\n' \"$*\" >> \"${BOOTSTRAP_TEST_AWS_LOG}\"\n"
        "if [ \"$1 $2\" = 'sts get-caller-identity' ]; then\n"
        "  printf '%s\\n' '123456789012'\n"
        "  exit 0\n"
        "fi\n"
        "exit 97\n",
        encoding="utf-8",
    )
    gh_stub = bin_path / "gh"
    gh_stub.write_text("#!/bin/bash\nexit 98\n", encoding="utf-8")
    executable = stat.S_IRUSR | stat.S_IWUSR | stat.S_IXUSR
    aws_stub.chmod(executable)
    gh_stub.chmod(executable)
    environment = os.environ.copy()
    for variable in (
        "AWS_ACCESS_KEY_ID",
        "AWS_CONFIG_FILE",
        "AWS_CONTAINER_AUTHORIZATION_TOKEN",
        "AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE",
        "AWS_CONTAINER_CREDENTIALS_FULL_URI",
        "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI",
        "AWS_DEFAULT_PROFILE",
        "AWS_PROFILE",
        "AWS_REGION",
        "AWS_ROLE_ARN",
        "AWS_SECRET_ACCESS_KEY",
        "AWS_SESSION_TOKEN",
        "AWS_SHARED_CREDENTIALS_FILE",
        "AWS_WEB_IDENTITY_TOKEN_FILE",
    ):
        environment.pop(variable, None)
    environment["AWS_EC2_METADATA_DISABLED"] = "true"
    environment["BOOTSTRAP_TEST_AWS_LOG"] = str(log_path)
    # Deliberately exclude user-local directories containing the real AWS CLI. If the repo-local
    # stub cannot execute, command lookup must fail closed instead of reaching the network.
    environment["PATH"] = f"{bin_path}{os.pathsep}/usr/bin{os.pathsep}/bin"
    result = subprocess.run(
        ["/bin/bash", str(BOOTSTRAP), "--check-drift", "--ambient"],
        cwd=ROOT,
        env=environment,
        capture_output=True,
        check=False,
        text=True,
    )
    expect("ambient mock stops before live resolution", result.returncode, 1)
    first_aws_invocation = (
        log_path.read_text(encoding="utf-8").splitlines() if log_path.exists() else []
    )
    expect(
        f"ambient AWS call has no profile option (stderr={result.stderr.strip()!r})",
        first_aws_invocation,
        ["sts get-caller-identity --query Account --output text"],
    )

    # Prove --apply cannot reach even its first read, much less a write, when a source contract
    # fails. Replacing python3 makes the source JSON/semantic gate fail deterministically.
    python_stub = bin_path / "python3"
    python_stub.write_text("#!/bin/bash\nexit 99\n", encoding="utf-8")
    python_stub.chmod(executable)
    log_path.unlink(missing_ok=True)
    apply_result = subprocess.run(
        ["/bin/bash", str(BOOTSTRAP), "--apply", "--ambient"],
        cwd=ROOT,
        env=environment,
        capture_output=True,
        check=False,
        text=True,
    )
    expect("failed source contract blocks apply", apply_result.returncode, 1)
    expect("failed source contract invokes no AWS command", log_path.exists(), False)

if failures:
    for failure in failures:
        print(f"test-iam-drift-structure: FAIL — {failure}", file=sys.stderr)
    raise SystemExit(1)

print(f"test-iam-drift-structure: OK — {assertions} assertions")
