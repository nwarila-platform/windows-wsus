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
    # Windows_Server-2025-English-Full-SQL_2022_Standard-2026.09.17, owner 801119661308 —
    # accepted from the framework's vendor allowlist, which is keyed by owner. SQL Server 2022
    # arrives licensed by AWS and installed by the image, so nothing here installs or licenses a
    # database engine. Standard, not Express or Web: SUSDB outgrows Express's 10 GiB ceiling, and
    # Web is licensed only for publicly accessible workloads. No STIG-hardened image carries SQL
    # Server, so this base is not the STIG one.
    #
    # All three servers take the SAME publication date, so a difference between generations is a
    # difference the operating system makes rather than one the images arrived with.
    ami = "ami-0d17ad6b56dfc66c9"
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

    # OsRelease is the release this host launched, which the instance itself cannot be asked
    # before Ansible can reach it: platform_details says only "Windows with SQL Server", and the
    # bootstrap that would let facts be gathered is the very thing being selected. The dynamic
    # inventory composes os_bootstrap_role from this, exactly as it composes the connection
    # settings from the Connection tag. It must name a role directory in the pinned
    # ansible-framework's operating_systems/ or the dispatcher fails at its route guard.
    tags = {
      Function  = "wsus"
      OsRelease = "windows_server_2025"
      Backup    = false
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
        # NO SSH RULE HERE, and its absence is the point. Reaching this host is a RUN-SCOPED grant
        # the framework attaches at apply: the runner's own address, plus a human's when the
        # pipeline resolves one from the organisation secret naming their host. Neither is
        # committed, so this file never publishes who may reach the estate or from where. What
        # stood here was tcp/22 open to the whole IPv4 space, described in its own comment as a
        # temporary development-cycle allowance to be removed when the cycle ended. It has.
        ingress = [
          # The client this deployment builds to prove itself, reaching the WSUS HTTPS endpoint.
          # Scoped to the subnet rather than to the client's security group because a group id
          # does not exist until apply and cannot be named here; the subnet is one /19 in one
          # private subnet in one availability zone, which is the tightest source this file can
          # express.
          #
          # BOTH ports and BOTH networks, and neither pair is sloppiness.
          #
          # WSUS splits its client traffic: metadata, authentication and reporting go over TLS on
          # 8531, and update PAYLOADS go over plain HTTP on 8530. That split is the vendor's, not
          # this deployment's -- measured on a live server, the Content virtual directory carries
          # no SSL requirement while the five client-facing services do, which is what makes
          # payloads reachable on 8530 and only there. Encrypting them would buy nothing: they are
          # Microsoft-signed and public, and the client verifies the signature regardless.
          # Admitting only 8531 produces the worst failure a proof can have -- a client that scans
          # successfully over TLS, correctly reports the updates it needs, and downloads none.
          #
          # The networks are the estate this server exists to serve: 10.0.0.0/16 is this account's
          # VPC, and 10.69.0.0/16 is on-prem. The VPC half alone would serve only the client this
          # deployment builds to prove the server -- and the machines that actually need patching
          # are the other half.
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
        # The VPN tunnel that carries this host onto the private network, and S3 -- nothing else.
        # The tunnel is scoped by port rather than by address because the profile names its
        # endpoint by DNS and that address changes.
        #
        # S3 is the exception to "every fetch happens on the CONTROLLER", and it is not a change
        # of mind: an image that ships without OpenSSH.Server has no sshd for a controller to
        # reach, so the capability must be installed from user_data BEFORE anything can connect.
        # That fetch is the one thing the guest must do for itself. Scoped to the S3 managed
        # prefix list rather than 0.0.0.0/0 because a WSUS server that can reach the whole
        # internet on 443 can reach Microsoft Update directly, and then "the client took this
        # update from the server this deployment built" stops being provable from the firewall.
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

    # No Elastic IP: the subnet auto-assigns the launch-time public IPv4 used for direct SSH.
    associate_public_ip = false
  },

  {
    # The production target. Ships WITHOUT OpenSSH.Server, so user_data installs it from the staged cab.
    region   = "us_east_1"
    hostname = "tcnaw-wsus02"
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
    # Windows_Server-2022-English-Full-SQL_2022_Standard-2026.09.17, owner 801119661308 —
    # accepted from the framework's vendor allowlist, which is keyed by owner. SQL Server 2022
    # arrives licensed by AWS and installed by the image, so nothing here installs or licenses a
    # database engine. Standard, not Express or Web: SUSDB outgrows Express's 10 GiB ceiling, and
    # Web is licensed only for publicly accessible workloads. No STIG-hardened image carries SQL
    # Server, so this base is not the STIG one.
    #
    # All three servers take the SAME publication date, so a difference between generations is a
    # difference the operating system makes rather than one the images arrived with.
    ami = "ami-0c1499dbc4eaf1bf6"
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

    # OsRelease is the release this host launched, which the instance itself cannot be asked
    # before Ansible can reach it: platform_details says only "Windows with SQL Server", and the
    # bootstrap that would let facts be gathered is the very thing being selected. The dynamic
    # inventory composes os_bootstrap_role from this, exactly as it composes the connection
    # settings from the Connection tag. It must name a role directory in the pinned
    # ansible-framework's operating_systems/ or the dispatcher fails at its route guard.
    tags = {
      Function  = "wsus"
      OsRelease = "windows_server_2022"
      Backup    = false
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
        description     = "tcnaw-wsus02 CI firewall"
        interface_type  = null
        private_ip      = null
        security_groups = []
        # NO SSH RULE HERE, and its absence is the point. Reaching this host is a RUN-SCOPED grant
        # the framework attaches at apply: the runner's own address, plus a human's when the
        # pipeline resolves one from the organisation secret naming their host. Neither is
        # committed, so this file never publishes who may reach the estate or from where. What
        # stood here was tcp/22 open to the whole IPv4 space, described in its own comment as a
        # temporary development-cycle allowance to be removed when the cycle ended. It has.
        ingress = [
          # The client this deployment builds to prove itself, reaching the WSUS HTTPS endpoint.
          # Scoped to the subnet rather than to the client's security group because a group id
          # does not exist until apply and cannot be named here; the subnet is one /19 in one
          # private subnet in one availability zone, which is the tightest source this file can
          # express.
          #
          # BOTH ports and BOTH networks, and neither pair is sloppiness.
          #
          # WSUS splits its client traffic: metadata, authentication and reporting go over TLS on
          # 8531, and update PAYLOADS go over plain HTTP on 8530. That split is the vendor's, not
          # this deployment's -- measured on a live server, the Content virtual directory carries
          # no SSL requirement while the five client-facing services do, which is what makes
          # payloads reachable on 8530 and only there. Encrypting them would buy nothing: they are
          # Microsoft-signed and public, and the client verifies the signature regardless.
          # Admitting only 8531 produces the worst failure a proof can have -- a client that scans
          # successfully over TLS, correctly reports the updates it needs, and downloads none.
          #
          # The networks are the estate this server exists to serve: 10.0.0.0/16 is this account's
          # VPC, and 10.69.0.0/16 is on-prem. The VPC half alone would serve only the client this
          # deployment builds to prove the server -- and the machines that actually need patching
          # are the other half.
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
        # The VPN tunnel that carries this host onto the private network, and S3 -- nothing else.
        # The tunnel is scoped by port rather than by address because the profile names its
        # endpoint by DNS and that address changes.
        #
        # S3 is the exception to "every fetch happens on the CONTROLLER", and it is not a change
        # of mind: an image that ships without OpenSSH.Server has no sshd for a controller to
        # reach, so the capability must be installed from user_data BEFORE anything can connect.
        # That fetch is the one thing the guest must do for itself. Scoped to the S3 managed
        # prefix list rather than 0.0.0.0/0 because a WSUS server that can reach the whole
        # internet on 443 can reach Microsoft Update directly, and then "the client took this
        # update from the server this deployment built" stops being provable from the firewall.
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

    # No Elastic IP: the subnet auto-assigns the launch-time public IPv4 used for direct SSH.
    associate_public_ip = false
  },

  {
    # The oldest supported generation. Also cab-installed, and additionally needs the framework hotfix that binds sshd to the payload crypto.
    region   = "us_east_1"
    hostname = "tcnaw-wsus03"
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
    # Windows_Server-2019-English-Full-SQL_2022_Standard-2026.09.17, owner 801119661308 —
    # accepted from the framework's vendor allowlist, which is keyed by owner. SQL Server 2022
    # arrives licensed by AWS and installed by the image, so nothing here installs or licenses a
    # database engine. Standard, not Express or Web: SUSDB outgrows Express's 10 GiB ceiling, and
    # Web is licensed only for publicly accessible workloads. No STIG-hardened image carries SQL
    # Server, so this base is not the STIG one.
    #
    # All three servers take the SAME publication date, so a difference between generations is a
    # difference the operating system makes rather than one the images arrived with.
    ami = "ami-08b450469362e16ab"
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

    # OsRelease is the release this host launched, which the instance itself cannot be asked
    # before Ansible can reach it: platform_details says only "Windows with SQL Server", and the
    # bootstrap that would let facts be gathered is the very thing being selected. The dynamic
    # inventory composes os_bootstrap_role from this, exactly as it composes the connection
    # settings from the Connection tag. It must name a role directory in the pinned
    # ansible-framework's operating_systems/ or the dispatcher fails at its route guard.
    tags = {
      Function  = "wsus"
      OsRelease = "windows_server_2019"
      Backup    = false
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
        description     = "tcnaw-wsus03 CI firewall"
        interface_type  = null
        private_ip      = null
        security_groups = []
        # NO SSH RULE HERE, and its absence is the point. Reaching this host is a RUN-SCOPED grant
        # the framework attaches at apply: the runner's own address, plus a human's when the
        # pipeline resolves one from the organisation secret naming their host. Neither is
        # committed, so this file never publishes who may reach the estate or from where. What
        # stood here was tcp/22 open to the whole IPv4 space, described in its own comment as a
        # temporary development-cycle allowance to be removed when the cycle ended. It has.
        ingress = [
          # The client this deployment builds to prove itself, reaching the WSUS HTTPS endpoint.
          # Scoped to the subnet rather than to the client's security group because a group id
          # does not exist until apply and cannot be named here; the subnet is one /19 in one
          # private subnet in one availability zone, which is the tightest source this file can
          # express.
          #
          # BOTH ports and BOTH networks, and neither pair is sloppiness.
          #
          # WSUS splits its client traffic: metadata, authentication and reporting go over TLS on
          # 8531, and update PAYLOADS go over plain HTTP on 8530. That split is the vendor's, not
          # this deployment's -- measured on a live server, the Content virtual directory carries
          # no SSL requirement while the five client-facing services do, which is what makes
          # payloads reachable on 8530 and only there. Encrypting them would buy nothing: they are
          # Microsoft-signed and public, and the client verifies the signature regardless.
          # Admitting only 8531 produces the worst failure a proof can have -- a client that scans
          # successfully over TLS, correctly reports the updates it needs, and downloads none.
          #
          # The networks are the estate this server exists to serve: 10.0.0.0/16 is this account's
          # VPC, and 10.69.0.0/16 is on-prem. The VPC half alone would serve only the client this
          # deployment builds to prove the server -- and the machines that actually need patching
          # are the other half.
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
        # The VPN tunnel that carries this host onto the private network, and S3 -- nothing else.
        # The tunnel is scoped by port rather than by address because the profile names its
        # endpoint by DNS and that address changes.
        #
        # S3 is the exception to "every fetch happens on the CONTROLLER", and it is not a change
        # of mind: an image that ships without OpenSSH.Server has no sshd for a controller to
        # reach, so the capability must be installed from user_data BEFORE anything can connect.
        # That fetch is the one thing the guest must do for itself. Scoped to the S3 managed
        # prefix list rather than 0.0.0.0/0 because a WSUS server that can reach the whole
        # internet on 443 can reach Microsoft Update directly, and then "the client took this
        # update from the server this deployment built" stops being provable from the firewall.
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

    # No Elastic IP: the subnet auto-assigns the launch-time public IPv4 used for direct SSH.
    associate_public_ip = false
  },
]

all_databases      = []
all_load_balancers = []
