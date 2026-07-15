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
- **Proper fix:** framework PR "loader v3.1 Windows support" — guard `package_facts`
  with `ansible_facts.os_family != 'Windows'`, add a `win_tempfile`-based temp-dir
  branch, document Windows become/transport expectations in the chassis. Any future
  Windows role needs this; the workarounds here are the evidence base for that PR.
  **Gate:** as a loader change, this proposal must pass
  the loader-change gate (two independent validations,
  generic-preservation proof, Director acceptance) BEFORE the upstream PR is opened.
- **Exit criteria:** framework release containing v3.1 → bump `.framework-pin` →
  delete the playbook workarounds → close TD-001.
