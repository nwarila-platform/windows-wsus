# nwarila-platform — Ansible style & design guide

> **STATUS: DRAFT — rules are ratified one at a time during build cycles.**
> Each rule carries a status: `RATIFIED` (Director-approved, enforceable),
> `SEEDED` (decided at kickoff, pending in-cycle validation), or `TBD`.
> Golden references: `wazuh_agent` (task-file authoring idiom, newest wazuh-repo role)
> and `ansible-framework/applications/python3_pip` (framework fit, loader v3 contract).

## 1. Repo & composition model — SEEDED (kickoff 2026-07-15)

- One single-purpose role per application repo; the repo composes into a
  version-pinned `ansible-framework` checkout at execution time (`.framework-pin`,
  `scripts/compose-and-run.sh`). Roles must be drop-in compatible with the framework's
  `applications/` namespace (`roles_path` resolution by bare name).
- The framework is the chassis: `ansible.cfg`, lint configs, loader contract, CI
  conventions all originate upstream. Application repos copy `.yamllint.yml` /
  `.editorconfig` for local dev parity.

## 2. Naming — SEEDED

- Repo: `windows-wsus` (OS-prefixed product). Role: `wsus` (bare product name,
  resolves via framework `roles_path`). Playbook: `wsus.yml`. Inventory group:
  `wsus_servers` (pluralized component, mirrors `wazuh_indexers`).
- Role defaults live under `<role>_defaults` in `defaults/main.yml`; the merged
  running config materializes as `<role>_running`; playbook overrides use the bare
  `<role>:` dict. (Loader v3 contract.)

## 3. Loader contract — SEEDED (framework v3.0.0)

- Every role ships the framework's generic loader as `tasks/main.yml`,
  **byte-identical, never edited per-role**. Loader changes are governance-surface →
  upstream framework PR only.
- **RATIFIED (Director, 2026-07-15):** `tasks/main.yml` is intentionally a generic,
  hash-matched global loader. Any recommended change and/or optimization
  recommendation targeting it MUST be validated by **two independent agents from
  different model families — one an independent reviewer and one a second independent reviewer** — each
  independently confirming (i) the change is warranted at all (default NO) and
  (ii) it is a generic improvement that fits EVERY consuming role comfortably,
  preserving the hash-match invariant. Full gate:
  the loader-change gate. Unanimous agreement + Director
  acceptance required; otherwise the loader does not change.
- OS task files: `<state>_<family>[_<dist>[_<ver>]].yml`, resolved most-specific-first
  via `first_found`. This role ships `present_windows.yml` + `clean_windows.yml`
  (family-level; `os_family=Windows`).
- Vars overlays: `vars/<family>[_...][_<env>].yml`, recursive combine,
  `list_merge='replace'`. `ENV` is mandatory and regex-validated by the loader.

## 4. Task authoring idioms — SEEDED (from wazuh_agent + python3_pip; ratify per cycle)

- Task names: `'STAGE | Imperative description'` — stages observed: `INIT`, `MAIN`,
  `BEGIN` (input guards), `END` (verification), `Cleanup`, `INFO` (block wrappers).
- `#region` / `#endregion` banner comments delimit logical sections; files open with
  the boxed header comment (`File:`, description, version where applicable).
- Fully-qualified collection names always (`ansible.builtin.*`, `ansible.windows.*`).
- Asserts use `quiet: true` with actionable, templated `fail_msg`.
- Comments explain WHY (contract, failure modes), not what.
- Service/state verification: retry loops with explicit `retries`/`delay`/`until`
  rather than fixed sleeps (wazuh_agent END-stage pattern).

## 4a. Role scope — the "handed machine" contract — RATIFIED (Director, 2026-07-15)

- The application role configures the target **end-to-end**. Its input contract is a
  machine handed to it as **OS + reachable SSH + attached-but-blank data disks** —
  exactly what a fresh Terraform-provisioned (today: snapshot) VM provides. From that
  point the role owns **all guest OS state**: storage init (Initialize/format/label/
  assign), features, app install, configuration, and verification.
- **Boundary:** *hardware provisioning* (disk count/size/attachment, vCPU/RAM, NIC)
  belongs to the deploy layer (baseline snapshot now, proxmox-terraform-framework
  later). *Guest OS state* belongs to the role. Formatting a disk into the baseline
  image is FORBIDDEN — it must be role-declared code, proven on every clean revert.
- This intentionally **diverges from wazuh**, where storage prep is an operator/packer
  prerequisite outside the app role. For nwarila-platform Windows app repos the app
  role is the single E2E configurator of the machine it is handed.
