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

| Key | Default | Purpose |
|-----|---------|---------|
| `data_disks` | database: 20 GiB; content: 30 GiB | Declares the two blank data disks handed to the role. Each item has the keys below. |
| `data_disks[].purpose` | `db`, `content` | Unique, non-empty logical purpose used by later storage tasks. |
| `data_disks[].size_gb` | `20`, `30` | Unique positive integer size in GiB. The role uses size plus RAW partition style to identify exactly one disk; disk numbers are never assumed. |

## Requirements

- Windows Server 2025 target over SSH (`ansible_shell_type: powershell`,
  OpenSSH `DefaultShell` = PowerShell), elevated admin account, `become: false`.
- Collections: `ansible.windows` (primary), `community.windows` (fallback).
- `ENV` play-var (loader-validated) and the TD-001 playbook workarounds — see
  `docs/TECH-DEBT.md`.
