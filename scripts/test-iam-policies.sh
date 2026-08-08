#!/usr/bin/env bash
# =========================================================================================== #
# test-iam-policies.sh — falsifiable tests for this repository's AWS IAM documents
# ------------------------------------------------------------------------------------------- #
# Materializes the IAM sources into a scratch directory using the LIVE account and this
# repository's real GitHub id, then exercises them two ways:
#
#   1. aws accessanalyzer validate-policy   — grammar, condition-key/action validity, findings
#   2. aws iam simulate-custom-policy       — the security PROPERTIES, as pass/fail assertions
#
# Both are READ-ONLY: nothing is created, modified or deleted in AWS. The scratch tree is
# destroyed on exit. Requires an AWS profile with iam:SimulateCustomPolicy and
# access-analyzer:ValidatePolicy.
#
#   ./scripts/test-iam-policies.sh [aws-profile]     (default: admin)
#
# Exit 0 = every assertion held.
# =========================================================================================== #
set -uo pipefail

PROFILE="${1:-admin}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IAM_DIR="${REPO_ROOT}/docs/reference/aws-iam"
OWNER='nwarila-platform'
THIS_REPO='windows-wsus'
SIBLINGS=('pdq-deploy-inventory' 'secure-wazuh')

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
pass=0; fail=0
ok()   { printf '  \033[32m✓\033[0m %-56s %s\n' "$1" "$2"; pass=$((pass+1)); }
bad()  { printf '  \033[31m✗\033[0m %-56s got=%s want=%s\n' "$1" "$2" "$3"; fail=$((fail+1)); }