- Disk identification is **declarative by a stable per-disk identifier — never
  disk-number- nor size-coupled** (amended C01r, 2026-07-15): select the target disk
  by its declared `unique_id` (Windows Get-Disk `UniqueId` / `win_disk_facts.unique_id`,
  e.g. `eui.<hex>`), supplied as a REQUIRED input — never by size and never by
  enumeration number, so the role is robust to enumeration order AND size changes.
  (`unique_id` is populated on RAW/blank disks and stable through GPT initialization.)

## 4b. BEGIN stage contract — RATIFIED (C01 seeded, C01r ratified 2026-07-15)

- The BEGIN stage is strictly **read-only**: facts gathering and asserts only. The
  first mutating task belongs to the piece that owns it, never to a guard.
- Declarative disk (or resource) selection must assert **exactly one** match per
  declared spec — zero and multiple matches are both hand-off failures, failed
  loudly with a fail_msg that enumerates what was actually found; never silently
  resolved. Declared specs must be mutually distinguishable (e.g. distinct identifiers).
- Guard pieces carry a negative proof (a deliberately-wrong input must fail on the
  intended assert, and sibling specs must still pass — per-spec discrimination) in
  addition to the clean-baseline presence proof. (Exercised: C01 presence/absence/
  ambiguity proofs.)

## 5. Windows conventions — SEEDED (first Windows role; ratify via research per cycle)

- Transport: **SSH** (org standard; key auth, one transport story across the fleet).
  `ansible_shell_type: powershell`; target's OpenSSH `DefaultShell` = PowerShell.
- `become: false` at play level (framework chassis `become=sudo` is POSIX-only;
  built-in administrator over SSH is already elevated). Revisit for least-privilege
  runs (runas) when a non-admin service account is introduced — TBD.
- Windows modules from `ansible.windows` (fallback `community.windows`); never invoke
  raw PowerShell where a module exists — TBD threshold for `win_shell` escape hatch.
- Loader Windows gaps are TD-001 workarounds in the playbook, not role hacks — see
  `docs/TECH-DEBT.md`.
- **RATIFIED (C01r, 2026-07-15) — required per-target inputs are dedicated top-level
  vars.** Environment-specific inputs the role cannot default (e.g. disk identifiers
  `wid_disk_id` / `wsus_disk_id`) are declared as top-level vars and asserted in the
  BEGIN guard, mirroring the loader's `ENV`/`state` contract — NOT nested in the
  `<role>:` override dict. This keeps a proof/override `-e` from clobbering sibling
  config (a `-e` `<role>:` dict *replaces* the playbook's dict). The README must
  clearly separate these required top-level inputs from merged `<role>_defaults`
  config (operators must not write `<role>.<var>`).
- **PROPOSED (C01):** never `set_fact` the name `ansible_facts` — the resulting
  set_fact variable shadows the live facts store and silently hides every later
  facts module's results (proven C01/P4: `win_disk_facts` results invisible until
  the TD-001 seed was rewritten to `packages: {} / cacheable: true`).

## 6. Controller & toolchain — SEEDED

- pipx-installed `ansible-core` pinned to the framework's supported range
  (currently 2.21.x), plus `ansible-lint`, `yamllint`. Collections pinned:
  `ansible.windows`, `community.windows`.
- Windows targets are never long-lived dev state: revert the lab VM to the clean
  baseline snapshot before every playbook execution (`scripts/revert-vm.sh`).
- **Lint from the composed tree** (proof S4b, 2026-07-15): the playbook's role
  resolves only inside the composed framework checkout, so `ansible-lint` runs from
  `.compose/ansible-framework/` (which also supplies the chassis `.ansible-lint`
  profile). Repo-side `ansible-lint <playbook>` fails `syntax-check` by design — do
  not "fix" that by vendoring a roles_path shim without a ratified rule.
- SSH multiplexing is isolated per-repo (`.compose/.cp`, pre-cleaned every run) —
  stale ControlMaster sockets from killed runs or VM reverts hang plays silently
  (proof S3, 2026-07-15).

## 7. Commits & process — SEEDED

- Conventional Commits, scope = role name or `framework` (framework CI enforces
  upstream; this repo follows the same format).
- Build process: one command per cycle via the cycle definition;
  every cycle ends with a ledger row and any style-rule ratifications recorded here
  with the cycle ID.

## 8. Open questions (moved to RATIFIED/rule sections as cycles decide them)

- `win_shell`/`win_command` escape-hatch policy and idempotency guards.
- Handler usage & service-restart conventions on Windows.
- Molecule (or equivalent) test story for Windows roles — framework roles ship
  `molecule/`; no Windows driver decision yet.
- Argument specs (`meta/argument_specs.yml`) — wazuh roles use them; python3_pip's
  meta shape TBD against it.
- Secrets handling for Windows (no vault usage yet in this repo).
