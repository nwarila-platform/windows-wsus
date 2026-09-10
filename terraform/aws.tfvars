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
    # OS-DRIVE REPLACEMENT (immutable-OS pattern). refresh=true makes this host swap-eligible:
    # bumping the framework's refresh_serial (0 -> 1 -> ...) replaces the OS instance while the
    # three data volumes, which are standalone resources rather than inline block devices, detach
    # and reattach to the replacement. It is a no-op until refresh_serial actually changes, so an
    # ordinary lifecycle is unaffected. Without it the mandate's replaceable operating system
    # cannot be exercised at all, and neither can the WSUS role's adoption of an existing SUSDB:
    # every lifecycle destroys its volumes at the end, so a swap inside one run is the only way a
    # database outlives the host that created it.
    refresh = true
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
          },
          # The client this deployment builds to prove itself, reaching the WSUS HTTPS endpoint.
          # Scoped to the subnet rather than to the client's security group because a group id
          # does not exist until apply and cannot be named here; the subnet is one /19 in one
          # private subnet in one availability zone, which is the tightest source this file can
          # express.
          #
          # BOTH ports, and the pair is not sloppiness. WSUS splits its client traffic: metadata,
          # authentication and reporting go over TLS on 8531, and update PAYLOADS go over plain
          # HTTP on 8530. That split is the vendor's, not this deployment's -- measured on a live
          # server, the Content virtual directory carries no SSL requirement while the five
          # client-facing services do, which is what makes payloads reachable on 8530 and only
          # there.
          #
          # Encrypting those payloads would buy nothing: they are Microsoft-signed and public, and
          # the client verifies the signature regardless. Admitting only 8531 produces the worst
          # failure a proof can have -- a client that scans successfully over TLS, correctly
          # reports the updates it needs, and cannot download one of them.
          {
            description                  = "WSUS metadata over HTTPS from the client subnet"
            ip_protocol                  = "tcp"
            from_port                    = 8531
            to_port                      = 8531
            cidr_ipv4                    = "10.0.128.0/19"
            prefix_list_id               = null
            referenced_security_group_id = null
          },
          {
            description                  = "WSUS update payloads over HTTP from the client subnet"
            ip_protocol                  = "tcp"
            from_port                    = 8530
            to_port                      = 8530
            cidr_ipv4                    = "10.0.128.0/19"
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
  },

  # ------------------------------------------------------------------------------------------- #
  # The client this deployment exists to convince. A WSUS server that reports itself healthy
  # proves that WSUS is configured; only a machine that asks it for updates, over the firewall
  # rules as written, proves that WSUS WORKS. This host is that machine, and it is built by the
  # same lifecycle so it is never stale and never hand-maintained.
  # ------------------------------------------------------------------------------------------- #
  {
    region            = "us_east_1"
    hostname          = "tcnaw-wsusc01"
    availability_zone = "us-east-1c"
    subnet_id         = "subnet-03a855e712be7b399"
    key_name          = "nwarila-ec2-key"

    iam_instance_profile = "nwarila-ec2-profile"
    aws_kms_alias        = "aws/ebs"

    # Windows_Server-2025-English-Full-Base-2026.08.12, owner 801119661308 -- the same build and
    # the same publication date as the server's image, so any difference between the two hosts is
    # a difference this deployment made rather than one the images arrived with. Base, not the SQL
    # image: a client has no database, and the SQL edition would bill a licence for an engine that
    # would never be started.
    ami = "ami-04fca11ec6cc2ddab"

    # No OS-drive replacement. The server carries refresh = true because a database has to be
    # shown outliving its operating system; a client holds nothing worth preserving, so a swap
    # here would prove nothing and could only fail.
    refresh = false

    # t3.medium, not the server's t3.xlarge. Without a SQL Server licence there is no SKU floor to
    # clear, and a Windows Update client's work is a handful of HTTPS calls and one install.
    instance_type = "t3.medium"

    connection_type = "ssh"
    readiness_user  = null

    readiness_gate             = false
    readiness_command          = null
    readiness_script_dir       = null
    readiness_private_key_path = null
    imds_hop_limit             = 1
    set_state                  = null

    # The Function tag is what puts this host in its own inventory group and therefore its own
    # play. The server's tag stays 'wsus'; nothing that configures a WSUS server may run here.
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
      # Larger than the Base image's native root, because this machine's whole purpose is to
      # download and install what WSUS offers it and an update that cannot land proves nothing.
      volume_size = "50"
    }

    # None. Every disk on the server exists to separate a database, a content store and a web root
    # that grow independently; a client separates nothing.
    ebs_block_devices = []

    ami_block_device_overrides = []

    network_interfaces = [
      {
        description     = "tcnaw-wsusc01 CI firewall"
        interface_type  = null
        private_ip      = null
        security_groups = []
        # The same deliberate development-cycle allowance the server carries, split into two
        # halves because the framework refuses a zero-length prefix; remove when the cycle ends.
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
        # THREE rules, and what is absent from them is the point of this host.
        #
        # The tunnel, because this machine joins the same directory the server does and the domain
        # controllers are on the other side of it.
        #
        # WSUS twice, scoped to this subnet: 8531 for the metadata, authentication and reporting
        # WSUS serves over TLS, and 8530 for the update payloads it serves over plain HTTP. The
        # split is the vendor's. Encrypting a Microsoft-signed public payload buys nothing, and
        # allowing only 8531 would produce a client that scans perfectly and downloads nothing.
        #
        # And NOTHING to the internet on 80 or 443. A domain policy tells this machine not to reach
        # Microsoft, but a policy value is a statement of intent the machine itself could
        # contradict. With no egress to Microsoft at all,
        # anything this client installs came from the WSUS server this deployment built, and the
        # proof stops depending on a policy setting being honoured.
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
            description                  = "WSUS metadata over HTTPS"
            ip_protocol                  = "tcp"
            from_port                    = 8531
            to_port                      = 8531
            cidr_ipv4                    = "10.0.128.0/19"
            prefix_list_id               = null
            referenced_security_group_id = null
          },
          {
            description                  = "WSUS update payloads over HTTP"
            ip_protocol                  = "tcp"
            from_port                    = 8530
            to_port                      = 8530
            cidr_ipv4                    = "10.0.128.0/19"
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
