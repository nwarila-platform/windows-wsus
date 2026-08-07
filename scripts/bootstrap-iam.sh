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
# alias, and the VPC/subnet from the deploy environment. The one exception is the artifact
# bucket — a Layer-0 output nothing in this account uniquely identifies — which must be passed
# as BOOTSTRAP_ARTIFACT_BUCKET (the gate fails closed without it). A key pair is NOT created
# here — it carries private key material whose custody is an operator decision.
# =========================================================================================== #
set -uo pipefail

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
# The deploy subnet's single source of truth is the terraform template — the same file the
# deploy workflow renders — so the IAM subnet pin and the tfvars can never disagree. The VPC
# is derived FROM that subnet (the account holds more than one VPC; a blind Vpcs[0] pick is a
# coin toss).
SUBNET_ID="$(grep -oE 'subnet-[0-9a-f]+' "${ROOT}/terraform/aws.tfvars" | head -1)"
[ -n "${SUBNET_ID}" ] || die 'no subnet_id found in terraform/aws.tfvars'
VPC_ID="$(aws ec2 describe-subnets --subnet-ids "${SUBNET_ID}" --profile "${PROFILE}" --region "${REGION}" \
  --query 'Subnets[0].VpcId' --output text)" || die "subnet ${SUBNET_ID} not found in ${REGION}"
# The org's shared EC2 key pair (secure-wazuh pattern); override only if a per-repo pair is
# ever minted. Its private half is the AWS_EC2_SSH_PRIVATE_KEY Actions secret.
KEY_PAIR="${BOOTSTRAP_KEY_PAIR_NAME:-nwarila-ec2-key}"
# The OIDC subject GitHub actually emits embeds the OWNER id as well as the repository id
# (proven by CloudTrail). Resolve it rather than hard-coding it.
OWNER_ID="$(gh api "orgs/${OWNER}" --jq .id)" || die "cannot resolve owner id for ${OWNER}"
# Layer-0 output, not derivable from this account (see the substitution contract: the bucket
# name grants nothing by itself — the object-key prefix inside the policies is load-bearing).
ARTIFACT_BUCKET="${BOOTSTRAP_ARTIFACT_BUCKET:-}"
[ -n "${ARTIFACT_BUCKET}" ] || die 'BOOTSTRAP_ARTIFACT_BUCKET is unset — the artifact policies cannot materialize (Layer-0 output; see README substitution contract)'
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
mapfile -t POLICIES < <(cd "${WORK}/policies" && ls *.json | sed 's/\.json$//')
DEPLOY_POLICIES=(); ADMIN_ONLY_POLICIES=(); STATE_POLICY=''; READER_POLICY=''
for p in "${POLICIES[@]}"; do
    case "${p}" in
        github_*) STATE_POLICY="${p}" ;;
        *_artifact-read) READER_POLICY="${p}" ;;
        *_artifact-folder|*_artifact-assume) ADMIN_ONLY_POLICIES+=("${p}") ;;
        *_deploy-*) DEPLOY_POLICIES+=("${p}") ;;
        *) die "unclassified policy source '${p}' — extend the classification case deliberately (README role-to-policy table first)" ;;
    esac
done
[ -n "${READER_POLICY}" ] || die 'artifact-read policy source not found'

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
        [ "${old}" != 'None' ] && [ -n "${old}" ] && \
          [ "$(aws iam list-policy-versions --policy-arn "${arn}" --profile "${PROFILE}" --query 'length(Versions)' --output text)" -ge 5 ] && \
          aws iam delete-policy-version --policy-arn "${arn}" --version-id "${old}" --profile "${PROFILE}" >/dev/null 2>&1
        aws iam create-policy-version --policy-arn "${arn}" --policy-document "file://${WORK}/policies/${p}.json" \
            --set-as-default --profile "${PROFILE}" >/dev/null && say "policy ${p}" 'new default version'
    else
        aws iam create-policy --policy-name "${p}" --policy-document "file://${WORK}/policies/${p}.json" \
            --description "${REPO} deploy boundary - see docs/reference/aws-iam" --profile "${PROFILE}" >/dev/null \
            && say "policy ${p}" 'created'
    fi
done

