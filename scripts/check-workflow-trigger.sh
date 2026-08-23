#!/usr/bin/env bash
# Assert the split workflow contract: unprivileged PR quality, protected-main AWS proof.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUALITY="${ROOT}/.github/workflows/quality.yml"
DEPLOY="${ROOT}/.github/workflows/aws-deploy.yml"
REAPER="${ROOT}/.github/workflows/aws-reaper.yml"
IAM_DRIFT="${ROOT}/.github/workflows/iam-drift.yml"
PIN_BUMP="${ROOT}/.github/workflows/pin-bump.yml"
TFVARS="${ROOT}/terraform/aws.tfvars"
CODEOWNERS="${ROOT}/.github/CODEOWNERS"

fail() { printf 'check-workflow-trigger: FAIL — %s\n' "$1" >&2; exit 1; }
[ -f "${QUALITY}" ] || fail "missing ${QUALITY}"
[ -f "${DEPLOY}" ] || fail "missing ${DEPLOY}"
[ -f "${REAPER}" ] || fail "missing ${REAPER}"
[ -f "${IAM_DRIFT}" ] || fail "missing ${IAM_DRIFT}"
[ -f "${PIN_BUMP}" ] || fail "missing ${PIN_BUMP}"
[ -f "${TFVARS}" ] || fail "missing ${TFVARS}"
[ -f "${CODEOWNERS}" ] || fail "missing ${CODEOWNERS}"

python3 - "${QUALITY}" "${DEPLOY}" "${REAPER}" "${IAM_DRIFT}" "${PIN_BUMP}" "${TFVARS}" \
  "${CODEOWNERS}" <<'PYEOF'
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


(
    quality_path,
    deploy_path,
    reaper_path,
    iam_drift_path,
    pin_bump_path,
    tfvars_path,
    codeowners_path,
) = sys.argv[1:8]
failures: list[str] = []
expected_main_condition = "github.ref == 'refs/heads/main'"


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


def expected_pin_reader(*pins: tuple[str, str]) -> str:
    calls = "\n".join(f"emit_pin {name} {path}" for name, path in pins)
    return f'''set -euo pipefail
emit_pin() {{
  local name="$1" path="$2" pin
  local -a lines
  mapfile -t lines < "${{path}}"
  [ "${{#lines[@]}}" -eq 1 ] || {{
    echo "${{path}} must contain exactly one line" >&2
    return 1
  }}
  pin="${{lines[0]}}"
  [[ "${{pin}}" =~ ^[0-9a-f]{{40}}$ ]] || {{
    echo "${{path}} must contain exactly one lowercase 40-character Git SHA" >&2
    return 1
  }}
  printf '%s=%s\\n' "${{name}}" "${{pin}}" >> "${{GITHUB_OUTPUT}}"
}}
{calls}'''


def require_exact_pin_reader(path: str, step: dict, *pins: tuple[str, str]) -> None:
    actual = mapping(step).get("run")
    expected = expected_pin_reader(*pins)
    if not isinstance(actual, str) or actual.strip() != expected.strip():
        failures.append(
            f"{path} Read framework pins must fail closed on exact single-line lowercase SHA pins"
        )


with open(codeowners_path, encoding="utf-8") as codeowners_handle:
    codeowner_rules = [
        line.strip()
        for line in codeowners_handle
        if line.strip() and not line.lstrip().startswith("#")
    ]
expected_codeowner_rules = [
    "* @NWarila",
    "/.github/workflows/ @NWarila",
    "/.github/renovate.json5 @NWarila",
    "/.github/ansible-framework-pin @NWarila",
    "/.github/terraform-framework-pin @NWarila",
    "/docs/reference/aws-iam/ @NWarila",
    "/scripts/ @NWarila",
]
if codeowner_rules != expected_codeowner_rules:
    failures.append(f"{codeowners_path} must retain exact ownership of automation/security surfaces")


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

