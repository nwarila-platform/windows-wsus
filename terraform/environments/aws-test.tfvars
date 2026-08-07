# =========================================================================================== #
# File: 'terraform/environments/aws-test.tfvars'
# --- [ Description ] ----------------------------------------------------------------------- #
#
# Variable input for the pinned aws-terraform-framework (SHA in .terraform-framework-pin).
# Plain tfvars, no templating: the workflow passes this file to terraform verbatim.
#
# This file is the single source of truth for the deploy subnet: bootstrap-iam.sh parses
# subnet_id out of it to materialize the IAM subnet pin, so the tfvars and the launch policy
# can never disagree. (The literals gate bans environment ids only under
# docs/reference/aws-iam/ — committing the subnet here is deliberate.)
#
# Every value here must stay inside the deploy role's launch boundary
# (docs/reference/aws-iam/README.md): t3.medium/t3.large only, gp3 encrypted <= 64 GiB,
# IMDSv2 with hop limit 1, the pinned key pair, and the pinned VPC/subnet.
#
# REACHABILITY: the framework attaches a PRE-CREATED ENI, and AWS never auto-assigns a public
# IP to that launch path — so without the EIP below the instance would have no route to
# anything (no NAT, no VPC endpoints in this account) and nothing could reach it. The EIP
# (~$0.005/h for the instance's short life) plus a key-auth-only SSH port is the entire
# exposure. Egress is EMPTY: WSUS here syncs from nothing — no
# Microsoft Update, no website — and the OpenSSH bootstrap pulls its key from link-local
# IMDS, which security groups never see.
#
# readiness_gate is FALSE by design: the framework's gate dials the instance's PRIVATE ip,
# which a GitHub-hosted runner cannot reach. The workflow performs its own readiness wait
# against the EIP, then sets the OpenSSH DefaultShell to PowerShell (the framework's
# bootstrap deliberately leaves cmd).
#
# =========================================================================================== #

environment = "test"

# Empty on purpose: no framework readiness gate runs (readiness_gate = false below), so no
# private-key path is needed by Terraform. CI holds the key only for its own SSH stages.
readiness_private_key_paths = {}

all_systems = [
  {
    region            = "us_east_1"
    hostname          = "wsus-poc-01"
    availability_zone = "us-east-1a"
    subnet_id         = "subnet-0e1c8aae192deff26"
    # The org's shared EC2 key pair (secure-wazuh pattern) — its private half is the
    # AWS_EC2_SSH_PRIVATE_KEY Actions secret. No per-repo key material is minted.
    key_name             = "nwarila-ec2-key"
    iam_instance_profile = "windows-wsus-poc-profile"
    aws_kms_alias        = "aws/ebs"
    ami                  = "windows_server_2025_base"
    refresh              = false
    # t3.large, not t3.medium: WSUS postinstall + SUSDB work on 4 GiB regularly pushes past the
    # CI stage budget. Both types are inside the launch policy's type lock.
    instance_type  = "t3.large"
    readiness_user = null
    readiness_gate = false
    imds_hop_limit = 1
    set_state      = null

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
      volume_size           = "50"
    }

    # The same three RAW data disks the lab baseline provides (VM-LIFECYCLE.md §1): the deploy
    # layer owns the hardware, the composed play's windows_disk_manager formats it. The
    # Function tags are the identities the role resolves each disk by (resolve_aws.yml).
    ebs_block_devices = [
      {
        iops         = null
        snapshot_id  = null
        skip_destroy = false
        tags         = { Function = "WSUSDB" }
        throughput   = null
        volume_type  = "gp3"
        volume_size  = "20"
      },
      {
        iops         = null
        snapshot_id  = null
        skip_destroy = false
        tags         = { Function = "WSUSDATA" }
        throughput   = null
        volume_type  = "gp3"
        volume_size  = "30"
      },
      {
        iops         = null
        snapshot_id  = null
        skip_destroy = false
        tags         = { Function = "WSUSIIS" }
        throughput   = null
        volume_type  = "gp3"
        volume_size  = "20"
      }
    ]

    network_interfaces = [
      {
        description     = "wsus-poc-01 CI firewall"
        interface_type  = null
        private_ip      = null
        security_groups = []
        # Non-null ingress + egress => the framework creates and attaches wsus-poc-01-eni-0-sg.
        # Ingress is SSH only, key-authenticated, on an instance that lives ~90 minutes.
        # Egress [] = no outbound at all: WSUS syncs from nothing in this PoC, the bootstrap's
        # key fetch is link-local IMDS (invisible to SGs), and SSH replies ride the stateful
        # inbound connection.
        ingress = [
          {
            description                  = "SSH (key auth only; ephemeral instance)"
            ip_protocol                  = "tcp"
            from_port                    = 22
            to_port                      = 22
            cidr_ipv4                    = "0.0.0.0/0"
            cidr_ipv6                    = null
            prefix_list_id               = null
            referenced_security_group_id = null
          }
        ]
        egress = []
        tags   = {}
      }
    ]

    # An Elastic IP on eni-0 — the only public-address path for a pre-created-ENI launch, and
    # the runner's only way to the instance. Tag-gated in the deploy IAM
    # (AllocateTaggedElasticIp / AssociateEipToOurResources).
    associate_public_ip = true
  }
]

all_databases      = []
all_load_balancers = []

# resource_metadata is injected by the workflow as TF_VAR_resource_metadata; it drives the
# provider default_tags that satisfy every create-time nwarila:management:repository-id
# condition in the deploy policies. Never hardcode it here.