apply_role() { # role-name trust-file
    local name="$1" trust="$2"
    if exists_role "${name}"; then
        aws iam update-assume-role-policy --role-name "${name}" --policy-document "file://${trust}" --profile "${PROFILE}" >/dev/null \
            && say "role ${name}" 'trust updated'
    else
        aws iam create-role --role-name "${name}" --assume-role-policy-document "file://${trust}" \
            --max-session-duration 3600 --description "${REPO} - see docs/reference/aws-iam" --profile "${PROFILE}" >/dev/null \
            && say "role ${name}" 'created'
    fi
}
apply_role "${CI_ROLE}"    "${WORK}/roles/github_${OWNER}_${REPO}.trust.json"
apply_role "${ADMIN_ROLE}" "${WORK}/roles/github_${OWNER}_${REPO}-admin.trust.json"
apply_role "${POC_ROLE}"   "${WORK}/roles/${REPO}-poc-role.trust.json"
# AFTER the CI/admin roles: the reader trust names both as principals, and IAM resolves
# principal ARNs at write time — a dangling principal fails the create.
apply_role "${READER_ROLE}" "${WORK}/roles/${REPO}-artifact-reader.trust.json"

attach() {
    aws iam attach-role-policy --role-name "$1" --policy-arn "$2" --profile "${PROFILE}" >/dev/null 2>&1 \
        || die "could not attach $(basename "$2") to $1 - the role may not exist"
}
for p in "${DEPLOY_POLICIES[@]}"; do
    attach "${CI_ROLE}"    "arn:aws:iam::${ACCOUNT}:policy/${p}"
    attach "${ADMIN_ROLE}" "arn:aws:iam::${ACCOUNT}:policy/${p}"
done
# the state policy goes to BOTH: the admin role's documented local deploy path cannot reach
# Terraform state without it.
attach "${CI_ROLE}"    "arn:aws:iam::${ACCOUNT}:policy/${STATE_POLICY}"
attach "${ADMIN_ROLE}" "arn:aws:iam::${ACCOUNT}:policy/${STATE_POLICY}"
# artifact path per the README role-to-policy table: folder+assume are ADMIN-ONLY (the CI role
# gets neither — it must not write TLS material or assume the reader), read goes to the
# controller-assumed reader role and nowhere else.
for p in "${ADMIN_ONLY_POLICIES[@]}"; do
    attach "${ADMIN_ROLE}" "arn:aws:iam::${ACCOUNT}:policy/${p}"
done
attach "${READER_ROLE}" "arn:aws:iam::${ACCOUNT}:policy/${READER_POLICY}"
attach "${POC_ROLE}"   'arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore'
say 'attachments' 'reconciled'

if ! aws iam get-instance-profile --instance-profile-name "${POC_PROFILE}" --profile "${PROFILE}" >/dev/null 2>&1; then
    aws iam create-instance-profile --instance-profile-name "${POC_PROFILE}" --profile "${PROFILE}" >/dev/null
    aws iam add-role-to-instance-profile --instance-profile-name "${POC_PROFILE}" --role-name "${POC_ROLE}" --profile "${PROFILE}" >/dev/null
    say "instance profile ${POC_PROFILE}" 'created'
fi

echo "== verify against the LIVE principal =="
sp() { aws iam simulate-principal-policy --policy-source-arn "arn:aws:iam::${ACCOUNT}:role/${CI_ROLE}" \
       --action-names "$1" --resource-arns "$2" --context-entries "${@:3}" --profile "${PROFILE}" --region "${REGION}" \
       --query 'EvaluationResults[0].EvalDecision' --output text 2>&1 | tail -1; }
TAGK='ContextKeyName=ec2:ResourceTag/nwarila:management:repository-id,ContextKeyType=string,ContextKeyValues'
REGK="ContextKeyName=aws:RequestedRegion,ContextKeyType=string,ContextKeyValues=${REGION}"
say 'terminate own tagged instance' "$(sp ec2:TerminateInstances "arn:aws:ec2:${REGION}:${ACCOUNT}:instance/i-0a" "${REGK}" "${TAGK}=${REPO_ID}")"
say 'terminate secure-wazuh instance' "$(sp ec2:TerminateInstances "arn:aws:ec2:${REGION}:${ACCOUNT}:instance/i-0b" "${REGK}" "${TAGK}=1307854438")"
say 'iam:AttachRolePolicy (escalation probe)' "$(sp iam:AttachRolePolicy "arn:aws:iam::${ACCOUNT}:role/${POC_ROLE}" "${REGK}")"
printf '\nbootstrap-iam: applied. A key pair (%s) is NOT created here — it carries private key\nmaterial whose custody is an operator decision.\n' "${KEY_PAIR}"