quality_steps = [step for step in required_job.get("steps", []) if isinstance(step, dict)]
quality_steps_by_name = {
    step.get("name"): step for step in quality_steps if isinstance(step.get("name"), str)
}
require_exact_pin_reader(
    quality_path,
    mapping(quality_steps_by_name.get("Read framework pins")),
    ("ansible", ".github/ansible-framework-pin"),
    ("terraform", ".github/terraform-framework-pin"),
)


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
if set(deploy_jobs) != {"main-ref", "aws-deploy", "report"}:
    failures.append(f"{deploy_path} jobs must be exactly main-ref, aws-deploy, and report")
guard = mapping(deploy_jobs.get("main-ref"))
if not guard:
    failures.append(f"{deploy_path} must contain the unprivileged main-ref guard job")
elif guard.get("permissions") != {}:
    failures.append(f"{deploy_path} main-ref guard permissions must be explicitly empty")

privileged = mapping(deploy_jobs.get("aws-deploy"))
deploy_env = mapping(privileged.get("env"))
needs = privileged.get("needs", [])
needs = [needs] if isinstance(needs, str) else needs
if "main-ref" not in (needs or []):
    failures.append(f"{deploy_path} aws-deploy must depend on the main-ref guard")
condition = privileged.get("if")
if condition != expected_main_condition:
    failures.append(
        f"{deploy_path} aws-deploy if must be exactly {expected_main_condition!r}; got {condition!r}"
    )
if privileged.get("permissions") != {"contents": "read", "id-token": "write"}:
    failures.append(f"{deploy_path} aws-deploy permissions must be exactly contents: read and id-token: write")
if deploy_env.get("AWS_REGION") != "us-east-1":
    failures.append(f"{deploy_path} aws-deploy AWS_REGION must be the code-owned value 'us-east-1'")
expected_state_key = "nwarila-platform/windows-wsus/aws-poc.tfstate"
if deploy_env.get("STATE_KEY") != expected_state_key:
    failures.append(f"{deploy_path} aws-deploy STATE_KEY must be exactly {expected_state_key!r}")

deploy_steps = [step for step in privileged.get("steps", []) if isinstance(step, dict)]
deploy_steps_by_name = {
    step.get("name"): step for step in deploy_steps if isinstance(step.get("name"), str)
}
require_exact_pin_reader(
    deploy_path,
    mapping(deploy_steps_by_name.get("Read framework pins")),
    ("terraform", ".github/terraform-framework-pin"),
    ("ansible", ".github/ansible-framework-pin"),
)
recovery_order = [
    "Terraform init",
    "Terraform apply",
    "Run the WSUS playbook",
    "Refresh AWS credentials before destroy (OIDC)",
    "Terraform destroy (always)",
    "Prove no live repository-owned AWS resources remain",
]
deploy_step_names = [step.get("name") for step in deploy_steps]
try:
    recovery_positions = [deploy_step_names.index(name) for name in recovery_order]
except ValueError:
    failures.append(f"{deploy_path} must retain every lifecycle and cleanup proof step")
else:
    if recovery_positions != sorted(recovery_positions):
        failures.append(f"{deploy_path} apply/converge/destroy/final-cleanup ordering is unsafe")

# The destroy path is the money path: it must run on every initialized lifecycle with
# credentials minted after the 100-minute converge, never with the expired originals.
destroy_gate = "always() && steps.tf-init.outcome == 'success'"
destroy_refresh = mapping(deploy_steps_by_name.get("Refresh AWS credentials before destroy (OIDC)"))
if destroy_refresh.get("if") != destroy_gate:
    failures.append(
        f"{deploy_path} destroy credential refresh must run whenever Terraform init succeeded"
    )
final_destroy = mapping(deploy_steps_by_name.get("Terraform destroy (always)"))
if final_destroy.get("if") != destroy_gate:
    failures.append(
        f"{deploy_path} final destroy must run whenever Terraform init succeeded"
    )
if mapping(deploy_steps_by_name.get("Prove no live repository-owned AWS resources remain")).get(
    "run"
) != "bash scripts/assert-aws-clean.sh":
    failures.append(f"{deploy_path} post-destroy cleanup must use the shared fail-closed proof")

