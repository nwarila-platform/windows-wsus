# =========================================================================================== #
# File: 'terraform/aws.tfvars'
# --- [ Description ] ----------------------------------------------------------------------- #
#
# Variable input for the pinned aws-terraform-framework (SHA in .github/terraform-framework-pin).
# Plain tfvars — the workflow passes this file to terraform verbatim. This repository declares
# NO .tf files of its own: resources live in the pinned framework, configuration in the pinned
# ansible-framework plus this repository's roles.
#
# REACHABILITY — DIRECT SSH OVER A PUBLIC IPv4, ADMITTED BY TWO GROUPS. The workflow discovers
# the runner's public IPv4 and passes it as the framework's runtime-only runner_ip variable; the
# framework attaches one group scoped to that address to every interface. The interface below
# carries a second group whose temporary development-cycle rules open tcp/22 to the whole IPv4
# space, so an operator can reach a held guest. The instance receives a public IPv4 at launch;
# no Elastic IP is involved. The account has no NAT and no VPC endpoints.
#
# The dependency worth knowing: MapPublicIpOnLaunch is an attribute of a shared subnet no
# repository owns. Direct SSH requires the instance's launch-time public address as well as the
# runner-scoped security group.
#
# readiness_gate is FALSE by design: the playbook owns the bounded direct-SSH readiness check.
# The OpenSSH DefaultShell boots as cmd; the playbook's bootstrap role flips it to PowerShell on
# first contact, and every play after that declares the PowerShell shell type.
#
# =========================================================================================== #

# environment and the deployment identity (repository, repository_id, commit_sha, run_id) are
# deliberately NOT in this file: the workflow passes them with -var, the highest-precedence
# source, so the identity that drives the provider's tags cannot be overridden here.

all_systems = [
  {
    region   = "us_east_1"
    hostname = "tcnaw-wsus01"
    # The ratified availability-zone spec lock, and a subnet in this account's only VPC.
    availability_zone = "us-east-1c"
    subnet_id         = "subnet-03a855e712be7b399"
    # The framework CONSUMES key pairs and never creates them, so this names the standing
    # account key pair. user_data installs its public half by reading IMDS; the private half
    # lives only in the AWS_EC2_SSH_PRIVATE_KEY organization secret and the runner's
    # temporary directory.
    key_name = "nwarila-ec2-key"
    # Ratified 2026-08-12: the EC2 instance REUSES the org-owned profile as-is. This
    # repository never creates or modifies it; the runner role only reads and passes it.
    iam_instance_profile = "nwarila-ec2-profile"
    aws_kms_alias        = "aws/ebs"
    # Windows_Server-2025-English-Full-SQL_2022_Standard-2026.08.12, owner 801119661308 —
    # accepted from the framework's vendor allowlist, which is keyed by owner. SQL Server 2022
    # arrives licensed by AWS and installed by the image, so nothing here installs or licenses a
    # database engine. Standard, not Express or Web: SUSDB outgrows Express's 10 GiB ceiling, and
    # Web is licensed only for publicly accessible workloads. No STIG-hardened image carries SQL
    # Server, so this base is not the STIG one. Server 2025 rather than the target's 2022 because
    # OpenSSH Server ships installed only from 2025, and the framework's user_data starts sshd
    # rather than installing it; on 2022 that bootstrap aborts and nothing can reach the guest.
    ami     = "ami-0ac1b4c911759cc2e"
    refresh = false
    # t3.xlarge because AWS publishes no license-included SQL Server Standard rate for any
    # 2-vCPU burstable type: t3.large has no SQL Std SKU at all, so RunInstances rejects the
    # pair after the network interface and volumes already exist. Four vCPUs is also the
    # minimum AWS bills that licence at, so a smaller type would pay for cores it cannot use.
    instance_type = "t3.xlarge"
    # Direct SSH reaches the launch-time public IPv4 through the runner-scoped framework SG.
    connection_type = "ssh"
    readiness_user  = null

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
      # The AMI's native size, which its SQL Server installation sets — SUSDB, content, and the
      # IIS root live on their own volumes, so padding the ephemeral root is pure cost.
      volume_size = "75"
    }

    # Three RAW data disks, one per concern, so each can be sized, backed up and permissioned
    # on its own: SUSDB on SQL Server, the WSUS content store, and the IIS root. The deploy
    # layer owns the hardware; the composed play's windows_disk_manager
    # formats each and assigns its drive letter. The Function tag is the identity the disk role
    # resolves a volume by (resolve_aws.yml), because a volume id only exists after apply, so
    # each tag here must be unique and must match the play's disk layout.
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
        # Deliberate temporary development-cycle allowance: SSH from the whole IPv4 space, split
        # into two halves because the framework refuses a zero-length prefix; remove when the
        # cycle ends.
        ingress = [
          {
            description                  = "SSH from first half of IPv4"
            ip_protocol                  = "tcp"
            from_port                    = 22
            to_port                      = 22
            cidr_ipv4                    = "0.0.0.0/1"
            prefix_list_id               = null
            referenced_security_group_id = null
          },
          {
            description                  = "SSH from second half of IPv4"
            ip_protocol                  = "tcp"
            from_port                    = 22
            to_port                      = 22
            cidr_ipv4                    = "128.0.0.0/1"
            prefix_list_id               = null
            referenced_security_group_id = null
          }
        ]
        # The VPN tunnel that carries this host onto the private network, and nothing else.
        # Scoped by port rather than by address because the profile names its endpoint by DNS and
        # that address changes. Every S3 fetch happens on the CONTROLLER, so the guest still needs
        # no outbound HTTPS of its own; replies to inbound SSH are stateful.
        egress = [
          {
            description                  = "OpenVPN tunnel out"
            ip_protocol                  = "udp"
            from_port                    = 1194
            to_port                      = 1194
            cidr_ipv4                    = "0.0.0.0/0"
            prefix_list_id               = null
            referenced_security_group_id = null
          }
        ]
        tags = {}
      }
    ]

    # No Elastic IP: the subnet auto-assigns the launch-time public IPv4 used for direct SSH.
    associate_public_ip = false
  }
]

all_databases      = []
all_load_balancers = []
