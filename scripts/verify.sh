#!/usr/bin/env bash
# One credential-free verification entry point for local use and CI.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUALITY_TMP=''
TERRAFORM_TEST_TMP=''

cleanup() {
    if [ -n "${TERRAFORM_TEST_TMP}" ] && [ -d "${TERRAFORM_TEST_TMP}" ]; then
        rm -rf -- "${TERRAFORM_TEST_TMP}"
    fi
    if [ -n "${QUALITY_TMP}" ] && [ -d "${QUALITY_TMP}" ]; then
        rm -rf -- "${QUALITY_TMP}"
    fi
}
trap cleanup EXIT

section() { printf '\n== %s ==\n' "$1"; }
require() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'verify: missing required command %s\n' "$1" >&2
        exit 2
    }
}

for command in actionlint bash python3 shellcheck terraform yamllint; do
    require "${command}"
done

section 'source formatting and static shell checks'
git -C "${ROOT}" diff --check
git -C "${ROOT}" diff --cached --check
if git -C "${ROOT}" rev-parse --verify HEAD^ >/dev/null 2>&1; then
    git -C "${ROOT}" diff --check HEAD^ HEAD
fi

mapfile -d '' shell_files < <(find "${ROOT}/scripts" -type f -name '*.sh' -print0 | sort -z)
bash -n "${shell_files[@]}"
shellcheck --severity=warning "${shell_files[@]}"
bash -n "${ROOT}/quality-tools.env"
shellcheck --shell=sh --severity=warning "${ROOT}/quality-tools.env"

section 'workflow syntax and immutable dependencies'
actionlint -no-color
python3 -B "${ROOT}/scripts/check-action-pins.py" --self-test
python3 -B "${ROOT}/scripts/check-action-pins.py"

section 'YAML, JSON, Python, and Terraform syntax'
yamllint -c "${ROOT}/.yamllint.yml" \
    "${ROOT}/.github" \
    "${ROOT}/ansible" \
    "${ROOT}/requirements-quality.yml"

python3 - "${ROOT}" <<'PYEOF'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
json_files = sorted((root / "docs" / "reference" / "aws-iam").rglob("*.json"))
if not json_files:
    raise SystemExit("verify: no IAM JSON documents found")
for path in json_files:
    with path.open(encoding="utf-8") as handle:
        json.load(handle)

python_files = sorted((root / "scripts").glob("*.py"))
for path in python_files:
    compile(path.read_text(encoding="utf-8"), str(path), "exec")

requirements = []
for raw_line in (root / "requirements-quality.txt").read_text(encoding="utf-8").splitlines():
    line = raw_line.strip()
    if not line or line.startswith("#"):
        continue
    if "==" not in line or any(marker in line for marker in (">=", "<=", "~=", "!=", " @ ")):
        raise SystemExit(f"verify: quality dependency is not exact: {line!r}")
    requirements.append(line)
if not requirements:
    raise SystemExit("verify: requirements-quality.txt has no dependencies")

for pin_file in (root / ".github" / "ansible-framework-pin", root / ".github" / "terraform-framework-pin"):
    value = pin_file.read_text(encoding="utf-8").strip()
    if len(value) != 40 or any(character not in "0123456789abcdef" for character in value):
        raise SystemExit(f"verify: {pin_file.relative_to(root)} is not a lowercase 40-character commit SHA")

print(f"verify: parsed {len(json_files)} JSON and {len(python_files)} Python file(s); dependency pins are exact")
PYEOF

terraform fmt -check -recursive -diff "${ROOT}/terraform"
terraform fmt -check -diff "${ROOT}/scripts/terraform-consumer.tftest.hcl"

