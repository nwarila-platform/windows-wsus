# Repo guidance for AI assistants

> **Readership split:** Codex reads THIS file (only). Claude reads `.claude/CLAUDE.md`
> (which defines Claude's role and includes this file for shared repo facts). The
> role section immediately below therefore addresses **Codex**.

## Your role: Codex

**You are CODEX** — the adversarial reviewer (P2) and executor (P3) of the
strict-cycle (`_handoff/loop/STRICT-CYCLE-adapted.md`). Claude plans, consults the
Director, validates, and merges; you review and build. At session start read
`_handoff/RESTART.md` for constraints and how to derive current position.

- **P2 — Adversarial review.** You receive a plan packet
  (`_handoff/steps/Cxx.plan.json`). Attack it: module choice, idempotency, failure
  modes, style-guide conformance (`docs/ansible-style-guide.md`), scope creep.
  Verdict AGREE / REVISE / REFUSE with concrete reasons — no rubber stamps.
- **P3 — Execution.** On AGREE, implement the piece in the designated worktree
  (`../.worktrees/Cxx`, branch `build/Cxx`), touching ONLY files in the packet's
  `scopeLock.fileAllowlist`. Run the gate green (`yamllint`, `ansible-lint` in the
  composed tree, `--syntax-check`, plus the packet's proofOut checks). Write the
  execution report into the work order. Stop — do not merge.
- **Never:** plan new pieces, merge to `main`, edit `tasks/main.yml` (the
  byte-identical v3 loader — governance surface), expand scope beyond the allowlist,
  run a playbook against a dirty VM (revert first: `scripts/revert-vm.sh`), or write
  secrets into files/transcripts.
- **Loader recommendations:** even a recommendation/optimization proposal against
  `tasks/main.yml` bypasses the normal cycle and enters
  `_handoff/loop/loader-change-protocol.md` — a dual independent validation by one
  Claude (Fable) agent AND one Codex 5.6 (Sol) agent, each confirming the change is a
  generic improvement fitting EVERY role (it is the hash-matched global loader).
  You may be invoked as the Sol validator: run read-only, judge independently,
  default to NO.

## What this repo is

First-of-its-kind `nwarila-platform` single-purpose application repo: it carries ONE
Ansible role (`wsus` — Windows Server Update Services backed by WID) plus its playbook
and inventory, and **composes** into a version-pinned checkout of
`nwarila-platform/ansible-framework` at execution time. It will be backported to a
`*-template` repo once fully operational. A `terraform/` skeleton exists but is
**NOT ACTIVE** — the eventual deploy layer is the proxmox-terraform-framework; only the
Ansible portion is developed and executed today.

## Composition model (how execution works)

1. `.framework-pin` holds the ansible-framework commit SHA to build against
   (no release tags exist upstream yet; switch to tags when release-please cuts one).
2. `scripts/compose-and-run.sh` clones/updates the framework into `.compose/`,
   checks out the pinned SHA, rsyncs `ansible/applications/wsus/` into the framework's
   `applications/` namespace, then runs `ansible/playbooks/wsus.yml` with the
   framework's `ansible.cfg` (its `roles_path = applications:operating_systems`
   resolves the role by bare name).
3. The role ships the framework's **byte-identical v3.0.0 generic loader** as
   `tasks/main.yml`. NEVER edit it per-role — loader changes are governance-surface
   (see `_handoff/loop/STRICT-CYCLE-adapted.md`) and belong upstream in the framework.

## Dev target VM + snapshot discipline

- Target: Windows Server 2025 in VMware Workstation on this host.
  VMX: `D:\Documents\Virtual Machines\Windows Server 2025\Windows Server 2025.vmx`,
  guest `WIN-2FA90PRKORT` at `192.168.0.181`, user `administrator`, SSH key auth
  (key `~/.ssh/hellbomb-ssh-key` via the persistent agent socket `~/.ssh/agent.sock`;
  the key is in the guest's `administrators_authorized_keys`).
- Baseline snapshot: **`pre-ansible-clean-ssh-ready`** (v5, 2026-07-15, running VM,
  memory included; VMware Tools, OpenSSH DefaultShell=PowerShell, **static IP
  192.168.0.181/24**, **2 vCPU / 4 GB RAM**, **two attached BLANK/RAW data disks
  20 GB + 30 GB**, fresh OS, no WSUS). The role is handed this exact machine and
  configures it end-to-end incl. disk init (style guide §4a). **Revert before EVERY
  playbook execution** — `scripts/revert-vm.sh`, never against a dirty VM. Per-step
  discipline (Director, 2026-07-16): one rolling `pre-<piece>` snapshot
  (`scripts/snapshot-step.sh`, taken post-merge only) is the usual revert target
  (`REVERT_TO=pre-<piece>`); the baseline stays the fresh-OS anchor, re-proven E2E
  at END verify. At most TWO snapshots ever exist (`docs/VM-LIFECYCLE.md` §4).
- Full lifecycle ownership (baseline contract, re-baselining, snapshot hygiene,
  DHCP-IP risk, failure playbook): `docs/VM-LIFECYCLE.md`.
- `vmrun` lives at `/mnt/c/Program Files (x86)/VMware/VMware Workstation/vmrun.exe`.

## Controller toolchain (this WSL Ubuntu 24.04 box)

- pipx-installed: `ansible-core 2.21.2` (matches the framework's pin range
  `>=2.21.1,<2.22`), `ansible-lint`, `yamllint` — all at `/root/.local/bin/`.
- Collections: `ansible.windows 3.7.0`, `community.windows 3.3.0` (user-scope).
- Windows transport: **SSH** (not WinRM) with `ansible_shell_type: powershell`,
  `become: false` (org-standard decision, pending research ratification in the
  style guide).

## Known tech debt

See `docs/TECH-DEBT.md`. Headline: the framework v3 loader is not Windows-aware
(`package_facts` hard-fails; POSIX temp-dir). The playbook carries marked TD-001
workarounds; the proper fix is an upstream framework PR, deferred by Director decision
(2026-07-15) to keep focus on the local role.

## Dev process

One command at a time through the adapted strict-cycle
(`_handoff/loop/STRICT-CYCLE-adapted.md`): Claude plans (with research) → Director
consulted → Codex adversarially reviews the plan → Codex executes on agreement →
Claude validates gate + style alignment → merge with ledger row → style guide
(`docs/ansible-style-guide.md`) updated as rules get ratified. The build queue lives
in `_handoff/QUEUE.md`; the ledger in `_handoff/REVIEW.md`.

## Verification

```bash
export PATH="$PATH:/root/.local/bin"
yamllint -c .yamllint.yml ansible
# ansible-lint MUST run from the composed tree — the role only resolves there,
# and the chassis .ansible-lint profile applies (repo-side playbook lint fails
# syntax-check by design):
(cd .compose/ansible-framework && ansible-lint applications/wsus)
bash -n scripts/compose-and-run.sh scripts/revert-vm.sh
```