for job_name, job in deploy_jobs.items():
    job = mapping(job)
    permissions = mapping(job.get("permissions"))
    if "id-token" in permissions and job_name != "aws-deploy":
        failures.append(f"{deploy_path} only aws-deploy may request id-token (found on {job_name})")
if mapping(deploy_jobs.get("report")).get("permissions") != {"issues": "write"}:
    failures.append(f"{deploy_path} report permissions must be exactly issues: write")


reaper = load(reaper_path)
reaper_on = triggers(reaper, reaper_path)
if set(reaper_on) != {"schedule", "workflow_dispatch"}:
    failures.append(
        f"{reaper_path} events must be exactly schedule and workflow_dispatch; "
        f"got {sorted(str(key) for key in reaper_on)!r}"
    )
if reaper_on.get("schedule") != [{"cron": "23 * * * *"}]:
    failures.append(f"{reaper_path} schedule must be the single off-minute hourly cron '23 * * * *'")
if reaper.get("permissions") != {}:
    failures.append(f"{reaper_path} top-level permissions must remain empty")

reaper_jobs = mapping(reaper.get("jobs"))
if set(reaper_jobs) != {"main-ref", "aws-reaper", "report"}:
    failures.append(f"{reaper_path} jobs must be exactly main-ref, aws-reaper, and report")
reaper_guard = mapping(reaper_jobs.get("main-ref"))
if not reaper_guard:
    failures.append(f"{reaper_path} must contain the unprivileged main-ref guard job")
elif reaper_guard.get("permissions") != {}:
    failures.append(f"{reaper_path} main-ref guard permissions must be explicitly empty")

reaper_privileged = mapping(reaper_jobs.get("aws-reaper"))
reaper_env = mapping(reaper_privileged.get("env"))
reaper_needs = reaper_privileged.get("needs", [])
reaper_needs = [reaper_needs] if isinstance(reaper_needs, str) else reaper_needs
if "main-ref" not in (reaper_needs or []):
    failures.append(f"{reaper_path} aws-reaper must depend on the main-ref guard")
reaper_condition = reaper_privileged.get("if")
if reaper_condition != expected_main_condition:
    failures.append(
        f"{reaper_path} aws-reaper if must be exactly {expected_main_condition!r}; "
        f"got {reaper_condition!r}"
    )
if reaper_privileged.get("permissions") != {
    "actions": "read",
    "contents": "read",
    "id-token": "write",
}:
    failures.append(
        f"{reaper_path} aws-reaper permissions must be exactly actions/contents: read and id-token: write"
    )
if reaper_env.get("AWS_REGION") != "us-east-1":
    failures.append(f"{reaper_path} aws-reaper AWS_REGION must be the code-owned value 'us-east-1'")
if reaper_env.get("STATE_KEY") != expected_state_key:
    failures.append(f"{reaper_path} aws-reaper STATE_KEY must exactly match the deploy state key")

with open(reaper_path, encoding="utf-8") as reaper_handle:
    reaper_text = reaper_handle.read()
required_live_instance_filter = (
    "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down"
)
if reaper_text.count(required_live_instance_filter) != 3:
    failures.append(
        f"{reaper_path} must treat shutting-down instances as live in all three inventory phases"
    )
for dependency_contract in (
    "assert_instance_dependency_graph",
    '--network-interface-ids "${dependency_interface_ids[@]}"',
    '--volume-ids "${dependency_volume_ids[@]}"',
    "assert_address_association_identity",
    'aws ec2 disassociate-address --association-id "${validated_association_id}"',
):
    if dependency_contract not in reaper_text:
        failures.append(
            f"{reaper_path} stale-resource mutation is missing dependency proof {dependency_contract!r}"
        )
# One definition plus one call per mutation class: instances, interfaces, addresses, volumes,
# and security groups. Key pairs are not a repository-owned class - the launch key is standing.
if reaper_text.count("assert_resource_graph") != 6 or (
    'python3 "${GITHUB_WORKSPACE}/scripts/assert-aws-resource-graph.py"' not in reaper_text
):
    failures.append(
        f"{reaper_path} must run the shared bidirectional graph proof before all five mutation classes"
    )
