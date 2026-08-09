#!/usr/bin/env python3
"""Offline structural assertions for the repository's IAM trust and identity policies."""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
ROLES = ROOT / "docs" / "reference" / "aws-iam" / "roles"
POLICIES = ROOT / "docs" / "reference" / "aws-iam" / "policies"
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

# Canonical-document digests turn every identity-policy edit into a reviewed contract change.
# The field-level assertions below explain the critical boundaries; these digests additionally
# make removal, widening, or insertion under a less-obvious Sid fail closed.
EXPECTED_POLICY_DIGESTS = {
    "github_nwarila-platform_windows-wsus.json": "6000ebd66a8b3e66fade24b5eec588c221882125c761ec786e4683f27aa2f523",
    "github_nwarila-platform_windows-wsus_iam-audit.json": "80ad52d864925445e3d3df07760534fe57a137cf314d4a4d7b9cbc39f890148d",
    "windows-wsus_artifact-assume.json": "d01f270cc7f11ac48bbb9862cf8933da5e633a536d123a7b0abf428eced27963",
    "windows-wsus_artifact-folder.json": "9940186bd44b7d20e9fb8a36fabbb34cad653fefccaf13749a68bfe8d4bbde8d",
    "windows-wsus_artifact-read.json": "a40220bd2c53753d30150f1e87400a5c0843cb00403fabc0c1740488fc51c7b1",
    "windows-wsus_deploy-discovery-iam.json": "0ff1df346dc7fd04864e917e8c95217a007ed01a16cf4acbe30c08305f67097a",
    "windows-wsus_deploy-ec2-launch.json": "3f60a4da6b62bcdcc9d4e9831ac048c300c9f52140faa252711aafea12ea8c7e",
    "windows-wsus_deploy-ec2-lifecycle.json": "723de17825f8c27336dcd36e74949efb4f1e9427e1156bfb717f9136021fe379",
    "windows-wsus_deploy-sg-ssm-kms.json": "605760ee37e6278fd5373845545117fec130c51d5199077c6c27279a29d2554b",
}

