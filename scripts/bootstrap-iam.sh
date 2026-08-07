#!/usr/bin/env bash
# =========================================================================================== #
# bootstrap-iam.sh — materialize and apply this repository's AWS IAM
# ------------------------------------------------------------------------------------------- #
# Creates the deploy boundary this repository declares: eight customer-managed policies, four
# roles, and the EC2 instance profile. Idempotent — re-running reconciles rather than duplicates,
# so it is safe to run after editing a source document.
#
#   ./scripts/bootstrap-iam.sh [--apply|--check-drift] [aws-profile]
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
# `<account-id>-ansible` convention the playbook consumes. The workflow creates its ephemeral EC2
# key pair; this script only scopes IAM to the key name declared in the tfvars.
# =========================================================================================== #
set -euo pipefail

APPLY=false; DRIFT=false
case "${1:-}" in
    --apply) APPLY=true; shift ;;
    --check-drift) DRIFT=true; shift ;;
esac
PROFILE="${1:-admin}"
REGION="${AWS_REGION:-us-east-1}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IAM_DIR="${ROOT}/docs/reference/aws-iam"
OWNER='nwarila-platform'
REPO="$(basename "${ROOT}")"

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
say() { printf '  %-52s %s\n' "$1" "$2"; }
die() { printf 'bootstrap-iam: FAIL — %s\n' "$1" >&2; exit 1; }

echo "== resolving substitution values from live sources =="
ACCOUNT="$(aws sts get-caller-identity --profile "${PROFILE}" --query Account --output text)" || die 'no AWS identity'
REPO_ID="$(gh api "repos/${OWNER}/${REPO}" --jq .id)" || die "GitHub repo ${OWNER}/${REPO} not found"
KMS_KEY="$(aws kms describe-key --key-id alias/aws/ebs --profile "${PROFILE}" --region "${REGION}" \
           --query 'KeyMetadata.KeyId' --output text)" || die 'alias/aws/ebs unresolved'
# The deploy subnet's single source of truth is terraform/aws.tfvars — the same file the
# deploy workflow passes to terraform verbatim — so the IAM subnet pin and the tfvars can
# never disagree. The VPC
# is derived FROM that subnet (the account holds more than one VPC; a blind Vpcs[0] pick is a
# coin toss).
SUBNET_ID="$(grep -oE 'subnet-[0-9a-f]+' "${ROOT}/terraform/aws.tfvars" | head -1)"
[ -n "${SUBNET_ID}" ] || die 'no subnet_id found in terraform/aws.tfvars'
VPC_ID="$(aws ec2 describe-subnets --subnet-ids "${SUBNET_ID}" --profile "${PROFILE}" --region "${REGION}" \
  --query 'Subnets[0].VpcId' --output text)" || die "subnet ${SUBNET_ID} not found in ${REGION}"
