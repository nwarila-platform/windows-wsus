# Tech debt register

## TD-001 — ansible-framework v3 loader is not Windows-aware

- **Recorded:** 2026-07-15 (Director decision: defer upstream fix, build role locally)
- **Where:** `applications/*/tasks/main.yml` (framework generic loader v3.0.0,
  byte-identical copy shipped in this repo's `wsus` role)
- **Gaps on a Windows target (SSH + PowerShell):**
  1. `INIT | Loading Installed Package Facts` runs `ansible.builtin.package_facts`
     (Python-only, no disable flag) → hard-fails on Windows.
  2. `INIT | Creating/Securing Temporary Directory` uses `ansible.builtin.tempfile` +
     POSIX/SELinux `file` attrs → Windows-incompatible (bypassable by design via
     `<role>.temp_dir: false`).
  3. Loader's explicit `ansible.builtin.setup` call: needs verification that it routes
     to `ansible.windows.setup` under `ansible_shell_type=powershell`; playbook-level
     `gather_facts: true` sidesteps it (loader skips when facts exist).
  4. Framework chassis `ansible.cfg` sets `become=True` with `sudo` → POSIX-only;
     Windows plays must set `become: false`.
- **Workarounds carried in `ansible/playbooks/wsus.yml`** (each marked `TD-001`):
  playbook-level fact gathering; `wsus.temp_dir: false` (role stages its own via
  `ansible.windows.win_tempfile`); pre-task seeding an empty `ansible_facts.packages`;
  play-level `become: false`.
- **Seed form (fixed C01/P4, commit 78cad4f):** the seed is
  `set_fact: packages: {} / cacheable: true`. It must NEVER set the name
  `ansible_facts` (the original `combine(...)` form did): a set_fact variable named
  `ansible_facts` shadows the live facts store and silently hides every later facts
  module's results (bit `win_disk_facts` in C01). The role must still not read
  `ansible_facts.packages` while the seed exists.
- **Override caveat (C01/P4):** an extra-vars `wsus:` dict REPLACES the playbook's
  `wsus:` dict; any `-e` override must re-state `temp_dir: false` or the loader's
  POSIX temp-dir path re-activates and fails the run.
- **Proper fix:** framework PR "loader v3.1 Windows support" — guard `package_facts`
  with `ansible_facts.os_family != 'Windows'`, add a `win_tempfile`-based temp-dir
  branch, document Windows become/transport expectations in the chassis. Any future
  Windows role needs this; the workarounds here are the evidence base for that PR.
  **Gate:** as a loader change, this proposal must pass
  the loader-change gate (two independent validations,
  generic-preservation proof, Director acceptance) BEFORE the upstream PR is opened.
- **Exit criteria:** framework release containing v3.1 → bump `.framework-pin` →
  delete the playbook workarounds → close TD-001.

## TD-002 — chassis ansible-lint config conflicts with the ratified `#region` idiom

- **Recorded:** 2026-07-15 (C01/P4 discovery; pending Director disposition)
- **Where:** framework chassis `.ansible-lint` (`profile: safety`, `warn_list` lacks
  `yaml[comments]`)
- **Symptom:** the documented gate `(cd .compose/ansible-framework && ansible-lint
  applications/wsus)` exits 2 with every `#region`/`#endregion` banner counted as a
  fatal `yaml[comments]` violation (34 in the wsus role at C01). This is NOT a wsus
  problem: the framework's own `applications/python3_pip` fails its own gate
  identically (exit 2). The chassis `.yamllint.yml` already treats the same banners
  as warnings — the two chassis configs disagree about the established idiom.
- **Interim gate (used from C01 on, proposed in review and independently validated):**
  `ansible-lint --warn-list 'yaml[comments]' applications/wsus` — 0 failures /
  34 warnings, matching the yamllint stance. The verification snippet in `AGENTS.md`
  still shows the plain command; update it once the Director accepts this gate.
- **Proper fix:** upstream framework PR adding `yaml[comments]` to the chassis
  `.ansible-lint` `warn_list` (config-only; NOT a loader change, so the normal PR
  process applies — no loader-change-protocol gate needed). Evidence base: this
  entry + C01 lint logs.
- **Exit criteria:** framework release with the warn_list fix → bump
  `.framework-pin` → drop the `--warn-list` flag from the gate → close TD-002.

## TD-003 — local v3 loader carries a `validate.yml` hook not yet upstream

- **What:** `ansible/applications/wsus/tasks/main.yml` was bumped **v3.0.0 → v3.1.0** under a
  one-time Director-approved exception (two independent reviewers: unanimous APPROVE, per
  the loader-change gate) to add a GENERIC `INIT | Validating Merged
  Configuration` hook: after merging the running config, the loader includes the role's optional
  `tasks/validate.yml` (`first_found`, skipped if absent), passing the merged `config`. This gives
  every role a place to assert its MERGED-config contract, which `meta/argument_specs.yml` cannot see.
- **Debt:** the loader is no longer **byte-identical / hash-matched** to the framework's v3.0.0
  (the ratified invariant, style §3). Until the framework adopts v3.1.0, the local loader diverges.
- **Rollout (panel conditions):** upstream v3.1.0 to `ansible-framework` **atomically** — every v3
  loader copy (applications/wsus, applications/python3_pip, all v3 consumers) to identical v3.1.0
  bytes in one commit; grep every consumer repo (incl. the 4 wazuh roles) for a pre-existing
  `tasks/validate.yml` before release; then bump `.framework-pin`, re-copy, and re-verify sha256
  equality → close TD-003 (restores the byte-identical invariant).
- **Evidence:** the V change record + the both independent reviewers verdicts (loader-change gate).
