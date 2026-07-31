# windows-wsus

Deploys a **WSUS server backed by WID** (Windows Internal Database) onto Windows
Server 2025 via Ansible-over-SSH.

This is a `nwarila-platform` single-purpose application repo: it contains one role
(`ansible/applications/wsus/`), its playbook, and inventory. At run time the role is
composed into a version-pinned checkout of
[ansible-framework](https://github.com/nwarila-platform/ansible-framework) — see
`scripts/compose-and-run.sh` and `.framework-pin`.

## Quickstart (lab)

```bash
# 1. Revert the dev VM to the clean baseline (ALWAYS, before every run)
scripts/revert-vm.sh

# 2. Compose the pinned framework + this role, then run the playbook
scripts/compose-and-run.sh -e env=int
```

## Layout

| Path | Purpose |
|---|---|
| `ansible/applications/wsus/` | The role (framework v3 loader + `present_windows.yml`) |
| `ansible/playbooks/wsus.yml` | The in-repo playbook (carries TD-001 Windows workarounds) |
| `ansible/inventory/vmware.yml` | Dev inventory → VMware Workstation lab VM |
| `scripts/` | compose-and-run + snapshot revert helpers |
| `terraform/` | **NOT ACTIVE** — future proxmox-terraform-framework consumer |
| `docs/ansible-style-guide.md` | The org style & design guide (grows per cycle) |
| `docs/TECH-DEBT.md` | Known debt (TD-001: framework loader Windows gap) |

Status: **skeleton** — role logic is built one command at a time; see `AGENTS.md`.