# Keep the IAM key ARN and the workflow/framework input on one source of truth. Refuse multiple
# systems/key names rather than materializing a policy that only some Terraform objects can use.
key_pair_text="$(sed -nE \
  's/^[[:space:]]*key_name[[:space:]]*=[[:space:]]*"([^"]+)"[[:space:]]*$/\1/p' \
  "${ROOT}/terraform/aws.tfvars")" || die 'could not read key_name from terraform/aws.tfvars'
mapfile -t KEY_PAIRS <<< "${key_pair_text}"
[ "${#KEY_PAIRS[@]}" -eq 1 ] || die 'terraform/aws.tfvars must declare exactly one key_name'
KEY_PAIR="${KEY_PAIRS[0]}"
[ "${KEY_PAIR}" = 'windows-wsus-ci' ] || die "unexpected workflow-managed key_name '${KEY_PAIR}'"
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
         --profile "${PROFILE}" --region "${REGION}" \
         --query 'length(findings[?findingType==`ERROR`||findingType==`SECURITY_WARNING`])' --output text)"
    [ "${n}" = 0 ] || die "$(basename "${f}") has ${n} error/security finding(s)"
    say "$(basename "${f}")" 'clean'
done
for f in "${WORK}"/roles/*.json; do
    n="$(aws accessanalyzer validate-policy --policy-type RESOURCE_POLICY --policy-document "file://${f}" \
         --profile "${PROFILE}" --region "${REGION}" \
         --query 'length(findings[?findingType==`ERROR`&&issueCode!=`MISSING_RESOURCE`])' --output text)"
    [ "${n}" = 0 ] || die "$(basename "${f}") has ${n} error(s)"
    say "$(basename "${f}")" 'clean'
done

# ---- the declared object model -------------------------------------------------------------
CI_ROLE="github_${OWNER}_${REPO}"
ADMIN_ROLE="github_${OWNER}_${REPO}-admin"
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
DEPLOY_POLICIES=(); ADMIN_ONLY_POLICIES=(); STATE_POLICY=''; READER_POLICY=''; ASSUME_POLICY=''
for p in "${POLICIES[@]}"; do
    case "${p}" in
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
[ "${#DEPLOY_POLICIES[@]}" -eq 4 ] || die 'expected exactly four deploy policy sources'
[ "${#ADMIN_ONLY_POLICIES[@]}" -eq 1 ] || die 'expected exactly one admin-only policy source'

policy_arn() { printf 'arn:aws:iam::%s:policy/%s\n' "${ACCOUNT}" "$1"; }

CI_ATTACHMENTS=("$(policy_arn "${STATE_POLICY}")" "$(policy_arn "${ASSUME_POLICY}")")
ADMIN_ATTACHMENTS=("$(policy_arn "${STATE_POLICY}")" "$(policy_arn "${ASSUME_POLICY}")")
READER_ATTACHMENTS=("$(policy_arn "${READER_POLICY}")")
POC_ATTACHMENTS=('arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore')
for p in "${DEPLOY_POLICIES[@]}"; do
    CI_ATTACHMENTS+=("$(policy_arn "${p}")")
    ADMIN_ATTACHMENTS+=("$(policy_arn "${p}")")
done
for p in "${ADMIN_ONLY_POLICIES[@]}"; do
    ADMIN_ATTACHMENTS+=("$(policy_arn "${p}")")
done

line_set() {
    (($# > 0)) || return 0
    printf '%s\n' "$@" | LC_ALL=C sort -u
}

attached_policy_arns() {
    local role="$1" response
    response="$(aws iam list-attached-role-policies --role-name "${role}" \
      --profile "${PROFILE}" --output json)" || return 1
    python3 -c 'import json,sys; print("\n".join(sorted(x["PolicyArn"] for x in json.load(sys.stdin)["AttachedPolicies"])))' \
      <<< "${response}"
}

inline_policy_names() {
    local role="$1" response
    response="$(aws iam list-role-policies --role-name "${role}" \
      --profile "${PROFILE}" --output json)" || return 1
    python3 -c 'import json,sys; print("\n".join(sorted(json.load(sys.stdin)["PolicyNames"])))' \
      <<< "${response}"
}

instance_profile_roles() {
    local response
    response="$(aws iam get-instance-profile --instance-profile-name "${POC_PROFILE}" \
      --profile "${PROFILE}" --output json)" || return 1
    python3 -c 'import json,sys; print("\n".join(sorted(x["RoleName"] for x in json.load(sys.stdin)["InstanceProfile"]["Roles"])))' \
      <<< "${response}"
}

check_role_contract() {
    local role="$1" expected_duration="$2" expected actual inline duration
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

    duration="$(aws iam get-role --role-name "${role}" --profile "${PROFILE}" \
      --query Role.MaxSessionDuration --output text)" || die "could not read MaxSessionDuration for ${role}"
    if [ "${duration}" = "${expected_duration}" ]; then
        say "session duration ${role}" "in sync (${expected_duration})"
    else
        say "session duration ${role}" "DRIFT — ${duration}, expected ${expected_duration}"
        drift=1
    fi
}

echo "== plan =="
exists_policy() { aws iam get-policy --policy-arn "arn:aws:iam::${ACCOUNT}:policy/$1" --profile "${PROFILE}" >/dev/null 2>&1; }
exists_role()   { aws iam get-role --role-name "$1" --profile "${PROFILE}" >/dev/null 2>&1; }
for p in "${POLICIES[@]}"; do say "policy ${p}" "$(exists_policy "${p}" && echo 'exists → new version' || echo 'CREATE')"; done
for r in "${CI_ROLE}" "${ADMIN_ROLE}" "${POC_ROLE}" "${READER_ROLE}"; do say "role ${r}" "$(exists_role "${r}" && echo 'exists → update trust' || echo 'CREATE')"; done
say "instance profile ${POC_PROFILE}" "$(aws iam get-instance-profile --instance-profile-name "${POC_PROFILE}" --profile "${PROFILE}" >/dev/null 2>&1 && echo exists || echo CREATE)"

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
        v="$(aws iam get-policy --policy-arn "${arn}" --profile "${PROFILE}" --query Policy.DefaultVersionId --output text)"
        aws iam get-policy-version --policy-arn "${arn}" --version-id "${v}" --profile "${PROFILE}" \
            --query PolicyVersion.Document --output json > "${WORK}/live.json"
        if python3 -S -c "
import json,sys,urllib.parse
l=json.load(open(sys.argv[1]))
if isinstance(l,str): l=json.loads(urllib.parse.unquote(l))
s=json.load(open(sys.argv[2]))
sys.exit(0 if l['Statement']==s['Statement'] else 1)" "${WORK}/live.json" "${WORK}/policies/${p}.json"; then
            say "policy ${p}" "in sync (${v})"
        else
            say "policy ${p}" "DRIFT — live ${v} differs from source"; drift=1
        fi
    done
    for pair in "${CI_ROLE}:github_${OWNER}_${REPO}.trust.json" \
                "${ADMIN_ROLE}:github_${OWNER}_${REPO}-admin.trust.json" \
                "${POC_ROLE}:${REPO}-poc-role.trust.json" \
                "${READER_ROLE}:${REPO}-artifact-reader.trust.json"; do
        role="${pair%%:*}"; tf="${pair#*:}"
        if ! exists_role "${role}"; then say "role ${role}" 'ABSENT LIVE'; drift=1; continue; fi
        aws iam get-role --role-name "${role}" --profile "${PROFILE}" --query Role.AssumeRolePolicyDocument --output json > "${WORK}/live.json"
        # IAM stores multi-value principals/conditions as unordered sets and returns them in
        # arbitrary order, so string lists are compared order-insensitively.
        if python3 -S -c "
import json,sys
def norm(x):
    if isinstance(x,dict): return {k:norm(v) for k,v in x.items()}
    if isinstance(x,list):
        xs=[norm(v) for v in x]
        return sorted(xs) if all(isinstance(v,str) for v in xs) else xs
    return x
sys.exit(0 if norm(json.load(open(sys.argv[1]))['Statement'])==norm(json.load(open(sys.argv[2]))['Statement']) else 1)" \
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
    if exists_role "${READER_ROLE}"; then
        check_role_contract "${READER_ROLE}" 3600 "${READER_ATTACHMENTS[@]}"
    fi
    if exists_role "${POC_ROLE}"; then
        check_role_contract "${POC_ROLE}" 3600 "${POC_ATTACHMENTS[@]}"
    fi

    if aws iam get-instance-profile --instance-profile-name "${POC_PROFILE}" \
      --profile "${PROFILE}" > /dev/null 2>&1; then
        profile_roles="$(instance_profile_roles)" || die "could not read ${POC_PROFILE} membership"
        if [ "${profile_roles}" = "${POC_ROLE}" ]; then
            say "instance profile ${POC_PROFILE}" 'in sync'
        else
            say "instance profile ${POC_PROFILE}" \
              "DRIFT — roles='${profile_roles//$'\n'/, }', expected ${POC_ROLE}"
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
for p in "${POLICIES[@]}"; do
    arn="arn:aws:iam::${ACCOUNT}:policy/${p}"
    if exists_policy "${p}"; then
        # keep at most 5 versions: prune the oldest non-default before adding
        old="$(aws iam list-policy-versions --policy-arn "${arn}" --profile "${PROFILE}" \
               --query 'Versions[?!IsDefaultVersion]|[-1].VersionId' --output text 2>/dev/null)"
        version_count="$(aws iam list-policy-versions --policy-arn "${arn}" \
          --profile "${PROFILE}" --query 'length(Versions)' --output text)"
        if [ "${old}" != 'None' ] && [ -n "${old}" ] && [ "${version_count}" -ge 5 ]; then
            aws iam delete-policy-version --policy-arn "${arn}" --version-id "${old}" \
              --profile "${PROFILE}" > /dev/null
        fi
        aws iam create-policy-version --policy-arn "${arn}" --policy-document "file://${WORK}/policies/${p}.json" \
          --set-as-default --profile "${PROFILE}" > /dev/null
        say "policy ${p}" 'new default version'
    else
        aws iam create-policy --policy-name "${p}" --policy-document "file://${WORK}/policies/${p}.json" \
          --description "${REPO} deploy boundary - see docs/reference/aws-iam" \
          --profile "${PROFILE}" > /dev/null
        say "policy ${p}" 'created'
    fi
done

apply_role() { # role-name trust-file
    local name="$1" trust="$2" duration="$3"
    if exists_role "${name}"; then
        aws iam update-assume-role-policy --role-name "${name}" \
          --policy-document "file://${trust}" --profile "${PROFILE}" > /dev/null
        aws iam update-role --role-name "${name}" --max-session-duration "${duration}" \
          --profile "${PROFILE}" > /dev/null
        say "role ${name}" 'trust and session duration updated'
    else
        aws iam create-role --role-name "${name}" --assume-role-policy-document "file://${trust}" \
          --max-session-duration "${duration}" --description "${REPO} - see docs/reference/aws-iam" \
          --profile "${PROFILE}" > /dev/null
        say "role ${name}" 'created'
    fi
}
apply_role "${CI_ROLE}"    "${WORK}/roles/github_${OWNER}_${REPO}.trust.json" 7200
apply_role "${ADMIN_ROLE}" "${WORK}/roles/github_${OWNER}_${REPO}-admin.trust.json" 3600
apply_role "${POC_ROLE}"   "${WORK}/roles/${REPO}-poc-role.trust.json" 3600
# AFTER the CI/admin roles: the reader trust names both as principals, and IAM resolves
# principal ARNs at write time — a dangling principal fails the create.
apply_role "${READER_ROLE}" "${WORK}/roles/${REPO}-artifact-reader.trust.json" 3600

reconcile_role_policies() {
    local role="$1" actual arn inline name keep expected_after
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
              --profile "${PROFILE}" > /dev/null
            say "detach ${role}" "${arn}"
        fi
    done <<< "${actual}"

    # Remove extras before adding a missing expected policy so a role already at IAM's
    # attachment quota can still converge to the declared set.
    for arn in "$@"; do
        aws iam attach-role-policy --role-name "${role}" --policy-arn "${arn}" \
          --profile "${PROFILE}" > /dev/null
    done

    inline="$(inline_policy_names "${role}")" || die "could not read inline policies for ${role}"
    while IFS= read -r name; do
        [ -n "${name}" ] || continue
        aws iam delete-role-policy --role-name "${role}" --policy-name "${name}" \
          --profile "${PROFILE}" > /dev/null
        say "delete inline ${role}" "${name}"
    done <<< "${inline}"

    actual="$(attached_policy_arns "${role}")" || die "could not verify attachments for ${role}"
    expected_after="$(line_set "$@")"
    [ "${actual}" = "${expected_after}" ] || die "attachment reconciliation failed for ${role}"
    say "attachments ${role}" 'reconciled exactly; inline policies absent'
}

reconcile_role_policies "${CI_ROLE}" "${CI_ATTACHMENTS[@]}"
reconcile_role_policies "${ADMIN_ROLE}" "${ADMIN_ATTACHMENTS[@]}"
reconcile_role_policies "${READER_ROLE}" "${READER_ATTACHMENTS[@]}"
reconcile_role_policies "${POC_ROLE}" "${POC_ATTACHMENTS[@]}"

if ! aws iam get-instance-profile --instance-profile-name "${POC_PROFILE}" \
  --profile "${PROFILE}" > /dev/null 2>&1; then
    aws iam create-instance-profile --instance-profile-name "${POC_PROFILE}" \
      --profile "${PROFILE}" > /dev/null
    say "instance profile ${POC_PROFILE}" 'created'
fi
profile_roles="$(instance_profile_roles)" || die "could not read ${POC_PROFILE} membership"
while IFS= read -r role; do
    [ -n "${role}" ] || continue
    if [ "${role}" != "${POC_ROLE}" ]; then
        aws iam remove-role-from-instance-profile --instance-profile-name "${POC_PROFILE}" \
          --role-name "${role}" --profile "${PROFILE}" > /dev/null
        say "instance profile removed role" "${role}"
    fi
done <<< "${profile_roles}"
profile_roles="$(instance_profile_roles)" || die "could not verify ${POC_PROFILE} membership"
if [ "${profile_roles}" != "${POC_ROLE}" ]; then
    [ -z "${profile_roles}" ] || die "${POC_PROFILE} still contains unexpected roles"
    aws iam add-role-to-instance-profile --instance-profile-name "${POC_PROFILE}" \
      --role-name "${POC_ROLE}" --profile "${PROFILE}" > /dev/null
fi
[ "$(instance_profile_roles)" = "${POC_ROLE}" ] || die "${POC_PROFILE} membership reconciliation failed"
say "instance profile ${POC_PROFILE}" 'reconciled exactly'

echo "== verify against the LIVE principal =="
sp() { aws iam simulate-principal-policy --policy-source-arn "arn:aws:iam::${ACCOUNT}:role/${CI_ROLE}" \
       --action-names "$1" --resource-arns "$2" --context-entries "${@:3}" \
       --profile "${PROFILE}" --region "${REGION}" \
       --query 'EvaluationResults[0].EvalDecision' --output text; }
TAGK='ContextKeyName=ec2:ResourceTag/nwarila:management:repository-id,ContextKeyType=string,ContextKeyValues'
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
printf '\nbootstrap-iam: applied. The workflow, not this bootstrap, imports and destroys the\nephemeral %s key pair.\n' "${KEY_PAIR}"
