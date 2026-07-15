# wsus

Installs and configures **Windows Server Update Services backed by WID** (Windows
Internal Database) on Windows Server 2025. Framework-compatible role: ships the
ansible-framework v3 generic loader (`tasks/main.yml`, byte-identical — never edit)
and a family-level `present_windows.yml` / `clean_windows.yml`.

**Status: build in progress.** BEGIN input guards are implemented; later logic lands
one command per strict-cycle piece — see `_handoff/QUEUE.md` (repo root) for the build
queue.

## Configuration

Defaults live under `wsus_defaults` (`defaults/main.yml`) and merge with
`vars/windows[_<env>].yml` overlays plus the playbook's `wsus:` override dict into
`wsus_running` (exposed to task files as `config`).

### Required inputs

The disk identifiers are required **top-level vars**, supplied through `group_vars`,
`host_vars`, inventory, or extra-vars. They are outside the merged configuration:
do not put them inside `wsus_defaults`, and do not declare them as
`wsus.wid_disk_id` or `wsus.wsus_disk_id`.

| Top-level var | Fixed target |
|---------------|--------------|
| `wid_disk_id` | WID/database disk, mapped to `E:` with label `WSUSDB` |
| `wsus_disk_id` | WSUS content disk, mapped to `F:` with label `WSUSDATA` |

Each value is the case-sensitive Windows disk `unique_id` (for example,
`eui.<hex>`). Read it with PowerShell's `Get-Disk` `UniqueId` property or from
`community.windows.win_disk_facts` as the disk's `unique_id`. The role requires one
exactly matching attached disk for each identifier. Drive letters, labels, and
filesystem conventions are documented here for the fixed mapping but land as
consumed configuration in C02.

## Requirements

- Windows Server 2025 target over SSH (`ansible_shell_type: powershell`,
  OpenSSH `DefaultShell` = PowerShell), elevated admin account, `become: false`.
- Collections: `ansible.windows` (primary), `community.windows` (fallback).
- `ENV` play-var (loader-validated) and the TD-001 playbook workarounds — see
  `docs/TECH-DEBT.md`.
