# =========================================================================================== #
# File: 'terraform/aws.tfvars'
# --- [ Description ] ----------------------------------------------------------------------- #
#
# Variable input for the pinned aws-terraform-framework (SHA in .github/terraform-framework-pin).
# Plain tfvars — the workflow passes this file to terraform verbatim.
#
# This file is the single source of truth for the deploy subnet: bootstrap-iam.sh parses
# subnet_id out of it to materialize the IAM subnet pin, so the tfvars and the launch policy
# can never disagree. (The literals gate bans environment ids only under
# docs/reference/aws-iam/ — committing the subnet here is deliberate.)
#
# Every value here must stay inside the deploy role's launch boundary
# (docs/reference/aws-iam/README.md): t3.medium/t3.large only, gp3 encrypted <= 64 GiB,
# IMDSv2 with hop limit 1, the per-run managed key pair, and the pinned VPC/subnet.
#
# REACHABILITY — ZERO INBOUND, SSH OVER SSM: the security group allows NO ingress at all.
# The runner reaches the instance through an SSM session (AWS-StartSSHSession, tag-gated in
# the deploy IAM), which rides the SSM AGENT's own outbound 443. That outbound path is why
# the EIP exists: the framework attaches a pre-created ENI, a launch path AWS never
# auto-assigns a public IP to, and the account has no NAT and no VPC endpoints — so without
# the EIP (~$0.005/h for the instance's short life) the agent could never register and
# nothing could configure the box.
#
# readiness_gate is FALSE by design: the framework's gate dials the instance directly over
# SSH, which a zero-ingress security group forbids. The playbook's first play waits for
# readiness over SSM-SSH instead. The OpenSSH DefaultShell stays cmd — the boot default —
# because a PowerShell login shell breaks ansible's module bootstrap (proven live).
#
# =========================================================================================== #

# environment and resource_metadata are deliberately NOT in this file: the workflow passes
# both with -var, the highest-precedence source, so the environment name and the deployment
# identity that drives the provider's tags cannot be overridden here.

all_systems = [
  {
    region            = "us_east_1"
    hostname          = "wsus-poc-01"
    availability_zone = "us-east-1a"
    subnet_id         = "subnet-0e1c8aae192deff26"
    # v3.0.0 CONSUMES key pairs and never creates them, so this names the standing account
    # key pair. user_data installs its public half by reading IMDS; the private half lives
    # only in the AWS_EC2_SSH_PRIVATE_KEY org secret and the runner's temporary directory.
    key_name             = "nwarila-ec2-key"
    iam_instance_profile = "windows-wsus-poc-profile"
    aws_kms_alias        = "aws/ebs"
    # Windows_Server-2025-English-STIG-Full-2026.07.15, owner 801119661308. A literal id is
    # accepted from the framework's vendor allowlist; catalog selectors stay locked to
    # self-published images. Both sides are transitional — see TD-009.
    ami     = "ami-04807a1de3f592cc5"
    refresh = false
    # t3.large, not t3.medium: WSUS postinstall + SUSDB work on 4 GiB regularly pushes past the
    # CI stage budget. Both types are inside the launch policy's type lock.
    instance_type = "t3.large"
    # "ssh-ssm" names what actually happens: SSH on the wire, reached through an SSM tunnel
    # with no inbound path opened. The framework requires readiness_gate = false for this
    # transport because its gate dials directly and cannot traverse the tunnel.
    connection_type = "ssh-ssm"
    readiness_user  = null
    # The framework gate dials the instance's PRIVATE ip, unreachable from a hosted runner,
    # so it stays off and the play performs readiness itself over SSH-in-SSM. The remaining
    # readiness attributes are required by the type regardless of the gate being disabled.
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
      # The AMI's native size — application data lives on the E:/F:/G: volumes, so padding
      # the ephemeral root is pure cost.
      volume_size = "30"
    }

    # Three RAW data disks: the deploy layer owns the hardware, the composed play's
    # windows_disk_manager formats it. The Function tags are the identities the role
    # resolves each disk by (resolve_aws.yml).
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

    # Windows_Server-2025-English-STIG-Full declares exactly one EBS mapping — its own root,
    # already covered by root_block_device above — plus 26 instance-store devices the
    # framework exempts. Nothing else to override.
    ami_block_device_overrides = []

    network_interfaces = [
      {
        description     = "wsus-poc-01 CI firewall"
        interface_type  = null
        private_ip      = null
        security_groups = []
        # Non-null ingress + egress => the framework creates and attaches wsus-poc-01-eni-0-sg.
        # Ingress [] = ZERO inbound: the runner's SSH rides the SSM agent's own outbound
        # session, so nothing on the internet can dial this instance. Egress is HTTPS only —
        # the SSM agent registering and streaming through the internet gateway.
        ingress = []
        egress = [
          {
            description                  = "HTTPS out (SSM agent registration and sessions)"
            ip_protocol                  = "tcp"
            from_port                    = 443
            to_port                      = 443
            cidr_ipv4                    = "0.0.0.0/0"
            prefix_list_id               = null
            referenced_security_group_id = null
          }
        ]
        tags = {}
      }
    ]

    # An Elastic IP on eni-0 — pure EGRESS enablement for the SSM agent (see the header), not
    # an inbound path. Tag-gated in the deploy IAM (AllocateTaggedElasticIp /
    # AssociateEipToOurResources).
    associate_public_ip = true
  }
]

all_databases      = []
all_load_balancers = []

# The deployment-identity variables (environment, repository, repository_id, commit_sha,
# run_id) are passed by the workflow as individual -var flags, which outrank every tfvars
# source. They stamp the RepositoryId/RunId/Environment/CommitSha/Repository tags that satisfy
# the create-time conditions in the deploy policies. Never hardcode them here.