if [ -n "${QUALITY_TERRAFORM_FRAMEWORK:-}" ]; then
    section 'pinned Terraform framework and consumer compatibility'

    terraform_framework="$(cd "${QUALITY_TERRAFORM_FRAMEWORK}" && pwd)"
    expected_terraform_framework="$(tr -d '\r\n' < "${ROOT}/.github/terraform-framework-pin")"
    actual_terraform_framework="$(git -C "${terraform_framework}" rev-parse HEAD)"
    [ "${actual_terraform_framework}" = "${expected_terraform_framework}" ] || {
        printf 'verify: Terraform framework is %s; pin requires %s\n' \
            "${actual_terraform_framework}" "${expected_terraform_framework}" >&2
        exit 1
    }

    terraform_root="${terraform_framework}/terraform"
    [ -f "${terraform_root}/.terraform.lock.hcl" ] || {
        printf 'verify: pinned Terraform framework has no provider lock file\n' >&2
        exit 1
    }
    [ -d "${terraform_root}/tests" ] || {
        printf 'verify: pinned Terraform framework has no configuration test suite\n' >&2
        exit 1
    }

    TERRAFORM_TEST_TMP="$(mktemp -d "${terraform_root}/.quality-tests.XXXXXXXX")"
    : > "${TERRAFORM_TEST_TMP}/empty-aws-config"

    # Strip every standard AWS credential source. The framework and consumer plans below use
    # mock_provider exclusively; init needs only public Terraform Registry access.
    terraform_without_aws() {
        env \
            -u AWS_ACCESS_KEY_ID \
            -u AWS_SECRET_ACCESS_KEY \
            -u AWS_SESSION_TOKEN \
            -u AWS_PROFILE \
            -u AWS_DEFAULT_PROFILE \
            -u AWS_WEB_IDENTITY_TOKEN_FILE \
            -u AWS_ROLE_ARN \
            -u AWS_CONTAINER_CREDENTIALS_RELATIVE_URI \
            -u AWS_CONTAINER_CREDENTIALS_FULL_URI \
            -u AWS_CONFIG_FILE \
            -u AWS_SHARED_CREDENTIALS_FILE \
            -u AWS_SDK_LOAD_CONFIG \
            AWS_CONFIG_FILE="${TERRAFORM_TEST_TMP}/empty-aws-config" \
            AWS_EC2_METADATA_DISABLED=true \
            AWS_SDK_LOAD_CONFIG=0 \
            AWS_SHARED_CREDENTIALS_FILE="${TERRAFORM_TEST_TMP}/empty-aws-config" \
            TF_IN_AUTOMATION=1 \
            terraform "$@"
    }

    terraform_without_aws -chdir="${terraform_root}" init \
        -backend=false -input=false -lockfile=readonly -no-color
    terraform_without_aws -chdir="${terraform_root}" validate -no-color
    terraform_without_aws -chdir="${terraform_root}" test -no-color

    # Terraform requires test directories to live beneath the configuration root. Copy only the
    # reviewed consumer test into an isolated, trap-cleaned directory in the pinned checkout.
    cp "${ROOT}/scripts/terraform-consumer.tftest.hcl" \
        "${TERRAFORM_TEST_TMP}/repository.tftest.hcl"
    terraform_without_aws -chdir="${terraform_root}" test -no-color \
        -test-directory="$(basename "${TERRAFORM_TEST_TMP}")" \
        -var-file="${ROOT}/terraform/aws.tfvars"
elif [ "${QUALITY_REQUIRE_TERRAFORM:-0}" = '1' ]; then
    printf 'verify: QUALITY_REQUIRE_TERRAFORM=1 but QUALITY_TERRAFORM_FRAMEWORK is unset\n' >&2
    exit 2
else
    printf '\nverify: Terraform framework checks skipped (set QUALITY_TERRAFORM_FRAMEWORK to the pinned checkout)\n'
fi

section 'offline repository contracts'
"${ROOT}/scripts/check-iam-literals.sh"
python3 -B "${ROOT}/scripts/test-iam-structure.py"
python3 -B "${ROOT}/scripts/test-iam-drift-structure.py"
"${ROOT}/scripts/check-workflow-trigger.sh"
python3 -B "${ROOT}/scripts/check-renovate-config.py"
"${ROOT}/scripts/test-aws-clean.sh"
python3 -B "${ROOT}/scripts/test-aws-resource-graph.py"
python3 -B "${ROOT}/scripts/check-winshell-splitargs.py"
python3 -B "${ROOT}/ansible/applications/wsus/tests/test_susdb_state_table.py"

