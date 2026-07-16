# wsus

Installs and configures **Windows Server Update Services backed by WID** (Windows
Internal Database) on Windows Server 2025. Framework-compatible role: ships the
ansible-framework v3 generic loader (`tasks/main.yml`, byte-identical — never edit)
and a family-level `present_windows.yml` / `clean_windows.yml`.

**Status: build in progress.** BEGIN input guards are implemented; later logic lands
one command per cycle piece — see the build queue (repo root) for the build
queue.

## Configuration

Defaults live under `wsus_defaults` (`defaults/main.yml`) and merge with
`vars/windows[_<env>].yml` overlays plus the playbook's `wsus:` override dict into
`wsus_running` (exposed to task files as `config`).

### Required inputs

The disk identifiers are declared in the `wsus:` override dict in the playbook,
`group_vars`, or `host_vars`. The loader merges that dict into the role configuration,
where the role consumes them as `config.wid_disk_id` and `config.wsus_disk_id`. They
are **not** top-level vars and are **not** nested under `wsus.data_disks.*`.

| `wsus:` override key | Consumed as | Fixed target |
|----------------------|-------------|--------------|
| `wid_disk_id` | `config.wid_disk_id` | WID/database disk, mapped to `E:` with label `WSUSDB` |
| `wsus_disk_id` | `config.wsus_disk_id` | WSUS content disk, mapped to `F:` with label `WSUSDATA` |

Each value is the case-sensitive Windows disk `unique_id` (for example,
`eui.<hex>`). Read it with PowerShell's `Get-Disk` `UniqueId` property or from
`community.windows.win_disk_facts` as the disk's `unique_id`. The role requires one
exactly matching attached disk for each identifier. Drive letters, labels, and
filesystem conventions are documented here for the fixed mapping but land as
consumed configuration one cycle piece at a time.

### Merged configuration

| `wsus_defaults` key | Default | Purpose |
|---------------------|---------|---------|
| `data_disks.db.drive_letter` | `E:` | Target drive letter for the WID/database disk |
| `data_disks.content.drive_letter` | `F:` | Target drive letter for the WSUS content disk |
| `data_disks.db.label` | `WSUSDB` | NTFS volume label for the WID/database disk (E:) |
| `data_disks.db.allocation_unit` | `65536` | NTFS allocation unit (bytes) for E: — 64 KiB, MS SQL/WID storage best practice |
| `data_disks.content.label` | `WSUSDATA` | NTFS volume label for the WSUS content disk (F:) |
| `data_disks.content.allocation_unit` | `4096` | NTFS allocation unit (bytes) for F: — 4 KiB NTFS default (MS is silent on WSUS-content cluster size) |

The role provisions a declared disk only when it is RAW or already carries its target
drive letter. It refuses an initialized disk carrying a foreign drive letter, which
protects existing data and prevents an identifier mistake from selecting the OS/system
disk with `C:`. Disk size is never used for selection. C02e NTFS-formats E:/F: with these labels +
allocation units (WSUSDB at 64 KiB, WSUSDATA at 4 KiB).

The identifiers and `temp_dir` must co-locate in one `wsus:` declaration. The loader
reads `temp_dir` from the raw `wsus` var, and Ansible does not merge role override
dicts across precedence levels; a higher-precedence `wsus:` value replaces the whole
mapping.

## Requirements

- Windows Server 2025 target over SSH (`ansible_shell_type: powershell`,
  OpenSSH `DefaultShell` = PowerShell), elevated admin account, `become: false`.
- Collections: `ansible.windows` (primary), `community.windows` (fallback).
- `ENV` play-var (loader-validated) and the TD-001 playbook workarounds — see
  `docs/TECH-DEBT.md`.