EXPECTED_POLICY_SIDS = {
    "github_nwarila-platform_windows-wsus.json": {
        "ReadWriteStateFileOnly",
        "ManageS3LockfileOnly",
        "ListStateBucket",
        "DenyDeleteStateFile",
        "DenyUnencryptedPuts",
        "DenyPutsWithoutEncryptionHeader",
    },
    "github_nwarila-platform_windows-wsus_iam-audit.json": {
        "ReadTrackedManagedPolicyDocuments",
        "ReadTrackedRoleContracts",
        "ReadTrackedInstanceProfile",
        "ReadTrackedRoleInstanceProfiles",
        "ResolveDeploySubnet",
        "ResolveEbsKey",
        "ValidateTrackedDocuments",
    },
    "windows-wsus_artifact-assume.json": {"AssumeOnlyTheWindowsWsusArtifactReader"},
    "windows-wsus_artifact-folder.json": {
        "ReadWriteWindowsWsusTlsArtifacts",
        "DenyUnencryptedArtifactPuts",
        "DenyArtifactPutsWithoutEncryptionHeader",
    },
    "windows-wsus_artifact-read.json": {"ReadOnlyWindowsWsusTlsArtifacts"},
    "windows-wsus_deploy-discovery-iam.json": {
        "DescribeEc2ForTerraformAndDiscovery",
        "GetPocInstanceProfile",
        "InspectPocInstanceRolePolicies",
        "PassOnlyPocInstanceRoleToEc2",
    },
    "windows-wsus_deploy-ec2-launch.json": {
        "RunInstancesTypeLocked",
        "RunInstancesVolumeCapped",
        "RunInstancesEniInDeploySubnet",
        "RunInstancesInDeploySubnet",
        "RunInstancesWithOwnedSecurityGroups",
        "RunInstancesImagesFromTrustedOwners",
        "RunInstancesWithPinnedKeyPair",
        "CreateDataVolumeCapped",
        "CreateEniWithRepoIdentity",
        "UseDeploySubnetForEniCreation",
        "UseOwnedSecurityGroupsForEniCreation",
        "AllocateTaggedElasticIp",
    },
    "windows-wsus_deploy-ec2-lifecycle.json": {
        "GetConsoleOutputForOurInstances",
        "TagOnlyAtCreateTime",
        "MergeTagsOnOwnedVolumes",
        "DenyOverwriteForeignRepoIdentityTag",
        "DenySetWrongRepoIdentityTag",
        "DenyDeleteRepoIdentityTag",
        "DenyDeleteTagsWithoutTagKeys",
        "LifecycleOnlyOnOurTaggedResources",
        "ElasticIpLifecycleOnOurTagged",
        "AssociateEipToOurResources",
        "DisassociateAddressRegionOnly",
        "ModifyMetadataImdsV2Only",
        "ModifyVolumeCapped",
    },
    "windows-wsus_deploy-sg-ssm-kms.json": {
        "ReadKmsAliasesForTerraform",
        "DescribeKmsKeysForTerraform",
        "KmsForEbsCryptographicOperations",
        "KmsGrantForEbsOnly",
        "DescribeSsmManagedInstances",
        "SsmSessionOnlyToOurTaggedInstances",
        "SsmStartSshSessionDocument",
        "SsmSessionTeardownInRegion",
        "CreateTaggedPocSecurityGroups",
        "UseDeployVpcForPocSecurityGroupCreation",
        "TagPocSecurityGroupResourcesAtCreate",
        "ManageTaggedPocSecurityGroupsInDeployVpc",
        "ManagePocSecurityGroupRuleResources",
    },
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


def load_policy(name: str) -> dict[str, Any]:
    with (POLICIES / name).open(encoding="utf-8") as handle:
        return json.load(handle)


def policy_index(
    assertions: Assertions,
    name: str,
    document: dict[str, Any],
) -> dict[str, dict[str, Any]]:
    statements = document.get("Statement")
    assertions.equal(f"{name} version", document.get("Version"), "2012-10-17")
    if not isinstance(statements, list) or not all(isinstance(item, dict) for item in statements):
        assertions.equal(f"{name} statements are a list of mappings", False, True)
        return {}

    index = {
        statement.get("Sid"): statement
        for statement in statements
        if isinstance(statement.get("Sid"), str)
    }
    assertions.equal(f"{name} has unique string Sids", len(index), len(statements))
    assertions.equal(f"{name} exact Sids", set(index), EXPECTED_POLICY_SIDS[name])

    canonical = json.dumps(document, sort_keys=True, separators=(",", ":")).encode()
    assertions.equal(
        f"{name} reviewed semantic digest",
        hashlib.sha256(canonical).hexdigest(),
        EXPECTED_POLICY_DIGESTS[name],
    )
    return index


def exact_statement_fields(
    assertions: Assertions,
    policy_name: str,
    statements: dict[str, dict[str, Any]],
    sid: str,
    *,
    effect: str,
    action: Any,
    resource: Any,
    condition: Any = None,
) -> None:
    statement = statements.get(sid, {})
    assertions.equal(f"{policy_name} {sid} effect", statement.get("Effect"), effect)
    assertions.equal(f"{policy_name} {sid} actions", statement.get("Action"), action)
    assertions.equal(f"{policy_name} {sid} resources", statement.get("Resource"), resource)
    assertions.equal(f"{policy_name} {sid} conditions", statement.get("Condition"), condition)


def only_statement(assertions: Assertions, name: str, document: dict[str, Any]) -> dict[str, Any]:
    statements = document.get("Statement")
    assertions.equal(f"{name} has exactly one statement", len(statements or []), 1)
    if not isinstance(statements, list) or len(statements) != 1 or not isinstance(statements[0], dict):
        return {}
    return statements[0]


def test_identity_policies(assertions: Assertions) -> None:
    on_disk = {path.name for path in POLICIES.glob("*.json")}
    assertions.equal(
        "identity-policy source filename set",
        on_disk,
        set(EXPECTED_POLICY_DIGESTS),
    )
    documents = {
        name: policy_index(assertions, name, load_policy(name))
        for name in EXPECTED_POLICY_DIGESTS
    }
    account = "<account-id>"
    region = "<region>"
    repository_id = "<repository-id>"
    request_tag = {"aws:RequestTag/RepositoryId": repository_id}
    resource_tag = {"ec2:ResourceTag/RepositoryId": repository_id}

    state_name = "github_nwarila-platform_windows-wsus.json"
    state = documents[state_name]
    state_prefix = f"arn:aws:s3:::{account}-terraform/nwarila-platform/windows-wsus"
    exact_statement_fields(
        assertions,
        state_name,
        state,
        "ReadWriteStateFileOnly",
        effect="Allow",
        action=["s3:GetObject", "s3:PutObject"],
        resource=f"{state_prefix}/*.tfstate",
        condition={"StringEquals": {"aws:ResourceAccount": account}},
    )
    exact_statement_fields(
        assertions,
        state_name,
        state,
        "ManageS3LockfileOnly",
        effect="Allow",
        action=["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
        resource=f"{state_prefix}/*.tfstate.tflock",
        condition={"StringEquals": {"aws:ResourceAccount": account}},
    )
    exact_statement_fields(
        assertions,
        state_name,
        state,
        "DenyDeleteStateFile",
        effect="Deny",
        action=["s3:DeleteObject", "s3:DeleteObjectVersion"],
        resource=f"{state_prefix}/*.tfstate",
    )
    exact_statement_fields(
        assertions,
        state_name,
        state,
        "DenyUnencryptedPuts",
        effect="Deny",
        action="s3:PutObject",
        resource=f"{state_prefix}/*",
        condition={"StringNotEquals": {"s3:x-amz-server-side-encryption": "AES256"}},
    )
    exact_statement_fields(
        assertions,
        state_name,
        state,
        "DenyPutsWithoutEncryptionHeader",
        effect="Deny",
        action="s3:PutObject",
        resource=f"{state_prefix}/*",
        condition={"Null": {"s3:x-amz-server-side-encryption": "true"}},
    )

    artifact_name = "windows-wsus_artifact-folder.json"
    artifact = documents[artifact_name]
    artifact_resource = "arn:aws:s3:::<artifact-bucket>/applications/windows-wsus/tls/*"
    exact_statement_fields(
        assertions,
        artifact_name,
        artifact,
        "ReadWriteWindowsWsusTlsArtifacts",
        effect="Allow",
        action=["s3:GetObject", "s3:PutObject"],
        resource=artifact_resource,
        condition={"StringEquals": {"aws:RequestedRegion": region}},
    )
    exact_statement_fields(
        assertions,
        artifact_name,
        artifact,
        "DenyUnencryptedArtifactPuts",
        effect="Deny",
        action="s3:PutObject",
        resource=artifact_resource,
        condition={"StringNotEquals": {"s3:x-amz-server-side-encryption": "AES256"}},
    )
    exact_statement_fields(
        assertions,
        artifact_name,
        artifact,
        "DenyArtifactPutsWithoutEncryptionHeader",
        effect="Deny",
        action="s3:PutObject",
        resource=artifact_resource,
        condition={"Null": {"s3:x-amz-server-side-encryption": "true"}},
    )
    exact_statement_fields(
        assertions,
        "windows-wsus_artifact-read.json",
        documents["windows-wsus_artifact-read.json"],
        "ReadOnlyWindowsWsusTlsArtifacts",
        effect="Allow",
        action="s3:GetObject",
        resource=artifact_resource,
        condition={"StringEquals": {"aws:RequestedRegion": region}},
    )

    discovery_name = "windows-wsus_deploy-discovery-iam.json"
    exact_statement_fields(
        assertions,
        discovery_name,
        documents[discovery_name],
        "PassOnlyPocInstanceRoleToEc2",
        effect="Allow",
        action="iam:PassRole",
        resource=f"arn:aws:iam::{account}:role/windows-wsus-poc-role",
        condition={"StringEquals": {"iam:PassedToService": "ec2.amazonaws.com"}},
    )

    launch_name = "windows-wsus_deploy-ec2-launch.json"
    launch = documents[launch_name]
    exact_statement_fields(
        assertions,
        launch_name,
        launch,
        "RunInstancesTypeLocked",
        effect="Allow",
        action="ec2:RunInstances",
        resource=f"arn:aws:ec2:{region}:*:instance/*",
        condition={
            "NumericLessThanEquals": {"ec2:MetadataHttpPutResponseHopLimit": "1"},
            "StringEquals": {
                **request_tag,
                "ec2:InstanceType": ["t3.medium", "t3.large"],
                "ec2:MetadataHttpTokens": "required",
                "ec2:Tenancy": "default",
            },
        },
    )
    volume_condition = {
        "Bool": {"ec2:Encrypted": "true"},
        "NumericLessThanEquals": {"ec2:VolumeSize": "64"},
        "NumericLessThanEqualsIfExists": {
            "ec2:VolumeIops": "3000",
            "ec2:VolumeThroughput": "125",
        },
        "StringEquals": {**request_tag, "ec2:VolumeType": "gp3"},
    }
    for sid, action in (
        ("RunInstancesVolumeCapped", "ec2:RunInstances"),
        ("CreateDataVolumeCapped", "ec2:CreateVolume"),
    ):
        exact_statement_fields(
            assertions,
            launch_name,
            launch,
            sid,
            effect="Allow",
            action=action,
            resource=f"arn:aws:ec2:{region}:*:volume/*",
            condition=volume_condition,
        )
    deploy_vpc = f"arn:aws:ec2:{region}:*:vpc/<vpc-id>"
    deploy_subnet = f"arn:aws:ec2:{region}:*:subnet/<subnet-id>"
    exact_statement_fields(
        assertions,
        launch_name,
        launch,
        "RunInstancesEniInDeploySubnet",
        effect="Allow",
        action="ec2:RunInstances",
        resource=f"arn:aws:ec2:{region}:*:network-interface/*",
        condition={"ArnLike": {"ec2:Subnet": deploy_subnet, "ec2:Vpc": deploy_vpc}},
    )
    exact_statement_fields(
        assertions,
        launch_name,
        launch,
        "RunInstancesInDeploySubnet",
        effect="Allow",
        action="ec2:RunInstances",
        resource=deploy_subnet,
        condition={"ArnLike": {"ec2:Vpc": deploy_vpc}},
    )
    exact_statement_fields(
        assertions,
        launch_name,
        launch,
        "RunInstancesWithOwnedSecurityGroups",
        effect="Allow",
        action="ec2:RunInstances",
        resource=f"arn:aws:ec2:{region}:*:security-group/*",
        condition={
            "ArnLike": {"ec2:Vpc": deploy_vpc},
            "StringEquals": resource_tag,
        },
    )
    exact_statement_fields(
        assertions,
        launch_name,
        launch,
        "UseDeploySubnetForEniCreation",
        effect="Allow",
        action="ec2:CreateNetworkInterface",
        resource=deploy_subnet,
        condition={
            "ArnLike": {"ec2:Vpc": deploy_vpc},
            "StringEquals": {"aws:RequestedRegion": region},
        },
    )
    exact_statement_fields(
        assertions,
        launch_name,
        launch,
        "UseOwnedSecurityGroupsForEniCreation",
        effect="Allow",
        action="ec2:CreateNetworkInterface",
        resource=f"arn:aws:ec2:{region}:*:security-group/*",
        condition={
            "ArnLike": {"ec2:Vpc": deploy_vpc},
            "StringEquals": {"aws:RequestedRegion": region, **resource_tag},
        },
    )
    key_resource = f"arn:aws:ec2:{region}:{account}:key-pair/<key-pair-name>"
    exact_statement_fields(
        assertions,
        launch_name,
        launch,
        "RunInstancesWithPinnedKeyPair",
        effect="Allow",
        action="ec2:RunInstances",
        resource=key_resource,
    )
    for sid, action, resource in (
        ("CreateEniWithRepoIdentity", "ec2:CreateNetworkInterface", f"arn:aws:ec2:{region}:*:network-interface/*"),
        ("AllocateTaggedElasticIp", "ec2:AllocateAddress", f"arn:aws:ec2:{region}:{account}:elastic-ip/*"),
    ):
        exact_statement_fields(
            assertions,
            launch_name,
            launch,
            sid,
            effect="Allow",
            action=action,
            resource=resource,
            condition={"StringEquals": {**request_tag, "aws:RequestedRegion": region}},
        )

    exact_statement_fields(
        assertions,
        "windows-wsus_artifact-assume.json",
        documents["windows-wsus_artifact-assume.json"],
        "AssumeOnlyTheWindowsWsusArtifactReader",
        effect="Allow",
        action="sts:AssumeRole",
        resource=f"arn:aws:iam::{account}:role/windows-wsus-artifact-reader",
    )

    lifecycle_name = "windows-wsus_deploy-ec2-lifecycle.json"
    lifecycle = documents[lifecycle_name]
    exact_statement_fields(
        assertions,
        lifecycle_name,
        lifecycle,
        "TagOnlyAtCreateTime",
        effect="Allow",
        action="ec2:CreateTags",
        resource=[
            f"arn:aws:ec2:{region}:*:instance/*",
            f"arn:aws:ec2:{region}:*:volume/*",
            f"arn:aws:ec2:{region}:*:network-interface/*",
            f"arn:aws:ec2:{region}:*:elastic-ip/*",
        ],
        condition={
            "StringEquals": {
                **request_tag,
                "ec2:CreateAction": [
                    "RunInstances",
                    "CreateVolume",
                    "CreateNetworkInterface",
                    "AllocateAddress",
                ],
            }
        },
    )
    exact_statement_fields(
        assertions,
        lifecycle_name,
        lifecycle,
        "DenyOverwriteForeignRepoIdentityTag",
        effect="Deny",
        action="ec2:CreateTags",
        resource=f"arn:aws:ec2:{region}:*:*/*",
        condition={
            "Null": {"ec2:ResourceTag/RepositoryId": "false"},
            "StringNotEquals": resource_tag,
        },
    )
    exact_statement_fields(
        assertions,
        lifecycle_name,
        lifecycle,
        "DenySetWrongRepoIdentityTag",
        effect="Deny",
        action="ec2:CreateTags",
        resource=f"arn:aws:ec2:{region}:*:*/*",
        condition={
            "Null": {"aws:RequestTag/RepositoryId": "false"},
            "StringNotEquals": request_tag,
        },
    )
    exact_statement_fields(
        assertions,
        lifecycle_name,
        lifecycle,
        "DenyDeleteRepoIdentityTag",
        effect="Deny",
        action="ec2:DeleteTags",
        resource=f"arn:aws:ec2:{region}:*:*/*",
        condition={
            "ForAnyValue:StringEquals": {
                "aws:TagKeys": "RepositoryId"
            }
        },
    )
    exact_statement_fields(
        assertions,
        lifecycle_name,
        lifecycle,
        "LifecycleOnlyOnOurTaggedResources",
        effect="Allow",
        action=[
            "ec2:TerminateInstances",
            "ec2:StartInstances",
            "ec2:StopInstances",
            "ec2:RebootInstances",
            "ec2:AttachVolume",
            "ec2:DetachVolume",
            "ec2:DeleteVolume",
            "ec2:AttachNetworkInterface",
            "ec2:DetachNetworkInterface",
            "ec2:DeleteNetworkInterface",
            "ec2:ModifyNetworkInterfaceAttribute",
            "ec2:DeleteTags",
        ],
        resource="*",
        condition={
            "StringEquals": {"aws:RequestedRegion": region, **resource_tag}
        },
    )
    exact_statement_fields(
        assertions,
        lifecycle_name,
        lifecycle,
        "ModifyMetadataImdsV2Only",
        effect="Allow",
        action="ec2:ModifyInstanceMetadataOptions",
        resource=f"arn:aws:ec2:{region}:*:instance/*",
        condition={
            "NumericLessThanEqualsIfExists": {
                "ec2:MetadataHttpPutResponseHopLimit": "1"
            },
            "StringEquals": {"aws:RequestedRegion": region, **resource_tag},
            "StringEqualsIfExists": {"ec2:MetadataHttpTokens": "required"},
        },
    )
    exact_statement_fields(
        assertions,
        lifecycle_name,
        lifecycle,
        "ModifyVolumeCapped",
        effect="Allow",
        action="ec2:ModifyVolume",
        resource=f"arn:aws:ec2:{region}:*:volume/*",
        condition={
            "NumericLessThanEqualsIfExists": {
                "ec2:VolumeIops": "3000",
                "ec2:VolumeSize": "64",
                "ec2:VolumeThroughput": "125",
            },
            "StringEquals": {"aws:RequestedRegion": region, **resource_tag},
            "StringEqualsIfExists": {"ec2:VolumeType": "gp3"},
        },
    )

    service_name = "windows-wsus_deploy-sg-ssm-kms.json"
    service = documents[service_name]
    key_arn = f"arn:aws:kms:{region}:{account}:key/<ebs-kms-key-id>"
    exact_statement_fields(
        assertions,
        service_name,
        service,
        "KmsForEbsCryptographicOperations",
        effect="Allow",
        action=["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*"],
        resource=key_arn,
        condition={"StringEquals": {"kms:ViaService": f"ec2.{region}.amazonaws.com"}},
    )
    exact_statement_fields(
        assertions,
        service_name,
        service,
        "KmsGrantForEbsOnly",
        effect="Allow",
        action="kms:CreateGrant",
        resource=key_arn,
        condition={
            "Bool": {"kms:GrantIsForAWSResource": "true"},
            "StringEquals": {"kms:ViaService": f"ec2.{region}.amazonaws.com"},
        },
    )
    exact_statement_fields(
        assertions,
        service_name,
        service,
        "SsmSessionOnlyToOurTaggedInstances",
        effect="Allow",
        action="ssm:StartSession",
        resource=f"arn:aws:ec2:{region}:*:instance/*",
        condition={
            "StringEquals": {
                "ssm:resourceTag/RepositoryId": repository_id
            }
        },
    )
    exact_statement_fields(
        assertions,
        service_name,
        service,
        "SsmSessionTeardownInRegion",
        effect="Allow",
        action=["ssm:TerminateSession", "ssm:ResumeSession"],
        resource=f"arn:aws:ssm:{region}:*:session/${{aws:userid}}-*",
    )
    exact_statement_fields(
        assertions,
        service_name,
        service,
        "CreateTaggedPocSecurityGroups",
        effect="Allow",
        action="ec2:CreateSecurityGroup",
        resource=f"arn:aws:ec2:{region}:*:security-group/*",
        condition={"StringEquals": {**request_tag, "aws:RequestedRegion": region}},
    )
    exact_statement_fields(
        assertions,
        service_name,
        service,
        "ManageTaggedPocSecurityGroupsInDeployVpc",
        effect="Allow",
        action=[
            "ec2:AuthorizeSecurityGroupIngress",
            "ec2:AuthorizeSecurityGroupEgress",
            "ec2:RevokeSecurityGroupIngress",
            "ec2:RevokeSecurityGroupEgress",
            "ec2:ModifySecurityGroupRules",
            "ec2:UpdateSecurityGroupRuleDescriptionsIngress",
            "ec2:UpdateSecurityGroupRuleDescriptionsEgress",
            "ec2:DeleteSecurityGroup",
        ],
        resource=f"arn:aws:ec2:{region}:*:security-group/*",
        condition={
            "ArnLike": {"ec2:Vpc": f"arn:aws:ec2:{region}:*:vpc/<vpc-id>"},
            "StringEquals": {"aws:RequestedRegion": region, **resource_tag},
        },
    )


def main() -> int:
    assertions = Assertions()

    assertions.equal(
        "trust source filename set",
        {path.name for path in ROLES.glob("*.json")},
        {
            "github_nwarila-platform_windows-wsus.trust.json",
            "github_nwarila-platform_windows-wsus-admin.trust.json",
            "github_nwarila-platform_windows-wsus-iam-audit.trust.json",
            "windows-wsus-artifact-reader.trust.json",
            "windows-wsus-poc-role.trust.json",
        },
    )

    ci = load(f"github_{OWNER}_{REPOSITORY}.trust.json")
    ci_statement = only_statement(assertions, "CI trust", ci)
    assertions.equal("CI trust top-level keys", set(ci), {"Version", "Statement"})
    assertions.equal(
        "CI trust statement keys",
        set(ci_statement),
        {"Sid", "Effect", "Principal", "Action", "Condition"},
    )
    assertions.equal("CI trust version", ci.get("Version"), "2012-10-17")
    assertions.equal(
        "CI trust Sid",
        ci_statement.get("Sid"),
        "GitHubActionsForWindowsWsusDeployWorkflows",
    )
    assertions.equal("CI trust effect", ci_statement.get("Effect"), "Allow")
    assertions.equal("CI trust action", ci_statement.get("Action"), "sts:AssumeRoleWithWebIdentity")
    assertions.equal(
        "CI trust principal",
        ci_statement.get("Principal"),
        {
            "Federated": "arn:aws:iam::<account-id>:oidc-provider/"
            "token.actions.githubusercontent.com"
        },
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
    assertions.equal(
        "CI trust exact condition mapping",
        conditions,
        {
            "StringEquals": {
                "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
                "token.actions.githubusercontent.com:repository_id": "<repository-id>",
                "token.actions.githubusercontent.com:ref": "refs/heads/main",
                "token.actions.githubusercontent.com:sub": [
                    f"repo:{OWNER}@<owner-id>/{REPOSITORY}@<repository-id>:ref:refs/heads/main",
                    f"repo:{OWNER}/{REPOSITORY}:ref:refs/heads/main",
                ],
                "token.actions.githubusercontent.com:job_workflow_ref": [
                    f"{OWNER}/{REPOSITORY}/.github/workflows/aws-deploy.yml@refs/heads/main",
                    f"{OWNER}/{REPOSITORY}/.github/workflows/aws-reaper.yml@refs/heads/main",
                ],
            }
        },
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
    assertions.equal("admin trust top-level keys", set(admin), {"Version", "Statement"})
    assertions.equal(
        "admin trust statement keys",
        set(admin_statement),
        {"Sid", "Effect", "Principal", "Action", "Condition"},
    )
    assertions.equal("admin trust version", admin.get("Version"), "2012-10-17")
    assertions.equal("admin trust Sid", admin_statement.get("Sid"), "OrganizationSsoBrokerOnly")
    assertions.equal("admin trust effect", admin_statement.get("Effect"), "Allow")
    assertions.equal("admin trust action", admin_statement.get("Action"), "sts:AssumeRole")
    assertions.equal(
        "admin trust principal",
        admin_statement.get("Principal"),
        {"AWS": "arn:aws:iam::<account-id>:root"},
    )
    assertions.equal(
        "admin SSO principal pattern",
        admin_statement.get("Condition", {}).get("ArnLike", {}).get("aws:PrincipalArn"),
        "arn:aws:iam::<account-id>:role/aws-reserved/sso.amazonaws.com/"
        "AWSReservedSSO_github_nwarila-platform_????????????????",
    )
    assertions.equal(
        "admin trust exact condition mapping",
        admin_statement.get("Condition"),
        {
            "ArnLike": {
                "aws:PrincipalArn": "arn:aws:iam::<account-id>:role/aws-reserved/"
                "sso.amazonaws.com/AWSReservedSSO_github_nwarila-platform_????????????????"
            }
        },
    )

    artifact = load(f"{REPOSITORY}-artifact-reader.trust.json")
    artifact_statement = only_statement(assertions, "artifact-reader trust", artifact)
    assertions.equal("artifact-reader trust top-level keys", set(artifact), {"Version", "Statement"})
    assertions.equal(
        "artifact-reader trust statement keys",
        set(artifact_statement),
        {"Sid", "Effect", "Principal", "Action"},
    )
    assertions.equal("artifact-reader trust version", artifact.get("Version"), "2012-10-17")
    assertions.equal(
        "artifact-reader trust Sid",
        artifact_statement.get("Sid"),
        "ControllerIdentitiesOnly",
    )
    assertions.equal("artifact-reader effect", artifact_statement.get("Effect"), "Allow")
    assertions.equal("artifact-reader action", artifact_statement.get("Action"), "sts:AssumeRole")
    assertions.equal(
        "artifact-reader principal",
        artifact_statement.get("Principal"),
        {
            "AWS": [
                "arn:aws:iam::<account-id>:role/github_nwarila-platform_windows-wsus",
                "arn:aws:iam::<account-id>:role/github_nwarila-platform_windows-wsus-admin",
            ]
        },
    )

    instance = load(f"{REPOSITORY}-poc-role.trust.json")
    instance_statement = only_statement(assertions, "instance trust", instance)
    assertions.equal("instance trust top-level keys", set(instance), {"Version", "Statement"})
    assertions.equal(
        "instance trust statement keys",
        set(instance_statement),
        {"Sid", "Effect", "Principal", "Action", "Condition"},
    )
    assertions.equal("instance trust version", instance.get("Version"), "2012-10-17")
    assertions.equal("instance trust Sid", instance_statement.get("Sid"), "Ec2AssumeForInstanceProfile")
    assertions.equal("instance trust effect", instance_statement.get("Effect"), "Allow")
    assertions.equal("instance trust action", instance_statement.get("Action"), "sts:AssumeRole")
    assertions.equal(
        "instance trust principal",
        instance_statement.get("Principal"),
        {"Service": "ec2.amazonaws.com"},
    )
    assertions.equal(
        "instance SourceAccount",
        instance_statement.get("Condition", {}).get("StringEquals", {}).get("aws:SourceAccount"),
        "<account-id>",
    )
    assertions.equal(
        "instance trust exact condition mapping",
        instance_statement.get("Condition"),
        {"StringEquals": {"aws:SourceAccount": "<account-id>"}},
    )

    audit = load(f"github_{OWNER}_{REPOSITORY}-iam-audit.trust.json")
    audit_statement = only_statement(assertions, "IAM-audit trust", audit)
    assertions.equal("IAM-audit trust top-level keys", set(audit), {"Version", "Statement"})
    assertions.equal(
        "IAM-audit trust statement keys",
        set(audit_statement),
        {"Sid", "Effect", "Principal", "Action", "Condition"},
    )
    assertions.equal("IAM-audit trust version", audit.get("Version"), "2012-10-17")
    assertions.equal(
        "IAM-audit trust Sid",
        audit_statement.get("Sid"),
        "GitHubActionsForWindowsWsusIamDrift",
    )
    assertions.equal("IAM-audit trust effect", audit_statement.get("Effect"), "Allow")
    assertions.equal(
        "IAM-audit trust action",
        audit_statement.get("Action"),
        "sts:AssumeRoleWithWebIdentity",
    )
    assertions.equal(
        "IAM-audit trust principal",
        audit_statement.get("Principal"),
        {
            "Federated": "arn:aws:iam::<account-id>:oidc-provider/"
            "token.actions.githubusercontent.com"
        },
    )
    assertions.equal(
        "IAM-audit trust exact condition mapping",
        audit_statement.get("Condition"),
        {
            "StringEquals": {
                "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
                "token.actions.githubusercontent.com:repository_id": "<repository-id>",
                "token.actions.githubusercontent.com:ref": "refs/heads/main",
                "token.actions.githubusercontent.com:sub": [
                    f"repo:{OWNER}@<owner-id>/{REPOSITORY}@<repository-id>:ref:refs/heads/main",
                    f"repo:{OWNER}/{REPOSITORY}:ref:refs/heads/main",
                ],
                "token.actions.githubusercontent.com:job_workflow_ref":
                    f"{OWNER}/{REPOSITORY}/.github/workflows/iam-drift.yml@refs/heads/main",
            }
        },
    )

    test_identity_policies(assertions)

    for failure in assertions.failures:
        print(f"test-iam-structure: FAIL — {failure}", file=sys.stderr)
    if assertions.failures:
        return 1

    print(f"test-iam-structure: OK — {assertions.count} offline IAM assertion(s) passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
