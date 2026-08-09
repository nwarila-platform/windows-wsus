# Consumer promotion test for the exact Terraform framework pin. The provider is mocked, so
# this exercises the complete plan and variable-validation graph without AWS credentials or APIs.
mock_provider "aws" {
  alias = "us_east_1"

  # The consumer owns an inline security group on a literal subnet. The framework derives that
  # group's VPC through this lookup; a stable mock value keeps the test provider-neutral.
  mock_data "aws_subnet" {
    defaults = {
      vpc_id = "vpc-quality-gate"
      # v3.0.0 asserts the system's declared zone equals its subnet's real zone. A random mock
      # zone would fail that precondition, so it mirrors the zone declared in aws.tfvars.
      availability_zone = "us-east-1a"
    }
  }

  # Every image is fetched by id and must be verified available before use. Under a mocked
  # provider the state is random, so it is pinned here; the id itself still comes from tfvars.
  mock_data "aws_ami" {
    defaults = {
      state = "available"
    }
  }

  # The framework consumes a pre-existing key pair; the mocked lookup only has to resolve.
  mock_data "aws_key_pair" {
    defaults = {
      key_name = "nwarila-ec2-key"
    }
  }

  # Provider-side validation requires this computed lookup result to retain ARN shape even when
  # mocked. The alias itself still comes from this repository's tfvars.
  mock_data "aws_kms_alias" {
    defaults = {
      target_key_arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000000"
    }
  }
}

variables {
  environment   = "test"
  repository    = "nwarila-platform/windows-wsus"
  repository_id = "123456789"
  commit_sha    = "0123456789abcdef0123456789abcdef01234567"
  run_id        = "1"
}

run "repository_tfvars_are_framework_compatible" {
  command = plan

  assert {
    condition = (
      length(var.all_systems) == 1 &&
      var.all_systems[0].hostname == "wsus-poc-01" &&
      var.all_systems[0].readiness_gate == false
    )
    error_message = "The compatibility test must load this repository's WSUS tfvars, not framework defaults."
  }

  assert {
    condition = (
      length(aws_instance.us_east_1) == 1 &&
      length(aws_network_interface.us_east_1) == 1 &&
      length(aws_security_group.us_east_1) == 1 &&
      length(aws_ebs_volume.us_east_1) == 3 &&
      length(aws_eip.us_east_1) == 1
    )
    error_message = "The WSUS tfvars must render the expected instance, ENI, firewall, data disks, and EIP."
  }
}
