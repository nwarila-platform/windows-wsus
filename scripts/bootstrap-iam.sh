#!/usr/bin/env bash
# =========================================================================================== #
# bootstrap-iam.sh — materialize and apply this repository's AWS IAM
# ------------------------------------------------------------------------------------------- #
# Creates the deploy boundary this repository declares: nine customer-managed policies, five
# roles, and the EC2 instance profile. Idempotent — re-running reconciles rather than duplicates,
# so it is safe to run after editing a source document.
#
#   ./scripts/bootstrap-iam.sh [--apply|--check-drift] [--ambient|aws-profile]
#
# --check-drift compares LIVE IAM against the tracked source and fails on any difference. That is
# the one comparison neither other gate makes: check-iam-literals.sh reads source vs filesystem,
# and test-iam-policies.sh materializes FROM source, so both pass while live holds an older version.
#
# Without --apply it PLANS: materializes, gates, validates every document through Access
# Analyzer, and prints what would be created or updated. Nothing is written to AWS.
# With --apply it additionally creates/updates and then verifies against the live principal.
#
# Substitution values are resolved from the live account and the live GitHub repository, never
# hand-typed: the account from sts, the repository id from the GitHub API, the EBS key from the
# alias, and the VPC/subnet from the deploy environment. The artifact bucket follows the same
# `<account-id>-ansible` convention the playbook consumes. The standing EC2 key pair is created
# out of band; this script only scopes IAM to the key name declared in the tfvars.
# =========================================================================================== #
set -euo pipefail

APPLY=false; DRIFT=false
case "${1:-}" in
    --apply) APPLY=true; shift ;;
    --check-drift) DRIFT=true; shift ;;
esac
PROFILE="${1:-admin}"
if [ "${PROFILE}" = '--ambient' ]; then
    AWS_PROFILE_ARGS=()
else
    AWS_PROFILE_ARGS=(--profile "${PROFILE}")
fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IAM_DIR="${ROOT}/docs/reference/aws-iam"
OWNER='nwarila-platform'
REPO="$(basename "${ROOT}")"

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
say() { printf '  %-52s %s\n' "$1" "$2"; }
die() { printf 'bootstrap-iam: FAIL — %s\n' "$1" >&2; exit 1; }

# These source-mode clone-safety and exact semantic/digest contracts are prerequisites to every
# mode and, critically, precede the first --apply write. test-iam-drift-structure.py remains in the
# outer quality gate because it invokes this script with mocked ambient credentials; calling it
# here would recurse.
echo "== validate tracked IAM source =="
"${ROOT}/scripts/check-iam-literals.sh" > /dev/null \
  || die 'the tracked IAM source failed the clone-safety gate — do not apply'
python3 "${ROOT}/scripts/test-iam-structure.py" > /dev/null \
  || die 'the tracked IAM source failed its exact semantic contract — do not apply'
say 'tracked source contracts' 'clean'

