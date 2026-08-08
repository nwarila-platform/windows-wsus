#!/usr/bin/env python3
"""Offline tests for the fail-closed EC2 dependency-graph proof."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "assert-aws-resource-graph.py"
spec = importlib.util.spec_from_file_location("aws_resource_graph", SCRIPT)
assert spec and spec.loader
graph = importlib.util.module_from_spec(spec)
spec.loader.exec_module(graph)

REPOSITORY_ID = "1316209092"
RUN_ID = "42"


def tag_list(run_id: str = RUN_ID, repository_id: str = REPOSITORY_ID, **extra: str):
    values = {
        graph.REPOSITORY_TAG: repository_id,
        graph.STACK_TAG: "aws-poc",
        graph.ENVIRONMENT_TAG: "test",
        graph.RUN_TAG: run_id,
        **extra,
    }
    return [{"Key": key, "Value": value} for key, value in values.items()]


def healthy_inventory():
    volumes = [
        {
            "VolumeId": "vol-root",
            "Tags": tag_list(Function="wsus"),
            "Attachments": [{"InstanceId": "i-owned"}],
        },
        *[
            {
                "VolumeId": f"vol-{function.lower()}",
                "Tags": tag_list(Function=function),
                "Attachments": [{"InstanceId": "i-owned"}],
            }
            for function in graph.EXPECTED_DATA_FUNCTIONS
        ],
    ]
    instance = {
        "InstanceId": "i-owned",
        "Tags": tag_list(Function="wsus"),
        "RootDeviceName": "/dev/sda1",
        "NetworkInterfaces": [{"NetworkInterfaceId": "eni-owned"}],
        "BlockDeviceMappings": [
            {"DeviceName": device, "Ebs": {"VolumeId": volume["VolumeId"]}}
            for device, volume in zip(("/dev/sda1", "/dev/sdf", "/dev/sdg", "/dev/sdh"), volumes)
        ],
    }
    interface = {
        "NetworkInterfaceId": "eni-owned",
        "TagSet": tag_list(),
        "Attachment": {"InstanceId": "i-owned"},
        "Association": {"AllocationId": "eipalloc-owned"},
        "PrivateIpAddresses": [
            {
                "PrivateIpAddress": "10.0.0.10",
                "Association": {"AllocationId": "eipalloc-owned"},
            }
        ],
    }
    address = {
        "AllocationId": "eipalloc-owned",
        "Tags": tag_list(),
        "NetworkInterfaceId": "eni-owned",
        "InstanceId": "i-owned",
    }
    return graph.Inventory.from_fixture(
        REPOSITORY_ID, [instance], [interface], volumes, [address], RUN_ID
    )


class ResourceGraphTests(unittest.TestCase):
    def test_healthy_exact_graph_and_wsus_disks_pass(self):
        healthy_inventory().validate(require_wsus_data_volumes=True)

    def test_empty_preclean_graph_passes(self):
        graph.Inventory.from_fixture(REPOSITORY_ID, [], [], [], []).validate()

    def test_foreign_attached_volume_fails(self):
        inventory = healthy_inventory()
        inventory.volumes["vol-wsusdb"]["Tags"] = tag_list(run_id="41")
        with self.assertRaisesRegex(graph.GraphError, "belongs to run 41; expected 42"):
            inventory.validate(require_wsus_data_volumes=True)

    def test_foreign_eip_association_fails_from_eni_reverse_edge(self):
        inventory = healthy_inventory()
        inventory.addresses["eipalloc-owned"]["Tags"] = tag_list(
            repository_id="999999999"
        )
        with self.assertRaisesRegex(graph.GraphError, "foreign or malformed"):
            inventory.validate()

    def test_foreign_eip_on_secondary_private_ip_fails_reverse_edge(self):
        inventory = healthy_inventory()
        inventory.addresses["eipalloc-foreign"] = {
            "AllocationId": "eipalloc-foreign",
            "Tags": tag_list(repository_id="999999999"),
            "NetworkInterfaceId": "eni-owned",
        }
        inventory.interfaces["eni-owned"]["PrivateIpAddresses"].append(
            {
                "PrivateIpAddress": "10.0.0.11",
                "Association": {"AllocationId": "eipalloc-foreign"},
            }
        )
        with self.assertRaisesRegex(graph.GraphError, "foreign or malformed"):
            inventory.validate()

    def test_missing_desired_data_volume_fails_before_guest_formatting(self):
        inventory = healthy_inventory()
        volume = inventory.volumes.pop("vol-wsusdata")
        inventory.instances["i-owned"]["BlockDeviceMappings"].remove(
            {"DeviceName": "/dev/sdg", "Ebs": {"VolumeId": volume["VolumeId"]}}
        )
        with self.assertRaisesRegex(graph.GraphError, "exactly three data volumes"):
            inventory.validate(require_wsus_data_volumes=True)

    def test_root_volume_cannot_substitute_for_a_missing_wsus_disk(self):
        inventory = healthy_inventory()
        inventory.volumes["vol-root"]["Tags"] = tag_list(Function="WSUSDB")
        inventory.volumes["vol-wsusdb"]["Tags"] = tag_list(Function="archive")
        with self.assertRaisesRegex(graph.GraphError, "root volume carries a reserved"):
            inventory.validate(require_wsus_data_volumes=True)

    def test_extra_same_run_disk_fails_exact_cardinality(self):
        inventory = healthy_inventory()
        extra = {
            "VolumeId": "vol-extra",
            "Tags": tag_list(Function="archive"),
            "Attachments": [{"InstanceId": "i-owned"}],
        }
        inventory.volumes["vol-extra"] = extra
        inventory.instances["i-owned"]["BlockDeviceMappings"].append(
            {"DeviceName": "/dev/sdi", "Ebs": {"VolumeId": "vol-extra"}}
        )
        with self.assertRaisesRegex(graph.GraphError, "exactly three data volumes"):
            inventory.validate(require_wsus_data_volumes=True)

    def test_terraform_state_ids_are_unioned_with_tag_discovery(self):
        inventory = graph.Inventory.from_fixture(REPOSITORY_ID, [], [], [], [])
        state = {
            "values": {
                "root_module": {
                    "child_modules": [
                        {
                            "resources": [
                                {
                                    "mode": "managed",
                                    "type": "aws_instance",
                                    "values": {"id": "i-deadbeef"},
                                }
                            ]
                        }
                    ]
                }
            }
        }
        retagged = {
            "InstanceId": "i-deadbeef",
            "Tags": tag_list(repository_id="999999999"),
            "NetworkInterfaces": [],
            "BlockDeviceMappings": [],
        }
        with mock.patch.object(
            graph,
            "aws_json",
            return_value={"Reservations": [{"Instances": [retagged]}]},
        ):
            inventory.include_terraform_state(state)
        with self.assertRaisesRegex(graph.GraphError, "foreign or malformed"):
            inventory.validate()

    def test_destroyed_resource_left_in_state_is_treated_as_absent(self):
        inventory = graph.Inventory.from_fixture(REPOSITORY_ID, [], [], [], [])
        state = {
            "values": {
                "root_module": {
                    "resources": [
                        {
                            "mode": "managed",
                            "type": "aws_instance",
                            "values": {"id": "i-deadbeef"},
                        }
                    ]
                }
            }
        }
        with mock.patch.object(graph, "aws_json", return_value={"Reservations": []}):
            inventory.include_terraform_state(state)
        inventory.validate()

    def test_state_lookup_authorization_failure_is_never_absence(self):
        inventory = graph.Inventory.from_fixture(REPOSITORY_ID, [], [], [], [])
        state = {
            "values": {
                "root_module": {
                    "resources": [
                        {
                            "mode": "managed",
                            "type": "aws_instance",
                            "values": {"id": "i-deadbeef"},
                        }
                    ]
                }
            }
        }
        denied = graph.GraphError(
            "AWS ec2 describe-instances failed: An error occurred (AccessDenied)"
        )
        with mock.patch.object(graph, "aws_json", side_effect=denied):
            with self.assertRaisesRegex(graph.GraphError, "AccessDenied"):
                inventory.include_terraform_state(state)

    def test_owned_orphan_volume_reverse_edge_is_still_checked_in_disk_mode(self):
        inventory = healthy_inventory()
        inventory.volumes["vol-orphan"] = {
            "VolumeId": "vol-orphan",
            "Tags": tag_list(),
            "Attachments": [{"InstanceId": "i-foreign"}],
        }
        foreign = {
            "InstanceId": "i-foreign",
            "Tags": tag_list(repository_id="999999999"),
            "NetworkInterfaces": [],
            "BlockDeviceMappings": [],
        }
        with mock.patch.object(inventory, "instance", return_value=foreign):
            with self.assertRaisesRegex(graph.GraphError, "foreign or malformed"):
                inventory.validate(require_wsus_data_volumes=True)

    def test_aws_api_failure_never_becomes_an_empty_graph(self):
        failed = subprocess.CompletedProcess(
            ["aws"], returncode=73, stdout="", stderr="AccessDenied"
        )
        with mock.patch.object(graph.subprocess, "run", return_value=failed):
            with self.assertRaisesRegex(graph.GraphError, "AccessDenied"):
                graph.aws_json("ec2", "describe-instances")

    def test_successful_malformed_aws_response_never_becomes_empty(self):
        with mock.patch.object(graph, "aws_json", return_value={}):
            with self.assertRaisesRegex(graph.GraphError, "Reservations"):
                graph.Inventory(REPOSITORY_ID)

    def test_malformed_optional_edge_mapping_is_not_ignored(self):
        inventory = healthy_inventory()
        inventory.interfaces["eni-owned"]["Association"] = []
        with self.assertRaisesRegex(graph.GraphError, "malformed Association"):
            inventory.validate()


if __name__ == "__main__":
    unittest.main()