if reaper_text.count(
    'assert_address_association_identity "${allocation_id}" "${source_run_id}"'
) != 2:
    failures.append(
        f"{reaper_path} must validate an EIP association before and after its lifecycle recheck"
    )
if reaper_text.count('lock_key="${STATE_KEY}.tflock"') != 1:
    failures.append(f"{reaper_path} must derive its sole lock key as ${{STATE_KEY}}.tflock")
if f"{expected_state_key}.tflock" in reaper_text:
    failures.append(f"{reaper_path} must not carry an independent literal lock key")

for job_name, job in reaper_jobs.items():
    permissions = mapping(mapping(job).get("permissions"))
    if "id-token" in permissions and job_name != "aws-reaper":
        failures.append(f"{reaper_path} only aws-reaper may request id-token (found on {job_name})")
if mapping(reaper_jobs.get("report")).get("permissions") != {"issues": "write"}:
    failures.append(f"{reaper_path} report permissions must be exactly issues: write")


iam_drift = load(iam_drift_path)
iam_drift_jobs = mapping(iam_drift.get("jobs"))
iam_drift_condition = mapping(iam_drift_jobs.get("attest")).get("if")
if iam_drift_condition != expected_main_condition:
    failures.append(
        f"{iam_drift_path} attest if must be exactly {expected_main_condition!r}; "
        f"got {iam_drift_condition!r}"
    )


pin_bump = load(pin_bump_path)
pin_bump_on = triggers(pin_bump, pin_bump_path)
if set(pin_bump_on) != {"schedule"}:
    failures.append(
        f"{pin_bump_path} must be schedule-only; got {sorted(str(key) for key in pin_bump_on)!r}"
    )
if pin_bump_on.get("schedule") != [{"cron": "43 7 * * 2"}]:
    failures.append(f"{pin_bump_path} schedule must be the single off-minute cron '43 7 * * 2'")
if pin_bump.get("permissions") != {}:
    failures.append(f"{pin_bump_path} top-level permissions must remain empty")

pin_jobs = mapping(pin_bump.get("jobs"))
if set(pin_jobs) != {"discover", "report"}:
    failures.append(f"{pin_bump_path} jobs must be exactly discover and report")
if mapping(pin_jobs.get("discover")).get("permissions") != {
    "actions": "write",
    "contents": "write",
    "pull-requests": "write",
}:
    failures.append(
        f"{pin_bump_path} discover permissions must be exactly actions/contents/pull-requests: write"
    )
if mapping(pin_jobs.get("report")).get("permissions") != {"issues": "write"}:
    failures.append(f"{pin_bump_path} report permissions must be exactly issues: write")


def reject_id_token(value, location: str) -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            child_location = f"{location}.{key}"
            if str(key) == "id-token":
                failures.append(f"{pin_bump_path} must never request id-token ({child_location})")
            reject_id_token(child, child_location)
    elif isinstance(value, list):
        for index, child in enumerate(value):
            reject_id_token(child, f"{location}[{index}]")


reject_id_token(pin_bump, "workflow")

with open(pin_bump_path, encoding="utf-8") as pin_bump_handle:
    pin_bump_text = pin_bump_handle.read()
dispatch_targets = re.findall(r"actions/workflows/([^/\s\"']+)/dispatches", pin_bump_text)
if dispatch_targets != ["quality.yml"] or pin_bump_text.count("/dispatches") != 1:
    failures.append(
        f"{pin_bump_path} must dispatch only quality.yml; got {sorted(set(dispatch_targets))!r}"
    )
if "gh workflow run" in pin_bump_text:
    failures.append(f"{pin_bump_path} must use its audited quality.yml dispatch endpoint")
if not re.search(
    r'select\(\.status\s*!=\s*"completed"\s+or\s+\.conclusion\s*==\s*"success"\)',
    pin_bump_text,
):
    failures.append(
        f"{pin_bump_path} must redispatch quality when every prior run is terminal non-success"
    )