# The data-only Terraform input is the region authority. Normalize its framework key form once and
# reject an out-of-band shell override rather than materializing IAM for a different region.
region_text="$(sed -nE \
  's/^[[:space:]]*region[[:space:]]*=[[:space:]]*"([^"]+)"[[:space:]]*$/\1/p' \
  "${ROOT}/terraform/aws.tfvars")" || die 'could not read region from terraform/aws.tfvars'
mapfile -t REGIONS <<< "${region_text}"
[ "${#REGIONS[@]}" -eq 1 ] || die 'terraform/aws.tfvars must declare exactly one region'
REGION="${REGIONS[0]//_/-}"
[[ "${REGION}" =~ ^[a-z]{2}(-gov)?-[a-z]+-[0-9]+$ ]] \
  || die "invalid normalized tfvars region '${REGION}'"
if [ -n "${AWS_REGION:-}" ] && [ "${AWS_REGION}" != "${REGION}" ]; then
    die "AWS_REGION ${AWS_REGION} disagrees with terraform/aws.tfvars (${REGION})"
fi

echo "== resolving substitution values from live sources =="
ACCOUNT="$(aws sts get-caller-identity "${AWS_PROFILE_ARGS[@]}" --query Account --output text)" || die 'no AWS identity'
REPO_ID="$(gh api "repos/${OWNER}/${REPO}" --jq .id)" || die "GitHub repo ${OWNER}/${REPO} not found"
KMS_KEY="$(aws kms describe-key --key-id alias/aws/ebs "${AWS_PROFILE_ARGS[@]}" --region "${REGION}" \
           --query 'KeyMetadata.KeyId' --output text)" || die 'alias/aws/ebs unresolved'
# The deploy subnet's single source of truth is terraform/aws.tfvars — the same file the
# deploy workflow passes to terraform verbatim — so the IAM subnet pin and the tfvars can
# never disagree. The VPC is derived FROM that subnet (the account holds more than one VPC; a
# blind Vpcs[0] pick is a coin toss). Parse assignments rather than arbitrary/commented text and
# refuse multiple distinct values instead of silently selecting the first one.
subnet_text="$(sed -nE \
  's/^[[:space:]]*subnet_id[[:space:]]*=[[:space:]]*"([^"]+)"[[:space:]]*$/\1/p' \
  "${ROOT}/terraform/aws.tfvars")" || die 'could not read subnet_id from terraform/aws.tfvars'
mapfile -t SUBNETS <<< "${subnet_text}"
SUBNET_ID="${SUBNETS[0]:-}"
[[ "${SUBNET_ID}" =~ ^subnet-[0-9a-f]{8}([0-9a-f]{9})?$ ]] \
  || die "terraform/aws.tfvars must declare a valid subnet_id"
for subnet in "${SUBNETS[@]}"; do
    [ "${subnet}" = "${SUBNET_ID}" ] \
      || die 'terraform/aws.tfvars declares more than one distinct subnet_id'
done
VPC_ID="$(aws ec2 describe-subnets --subnet-ids "${SUBNET_ID}" "${AWS_PROFILE_ARGS[@]}" --region "${REGION}" \
  --query 'Subnets[0].VpcId' --output text)" || die "subnet ${SUBNET_ID} not found in ${REGION}"
# Keep the IAM key ARN and the workflow/framework input on one source of truth. Refuse multiple
# systems/key names rather than materializing a policy that only some Terraform objects can use.
key_pair_text="$(sed -nE \
  's/^[[:space:]]*key_name[[:space:]]*=[[:space:]]*"([^"]+)"[[:space:]]*$/\1/p' \
  "${ROOT}/terraform/aws.tfvars")" || die 'could not read key_name from terraform/aws.tfvars'
mapfile -t KEY_PAIRS <<< "${key_pair_text}"
[ "${#KEY_PAIRS[@]}" -eq 1 ] || die 'terraform/aws.tfvars must declare exactly one key_name'
KEY_PAIR="${KEY_PAIRS[0]}"
[ "${KEY_PAIR}" = 'nwarila-ec2-key' ] || die "unexpected key_name '${KEY_PAIR}'"
# The OIDC subject GitHub actually emits embeds the OWNER id as well as the repository id
# (proven by CloudTrail). Resolve it rather than hard-coding it.
OWNER_ID="$(gh api "orgs/${OWNER}" --jq .id)" || die "cannot resolve owner id for ${OWNER}"
# One reviewed naming contract feeds IAM and the playbook. Retain the old environment knob only as
# a fail-closed compatibility assertion; it can no longer silently materialize a different bucket.
ARTIFACT_BUCKET="${ACCOUNT}-ansible"
if [ -n "${BOOTSTRAP_ARTIFACT_BUCKET:-}" ] && \
  [ "${BOOTSTRAP_ARTIFACT_BUCKET}" != "${ARTIFACT_BUCKET}" ]; then
    die "BOOTSTRAP_ARTIFACT_BUCKET must equal the playbook bucket ${ARTIFACT_BUCKET}"
fi
say 'repository id' "${REPO_ID}"
say 'vpc / subnet' "${VPC_ID} / ${SUBNET_ID}"
say 'ebs key' "${KMS_KEY}"
say 'artifact bucket' "${ARTIFACT_BUCKET}"

echo "== materialize =="
mkdir -p "${WORK}/policies" "${WORK}/roles"
cp "${IAM_DIR}/policies/"*.json "${WORK}/policies/"
cp "${IAM_DIR}/roles/"*.json    "${WORK}/roles/"
sed -i "s|<account-id>|${ACCOUNT}|g; s|<repository-id>|${REPO_ID}|g; s|<region>|${REGION}|g;
        s|<vpc-id>|${VPC_ID}|g; s|<subnet-id>|${SUBNET_ID}|g; s|<ebs-kms-key-id>|${KMS_KEY}|g;
        s|<key-pair-name>|${KEY_PAIR}|g; s|<owner-id>|${OWNER_ID}|g;
        s|<artifact-bucket>|${ARTIFACT_BUCKET}|g" "${WORK}"/policies/*.json "${WORK}"/roles/*.json

"${ROOT}/scripts/check-iam-literals.sh" --materialized "${WORK}" >/dev/null \
  || die 'the materialized tree failed the substitution gate — do not apply'
say 'substitution gate' 'clean'

echo "== validate every document before anything is written =="
for f in "${WORK}"/policies/*.json; do
    n="$(aws accessanalyzer validate-policy --policy-type IDENTITY_POLICY --policy-document "file://${f}" \
         "${AWS_PROFILE_ARGS[@]}" --region "${REGION}" \
         --query 'length(findings[?findingType==`ERROR`||findingType==`SECURITY_WARNING`])' --output text)"
    [ "${n}" = 0 ] || die "$(basename "${f}") has ${n} error/security finding(s)"
    say "$(basename "${f}")" 'clean'
done
for f in "${WORK}"/roles/*.json; do
    n="$(aws accessanalyzer validate-policy --policy-type RESOURCE_POLICY --policy-document "file://${f}" \
         "${AWS_PROFILE_ARGS[@]}" --region "${REGION}" \
         --query 'length(findings[?(findingType==`ERROR`&&issueCode!=`MISSING_RESOURCE`)||findingType==`SECURITY_WARNING`])' --output text)"
    [ "${n}" = 0 ] || die "$(basename "${f}") has ${n} error/security finding(s)"
    say "$(basename "${f}")" 'clean'
done

# ---- the declared object model -------------------------------------------------------------
CI_ROLE="github_${OWNER}_${REPO}"
ADMIN_ROLE="github_${OWNER}_${REPO}-admin"
AUDIT_ROLE="github_${OWNER}_${REPO}-iam-audit"
POC_ROLE="${REPO}-poc-role"
READER_ROLE="${REPO}-artifact-reader"
POC_PROFILE="${REPO}-poc-profile"
# policy file -> applied name (file basename IS the applied name, per this repo's convention).
# Classification mirrors the README role-to-policy table EXACTLY, and fails closed on a policy
# source it has never seen: the old everything-else-is-deploy default silently attached the
# artifact policies to the CI role, over-granting it S3 write and sts:AssumeRole.
POLICIES=()
for policy_path in "${WORK}"/policies/*.json; do
    [ -f "${policy_path}" ] || die 'no policy source documents found'
    POLICIES+=("$(basename "${policy_path}" .json)")
done
DEPLOY_POLICIES=(); ADMIN_ONLY_POLICIES=(); STATE_POLICY=''; READER_POLICY=''; ASSUME_POLICY=''; AUDIT_POLICY=''
for p in "${POLICIES[@]}"; do
    case "${p}" in
        *_iam-audit)
            [ -z "${AUDIT_POLICY}" ] || die "multiple IAM-audit policy sources"
            AUDIT_POLICY="${p}"
            ;;
        github_*)
            [ -z "${STATE_POLICY}" ] || die "multiple state policy sources: ${STATE_POLICY}, ${p}"
            STATE_POLICY="${p}"
            ;;
        *_artifact-read)
            [ -z "${READER_POLICY}" ] || die "multiple artifact-read policy sources"
            READER_POLICY="${p}"
            ;;
        # assume goes to CI AND admin: the CI deploy assumes the reader to deliver the TLS
        # PFX at configure time. folder (write) stays admin-only.
        *_artifact-assume)
            [ -z "${ASSUME_POLICY}" ] || die "multiple artifact-assume policy sources"
            ASSUME_POLICY="${p}"
            ;;
        *_artifact-folder) ADMIN_ONLY_POLICIES+=("${p}") ;;
        *_deploy-*) DEPLOY_POLICIES+=("${p}") ;;
        *) die "unclassified policy source '${p}' — extend the classification case deliberately (README role-to-policy table first)" ;;
    esac
done
[ -n "${READER_POLICY}" ] || die 'artifact-read policy source not found'
[ -n "${ASSUME_POLICY}" ] || die 'artifact-assume policy source not found'
[ -n "${STATE_POLICY}" ] || die 'state policy source not found'
[ -n "${AUDIT_POLICY}" ] || die 'IAM-audit policy source not found'
[ "${#DEPLOY_POLICIES[@]}" -eq 4 ] || die 'expected exactly four deploy policy sources'
[ "${#ADMIN_ONLY_POLICIES[@]}" -eq 1 ] || die 'expected exactly one admin-only policy source'

policy_arn() { printf 'arn:aws:iam::%s:policy/%s\n' "${ACCOUNT}" "$1"; }

CI_ATTACHMENTS=("$(policy_arn "${STATE_POLICY}")" "$(policy_arn "${ASSUME_POLICY}")")
ADMIN_ATTACHMENTS=("$(policy_arn "${STATE_POLICY}")" "$(policy_arn "${ASSUME_POLICY}")")
READER_ATTACHMENTS=("$(policy_arn "${READER_POLICY}")")
AUDIT_ATTACHMENTS=("$(policy_arn "${AUDIT_POLICY}")")
POC_ATTACHMENTS=('arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore')
for p in "${DEPLOY_POLICIES[@]}"; do
    CI_ATTACHMENTS+=("$(policy_arn "${p}")")
    ADMIN_ATTACHMENTS+=("$(policy_arn "${p}")")
done
for p in "${ADMIN_ONLY_POLICIES[@]}"; do
    ADMIN_ATTACHMENTS+=("$(policy_arn "${p}")")
done

# Build the inverse of the role attachment declarations above. Daily drift must prove not only
# that each modeled role has its expected policies, but also that none of this repository's nine
# customer-managed policies has been attached to an unmodeled role, user, group, or permissions
# boundary. Deriving this view from the same arrays prevents the two assertions from drifting.
expected_policy_entities() {
    local policy="$1" target arn
    target="$(policy_arn "${policy}")"
    for arn in "${CI_ATTACHMENTS[@]}"; do
        if [ "${arn}" = "${target}" ]; then printf 'role:%s\n' "${CI_ROLE}"; fi
    done
    for arn in "${ADMIN_ATTACHMENTS[@]}"; do
        if [ "${arn}" = "${target}" ]; then printf 'role:%s\n' "${ADMIN_ROLE}"; fi
    done
    for arn in "${AUDIT_ATTACHMENTS[@]}"; do
        if [ "${arn}" = "${target}" ]; then printf 'role:%s\n' "${AUDIT_ROLE}"; fi
    done
    for arn in "${READER_ATTACHMENTS[@]}"; do
        if [ "${arn}" = "${target}" ]; then printf 'role:%s\n' "${READER_ROLE}"; fi
    done
    for arn in "${POC_ATTACHMENTS[@]}"; do
        if [ "${arn}" = "${target}" ]; then printf 'role:%s\n' "${POC_ROLE}"; fi
    done
    return 0
}

line_set() {
    (($# > 0)) || return 0
    printf '%s\n' "$@" | LC_ALL=C sort -u
}

attached_policy_arns() {
    local role="$1" response
    response="$(aws iam list-attached-role-policies --role-name "${role}" \
      "${AWS_PROFILE_ARGS[@]}" --output json)" || return 1
    python3 -c 'import json,sys; print("\n".join(sorted(x["PolicyArn"] for x in json.load(sys.stdin)["AttachedPolicies"])))' \
      <<< "${response}"
}

inline_policy_names() {
    local role="$1" response
    response="$(aws iam list-role-policies --role-name "${role}" \
      "${AWS_PROFILE_ARGS[@]}" --output json)" || return 1
    python3 -c 'import json,sys; print("\n".join(sorted(json.load(sys.stdin)["PolicyNames"])))' \
      <<< "${response}"
}

role_tags_json() {
    local role="$1" response
    response="$(aws iam list-role-tags --role-name "${role}" \
      "${AWS_PROFILE_ARGS[@]}" --output json)" || return 1
    python3 -c '
import json,sys
tags=json.load(sys.stdin)["Tags"]
print(json.dumps(sorted(tags, key=lambda item: (item["Key"], item["Value"])), separators=(",", ":")))
' <<< "${response}"
}

policy_entities() {
    local policy_arn="$1" usage="$2" response
    response="$(aws iam list-entities-for-policy --policy-arn "${policy_arn}" \
      --policy-usage-filter "${usage}" "${AWS_PROFILE_ARGS[@]}" --output json)" || return 1
    python3 -c '
import json,sys
d=json.load(sys.stdin)
entities=[]
entities += ["group:" + x["GroupName"] for x in d.get("PolicyGroups", [])]
entities += ["role:" + x["RoleName"] for x in d.get("PolicyRoles", [])]
entities += ["user:" + x["UserName"] for x in d.get("PolicyUsers", [])]
print("\n".join(sorted(entities)))
' <<< "${response}"
}

is_modeled_role() {
    case "$1" in
        "${CI_ROLE}"|"${ADMIN_ROLE}"|"${AUDIT_ROLE}"|"${POC_ROLE}"|"${READER_ROLE}") return 0 ;;
        *) return 1 ;;
    esac
}

unexpected_policy_consumers() {
    local policy="$1" arn expected actual entity expected_entity keep
    arn="$(policy_arn "${policy}")"
    expected="$(expected_policy_entities "${policy}" | LC_ALL=C sort -u)"
    actual="$(policy_entities "${arn}" PermissionsPolicy)" || return 1
    while IFS= read -r entity; do
        [ -n "${entity}" ] || continue
        keep=0
        while IFS= read -r expected_entity; do
            if [ "${entity}" = "${expected_entity}" ]; then
                keep=1
                break
            fi
        done <<< "${expected}"
        [ "${keep}" -eq 1 ] || printf '%s\n' "${entity}"
    done <<< "${actual}"
}

wait_for_policy_no_consumers() {
    local policy="$1" arn actual attempt
    arn="$(policy_arn "${policy}")"
    actual='not-yet-checked'
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        actual="$(policy_entities "${arn}" PermissionsPolicy)" \
          || die "could not verify quarantine consumers for ${policy}"
        [ -z "${actual}" ] && return 0
        [ "${attempt}" -eq 10 ] || sleep 2
    done
    die "policy ${policy} consumers did not settle to empty: ${actual//$'\n'/, }"
}

remove_unexpected_policy_entities() {
    local policy="$1" arn actual expected entity expected_entity kind name keep boundaries
    local attempt unexpected
    arn="$(policy_arn "${policy}")"
    expected="$(expected_policy_entities "${policy}" | LC_ALL=C sort -u)"
    actual="$(policy_entities "${arn}" PermissionsPolicy)" \
      || die "could not enumerate permissions-policy consumers for ${policy}"
    while IFS= read -r entity; do
        [ -n "${entity}" ] || continue
        keep=0
        while IFS= read -r expected_entity; do
            if [ "${entity}" = "${expected_entity}" ]; then
                keep=1
                break
            fi
        done <<< "${expected}"
        [ "${keep}" -eq 0 ] || continue
        kind="${entity%%:*}"
        name="${entity#*:}"
        case "${kind}" in
            role) aws iam detach-role-policy --role-name "${name}" --policy-arn "${arn}" \
                    "${AWS_PROFILE_ARGS[@]}" > /dev/null ;;
            user) aws iam detach-user-policy --user-name "${name}" --policy-arn "${arn}" \
                    "${AWS_PROFILE_ARGS[@]}" > /dev/null ;;
            group) aws iam detach-group-policy --group-name "${name}" --policy-arn "${arn}" \
                    "${AWS_PROFILE_ARGS[@]}" > /dev/null ;;
            *) die "unknown IAM entity '${entity}' consuming ${policy}" ;;
        esac
        say "detach ${policy}" "unexpected ${entity}"
    done <<< "${actual}"

    # IAM attachment reads are eventually consistent. Do not restore any role trust while a
    # just-detached foreign consumer can still observe a tracked policy.
    unexpected='not-yet-checked'
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        unexpected="$(unexpected_policy_consumers "${policy}")" \
          || die "could not verify permissions-policy consumers for ${policy}"
        [ -z "${unexpected}" ] && break
        [ "${attempt}" -eq 10 ] || sleep 2
    done
    [ -z "${unexpected}" ] \
      || die "unexpected consumers for ${policy} did not settle: ${unexpected//$'\n'/, }"

    boundaries="$(policy_entities "${arn}" PermissionsBoundary)" \
      || die "could not enumerate permissions-boundary consumers for ${policy}"
    while IFS= read -r entity; do
        [ -n "${entity}" ] || continue
        kind="${entity%%:*}"
        name="${entity#*:}"
        if [ "${kind}" = role ] && is_modeled_role "${name}"; then
            # Removed later, after this role's unexpected attachments and inline policies are
            # gone. Deleting a restrictive boundary first could activate an over-grant.
            continue
        fi
        die "${policy} is a boundary on unmodeled ${entity}; remove or migrate it manually"
    done <<< "${boundaries}"
}

instance_profile_roles() {
    local response
    if ! response="$(aws iam get-instance-profile --instance-profile-name "${POC_PROFILE}" \
      "${AWS_PROFILE_ARGS[@]}" --output json 2>&1)"; then
        [[ "${response}" == *"(NoSuchEntity)"* ]] && return 1
        die "could not read ${POC_PROFILE}: ${response}"
    fi
    python3 -c 'import json,sys; print("\n".join(sorted(x["RoleName"] for x in json.load(sys.stdin)["InstanceProfile"]["Roles"])))' \
      <<< "${response}"
}

instance_profile_path() {
    local response
    if ! response="$(aws iam get-instance-profile --instance-profile-name "${POC_PROFILE}" \
      "${AWS_PROFILE_ARGS[@]}" --output json 2>&1)"; then
        [[ "${response}" == *"(NoSuchEntity)"* ]] && return 1
        die "could not read ${POC_PROFILE}: ${response}"
    fi
    python3 -c 'import json,sys; print(json.load(sys.stdin)["InstanceProfile"].get("Path", ""))' \
      <<< "${response}"
}

instance_profiles_for_role() {
    local role="$1" response
    response="$(aws iam list-instance-profiles-for-role --role-name "${role}" \
      "${AWS_PROFILE_ARGS[@]}" --output json)" || return 1
    python3 -c 'import json,sys; print("\n".join(sorted(x["InstanceProfileName"] for x in json.load(sys.stdin)["InstanceProfiles"])))' \
      <<< "${response}"
}

expected_instance_profiles_for_role() {
    if [ "$1" = "${POC_ROLE}" ]; then
        printf '%s\n' "${POC_PROFILE}"
    fi
    return 0
}

wait_for_instance_profile_roles() {
    local expected="$1" actual attempt
    actual='not-yet-checked'
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        if actual="$(instance_profile_roles)" && [ "${actual}" = "${expected}" ]; then
            return 0
        fi
        [ "${attempt}" -eq 10 ] || sleep 2
    done
    die "${POC_PROFILE} membership did not settle to '${expected}'"
}

wait_for_instance_profile_path() {
    local expected="$1" actual attempt
    actual='not-yet-checked'
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        if actual="$(instance_profile_path)" && [ "${actual}" = "${expected}" ]; then
            return 0
        fi
        [ "${attempt}" -eq 10 ] || sleep 2
    done
    die "${POC_PROFILE} path did not settle to '${expected}'"
}

wait_for_role_instance_profiles() {
    local role="$1" expected="$2" actual attempt
    actual='not-yet-checked'
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        actual="$(instance_profiles_for_role "${role}")" \
          || die "could not verify instance profiles for ${role}"
        if [ "${actual}" = "${expected}" ]; then
            return 0
        fi
        [ "${attempt}" -eq 10 ] || sleep 2
    done
    die "${role} instance-profile associations did not settle to '${expected}'"
}

role_contract_values() {
    local role="$1" response
    response="$(aws iam get-role --role-name "${role}" \
      "${AWS_PROFILE_ARGS[@]}" --output json)" || return 1
    python3 -c '
import json,sys
role=json.load(sys.stdin)["Role"]
print(role.get("Path", ""))
print(role.get("PermissionsBoundary", {}).get("PermissionsBoundaryArn", ""))
print(role.get("MaxSessionDuration", ""))
' <<< "${response}"
}

check_role_contract() {
    local role="$1" expected_duration="$2" expected actual inline tags metadata path boundary duration
    local -a fields
    shift 2
    expected="$(line_set "$@")"
    actual="$(attached_policy_arns "${role}")" || die "could not read attachments for ${role}"
    if [ "${actual}" = "${expected}" ]; then
        say "attachments ${role}" 'in sync'
    else
        say "attachments ${role}" 'DRIFT — attached policy set differs'
        drift=1
    fi

    inline="$(inline_policy_names "${role}")" || die "could not read inline policies for ${role}"
    if [ -z "${inline}" ]; then
        say "inline policies ${role}" 'none'
    else
        say "inline policies ${role}" "DRIFT — unexpected: ${inline//$'\n'/, }"
        drift=1
    fi

    tags="$(role_tags_json "${role}")" || die "could not read tags for ${role}"
    if [ "${tags}" = '[]' ]; then
        say "role tags ${role}" 'none'
    else
        say "role tags ${role}" "DRIFT — unexpected: ${tags}"
        drift=1
    fi

    metadata="$(role_contract_values "${role}")" || die "could not read metadata for ${role}"
    mapfile -t fields <<< "${metadata}"
    path="${fields[0]:-}"
    boundary="${fields[1]:-}"
    duration="${fields[2]:-}"

    if [ "${path}" = '/' ]; then
        say "path ${role}" 'in sync (/)'
    else
        say "path ${role}" "DRIFT — '${path}', expected /"
        drift=1
    fi

    if [ -z "${boundary}" ]; then
        say "permissions boundary ${role}" 'absent'
    else
        say "permissions boundary ${role}" "DRIFT — unexpected: ${boundary}"
        drift=1
    fi

    if [ "${duration}" = "${expected_duration}" ]; then
        say "session duration ${role}" "in sync (${expected_duration})"
    else
        say "session duration ${role}" "DRIFT — ${duration}, expected ${expected_duration}"
        drift=1
    fi
}

echo "== plan =="
iam_lookup() {
    local kind="$1" name="$2" response
    case "${kind}" in
        policy)
            if response="$(aws iam get-policy \
              --policy-arn "arn:aws:iam::${ACCOUNT}:policy/${name}" \
              "${AWS_PROFILE_ARGS[@]}" 2>&1)"; then
                return 0
            fi
            ;;
        role)
            if response="$(aws iam get-role --role-name "${name}" \
              "${AWS_PROFILE_ARGS[@]}" 2>&1)"; then
                return 0
            fi
            ;;
        instance-profile)
            if response="$(aws iam get-instance-profile --instance-profile-name "${name}" \
              "${AWS_PROFILE_ARGS[@]}" 2>&1)"; then
                return 0
            fi
            ;;
        *) die "internal error: unknown IAM lookup kind ${kind}" ;;
    esac
    if [[ "${response}" == *"(NoSuchEntity)"* ]]; then
        return 1
    fi
    die "could not determine whether IAM ${kind} ${name} exists: ${response}"
}
exists_policy() { iam_lookup policy "$1"; }
exists_role() { iam_lookup role "$1"; }
exists_instance_profile() { iam_lookup instance-profile "$1"; }

for p in "${POLICIES[@]}"; do
    if exists_policy "${p}"; then state='exists → new version'; else state='CREATE'; fi
    say "policy ${p}" "${state}"
done
for r in "${CI_ROLE}" "${ADMIN_ROLE}" "${AUDIT_ROLE}" "${POC_ROLE}" "${READER_ROLE}"; do
    if exists_role "${r}"; then state='exists → update trust'; else state='CREATE'; fi
    say "role ${r}" "${state}"
done
if exists_instance_profile "${POC_PROFILE}"; then state='exists'; else state='CREATE'; fi
say "instance profile ${POC_PROFILE}" "${state}"

assert_no_active_lifecycle_runs() {
    local active
    # Use the repository endpoint so a new workflow that is not registered on the default branch
    # yet does not 404 during its prerequisite IAM rollout. Fetch without a status filter so a
    # future/nonstandard GitHub state cannot be mistaken for idle. Match only exact lifecycle
    # filenames, accepting the repo-qualified path form returned for some reusable invocations.
    active="$(gh api --paginate \
      "repos/${OWNER}/${REPO}/actions/runs?per_page=100" \
      --jq '.workflow_runs[]
        | select(.status != "completed")
        | select(.path | test("(^|/)\\.github/workflows/(aws-deploy|aws-reaper|iam-drift)\\.yml(@|$)"))
        | "\(.html_url) (\(.path), \(.status))"')" \
      || die 'could not prove deploy/reaper/IAM workflows have no nonterminal run'
    [ -z "${active}" ] \
      || die "lifecycle automation is active at ${active//$'\n'/, }; retry in a maintenance window"
    say 'GitHub deploy/reaper/IAM attestation' 'idle'
}

preflight_modeled_role_metadata() {
    local role metadata tags expected_profiles actual_profiles instance_profile profile_roles profile_path
    local -a role_fields
    for role in "${CI_ROLE}" "${ADMIN_ROLE}" "${AUDIT_ROLE}" "${POC_ROLE}" "${READER_ROLE}"; do
        if exists_role "${role}"; then
            metadata="$(role_contract_values "${role}")" || die "could not read metadata for ${role}"
            mapfile -t role_fields <<< "${metadata}"
            [ "${role_fields[0]:-}" = '/' ] \
              || die "role ${role} has path '${role_fields[0]:-}'; IAM cannot update role paths in place"

            tags="$(role_tags_json "${role}")" || die "could not preflight tags for ${role}"
            [ "${tags}" = '[]' ] \
              || die "role ${role} has tags ${tags}; refusing every apply write — review and migrate any tag-based ABAC or restrictive policy dependency manually"

            expected_profiles="$(expected_instance_profiles_for_role "${role}")"
            actual_profiles="$(instance_profiles_for_role "${role}")" \
              || die "could not preflight instance profiles for ${role}"
            while IFS= read -r instance_profile; do
                [ -n "${instance_profile}" ] || continue
                if [ -z "${expected_profiles}" ] || \
                  [ "${instance_profile}" != "${expected_profiles}" ]; then
                    die "role ${role} is associated with unexpected instance profile ${instance_profile}; refusing every apply write — detach or migrate that foreign profile manually"
                fi
            done <<< "${actual_profiles}"
        fi
    done

    # The named profile is owned by this repository, but an unmodeled role attached to it is still
    # foreign identity state. Refuse before every write instead of silently detaching that role.
    if exists_instance_profile "${POC_PROFILE}"; then
        profile_path="$(instance_profile_path)" \
          || die "could not preflight ${POC_PROFILE} path"
        [ "${profile_path}" = '/' ] \
          || die "${POC_PROFILE} has path '${profile_path}'; refusing every apply write — an instance profile can be attached to out-of-scope EC2, so migrate its immutable path manually"
        profile_roles="$(instance_profile_roles)" \
          || die "could not preflight ${POC_PROFILE} membership"
        while IFS= read -r role; do
            [ -n "${role}" ] || continue
            [ "${role}" = "${POC_ROLE}" ] \
              || die "${POC_PROFILE} contains unexpected role ${role}; refusing every apply write — detach or migrate that foreign association manually"
        done <<< "${profile_roles}"
    fi
}

# IAM does not support changing an existing role or instance-profile Path in place. Refuse --apply
# before its first write if either is outside the source contract: recreating a role changes its
# principal identity, while recreating a profile could disrupt an out-of-scope EC2 attachment.
# Those are explicit operator migrations. New identities are created at `/` below.
if ${APPLY}; then
    # Quarantining the deployment and instance roles is intentionally fail-closed but disruptive
    # to an in-flight lifecycle or attestation. Prove all three GitHub workflows idle and the
    # repository's AWS footprint/lock empty before the first detach. An operator must resolve
    # either condition; no override exists that could silently strand a deployment.
    assert_no_active_lifecycle_runs
    clean_profile_name=''
    if [ "${PROFILE}" != '--ambient' ]; then
        clean_profile_name="${PROFILE}"
    fi
    env \
      AWS_CLI_PROFILE_NAME="${clean_profile_name}" \
      AWS_ACCOUNT_ID="${ACCOUNT}" \
      AWS_REGION="${REGION}" \
      GITHUB_REPOSITORY_ID="${REPO_ID}" \
      STATE_KEY="${OWNER}/${REPO}/aws-poc.tfstate" \
      CLEAN_PROOF_ATTEMPTS=1 \
      CLEAN_PROOF_DELAY_SECONDS=0 \
      bash "${ROOT}/scripts/assert-aws-clean.sh" > /dev/null \
      || die 'repository-owned resources or the Terraform lock are live; refusing every apply write'
    say 'repository AWS footprint / Terraform lock' 'empty'
    preflight_modeled_role_metadata
    # A permissions boundary on an unmodeled principal is restrictive. Automatically deleting it
    # could activate unrelated broad identity policies, so refuse before the first write. Modeled
    # role boundaries are safe to remove later only after their full attachment contract is clean.
    for p in "${POLICIES[@]}"; do
        exists_policy "${p}" || continue
        arn="$(policy_arn "${p}")"
        boundaries="$(policy_entities "${arn}" PermissionsBoundary)" \
          || die "could not preflight permissions-boundary consumers for ${p}"
        while IFS= read -r entity; do
            [ -n "${entity}" ] || continue
            kind="${entity%%:*}"
            name="${entity#*:}"
            if [ "${kind}" != role ] || ! is_modeled_role "${name}"; then
                die "${p} is a boundary on unmodeled ${entity}; refusing every apply write"
            fi
        done <<< "${boundaries}"
    done
fi

live_policy_matches_version_and_source() {
    local policy="$1" expected_version="$2" arn default_version document response
    arn="$(policy_arn "${policy}")"
    if ! response="$(aws iam get-policy --policy-arn "${arn}" "${AWS_PROFILE_ARGS[@]}" \
      --query Policy.DefaultVersionId --output text 2>&1)"; then
        [[ "${response}" == *"(NoSuchEntity)"* ]] && return 1
        die "could not read default version for ${policy}: ${response}"
    fi
    default_version="${response}"
    [ "${default_version}" = "${expected_version}" ] || return 1
    if ! document="$(aws iam get-policy-version --policy-arn "${arn}" \
      --version-id "${default_version}" "${AWS_PROFILE_ARGS[@]}" \
      --query PolicyVersion.Document --output json 2>&1)"; then
        [[ "${document}" == *"(NoSuchEntity)"* ]] && return 1
        die "could not read ${policy} ${default_version}: ${document}"
    fi
    python3 -S -c '
import json,sys,urllib.parse
def norm(value):
    if isinstance(value, dict):
        return {key: norm(child) for key, child in sorted(value.items())}
    if isinstance(value, list):
        children = [norm(child) for child in value]
        return sorted(children) if all(isinstance(child, str) for child in children) else children
    return value
live = json.load(sys.stdin)
if isinstance(live, str):
    live = json.loads(urllib.parse.unquote(live))
with open(sys.argv[1], encoding="utf-8") as source_handle:
    source = json.load(source_handle)
raise SystemExit(0 if norm(live) == norm(source) else 1)
' "${WORK}/policies/${policy}.json" <<< "${document}"
}

wait_for_live_policy_source() {
    local policy="$1" expected_version="$2" attempt
    [[ "${expected_version}" =~ ^v[1-9][0-9]*$ ]] \
      || die "AWS returned invalid version id '${expected_version}' for ${policy}"
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        if live_policy_matches_version_and_source "${policy}" "${expected_version}"; then
            say "live policy ${policy}" "${expected_version} verified from source"
            return 0
        fi
        [ "${attempt}" -eq 10 ] || sleep 2
    done
    die "${policy} ${expected_version} did not become the exact live default"
}

# ---- drift mode ------------------------------------------------------------------------------
# The gap this closes, learned the hard way 2026-07-29: check-iam-literals.sh compares the SOURCE
# documents to the filesystem, and test-iam-policies.sh MATERIALIZES from source — so both pass
# happily while LIVE IAM still holds an older version. Editing a trust and forgetting to re-apply
# left two repositories whose live trust named a workflow that no longer existed, meaning no CI job
# could assume the deploy role at all. Nothing detected it because nothing compared source to live.
if [ "${DRIFT:-false}" = 'true' ]; then
    drift=0
    for p in "${POLICIES[@]}"; do
        arn="arn:aws:iam::${ACCOUNT}:policy/${p}"
        if ! exists_policy "${p}"; then say "policy ${p}" 'ABSENT LIVE'; drift=1; continue; fi
        v="$(aws iam get-policy --policy-arn "${arn}" "${AWS_PROFILE_ARGS[@]}" --query Policy.DefaultVersionId --output text)"
        aws iam get-policy-version --policy-arn "${arn}" --version-id "${v}" "${AWS_PROFILE_ARGS[@]}" \
            --query PolicyVersion.Document --output json > "${WORK}/live.json"
        if python3 -S -c "
import json,sys,urllib.parse
def norm(x):
    if isinstance(x,dict): return {k:norm(v) for k,v in sorted(x.items())}
    if isinstance(x,list):
        xs=[norm(v) for v in x]
        return sorted(xs) if all(isinstance(v,str) for v in xs) else xs
    return x
l=json.load(open(sys.argv[1]))
if isinstance(l,str): l=json.loads(urllib.parse.unquote(l))
s=json.load(open(sys.argv[2]))
sys.exit(0 if norm(l)==norm(s) else 1)" "${WORK}/live.json" "${WORK}/policies/${p}.json"; then
            say "policy ${p}" "in sync (${v})"
        else
            say "policy ${p}" "DRIFT — live ${v} differs from source"; drift=1
        fi
    done
    for p in "${POLICIES[@]}"; do
        arn="$(policy_arn "${p}")"
        exists_policy "${p}" || continue
        expected="$(expected_policy_entities "${p}" | LC_ALL=C sort -u)"
        actual="$(policy_entities "${arn}" PermissionsPolicy)" \
          || die "could not enumerate permissions-policy consumers for ${p}"
        if [ "${actual}" = "${expected}" ]; then
            say "consumers ${p}" 'in sync'
        else
            say "consumers ${p}" \
              "DRIFT — '${actual//$'\n'/, }', expected '${expected//$'\n'/, }'"
            drift=1
        fi
        boundaries="$(policy_entities "${arn}" PermissionsBoundary)" \
          || die "could not enumerate permissions-boundary consumers for ${p}"
        if [ -z "${boundaries}" ]; then
            say "boundary uses ${p}" 'none'
        else
            say "boundary uses ${p}" "DRIFT — unexpected: ${boundaries//$'\n'/, }"
            drift=1
        fi
    done
    for pair in "${CI_ROLE}:github_${OWNER}_${REPO}.trust.json" \
                "${ADMIN_ROLE}:github_${OWNER}_${REPO}-admin.trust.json" \
                "${AUDIT_ROLE}:github_${OWNER}_${REPO}-iam-audit.trust.json" \
                "${POC_ROLE}:${REPO}-poc-role.trust.json" \
                "${READER_ROLE}:${REPO}-artifact-reader.trust.json"; do
        role="${pair%%:*}"; tf="${pair#*:}"
        if ! exists_role "${role}"; then say "role ${role}" 'ABSENT LIVE'; drift=1; continue; fi
        aws iam get-role --role-name "${role}" "${AWS_PROFILE_ARGS[@]}" --query Role.AssumeRolePolicyDocument --output json > "${WORK}/live.json"
        # IAM stores multi-value principals/conditions as unordered sets and returns them in
        # arbitrary order, so string lists are compared order-insensitively. Compare the whole
        # document so an unexpected top-level field or Version can never hide outside Statement.
        if python3 -S -c "
import json,sys
def norm(x):
    if isinstance(x,dict): return {k:norm(v) for k,v in sorted(x.items())}
    if isinstance(x,list):
        xs=[norm(v) for v in x]
        return sorted(xs) if all(isinstance(v,str) for v in xs) else xs
    return x
sys.exit(0 if norm(json.load(open(sys.argv[1])))==norm(json.load(open(sys.argv[2]))) else 1)" \
            "${WORK}/live.json" "${WORK}/roles/${tf}"; then
            say "trust ${role}" 'in sync'
        else
            say "trust ${role}" 'DRIFT — live differs from source'; drift=1
        fi
    done

    if exists_role "${CI_ROLE}"; then
        check_role_contract "${CI_ROLE}" 7200 "${CI_ATTACHMENTS[@]}"
    fi
    if exists_role "${ADMIN_ROLE}"; then
        check_role_contract "${ADMIN_ROLE}" 3600 "${ADMIN_ATTACHMENTS[@]}"
    fi
    if exists_role "${AUDIT_ROLE}"; then
        check_role_contract "${AUDIT_ROLE}" 3600 "${AUDIT_ATTACHMENTS[@]}"
    fi
    if exists_role "${READER_ROLE}"; then
        check_role_contract "${READER_ROLE}" 3600 "${READER_ATTACHMENTS[@]}"
    fi
    if exists_role "${POC_ROLE}"; then
        check_role_contract "${POC_ROLE}" 3600 "${POC_ATTACHMENTS[@]}"
    fi

    # Prove the profile contract in both directions. Reading only the named profile would miss a
    # tracked role that had also been placed in a foreign profile.
    for role in "${CI_ROLE}" "${ADMIN_ROLE}" "${AUDIT_ROLE}" "${READER_ROLE}" "${POC_ROLE}"; do
        exists_role "${role}" || continue
        expected_profiles="$(expected_instance_profiles_for_role "${role}")"
        actual_profiles="$(instance_profiles_for_role "${role}")" \
          || die "could not enumerate instance profiles for ${role}"
        if [ "${actual_profiles}" = "${expected_profiles}" ]; then
            if [ -n "${expected_profiles}" ]; then
                say "instance profiles ${role}" "in sync (${expected_profiles})"
            else
                say "instance profiles ${role}" 'none'
            fi
        else
            say "instance profiles ${role}" \
              "DRIFT — '${actual_profiles//$'\n'/, }', expected '${expected_profiles//$'\n'/, }'"
            drift=1
        fi
    done

    if exists_instance_profile "${POC_PROFILE}"; then
        profile_roles="$(instance_profile_roles)" || die "could not read ${POC_PROFILE} membership"
        if [ "${profile_roles}" = "${POC_ROLE}" ]; then
            say "instance profile ${POC_PROFILE}" 'in sync'
        else
            say "instance profile ${POC_PROFILE}" \
              "DRIFT — roles='${profile_roles//$'\n'/, }', expected ${POC_ROLE}"
            drift=1
        fi
        profile_path="$(instance_profile_path)" || die "could not read ${POC_PROFILE} path"
        if [ "${profile_path}" = '/' ]; then
            say "instance profile path ${POC_PROFILE}" 'in sync (/)'
        else
            say "instance profile path ${POC_PROFILE}" \
              "DRIFT — '${profile_path}', expected /"
            drift=1
        fi
    else
        say "instance profile ${POC_PROFILE}" 'ABSENT LIVE'
        drift=1
    fi

    [ "${drift}" -eq 0 ] || die 'live IAM has drifted from the tracked source. Re-run with --apply.'
    printf '\nbootstrap-iam: NO DRIFT — live IAM matches the tracked source.\n'
    exit 0
fi

if ! ${APPLY}; then
    printf '\nbootstrap-iam: PLAN ONLY — nothing was written. Re-run with --apply.\n'
    exit 0
fi

echo "== apply =="
live_role_matches_source() {
    local name="$1" trust="$2" duration="$3" response
    if ! response="$(aws iam get-role --role-name "${name}" "${AWS_PROFILE_ARGS[@]}" \
      --output json 2>&1)"; then
        [[ "${response}" == *"(NoSuchEntity)"* ]] && return 1
        die "could not read live role contract for ${name}: ${response}"
    fi
    python3 -S -c '
import json,sys,urllib.parse
def norm(value):
    if isinstance(value, dict):
        return {key: norm(child) for key, child in sorted(value.items())}
    if isinstance(value, list):
        children = [norm(child) for child in value]
        return sorted(children) if all(isinstance(child, str) for child in children) else children
    return value
live_role = json.load(sys.stdin)["Role"]
live_trust = live_role["AssumeRolePolicyDocument"]
if isinstance(live_trust, str):
    live_trust = json.loads(urllib.parse.unquote(live_trust))
with open(sys.argv[1], encoding="utf-8") as source_handle:
    source_trust = json.load(source_handle)
matches = (
    norm(live_trust) == norm(source_trust)
    and live_role.get("Path") == "/"
    and live_role.get("MaxSessionDuration") == int(sys.argv[2])
)
raise SystemExit(0 if matches else 1)
' "${trust}" "${duration}" <<< "${response}"
}

wait_for_live_role_source() {
    local name="$1" trust="$2" duration="$3" attempt
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        if live_role_matches_source "${name}" "${trust}" "${duration}"; then
            say "role ${name}" 'trust, path, and session duration verified from source'
            return 0
        fi
        [ "${attempt}" -eq 10 ] || sleep 2
    done
    die "role trust/metadata reconciliation did not settle for ${name}"
}

apply_role() { # role-name trust-file
    local name="$1" trust="$2" duration="$3" metadata path
    local -a fields
    if exists_role "${name}"; then
        metadata="$(role_contract_values "${name}")" || die "could not read metadata for ${name}"
        mapfile -t fields <<< "${metadata}"
        path="${fields[0]:-}"

        aws iam update-assume-role-policy --role-name "${name}" \
          --policy-document "file://${trust}" "${AWS_PROFILE_ARGS[@]}" > /dev/null
        [ "${path}" = '/' ] || die "refusing unsupported in-place path change for ${name}"
        aws iam update-role --role-name "${name}" --max-session-duration "${duration}" \
          "${AWS_PROFILE_ARGS[@]}" > /dev/null
        say "role ${name}" 'trust and session duration written'
    else
        aws iam create-role --role-name "${name}" --assume-role-policy-document "file://${trust}" \
          --path / --max-session-duration "${duration}" \
          --description "${REPO} - see docs/reference/aws-iam" \
          "${AWS_PROFILE_ARGS[@]}" > /dev/null
        say "role ${name}" 'created'
    fi

    wait_for_live_role_source "${name}" "${trust}" "${duration}"
}

unexpected_role_policy_arns() {
    local role="$1" actual arn expected keep
    shift
    actual="$(attached_policy_arns "${role}")" || return 1
    while IFS= read -r arn; do
        [ -n "${arn}" ] || continue
        keep=0
        for expected in "$@"; do
            if [ "${arn}" = "${expected}" ]; then
                keep=1
                break
            fi
        done
        [ "${keep}" -eq 1 ] || printf '%s\n' "${arn}"
    done <<< "${actual}"
}

wait_for_role_policy_boundary() {
    local role="$1" unexpected inline attempt
    shift
    unexpected='not-yet-checked'; inline='not-yet-checked'
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        unexpected="$(unexpected_role_policy_arns "${role}" "$@")" \
          || die "could not verify attachments for ${role}"
        inline="$(inline_policy_names "${role}")" \
          || die "could not verify inline policies for ${role}"
        if [ -z "${unexpected}" ] && [ -z "${inline}" ]; then
            return 0
        fi
        [ "${attempt}" -eq 10 ] || sleep 2
    done
    die "role ${role} policy quarantine did not settle"
}

strip_unexpected_role_policies() {
    local role="$1" actual arn inline name keep
    shift
    actual="$(attached_policy_arns "${role}")" || die "could not read attachments for ${role}"
    while IFS= read -r arn; do
        [ -n "${arn}" ] || continue
        keep=0
        for expected in "$@"; do
            if [ "${arn}" = "${expected}" ]; then
                keep=1
                break
            fi
        done
        if [ "${keep}" -eq 0 ]; then
            aws iam detach-role-policy --role-name "${role}" --policy-arn "${arn}" \
              "${AWS_PROFILE_ARGS[@]}" > /dev/null
            say "detach ${role}" "${arn}"
        fi
    done <<< "${actual}"

    inline="$(inline_policy_names "${role}")" || die "could not read inline policies for ${role}"
    while IFS= read -r name; do
        [ -n "${name}" ] || continue
        aws iam delete-role-policy --role-name "${role}" --policy-name "${name}" \
          "${AWS_PROFILE_ARGS[@]}" > /dev/null
        say "delete inline ${role}" "${name}"
    done <<< "${inline}"

    wait_for_role_policy_boundary "${role}" "$@"
}

# Quarantine every existing modeled role under its current trust before making a disabled or
# restrictive role assumable. Detach expected policies too: their LIVE default documents may be
# the very drift this apply is repairing, so retaining them across trust activation would let a
# partially failed apply expose stale/broadened permissions. Missing roles have no policies to
# strip and are created unattached below. The exact sets are reattached only after bounded reads
# prove the tracked trust and policy documents have become the live contracts.
if exists_role "${CI_ROLE}"; then
    strip_unexpected_role_policies "${CI_ROLE}"
fi
if exists_role "${ADMIN_ROLE}"; then
    strip_unexpected_role_policies "${ADMIN_ROLE}"
fi
if exists_role "${AUDIT_ROLE}"; then
    strip_unexpected_role_policies "${AUDIT_ROLE}"
fi
if exists_role "${READER_ROLE}"; then
    strip_unexpected_role_policies "${READER_ROLE}"
fi
if exists_role "${POC_ROLE}"; then
    strip_unexpected_role_policies "${POC_ROLE}"
fi

for p in "${POLICIES[@]}"; do
    if exists_policy "${p}"; then
        remove_unexpected_policy_entities "${p}"
        wait_for_policy_no_consumers "${p}"
    fi
done

# Only after the attachment and inverse-consumer boundary is clean may a role's desired trust be
# installed. The reader trust names both GitHub roles as principals, so create/update it after
# those principal ARNs exist; IAM rejects a dangling principal at write time.
apply_role "${CI_ROLE}"    "${WORK}/roles/github_${OWNER}_${REPO}.trust.json" 7200
apply_role "${ADMIN_ROLE}" "${WORK}/roles/github_${OWNER}_${REPO}-admin.trust.json" 3600
apply_role "${AUDIT_ROLE}" "${WORK}/roles/github_${OWNER}_${REPO}-iam-audit.trust.json" 3600
apply_role "${POC_ROLE}"   "${WORK}/roles/${REPO}-poc-role.trust.json" 3600
apply_role "${READER_ROLE}" "${WORK}/roles/${REPO}-artifact-reader.trust.json" 3600

# A restrictive boundary can mask an over-grant. Remove it only after unexpected role policies
# and inverse consumers are gone, so boundary removal cannot transiently activate an extra Allow.
for role in "${CI_ROLE}" "${ADMIN_ROLE}" "${AUDIT_ROLE}" "${READER_ROLE}" "${POC_ROLE}"; do
    metadata="$(role_contract_values "${role}")" || die "could not read metadata for ${role}"
    mapfile -t role_fields <<< "${metadata}"
    if [ -n "${role_fields[1]:-}" ]; then
        aws iam delete-role-permissions-boundary --role-name "${role}" \
          "${AWS_PROFILE_ARGS[@]}" > /dev/null
        say "permissions boundary ${role}" 'removed'
    fi
done

for p in "${POLICIES[@]}"; do
    arn="arn:aws:iam::${ACCOUNT}:policy/${p}"
    if exists_policy "${p}"; then
        # Keep at most five versions: prune the oldest non-default before adding.
        old="$(aws iam list-policy-versions --policy-arn "${arn}" "${AWS_PROFILE_ARGS[@]}" \
               --query 'Versions[?!IsDefaultVersion]|[-1].VersionId' --output text 2>/dev/null)"
        version_count="$(aws iam list-policy-versions --policy-arn "${arn}" \
          "${AWS_PROFILE_ARGS[@]}" --query 'length(Versions)' --output text)"
        if [ "${old}" != 'None' ] && [ -n "${old}" ] && [ "${version_count}" -ge 5 ]; then
            aws iam delete-policy-version --policy-arn "${arn}" --version-id "${old}" \
              "${AWS_PROFILE_ARGS[@]}" > /dev/null
        fi
        new_version="$(aws iam create-policy-version --policy-arn "${arn}" \
          --policy-document "file://${WORK}/policies/${p}.json" --set-as-default \
          "${AWS_PROFILE_ARGS[@]}" --query PolicyVersion.VersionId --output text)" \
          || die "could not publish a new version for ${p}"
        say "policy ${p}" "new default ${new_version}"
    else
        new_version="$(aws iam create-policy --policy-name "${p}" \
          --policy-document "file://${WORK}/policies/${p}.json" \
          --description "${REPO} deploy boundary - see docs/reference/aws-iam" \
          "${AWS_PROFILE_ARGS[@]}" --query Policy.DefaultVersionId --output text)" \
          || die "could not create policy ${p}"
        say "policy ${p}" "created at ${new_version}"
    fi
    wait_for_live_policy_source "${p}" "${new_version}"
done

reconcile_role_policies() {
    local role="$1" arn actual inline tags expected_after metadata attempt
    local -a fields
    shift
    strip_unexpected_role_policies "${role}" "$@"

    for arn in "$@"; do
        aws iam attach-role-policy --role-name "${role}" --policy-arn "${arn}" \
          "${AWS_PROFILE_ARGS[@]}" > /dev/null
    done

    expected_after="$(line_set "$@")"
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        actual="$(attached_policy_arns "${role}")" \
          || die "could not verify attachments for ${role}"
        inline="$(inline_policy_names "${role}")" \
          || die "could not verify inline policies for ${role}"
        tags="$(role_tags_json "${role}")" \
          || die "could not verify tags for ${role}"
        metadata="$(role_contract_values "${role}")" \
          || die "could not verify metadata for ${role}"
        mapfile -t fields <<< "${metadata}"
        if [ "${actual}" = "${expected_after}" ] && [ -z "${inline}" ] && \
          [ "${tags}" = '[]' ] && \
          [ -z "${fields[1]:-}" ]; then
            say "attachments ${role}" \
              'reconciled exactly; inline policies, tags, and boundary absent'
            return 0
        fi
        [ "${attempt}" -eq 10 ] || sleep 2
    done
    die "role attachment/boundary reconciliation did not settle for ${role}"
}

reconcile_role_policies "${CI_ROLE}" "${CI_ATTACHMENTS[@]}"
reconcile_role_policies "${ADMIN_ROLE}" "${ADMIN_ATTACHMENTS[@]}"
reconcile_role_policies "${AUDIT_ROLE}" "${AUDIT_ATTACHMENTS[@]}"
reconcile_role_policies "${READER_ROLE}" "${READER_ATTACHMENTS[@]}"
reconcile_role_policies "${POC_ROLE}" "${POC_ATTACHMENTS[@]}"

reconcile_policy_entities() {
    local policy="$1" arn expected boundaries verified attempt
    arn="$(policy_arn "${policy}")"
    expected="$(expected_policy_entities "${policy}" | LC_ALL=C sort -u)"
    remove_unexpected_policy_entities "${policy}"

    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        verified="$(policy_entities "${arn}" PermissionsPolicy)" \
          || die "could not verify permissions-policy consumers for ${policy}"
        boundaries="$(policy_entities "${arn}" PermissionsBoundary)" \
          || die "could not verify permissions-boundary consumers for ${policy}"
        if [ "${verified}" = "${expected}" ] && [ -z "${boundaries}" ]; then
            say "consumers ${policy}" 'reconciled exactly; boundary uses absent'
            return 0
        fi
        [ "${attempt}" -eq 10 ] || sleep 2
    done
    die "policy consumer/boundary reconciliation did not settle for ${policy}"
}

for p in "${POLICIES[@]}"; do
    reconcile_policy_entities "${p}"
done

if exists_instance_profile "${POC_PROFILE}"; then
    profile_path="$(instance_profile_path)" || die "could not read ${POC_PROFILE} path"
    [ "${profile_path}" = '/' ] \
      || die "${POC_PROFILE} path changed after preflight; refusing to recreate it"
else
    aws iam create-instance-profile --instance-profile-name "${POC_PROFILE}" --path / \
      "${AWS_PROFILE_ARGS[@]}" > /dev/null
    say "instance profile ${POC_PROFILE}" 'created at /'
    wait_for_instance_profile_roles ''
    wait_for_instance_profile_path '/'
fi

profile_roles="$(instance_profile_roles)" || die "could not read ${POC_PROFILE} membership"
if [ -z "${profile_roles}" ]; then
    aws iam add-role-to-instance-profile --instance-profile-name "${POC_PROFILE}" \
      --role-name "${POC_ROLE}" "${AWS_PROFILE_ARGS[@]}" > /dev/null
elif [ "${profile_roles}" != "${POC_ROLE}" ]; then
    die "${POC_PROFILE} gained unexpected membership after preflight; refusing to detach it"
fi
wait_for_instance_profile_roles "${POC_ROLE}"
wait_for_instance_profile_path '/'
for role in "${CI_ROLE}" "${ADMIN_ROLE}" "${AUDIT_ROLE}" "${READER_ROLE}" "${POC_ROLE}"; do
    expected_profiles="$(expected_instance_profiles_for_role "${role}")"
    wait_for_role_instance_profiles "${role}" "${expected_profiles}"
done
say "instance profile ${POC_PROFILE}" 'path and bidirectional membership reconciled exactly'

echo "== verify against the LIVE principal =="
sp() { aws iam simulate-principal-policy --policy-source-arn "arn:aws:iam::${ACCOUNT}:role/${CI_ROLE}" \
       --action-names "$1" --resource-arns "$2" --context-entries "${@:3}" \
       "${AWS_PROFILE_ARGS[@]}" --region "${REGION}" \
       --query 'EvaluationResults[0].EvalDecision' --output text; }
TAGK='ContextKeyName=ec2:ResourceTag/RepositoryId,ContextKeyType=string,ContextKeyValues'
REGK="ContextKeyName=aws:RequestedRegion,ContextKeyType=string,ContextKeyValues=${REGION}"
own_decision="$(sp ec2:TerminateInstances "arn:aws:ec2:${REGION}:${ACCOUNT}:instance/i-0a" \
  "${REGK}" "${TAGK}=${REPO_ID}")" || die 'own-resource simulation failed'
foreign_decision="$(sp ec2:TerminateInstances "arn:aws:ec2:${REGION}:${ACCOUNT}:instance/i-0b" \
  "${REGK}" "${TAGK}=1307854438")" || die 'foreign-resource simulation failed'
escalation_decision="$(sp iam:AttachRolePolicy "arn:aws:iam::${ACCOUNT}:role/${POC_ROLE}" \
  "${REGK}")" || die 'escalation simulation failed'
say 'terminate own tagged instance' "${own_decision}"
say 'terminate secure-wazuh instance' "${foreign_decision}"
say 'iam:AttachRolePolicy (escalation probe)' "${escalation_decision}"
[ "${own_decision}" = allowed ] || die 'own tagged instance is not allowed'
[[ "${foreign_decision}" =~ ^(implicitDeny|explicitDeny)$ ]] || die 'foreign instance is not denied'
[[ "${escalation_decision}" =~ ^(implicitDeny|explicitDeny)$ ]] || die 'IAM escalation is not denied'
printf '\nbootstrap-iam: applied. The pinned framework consumes the standing %s key pair;\nneither this script nor the workflow creates or destroys it.\n' "${KEY_PAIR}"
