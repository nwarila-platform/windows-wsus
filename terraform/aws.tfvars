# =========================================================================================== #
# File: 'terraform/aws.tfvars'
# --- [ Description ] ----------------------------------------------------------------------- #
#
# Variable input for the pinned aws-terraform-framework (SHA in .github/terraform-framework-pin).
# Plain tfvars — the workflow passes this file to terraform verbatim. This repository declares
# no .tf files of its own: resources live in the pinned framework, configuration in the pinned
# ansible-framework plus this repository's roles.
#
# Reachability is SSH (22) or WinRM (5986) through the run-scoped group the framework creates for
# the runner's address. The account has no NAT and no VPC endpoints.
#
# The 2019 client uses the EC2Launch v2 image because the pinned readiness check needs EC2Launch v2.
# readiness_gate is false because credential_resolver owns the bounded connection wait.
#
# =========================================================================================== #

# The workflow passes the environment and deployment identity with highest-precedence -var flags.

all_systems = [
  {
    region   = "us_east_1"
    hostname = "tcnaw-wsus01"
    # The ratified availability-zone spec lock, and a subnet in this account's only VPC.
    availability_zone = "us-east-1c"
    subnet_id         = "subnet-03a855e712be7b399"
    # The framework consumes the standing key pair; its private half remains on the runner.
    key_name = "nwarila-ec2-key"
    # The instance reuses the organization-owned profile; this repository never modifies it.
    iam_instance_profile = "nwarila-ec2-profile"
    aws_kms_alias        = "aws/ebs"
    # License-included SQL Server 2022 Standard: Express's 10 GiB ceiling is too small for SUSDB.
    # Not a STIG image, because no STIG image carries SQL Server.
    ami = "ami-0c1499dbc4eaf1bf6"
    # A refresh replaces the operating system while retaining the three standalone data volumes.
    refresh = true
    # SQL Server Standard has no license-included SKU for a smaller burstable instance type.
    instance_type              = "t3.xlarge"
    connection_type            = "ssh"
    readiness_user             = null
    readiness_gate             = false
    readiness_command          = null
    readiness_script_dir       = null
    readiness_private_key_path = null
    imds_hop_limit             = 1
    set_state                  = null
    tags = {
      Function = "wsus"
      Backup   = false
    }
    root_block_device = {
      delete_on_termination = true
      iops                  = null
      tags                  = {}
      throughput            = null
      volume_type           = "gp3"
      volume_size           = "75"
    }
    # Stable Function tags let the disk role resolve volumes without relying on enumeration order.
    ebs_block_devices = [
      {
        resource_key = "wsusdb"
        device_index = 0
        iops         = null
        snapshot_id  = null
        skip_destroy = false
        tags         = { Function = "WSUSDB" }
        throughput   = null
        volume_type  = "gp3"
        volume_size  = "20"
      },
      {
        resource_key = "wsusdata"
        device_index = 1
        iops         = null
        snapshot_id  = null
        skip_destroy = false
        tags         = { Function = "WSUSDATA" }
        throughput   = null
        volume_type  = "gp3"
        volume_size  = "30"
      },
      {
        resource_key = "wsusiis"
        device_index = 2
        iops         = null
        snapshot_id  = null
        skip_destroy = false
        tags         = { Function = "WSUSIIS" }
        throughput   = null
        volume_type  = "gp3"
        volume_size  = "20"
      }
    ]
    ami_block_device_overrides = []
    network_interfaces = [
      {
        description     = "tcnaw-wsus01 CI firewall"
        interface_type  = null
        private_ip      = null
        security_groups = []
        # Client traffic needs TLS metadata on 8531 and signed update payloads on HTTP 8530.
        # 10.69.0.0/16 is the on-prem estate. Rules name CIDRs because a client's security-group id
        # does not exist until apply.
        ingress = [
          {
            description                  = "WSUS metadata over HTTPS from the VPC"
            ip_protocol                  = "tcp"
            from_port                    = 8531
            to_port                      = 8531
            cidr_ipv4                    = "10.0.0.0/16"
            prefix_list_id               = null
            referenced_security_group_id = null
          },
          {
            description                  = "WSUS metadata over HTTPS from the estate"
            ip_protocol                  = "tcp"
            from_port                    = 8531
            to_port                      = 8531
            cidr_ipv4                    = "10.69.0.0/16"
            prefix_list_id               = null
            referenced_security_group_id = null
          },
          {
            description                  = "WSUS update payloads over HTTP from the VPC"
            ip_protocol                  = "tcp"
            from_port                    = 8530
            to_port                      = 8530
            cidr_ipv4                    = "10.0.0.0/16"
            prefix_list_id               = null
            referenced_security_group_id = null
          },
          {
            description                  = "WSUS update payloads over HTTP from the estate"
            ip_protocol                  = "tcp"
            from_port                    = 8530
            to_port                      = 8530
            cidr_ipv4                    = "10.69.0.0/16"
            prefix_list_id               = null
            referenced_security_group_id = null
          }
        ]
        # The guest reaches only OpenVPN and the S3-staged OpenSSH capability.
        egress = [
          {
            description                  = "OpenVPN tunnel out"
            ip_protocol                  = "udp"
            from_port                    = 1194
            to_port                      = 1194
            cidr_ipv4                    = "0.0.0.0/0"
            prefix_list_id               = null
            referenced_security_group_id = null
          },
          {
            # The S3 prefix list blocks direct Microsoft Update and preserves client attribution.
            description                  = "OpenSSH Feature-on-Demand cab from S3"
            ip_protocol                  = "tcp"
            from_port                    = 443
            to_port                      = 443
            cidr_ipv4                    = null
            prefix_list_id               = "pl-63a5400a"
            referenced_security_group_id = null
          }
        ]
        tags = {}
      }
    ]
    # No Elastic IP: the subnet assigns the public address used by the run-scoped access group.
    associate_public_ip = false
  },
  {
    # Server 2019 client reached through WinRM with the EC2 launch password before the join.
    region                     = "us_east_1"
    hostname                   = "tcnaw-wsusc01"
    availability_zone          = "us-east-1c"
    subnet_id                  = "subnet-03a855e712be7b399"
    key_name                   = "nwarila-ec2-key"
    iam_instance_profile       = "nwarila-ec2-profile"
    aws_kms_alias              = "aws/ebs"
    ami                        = "ami-0373950d5ba064b67"
    refresh                    = false
    instance_type              = "t3.medium"
    connection_type            = "winrm"
    readiness_user             = null
    readiness_gate             = false
    readiness_command          = null
    readiness_script_dir       = null
    readiness_private_key_path = null
    imds_hop_limit             = 1
    set_state                  = null
    tags = {
      Function = "wsus_client"
      Backup   = false
    }
    root_block_device = {
      delete_on_termination = true
      iops                  = null
      tags                  = {}
      throughput            = null
      volume_type           = "gp3"
      volume_size           = "50"
    }
    ebs_block_devices = [

    ]
    ami_block_device_overrides = []
    network_interfaces = [
      {
        description     = "tcnaw-wsusc01 CI firewall"
        interface_type  = null
        private_ip      = null
        security_groups = []
        ingress = [

        ]
        egress = [
          {
            description                  = "OpenVPN tunnel out"
            ip_protocol                  = "udp"
            from_port                    = 1194
            to_port                      = 1194
            cidr_ipv4                    = "0.0.0.0/0"
            prefix_list_id               = null
            referenced_security_group_id = null
          },
          {
            description                  = "WSUS metadata over HTTPS in the VPC"
            ip_protocol                  = "tcp"
            from_port                    = 8531
            to_port                      = 8531
            cidr_ipv4                    = "10.0.0.0/16"
            prefix_list_id               = null
            referenced_security_group_id = null
          },
          {
            description                  = "WSUS metadata over HTTPS across the tunnel"
            ip_protocol                  = "tcp"
            from_port                    = 8531
            to_port                      = 8531
            cidr_ipv4                    = "10.69.0.0/16"
            prefix_list_id               = null
            referenced_security_group_id = null
          },
          {
            description                  = "WSUS update payloads over HTTP in the VPC"
            ip_protocol                  = "tcp"
            from_port                    = 8530
            to_port                      = 8530
            cidr_ipv4                    = "10.0.0.0/16"
            prefix_list_id               = null
            referenced_security_group_id = null
          },
          {
            description                  = "WSUS update payloads over HTTP across the tunnel"
            ip_protocol                  = "tcp"
            from_port                    = 8530
            to_port                      = 8530
            cidr_ipv4                    = "10.69.0.0/16"
            prefix_list_id               = null
            referenced_security_group_id = null
          }
        ]
        tags = {}
      }
    ]
    associate_public_ip = false
  },
  {
    # Server 2022 client that deliberately proves SSH password authentication.
    region                     = "us_east_1"
    hostname                   = "tcnaw-wsusc02"
    availability_zone          = "us-east-1c"
    subnet_id                  = "subnet-03a855e712be7b399"
    key_name                   = "nwarila-ec2-key"
    iam_instance_profile       = "nwarila-ec2-profile"
    aws_kms_alias              = "aws/ebs"
    ami                        = "ami-0ed58a129008c2cc2"
    refresh                    = false
    instance_type              = "t3.medium"
    connection_type            = "ssh"
    readiness_user             = null
    readiness_gate             = false
    readiness_command          = null
    readiness_script_dir       = null
    readiness_private_key_path = null
    imds_hop_limit             = 1
    set_state                  = null
    # The play reads Authentication; the inventory does not.
    tags = {
      Function       = "wsus_client"
      Authentication = "password"
      Backup         = false
    }
    root_block_device = {
      delete_on_termination = true
      iops                  = null
      tags                  = {}
      throughput            = null
      volume_type           = "gp3"
      volume_size           = "50"
    }
    ebs_block_devices = [

    ]
    ami_block_device_overrides = []
    network_interfaces = [
      {
        description     = "tcnaw-wsusc02 CI firewall"
        interface_type  = null
        private_ip      = null
        security_groups = []
        ingress = [

        ]
        egress = [
          {
            description                  = "OpenVPN tunnel out"
            ip_protocol                  = "udp"
            from_port                    = 1194
            to_port                      = 1194
            cidr_ipv4                    = "0.0.0.0/0"
            prefix_list_id               = null
            referenced_security_group_id = null
          },
          {
            description                  = "WSUS metadata over HTTPS in the VPC"
            ip_protocol                  = "tcp"
            from_port                    = 8531
            to_port                      = 8531
            cidr_ipv4                    = "10.0.0.0/16"
            prefix_list_id               = null
            referenced_security_group_id = null
          },
          {
            description                  = "WSUS metadata over HTTPS across the tunnel"
            ip_protocol                  = "tcp"
            from_port                    = 8531
            to_port                      = 8531
            cidr_ipv4                    = "10.69.0.0/16"
            prefix_list_id               = null
            referenced_security_group_id = null
          },
          {
            description                  = "WSUS update payloads over HTTP in the VPC"
            ip_protocol                  = "tcp"
            from_port                    = 8530
            to_port                      = 8530
            cidr_ipv4                    = "10.0.0.0/16"
            prefix_list_id               = null
            referenced_security_group_id = null
          },
          {
            description                  = "WSUS update payloads over HTTP across the tunnel"
            ip_protocol                  = "tcp"
            from_port                    = 8530
            to_port                      = 8530
            cidr_ipv4                    = "10.69.0.0/16"
            prefix_list_id               = null
            referenced_security_group_id = null
          },
          {
            # The S3 prefix list blocks direct Microsoft Update and preserves client attribution.
            description                  = "OpenSSH Feature-on-Demand cab from S3"
            ip_protocol                  = "tcp"
            from_port                    = 443
            to_port                      = 443
            cidr_ipv4                    = null
            prefix_list_id               = "pl-63a5400a"
            referenced_security_group_id = null
          }
        ]
        tags = {}
      }
    ]
    associate_public_ip = false
  },
  {
    # Server 2025 client reached through SSH keys before and after the join.
    region                     = "us_east_1"
    hostname                   = "tcnaw-wsusc03"
    availability_zone          = "us-east-1c"
    subnet_id                  = "subnet-03a855e712be7b399"
    key_name                   = "nwarila-ec2-key"
    iam_instance_profile       = "nwarila-ec2-profile"
    aws_kms_alias              = "aws/ebs"
    ami                        = "ami-00d8aa800578d8b12"
    refresh                    = false
    instance_type              = "t3.medium"
    connection_type            = "ssh"
    readiness_user             = null
    readiness_gate             = false
    readiness_command          = null
    readiness_script_dir       = null
    readiness_private_key_path = null
    imds_hop_limit             = 1
    set_state                  = null
    tags = {
      Function = "wsus_client"
      Backup   = false
    }
    root_block_device = {
      delete_on_termination = true
      iops                  = null
      tags                  = {}
      throughput            = null
      volume_type           = "gp3"
      volume_size           = "50"
    }
    ebs_block_devices = [

    ]
    ami_block_device_overrides = []
    network_interfaces = [
      {
        description     = "tcnaw-wsusc03 CI firewall"
        interface_type  = null
        private_ip      = null
        security_groups = []
        ingress = [

        ]
        egress = [
          {
            description                  = "OpenVPN tunnel out"
            ip_protocol                  = "udp"
            from_port                    = 1194
            to_port                      = 1194
            cidr_ipv4                    = "0.0.0.0/0"
            prefix_list_id               = null
            referenced_security_group_id = null
          },
          {
            description                  = "WSUS metadata over HTTPS in the VPC"
            ip_protocol                  = "tcp"
            from_port                    = 8531
            to_port                      = 8531
            cidr_ipv4                    = "10.0.0.0/16"
            prefix_list_id               = null
            referenced_security_group_id = null
          },
          {
            description                  = "WSUS metadata over HTTPS across the tunnel"
            ip_protocol                  = "tcp"
            from_port                    = 8531
            to_port                      = 8531
            cidr_ipv4                    = "10.69.0.0/16"
            prefix_list_id               = null
            referenced_security_group_id = null
          },
          {
            description                  = "WSUS update payloads over HTTP in the VPC"
            ip_protocol                  = "tcp"
            from_port                    = 8530
            to_port                      = 8530
            cidr_ipv4                    = "10.0.0.0/16"
            prefix_list_id               = null
            referenced_security_group_id = null
          },
          {
            description                  = "WSUS update payloads over HTTP across the tunnel"
            ip_protocol                  = "tcp"
            from_port                    = 8530
            to_port                      = 8530
            cidr_ipv4                    = "10.69.0.0/16"
            prefix_list_id               = null
            referenced_security_group_id = null
          }
        ]
        tags = {}
      }
    ]
    associate_public_ip = false
  }
]

all_databases      = []
all_load_balancers = []