region_text="$(sed -nE \
  's/^[[:space:]]*region[[:space:]]*=[[:space:]]*"([^"]+)"[[:space:]]*$/\1/p' \
  "${REPO_ROOT}/terraform/aws.tfvars")" || exit 1
mapfile -t REGIONS <<< "${region_text}"
[ "${#REGIONS[@]}" -eq 1 ] || {
    printf 'test-iam-policies: terraform/aws.tfvars must declare exactly one region\n' >&2
    exit 1
}
REGION="${REGIONS[0]//_/-}"
[[ "${REGION}" =~ ^[a-z]{2}(-gov)?-[a-z]+-[0-9]+$ ]] || {
    printf 'test-iam-policies: invalid normalized region %s\n' "${REGION}" >&2
    exit 1
}
if [ -n "${AWS_REGION:-}" ] && [ "${AWS_REGION}" != "${REGION}" ]; then
    printf 'test-iam-policies: AWS_REGION %s disagrees with tfvars %s\n' \
      "${AWS_REGION}" "${REGION}" >&2
    exit 1
fi

# These assertions need no AWS account and are also run by the unprivileged quality workflow.
# Keep them first so a widened trust fails before any credential or network lookup is attempted.
python3 "${REPO_ROOT}/scripts/test-iam-structure.py" || exit 1

echo "== resolving live values =="
ACCOUNT="$(aws sts get-caller-identity --profile "${PROFILE}" --query Account --output text)" || exit 1
REPO_ID="$(gh api "repos/${OWNER}/${THIS_REPO}" --jq .id)" || exit 1
KMS_KEY="$(aws kms describe-key --key-id alias/aws/ebs --profile "${PROFILE}" --region "${REGION}" \
           --query 'KeyMetadata.KeyId' --output text 2>/dev/null || echo '00000000-0000-0000-0000-000000000000')"
declare -A SIB_ID
for s in "${SIBLINGS[@]}"; do SIB_ID["$s"]="$(gh api "repos/${OWNER}/${s}" --jq .id 2>/dev/null || echo 0)"; done
echo "  repository id ${REPO_ID}; siblings $(for s in "${SIBLINGS[@]}"; do printf '%s=%s ' "$s" "${SIB_ID[$s]}"; done)"

# ---- materialize -------------------------------------------------------------------------
mkdir -p "${WORK}/policies" "${WORK}/roles"
cp "${IAM_DIR}/policies/"*.json "${WORK}/policies/"
cp "${IAM_DIR}/roles/"*.json    "${WORK}/roles/"
sed -i "s|<account-id>|${ACCOUNT}|g; s|<repository-id>|${REPO_ID}|g; s|<region>|${REGION}|g;
        s|<vpc-id>|vpc-00000000000000000|g; s|<subnet-id>|subnet-00000000000000000|g;
        s|<ebs-kms-key-id>|${KMS_KEY}|g; s|<key-pair-name>|windows-wsus-ci|g; s|<owner-id>|000000000|g;
        s|<artifact-bucket>|${ACCOUNT}-ansible|g" \
    "${WORK}"/policies/*.json "${WORK}"/roles/*.json

"${REPO_ROOT}/scripts/check-iam-literals.sh" --materialized "${WORK}" >/dev/null \
  && ok "substitution gate (--materialized)" "clean" \
  || bad "substitution gate (--materialized)" "FAIL" "clean"

# ---- 1. grammar + semantics ----------------------------------------------------------------
echo "== validate-policy =="
for f in "${WORK}"/policies/*.json; do
    n="$(aws accessanalyzer validate-policy --policy-type IDENTITY_POLICY \
         --policy-document "file://${f}" --profile "${PROFILE}" --region "${REGION}" \
         --query 'length(findings[?findingType==`ERROR` || findingType==`SECURITY_WARNING`])' --output text 2>&1)"
    [ "${n}" = "0" ] && ok "$(basename "${f}")" "0 error/security findings" \
                     || bad "$(basename "${f}")" "${n}" "0"
done

# ---- 1b. trust documents -------------------------------------------------------------------
# simulate-custom-policy cannot evaluate sts:AssumeRoleWithWebIdentity, so the OIDC and SSO
# hardening has no simulable proof. Validate the grammar and assert the structural properties
# directly instead, so a widened trust cannot pass unnoticed.
#
# MISSING_RESOURCE is expected and filtered: a trust policy has no Resource element by design.
# Verified against secure-wazuh's live, working trust documents, which return the identical code.
echo "== trust documents =="
for f in "${WORK}"/roles/*.json; do
    n="$(aws accessanalyzer validate-policy --policy-type RESOURCE_POLICY \
         --policy-document "file://${f}" --profile "${PROFILE}" --region "${REGION}" \
         --query 'length(findings[?(findingType==`ERROR` && issueCode!=`MISSING_RESOURCE`) || findingType==`SECURITY_WARNING`])' --output text 2>&1)"
    [ "${n}" = "0" ] && ok "$(basename "${f}")" "grammar clean" || bad "$(basename "${f}")" "${n}" "0"
done

trust_assert() { # name jq-expression expected file
    local name="$1" expr="$2" want="$3" file="$4"
    local got; got="$(python3 -S -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(eval(sys.argv[2], {"d": d, "json": json}))' "${WORK}/roles/${file}" "${expr}" 2>&1 | tail -1)"
    [ "${got}" = "${want}" ] && ok "${name}" "${got}" || bad "${name}" "${got}" "${want}"
}
CI_TRUST="github_nwarila-platform_${THIS_REPO}.trust.json"
ADMIN_TRUST="github_nwarila-platform_${THIS_REPO}-admin.trust.json"
AUDIT_TRUST="github_nwarila-platform_${THIS_REPO}-iam-audit.trust.json"
POC_TRUST="${THIS_REPO}-poc-role.trust.json"
C='d["Statement"][0]["Condition"]'

# `sub` MUST list BOTH forms. CloudTrail proves GitHub emits the ID-EMBEDDED subject
# (repo:<owner>@<owner-id>/<repo>@<repo-id>:<context>) for these repositories, not the plain slug
# form. `repository_id` StringEquals is the identity boundary, while exact main-ref suffixes prevent
# feature-branch workflow code from receiving AWS credentials.
trust_assert "OIDC sub lists BOTH subject forms" \
  "len(${C}['StringEquals']['token.actions.githubusercontent.com:sub'])" "2" "${CI_TRUST}"
trust_assert "OIDC sub includes the ID-embedded form GitHub emits" \
  "any('@' in x for x in ${C}['StringEquals']['token.actions.githubusercontent.com:sub'])" "True" "${CI_TRUST}"
trust_assert "OIDC subjects are exact protected-main forms" \
  "set(${C}['StringEquals']['token.actions.githubusercontent.com:sub']) == {'repo:nwarila-platform@000000000/windows-wsus@${REPO_ID}:ref:refs/heads/main', 'repo:nwarila-platform/windows-wsus:ref:refs/heads/main'}" "True" "${CI_TRUST}"
trust_assert "OIDC workflow refs are the exact two protected-main workflows" \
  "set(${C}['StringEquals']['token.actions.githubusercontent.com:job_workflow_ref']) == {'nwarila-platform/windows-wsus/.github/workflows/aws-deploy.yml@refs/heads/main', 'nwarila-platform/windows-wsus/.github/workflows/aws-reaper.yml@refs/heads/main'}" "True" "${CI_TRUST}"
trust_assert "OIDC binds this repository id exactly" \
  "${C}['StringEquals']['token.actions.githubusercontent.com:repository_id']" "${REPO_ID}" "${CI_TRUST}"
trust_assert "OIDC audience is exact" \
  "${C}['StringEquals']['token.actions.githubusercontent.com:aud']" "sts.amazonaws.com" "${CI_TRUST}"
trust_assert "OIDC ref is exact protected main" \
  "${C}['StringEquals']['token.actions.githubusercontent.com:ref']" "refs/heads/main" "${CI_TRUST}"
trust_assert "every OIDC sub names this repository" \
  "all('${THIS_REPO}' in x for x in ${C}['StringEquals']['token.actions.githubusercontent.com:sub'])" "True" "${CI_TRUST}"
trust_assert "IAM audit OIDC workflow ref is exact" \
  "${C}['StringEquals']['token.actions.githubusercontent.com:job_workflow_ref']" \
  "nwarila-platform/windows-wsus/.github/workflows/iam-drift.yml@refs/heads/main" "${AUDIT_TRUST}"
trust_assert "IAM audit OIDC binds this repository id" \
  "${C}['StringEquals']['token.actions.githubusercontent.com:repository_id']" "${REPO_ID}" "${AUDIT_TRUST}"
trust_assert "IAM audit OIDC ref is exact protected main" \
  "${C}['StringEquals']['token.actions.githubusercontent.com:ref']" "refs/heads/main" "${AUDIT_TRUST}"
# The SSO suffix must be hash-bounded, not a trailing wildcard that also matches a future
# permission set named github_<owner>_<anything>.
trust_assert "SSO trust is hash-bounded, not wildcard" \
  "${C}['ArnLike']['aws:PrincipalArn'].endswith('_' + '?'*16)" "True" "${ADMIN_TRUST}"
trust_assert "SSO trust carries no trailing wildcard" \
  "not ${C}['ArnLike']['aws:PrincipalArn'].endswith('*')" "True" "${ADMIN_TRUST}"
# Confused-deputy guard on the instance-profile trust.
trust_assert "instance trust pins SourceAccount" \
  "${C}['StringEquals']['aws:SourceAccount']" "${ACCOUNT}" "${POC_TRUST}"
trust_assert "instance trust principal is ec2" \
  "d['Statement'][0]['Principal']['Service']" "ec2.amazonaws.com" "${POC_TRUST}"

# ---- 2. security properties ----------------------------------------------------------------
simulate() { # action resource context...
    local action="$1" resource="$2"; shift 2
    python3 -S -c '
import json, sys
work, action, resource = sys.argv[1], sys.argv[2], sys.argv[3]
ctx = []
for kv in sys.argv[4:]:
    k, t, v = kv.split("=", 2)
    ctx.append({"ContextKeyName": k, "ContextKeyType": t, "ContextKeyValues": [v]})
ci_policy_names = [
    "github_nwarila-platform_windows-wsus.json",
    "windows-wsus_artifact-assume.json",
    "windows-wsus_deploy-discovery-iam.json",
    "windows-wsus_deploy-ec2-launch.json",
    "windows-wsus_deploy-ec2-lifecycle.json",
    "windows-wsus_deploy-sg-ssm-kms.json",
]
json.dump({"PolicyInputList": [open(work + "/policies/" + name).read() for name in ci_policy_names],
           "ActionNames": [action], "ResourceArns": [resource], "ContextEntries": ctx},
          open(work + "/req.json", "w"))
' "${WORK}" "${action}" "${resource}" "$@"
    aws iam simulate-custom-policy --profile "${PROFILE}" --region "${REGION}" \
        --cli-input-json "file://${WORK}/req.json" \
        --query 'EvaluationResults[0].EvalDecision' --output text 2>&1
}
assert() { # name expected action resource context...
    local name="$1" want="$2"; shift 2
    local got; got="$(simulate "$@" | tail -1)"
    [ "${got}" = "${want}" ] && ok "${name}" "${got}" || bad "${name}" "${got}" "${want}"
}

simulate_audit() { # action resource context...
    local action="$1" resource="$2"; shift 2
    python3 -S -c '
import json, sys
work, action, resource = sys.argv[1], sys.argv[2], sys.argv[3]
ctx = []
for kv in sys.argv[4:]:
    k, t, v = kv.split("=", 2)
    ctx.append({"ContextKeyName": k, "ContextKeyType": t, "ContextKeyValues": [v]})
policy = open(work + "/policies/github_nwarila-platform_windows-wsus_iam-audit.json").read()
json.dump({"PolicyInputList": [policy], "ActionNames": [action], "ResourceArns": [resource],
           "ContextEntries": ctx}, open(work + "/audit-req.json", "w"))
' "${WORK}" "${action}" "${resource}" "$@"
    aws iam simulate-custom-policy --profile "${PROFILE}" --region "${REGION}" \
        --cli-input-json "file://${WORK}/audit-req.json" \
        --query 'EvaluationResults[0].EvalDecision' --output text 2>&1
}
assert_audit() { # name expected action resource context...
    local name="$1" want="$2"; shift 2
    local got; got="$(simulate_audit "$@" | tail -1)"
    [ "${got}" = "${want}" ] && ok "${name}" "${got}" || bad "${name}" "${got}" "${want}"
}

TAG='ec2:ResourceTag/nwarila:management:repository-id'
RTAG='aws:RequestTag/nwarila:management:repository-id'
REG="aws:RequestedRegion=string=${REGION}"
INST="arn:aws:ec2:${REGION}:${ACCOUNT}:instance/i-0test"
VOL="arn:aws:ec2:${REGION}:${ACCOUNT}:volume/vol-0test"
STATE="arn:aws:s3:::${ACCOUNT}-terraform/${OWNER}/${THIS_REPO}"
# The suite materializes DUMMY network ids (see the sed above), so every network-leg assertion
# must use these, not the live vpc/subnet — a leg pinned by ArnLike to the materialized value
# returns implicitDeny for any other ARN, which would make these assertions lie.
VPC_ID='vpc-00000000000000000'
SUBNET_ID='subnet-00000000000000000'
KEY_PAIR='windows-wsus-ci'
KEY_ARN="arn:aws:ec2:${REGION}:${ACCOUNT}:key-pair/${KEY_PAIR}"
ENI="arn:aws:ec2:${REGION}:${ACCOUNT}:network-interface/eni-0test"
SUBNET="arn:aws:ec2:${REGION}:${ACCOUNT}:subnet/${SUBNET_ID}"
SG="arn:aws:ec2:${REGION}:${ACCOUNT}:security-group/sg-0test"
VPCC="ec2:Vpc=string=arn:aws:ec2:${REGION}:${ACCOUNT}:vpc/${VPC_ID}"
SUBC="ec2:Subnet=string=arn:aws:ec2:${REGION}:${ACCOUNT}:subnet/${SUBNET_ID}"

echo "== read-only IAM drift boundary =="
AUDIT_POLICY_ARN="arn:aws:iam::${ACCOUNT}:policy/github_nwarila-platform_windows-wsus_iam-audit"
STATE_POLICY_ARN="arn:aws:iam::${ACCOUNT}:policy/github_nwarila-platform_windows-wsus"
AUDIT_ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/github_nwarila-platform_windows-wsus-iam-audit"
CI_ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/github_nwarila-platform_windows-wsus"
POC_ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/windows-wsus-poc-role"
PROFILE_ARN="arn:aws:iam::${ACCOUNT}:instance-profile/windows-wsus-poc-profile"
KMS_ARN="arn:aws:kms:${REGION}:${ACCOUNT}:key/${KMS_KEY}"
assert_audit "audit reads tracked policy metadata" allowed iam:GetPolicy "${STATE_POLICY_ARN}"
assert_audit "audit reads tracked policy document" allowed iam:GetPolicyVersion "${AUDIT_POLICY_ARN}"
assert_audit "audit enumerates tracked policy consumers" allowed iam:ListEntitiesForPolicy \
  "${STATE_POLICY_ARN}"
assert_audit "audit reads tracked role trust" allowed iam:GetRole "${AUDIT_ROLE_ARN}"
assert_audit "audit lists tracked role attachments" allowed iam:ListAttachedRolePolicies "${CI_ROLE_ARN}"
assert_audit "audit lists tracked role inline policies" allowed iam:ListRolePolicies "${CI_ROLE_ARN}"
assert_audit "audit lists tracked role tags" allowed iam:ListRoleTags "${CI_ROLE_ARN}"
assert_audit "audit reads tracked instance profile" allowed iam:GetInstanceProfile "${PROFILE_ARN}"
assert_audit "audit lists POC role instance profiles" allowed iam:ListInstanceProfilesForRole \
  "${POC_ROLE_ARN}"
assert_audit "audit resolves deploy subnet" allowed ec2:DescribeSubnets "*" "${REG}"
assert_audit "audit resolves exact EBS key" allowed kms:DescribeKey "${KMS_ARN}"
assert_audit "audit validates tracked documents" allowed access-analyzer:ValidatePolicy "*" "${REG}"
assert_audit "audit cannot read an untracked policy" implicitDeny iam:GetPolicy \
  "arn:aws:iam::${ACCOUNT}:policy/untracked"
assert_audit "audit cannot enumerate an untracked policy" implicitDeny iam:ListEntitiesForPolicy \
  "arn:aws:iam::${ACCOUNT}:policy/untracked"
assert_audit "audit cannot read an untracked role" implicitDeny iam:GetRole \
  "arn:aws:iam::${ACCOUNT}:role/untracked"
assert_audit "audit cannot list tags on an untracked role" implicitDeny iam:ListRoleTags \
  "arn:aws:iam::${ACCOUNT}:role/untracked"
assert_audit "audit cannot list profiles for an untracked role" implicitDeny \
  iam:ListInstanceProfilesForRole "arn:aws:iam::${ACCOUNT}:role/untracked"
assert_audit "audit cannot mutate a tracked role" implicitDeny iam:UpdateRole "${AUDIT_ROLE_ARN}"
assert_audit "audit cannot create policies" implicitDeny iam:CreatePolicy \
  "arn:aws:iam::${ACCOUNT}:policy/untracked"
assert_audit "audit cannot resolve subnets out of region" implicitDeny ec2:DescribeSubnets "*" \
  "aws:RequestedRegion=string=us-west-2"
assert_audit "audit cannot describe another KMS key" implicitDeny kms:DescribeKey \
  "arn:aws:kms:${REGION}:${ACCOUNT}:key/11111111-1111-1111-1111-111111111111"
assert_audit "audit cannot mutate EC2" implicitDeny ec2:TerminateInstances "${INST}" "${REG}"

echo "== cross-repository isolation (the identity tag is the only separator) =="
assert "terminate own instance"        allowed      ec2:TerminateInstances "${INST}" "${REG}" "${TAG}=string=${REPO_ID}"
for s in "${SIBLINGS[@]}"; do
  assert "terminate ${s} instance"     implicitDeny ec2:TerminateInstances "${INST}" "${REG}" "${TAG}=string=${SIB_ID[$s]}"
  assert "SSM shell into ${s}"         implicitDeny ssm:StartSession       "${INST}" "ssm:resourceTag/nwarila:management:repository-id=string=${SIB_ID[$s]}"
  assert "write ${s} tfstate"          implicitDeny s3:PutObject "arn:aws:s3:::${ACCOUNT}-terraform/${OWNER}/${s}/aws.tfstate" \
                                                    "aws:ResourceAccount=string=${ACCOUNT}" "s3:x-amz-server-side-encryption=string=AES256"
done
assert "delete own volume"             allowed      ec2:DeleteVolume "${VOL}" "${REG}" "${TAG}=string=${REPO_ID}"
assert "detach a sibling's volume"     implicitDeny ec2:DetachVolume "${VOL}" "${REG}" "${TAG}=string=${SIB_ID[${SIBLINGS[0]}]}"

echo "== launch controls =="
assert "t3.medium, IMDSv2, hop 1, tagged" allowed   ec2:RunInstances "${INST}" "ec2:InstanceType=string=t3.medium" \
       "ec2:Tenancy=string=default" "ec2:MetadataHttpTokens=string=required" \
       "ec2:MetadataHttpPutResponseHopLimit=numeric=1" "${RTAG}=string=${REPO_ID}"
assert "disallowed instance type"      implicitDeny ec2:RunInstances "${INST}" "ec2:InstanceType=string=m6i.xlarge" \
       "ec2:Tenancy=string=default" "ec2:MetadataHttpTokens=string=required" "${RTAG}=string=${REPO_ID}"
assert "IMDSv1 at launch"              implicitDeny ec2:RunInstances "${INST}" "ec2:InstanceType=string=t3.medium" \
       "ec2:Tenancy=string=default" "ec2:MetadataHttpTokens=string=optional" "${RTAG}=string=${REPO_ID}"
assert "dedicated tenancy"             implicitDeny ec2:RunInstances "${INST}" "ec2:InstanceType=string=t3.medium" \
       "ec2:Tenancy=string=dedicated" "ec2:MetadataHttpTokens=string=required" "${RTAG}=string=${REPO_ID}"
assert "untagged launch"               implicitDeny ec2:RunInstances "${INST}" "ec2:InstanceType=string=t3.medium" \
       "ec2:Tenancy=string=default" "ec2:MetadataHttpTokens=string=required"

echo "== RunInstances: EVERY resource leg (a launch needs ALL of them) =="
# The ec2:Subnet defect denied the subnet and security-group legs while the instance leg — the only
# leg the suite asserted — stayed green. One assertion per leg is the only shape that catches it.
assert "leg: instance"          allowed      ec2:RunInstances "${INST}" "ec2:InstanceType=string=t3.medium" \
       "ec2:Tenancy=string=default" "ec2:MetadataHttpTokens=string=required" \
       "ec2:MetadataHttpPutResponseHopLimit=numeric=1" "${RTAG}=string=${REPO_ID}"
assert "leg: volume"            allowed      ec2:RunInstances "${VOL}" "${REG}" "ec2:VolumeType=string=gp3" \
       "ec2:VolumeSize=numeric=50" "ec2:Encrypted=boolean=true" "${RTAG}=string=${REPO_ID}"
assert "leg: network-interface" allowed      ec2:RunInstances "${ENI}" "${VPCC}" "${SUBC}"
assert "leg: subnet"            allowed      ec2:RunInstances "${SUBNET}" "${VPCC}"
assert "leg: owned security-group" allowed   ec2:RunInstances "${SG}" "${VPCC}" \
       "${TAG}=string=${REPO_ID}"
assert "leg: untagged security-group -> deny" implicitDeny ec2:RunInstances "${SG}" "${VPCC}"
assert "leg: foreign security-group -> deny" implicitDeny ec2:RunInstances "${SG}" "${VPCC}" \
       "${TAG}=string=${SIB_ID[${SIBLINGS[0]}]}"
assert "leg: image (amazon)"    allowed      ec2:RunInstances "arn:aws:ec2:${REGION}::image/ami-0test" "ec2:Owner=string=amazon"
assert "leg: key-pair (pinned)" allowed      ec2:RunInstances "${KEY_ARN}"
# refuter correction: the positive key-pair assertion cannot fail (no Condition, and both sides are
# built from the same variable). The negative is the shape that fails if the ARN is widened.
assert "leg: key-pair OTHER -> deny" implicitDeny ec2:RunInstances "arn:aws:ec2:${REGION}:${ACCOUNT}:key-pair/some-other-key"
assert "leg: image marketplace -> deny" implicitDeny ec2:RunInstances "arn:aws:ec2:${REGION}::image/ami-0test" "ec2:Owner=string=aws-marketplace"
assert "ENI in a FOREIGN subnet -> deny" implicitDeny ec2:RunInstances "${ENI}" "${VPCC}" \
       "ec2:Subnet=string=arn:aws:ec2:${REGION}:${ACCOUNT}:subnet/subnet-0foreign"

echo "== CreateNetworkInterface: created resource and exact supporting legs =="
assert "create repository-tagged ENI" allowed ec2:CreateNetworkInterface "${ENI}" \
       "${REG}" "${RTAG}=string=${REPO_ID}"
assert "create untagged ENI -> deny" implicitDeny ec2:CreateNetworkInterface "${ENI}" "${REG}"
assert "create foreign-tagged ENI -> deny" implicitDeny ec2:CreateNetworkInterface "${ENI}" \
       "${REG}" "${RTAG}=string=${SIB_ID[${SIBLINGS[0]}]}"
assert "create ENI in exact subnet" allowed ec2:CreateNetworkInterface "${SUBNET}" \
       "${REG}" "${VPCC}"
assert "create ENI in foreign subnet -> deny" implicitDeny ec2:CreateNetworkInterface \
       "arn:aws:ec2:${REGION}:${ACCOUNT}:subnet/subnet-0foreign" "${REG}" "${VPCC}"
assert "create ENI with owned security group" allowed ec2:CreateNetworkInterface "${SG}" \
       "${REG}" "${VPCC}" "${TAG}=string=${REPO_ID}"
assert "create ENI with untagged security group -> deny" implicitDeny \
       ec2:CreateNetworkInterface "${SG}" "${REG}" "${VPCC}"
assert "create ENI with foreign security group -> deny" implicitDeny \
       ec2:CreateNetworkInterface "${SG}" "${REG}" "${VPCC}" \
       "${TAG}=string=${SIB_ID[${SIBLINGS[0]}]}"
assert "create ENI with owned security group in foreign VPC -> deny" implicitDeny \
       ec2:CreateNetworkInterface "${SG}" "${REG}" \
       "ec2:Vpc=string=arn:aws:ec2:${REGION}:${ACCOUNT}:vpc/vpc-0foreign" \
       "${TAG}=string=${REPO_ID}"

echo "== ephemeral key-pair lifecycle =="
assert "import exact key with repository tag" allowed ec2:ImportKeyPair "${KEY_ARN}" \
       "${REG}" "${RTAG}=string=${REPO_ID}"
assert "import key without repository tag" implicitDeny ec2:ImportKeyPair "${KEY_ARN}" "${REG}"
assert "import key with foreign repository tag" implicitDeny ec2:ImportKeyPair "${KEY_ARN}" \
       "${REG}" "${RTAG}=string=${SIB_ID[${SIBLINGS[0]}]}"
assert "import a different key name" implicitDeny ec2:ImportKeyPair \
       "arn:aws:ec2:${REGION}:${ACCOUNT}:key-pair/some-other-key" \
       "${REG}" "${RTAG}=string=${REPO_ID}"
assert "tag imported key at create time" allowed ec2:CreateTags "${KEY_ARN}" \
       "ec2:CreateAction=string=ImportKeyPair" "${RTAG}=string=${REPO_ID}"
assert "tag imported key without identity" implicitDeny ec2:CreateTags "${KEY_ARN}" \
       "ec2:CreateAction=string=ImportKeyPair"
assert "tag imported key with foreign identity" explicitDeny ec2:CreateTags "${KEY_ARN}" \
       "ec2:CreateAction=string=ImportKeyPair" "${RTAG}=string=${SIB_ID[${SIBLINGS[0]}]}"
assert "delete owned ephemeral key" allowed ec2:DeleteKeyPair "${KEY_ARN}" \
       "${REG}" "${TAG}=string=${REPO_ID}"
assert "delete key without ownership tag" implicitDeny ec2:DeleteKeyPair "${KEY_ARN}" "${REG}"
assert "delete foreign-owned key" implicitDeny ec2:DeleteKeyPair "${KEY_ARN}" \
       "${REG}" "${TAG}=string=${SIB_ID[${SIBLINGS[0]}]}"
assert "delete a different key name" implicitDeny ec2:DeleteKeyPair \
       "arn:aws:ec2:${REGION}:${ACCOUNT}:key-pair/some-other-key" \
       "${REG}" "${TAG}=string=${REPO_ID}"

echo "== omitted-key bypass (a condition avoided by omission is not a control) =="
# Every one of these omits the key entirely. If the result is `allowed`, the control is decoration.
assert "hop limit OMITTED -> deny"  implicitDeny ec2:RunInstances "${INST}" "ec2:InstanceType=string=t3.medium" \
       "ec2:Tenancy=string=default" "ec2:MetadataHttpTokens=string=required" "${RTAG}=string=${REPO_ID}"
assert "DeleteTags with TagKeys OMITTED -> deny" explicitDeny ec2:DeleteTags "${INST}" "${REG}" \
       "${TAG}=string=${REPO_ID}"
assert "CreateVolume Encrypted OMITTED -> deny" implicitDeny ec2:CreateVolume "${VOL}" "${REG}" \
       "ec2:VolumeType=string=gp3" "ec2:VolumeSize=numeric=30" "${RTAG}=string=${REPO_ID}"

echo "== volume controls =="
assert "encrypted gp3 within cap"      allowed      ec2:CreateVolume "${VOL}" "${REG}" "ec2:VolumeType=string=gp3" \
       "ec2:VolumeSize=numeric=30" "ec2:Encrypted=boolean=true" "${RTAG}=string=${REPO_ID}"
assert "UNENCRYPTED volume"            implicitDeny ec2:CreateVolume "${VOL}" "${REG}" "ec2:VolumeType=string=gp3" \
       "ec2:VolumeSize=numeric=30" "ec2:Encrypted=boolean=false" "${RTAG}=string=${REPO_ID}"
assert "oversized volume"              implicitDeny ec2:CreateVolume "${VOL}" "${REG}" "ec2:VolumeType=string=gp3" \
       "ec2:VolumeSize=numeric=500" "ec2:Encrypted=boolean=true" "${RTAG}=string=${REPO_ID}"
assert "non-gp3 volume type"           implicitDeny ec2:CreateVolume "${VOL}" "${REG}" "ec2:VolumeType=string=io2" \
       "ec2:VolumeSize=numeric=30" "ec2:Encrypted=boolean=true" "${RTAG}=string=${REPO_ID}"

echo "== identity-tag tamper Denies (explicit) =="
assert "retag a foreign-owned resource" explicitDeny ec2:CreateTags "${VOL}" "${REG}" \
       "${TAG}=string=${SIB_ID[${SIBLINGS[0]}]}" "${RTAG}=string=${REPO_ID}"
assert "stamp a foreign identity"       explicitDeny ec2:CreateTags "${INST}" "${REG}" \
       "ec2:CreateAction=string=RunInstances" "${RTAG}=string=${SIB_ID[${SIBLINGS[0]}]}"
assert "delete the identity tag"        explicitDeny ec2:DeleteTags "${INST}" "${REG}" \
       "${TAG}=string=${REPO_ID}" "aws:TagKeys=string=nwarila:management:repository-id"

echo "== PassRole =="
assert "pass own instance role"         allowed      iam:PassRole "arn:aws:iam::${ACCOUNT}:role/${THIS_REPO}-poc-role" \
       "iam:PassedToService=string=ec2.amazonaws.com"
assert "pass a sibling's instance role" implicitDeny iam:PassRole "arn:aws:iam::${ACCOUNT}:role/${SIBLINGS[1]}-poc-role" \
       "iam:PassedToService=string=ec2.amazonaws.com"
assert "pass own role to a non-EC2"     implicitDeny iam:PassRole "arn:aws:iam::${ACCOUNT}:role/${THIS_REPO}-poc-role" \
       "iam:PassedToService=string=lambda.amazonaws.com"

echo "== state protection =="
assert "write own state, encrypted"     allowed      s3:PutObject "${STATE}/aws.tfstate" \
       "aws:ResourceAccount=string=${ACCOUNT}" "s3:x-amz-server-side-encryption=string=AES256"
assert "write own state UNENCRYPTED"    explicitDeny s3:PutObject "${STATE}/aws.tfstate" \
       "aws:ResourceAccount=string=${ACCOUNT}" "s3:x-amz-server-side-encryption=string=AES128"
assert "write own state, no header"     explicitDeny s3:PutObject "${STATE}/aws.tfstate" \
       "aws:ResourceAccount=string=${ACCOUNT}"
assert "delete own state"               explicitDeny s3:DeleteObject "${STATE}/aws.tfstate" \
       "aws:ResourceAccount=string=${ACCOUNT}"

echo "== region lock =="
assert "terminate out of region"        implicitDeny ec2:TerminateInstances \
       "arn:aws:ec2:us-west-2:${ACCOUNT}:instance/i-0test" "aws:RequestedRegion=string=us-west-2" "${TAG}=string=${REPO_ID}"

echo
printf 'test-iam-policies: %d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]
