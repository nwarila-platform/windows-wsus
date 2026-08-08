#!/usr/bin/env bash
# Offline regression tests for the fail-closed AWS cleanup proof.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${ROOT}/.quality-local.aws-clean.XXXXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

grep -F 'Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down' \
  "${ROOT}/scripts/assert-aws-clean.sh" > /dev/null || {
    echo 'test-aws-clean: shared proof must treat shutting-down instances as live' >&2
    exit 1
}

mkdir -p "${WORK}/bin"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'if [ -n "${AWS_CLEAN_STUB_LOG:-}" ]; then printf "%s\n" "$*" >> "${AWS_CLEAN_STUB_LOG}"; fi' \
  'if [ "${AWS_CLEAN_STUB_MODE}" = api-failure ] && [ "$1 $2" = "ec2 describe-volumes" ]; then exit 73; fi' \
  'if [ "$1 $2" = "s3api list-objects-v2" ]; then printf "%s\n" "{\"Contents\":[]}"; exit 0; fi' \
  'if [ "${AWS_CLEAN_STUB_MODE}" = resource ] && [ "$1 $2" = "ec2 describe-key-pairs" ]; then' \
  '  printf "%s\n" key-0123456789abcdef0; exit 0' \
  'fi' \
  'exit 0' > "${WORK}/bin/aws"
chmod +x "${WORK}/bin/aws"

run_proof() {
    PATH="${WORK}/bin:${PATH}" \
      AWS_ACCOUNT_ID=123456789012 \
      AWS_REGION=us-east-1 \
      GITHUB_REPOSITORY_ID=1316209092 \
      STATE_KEY=nwarila-platform/windows-wsus/aws-poc.tfstate \
      CLEAN_PROOF_ATTEMPTS=1 \
      CLEAN_PROOF_DELAY_SECONDS=0 \
      AWS_CLEAN_STUB_MODE="$1" \
      AWS_CLI_PROFILE_NAME="${2:-}" \
      AWS_CLEAN_STUB_LOG="${3:-}" \
      "${ROOT}/scripts/assert-aws-clean.sh"
}

run_proof empty > "${WORK}/empty.out" 2>&1 || {
    echo 'test-aws-clean: empty authoritative results must prove clean' >&2
    exit 1
}
grep -F 'AWS clean proof passed' "${WORK}/empty.out" > /dev/null || {
    echo 'test-aws-clean: empty-result proof emitted no success marker' >&2
    exit 1
}

if run_proof api-failure > "${WORK}/failure.out" 2>&1; then
    echo 'test-aws-clean: an AWS API failure was mistaken for an empty result' >&2
    exit 1
fi

if run_proof resource > "${WORK}/resource.out" 2>&1; then
    echo 'test-aws-clean: a remaining repository-owned key pair was missed' >&2
    exit 1
fi
grep -F 'key-pairs:key-0123456789abcdef0' "${WORK}/resource.out" > /dev/null || {
    echo 'test-aws-clean: remaining-resource diagnostics omitted the key pair id' >&2
    exit 1
}

profile_log="${WORK}/profile.log"
run_proof empty mgmt-admin "${profile_log}" > /dev/null 2>&1 || {
    echo 'test-aws-clean: explicit CLI profile proof unexpectedly failed' >&2
    exit 1
}
[ "$(wc -l < "${profile_log}")" -eq 7 ] || {
    echo 'test-aws-clean: explicit profile test did not observe every AWS query' >&2
    exit 1
}
if grep -vF -- '--profile mgmt-admin' "${profile_log}" | grep -q .; then
    echo 'test-aws-clean: an AWS clean query omitted the explicit CLI profile' >&2
    exit 1
fi

echo 'test-aws-clean: OK — empty results pass; API failures/residuals fail; profile is exact'
