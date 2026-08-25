# aws_windows_disk_manager role

Provisions declared NTFS data volumes on a Windows Server 2025 host running on Amazon EC2.
This is a deliberate single-platform narrowing of the framework's `windows_disk_manager`,
forked at ansible-framework pin `24a8ec74a7965b3a6f9cc827455962d541ff6d73` and owned here so
the one platform this repository deploys to has exactly one disk-identity code path.

What the narrowing removed:

- the `platform` knob — the target must be Amazon EC2, asserted from the observed system
  vendor before any facts or mutation;
- the literal `unique_id` identity mode — every disk is identified by its EBS volume's
  `Function` tag, resolved through one controller-side describe per host and matched to the
  physical disk via the Nitro guarantee that the NVMe serial equals the volume-id without its
  hyphen. A volume-id is Terraform's to assign, never configuration.

Both retired keys are refused by name at validation rather than silently ignored: a stale
`unique_id` beside a `function` could target a different disk than the tag names.

What is unchanged from the fork point: the shared v3.3.0 loader, byte-identical as every
consuming role's must be; the observed-state classification, and the mutation-safety contract — an
idempotent online/writable fixup, provisioning only from a positively recognized RAW/blank or
GPT/unformatted state, an idempotent skip when an NTFS volume already carries the declared
label, and fail-closed refusal of the entire declaration set when any one disk classifies as
foreign.

## Configuration model

The loader merges `aws_windows_disk_manager_defaults` with the playbook's
`aws_windows_disk_manager:` override into `aws_windows_disk_manager_running`, exposed to task
files as `config`. Validation runs against that effective mapping before target mutation.

| Key | Contract |
|---|---|
| `disks[].function` | REQUIRED. The attached EBS volume's `Function` tag value; exactly one attached volume per host may carry it. |
| `disks[].drive_letter` | One ASCII letter (`D`, `D:`, or `D:\`), distinct per entry after canonicalization. |
| `disks[].label` | NTFS volume label, 1–32 characters, distinct per entry. |
| `disks[].allocation_unit` | Optional; a classic NTFS cluster size (512–65536). Default 4096. |

This role is retained but unreferenced: `ansible/playbooks/wsus-aws.yml` currently delegates
guest storage to the pinned framework's `windows_disk_manager`, mirroring the sibling reference.

## Requirements

- Windows Server 2025 on EC2 reached over OpenSSH with `ansible_shell_type: cmd`; the play
  must use `become: false`, a transport setting rather than a role choice.
- Controller-side AWS credentials holding the deploy identity's existing `ec2:DescribeVolumes`
  grant; the target instance itself needs no EBS or IAM permission.
- Exact collection versions from `requirements-quality.yml` (`amazon.aws`,
  `ansible.windows`, `community.windows`).