if [ "${QUALITY_ENFORCE_TOOL_VERSIONS:-0}" = '1' ]; then
    section 'installed tool versions'
    # This file contains only reviewed single-quoted assignments.
    # shellcheck disable=SC1091
    source "${ROOT}/quality-tools.env"
    [ "$(actionlint -version | head -n 1)" = "${ACTIONLINT_VERSION}" ] || {
        printf 'verify: actionlint version does not match %s\n' "${ACTIONLINT_VERSION}" >&2
        exit 1
    }
    shellcheck --version | grep -Fx "version: ${SHELLCHECK_APT_VERSION%-*}" >/dev/null || {
        printf 'verify: ShellCheck version does not match %s\n' "${SHELLCHECK_APT_VERSION}" >&2
        exit 1
    }
    [ "$(terraform version | sed -n '1p')" = "Terraform v${TERRAFORM_VERSION}" ] || {
        printf 'verify: Terraform version does not match %s\n' "${TERRAFORM_VERSION}" >&2
        exit 1
    }
    python3 - "${ROOT}/requirements-quality.txt" <<'PYEOF'
from importlib import metadata
import pathlib
import sys

for raw_line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    line = raw_line.strip()
    if not line or line.startswith("#"):
        continue
    package, expected = line.split("==", 1)
    actual = metadata.version(package)
    if actual != expected:
        raise SystemExit(f"verify: {package} {actual} is installed; expected {expected}")
print("verify: direct Python quality dependencies match their pins")
PYEOF
fi

if [ -n "${QUALITY_ANSIBLE_FRAMEWORK:-}" ]; then
    section 'composed Ansible syntax and lint'
    require ansible-lint
    require ansible-playbook
    require rsync

    framework="$(cd "${QUALITY_ANSIBLE_FRAMEWORK}" && pwd)"
    expected_framework="$(tr -d '\r\n' < "${ROOT}/.github/ansible-framework-pin")"
    actual_framework="$(git -C "${framework}" rev-parse HEAD)"
    [ "${actual_framework}" = "${expected_framework}" ] || {
        printf 'verify: composed framework is %s; pin requires %s\n' \
            "${actual_framework}" "${expected_framework}" >&2
        exit 1
    }

    QUALITY_TMP="$(mktemp -d "${TMPDIR:-/tmp}/windows-wsus-quality.XXXXXXXX")"
    compose="${QUALITY_TMP}/ansible-framework"
    mkdir -p "${compose}"
    rsync -a --exclude='.git/' "${framework}/" "${compose}/"

    for role_source in "${ROOT}"/ansible/applications/*; do
        role_name="$(basename "${role_source}")"
        [ -f "${role_source}/tasks/main.yml" ] || {
            printf 'verify: %s is missing tasks/main.yml\n' "${role_source}" >&2
            exit 1
        }
        if [ -n "$(git -C "${framework}" ls-files -- "applications/${role_name}/")" ]; then
            printf 'verify: refusing to replace framework-owned role applications/%s\n' "${role_name}" >&2
            exit 1
        fi
        rsync -a --delete "${role_source}/" "${compose}/applications/${role_name}/"
    done

    mkdir -p "${QUALITY_TMP}/ansible-home" "${QUALITY_TMP}/ansible-local"
    (
        cd "${compose}"
        export ANSIBLE_CONFIG="${compose}/ansible.cfg"
        export ANSIBLE_HOME="${QUALITY_TMP}/ansible-home"
        export ANSIBLE_LOCAL_TEMP="${QUALITY_TMP}/ansible-local"
        export AWS_ACCOUNT_ID='000000000000'
        export AWS_REGION='us-east-1'
        ansible-playbook -i 'localhost,' --syntax-check \
            "${ROOT}/ansible/playbooks/wsus-aws.yml" -e env=test
        # Yamllint already owns YAML formatting. ENV and role-name dictionaries are framework
        # contracts; keep var-naming visible but non-blocking while safety rules still fail.
        ansible-lint --offline --format quiet --skip-list yaml --warn-list var-naming \
            "${ROOT}/ansible/playbooks/wsus-aws.yml" \
            "${compose}/applications/wsus"
    )
elif [ "${QUALITY_REQUIRE_COMPOSED:-0}" = '1' ]; then
    printf 'verify: QUALITY_REQUIRE_COMPOSED=1 but QUALITY_ANSIBLE_FRAMEWORK is unset\n' >&2
    exit 2
else
    printf '\nverify: composed Ansible lint skipped (set QUALITY_ANSIBLE_FRAMEWORK to the pinned checkout)\n'
fi

printf '\nverify: all requested checks passed\n'
