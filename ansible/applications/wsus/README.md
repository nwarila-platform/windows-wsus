# wsus

Installs and configures **Windows Server Update Services backed by WID** (Windows
Internal Database) on Windows Server 2025. Framework-compatible role: ships the
ansible-framework v3 generic loader (`tasks/main.yml`, byte-identical — never edit)
and a family-level `present_windows.yml` / `clean_windows.yml`.

**Status: scaffolding.** Logic lands one command per cycle piece — see
the build queue (repo root) for the build queue.

## Configuration

Defaults live under `wsus_defaults` (`defaults/main.yml`) and merge with
`vars/windows[_<env>].yml` overlays plus the playbook's `wsus:` override dict into
`wsus_running` (exposed to task files as `config`).

| Key | Default | Purpose |
|-----|---------|---------|
| _none yet_ | | populated per build piece, same cycle it lands |

## Requirements

- Windows Server 2025 target over SSH (`ansible_shell_type: powershell`,
  OpenSSH `DefaultShell` = PowerShell), elevated admin account, `become: false`.
- Collections: `ansible.windows` (primary), `community.windows` (fallback).
- `ENV` play-var (loader-validated) and the TD-001 playbook workarounds — see
  `docs/TECH-DEBT.md`.