for required_pr_filter in (
    "--json number,headRefName,headRepositoryOwner,isCrossRepository",
    ".headRefName == $branch",
    ".headRepositoryOwner.login == $owner",
    ".isCrossRepository == false",
):
    if required_pr_filter not in pin_bump_text:
        failures.append(
            f"{pin_bump_path} managed PR lookup is missing {required_pr_filter!r}"
        )
pr_list_commands = re.findall(r"gh pr list[^\n]*(?:\\\n[^\n]*)*", pin_bump_text)
if any('--head "${UPDATE_BRANCH}"' in command for command in pr_list_commands):
    failures.append(f"{pin_bump_path} must not trust gh pr list --head across fork owners")
if not re.search(
    r'\[\s*"\$\{#managed_pr_numbers\[@\]\}"\s+-gt\s+1\s*\]',
    pin_bump_text,
):
    failures.append(f"{pin_bump_path} must reject multiple local canonical managed PRs")
for privileged_workflow in ("aws-deploy.yml", "aws-reaper.yml"):
    if re.search(
        rf"actions/workflows/{re.escape(privileged_workflow)}/dispatches",
        pin_bump_text,
    ):
        failures.append(f"{pin_bump_path} must never dispatch {privileged_workflow}")

with open(tfvars_path, encoding="utf-8") as tfvars_handle:
    tfvars_text = tfvars_handle.read()
tfvars_regions = re.findall(r'^\s*region\s*=\s*"([^"]+)"\s*$', tfvars_text, re.MULTILINE)
tfvars_zones = re.findall(r'^\s*availability_zone\s*=\s*"([^"]+)"\s*$', tfvars_text, re.MULTILINE)
normalized_regions = [value.replace("_", "-") for value in tfvars_regions]
if normalized_regions != ["us-east-1"]:
    failures.append(f"{tfvars_path} must contain exactly one system region normalized to us-east-1")
if len(tfvars_zones) != 1 or not re.fullmatch(r"us-east-1[a-z]", tfvars_zones[0]):
    failures.append(f"{tfvars_path} availability zone must be the sole us-east-1 zone")

incident_contracts = (
    (deploy_path, deploy_jobs, "<!-- windows-wsus-automation:aws-lifecycle -->"),
    (reaper_path, reaper_jobs, "<!-- windows-wsus-automation:aws-reaper -->"),
    (iam_drift_path, iam_drift_jobs, "<!-- windows-wsus-automation:iam-drift -->"),
    (pin_bump_path, pin_jobs, "<!-- windows-wsus-automation:framework-discovery -->"),
)
for path, jobs, expected_marker in incident_contracts:
    report_job = mapping(jobs.get("report"))
    report_env = mapping(report_job.get("env"))
    report_steps = [step for step in report_job.get("steps", []) if isinstance(step, dict)]
    report_run = "\n".join(str(step.get("run", "")) for step in report_steps)
    if report_env.get("INCIDENT_LABEL") != "automation-incident":
        failures.append(f"{path} report must use the automation-only incident label")
    if report_env.get("INCIDENT_MARKER") != expected_marker:
        failures.append(f"{path} report must use its exact stable incident body marker")
    for fragment in (
        'gh label create "${INCIDENT_LABEL}"',
        '--label "${INCIDENT_LABEL}"',
        '.author.login == "app/github-actions"',
        'contains($marker)',
        'printf \'%s\\n\\n%s\' "${INCIDENT_MARKER}"',
    ):
        if fragment not in report_run:
            failures.append(f"{path} incident reporter is missing provenance guard {fragment!r}")
    if "in:title" in report_run:
        failures.append(f"{path} incident reporter must never mutate a title-only issue match")

for failure in failures:
    print(f"check-workflow-trigger: FAIL — {failure}", file=sys.stderr)
if failures:
    raise SystemExit(1)

print(
    "check-workflow-trigger: OK — quality is secret-free; AWS workflows and pin discovery are bounded"
)
PYEOF
