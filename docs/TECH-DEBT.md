# Tech debt register

## TD-001 — local WSUS loader and chassis require Windows workarounds

- **Recorded:** 2026-07-15
- **Where:** `ansible/applications/wsus/tasks/main.yml` is still the local v3.1.0
  loader. The pinned framework now supplies a v3.2.1 loader with Windows guards, but
  changing `.github/ansible-framework-pin` does not replace this repository's overlaid loader.
- **Local loader gaps on a Windows target over SSH and PowerShell:**
  1. `INIT | Loading Installed Package Facts` runs
     `ansible.builtin.package_facts`, which requires Python and hard-fails on Windows.
  2. `INIT | Creating/Securing Temporary Directory` uses
     `ansible.builtin.tempfile` and POSIX file attributes. The playbook bypasses this
     path with `wsus.temp_dir: false`; the WSUS role does not consume the loader's
     staging directory.
  3. The loader's explicit `ansible.builtin.setup` call still needs verification on
     this transport. Playbook-level `gather_facts: true` supplies the required facts
     first, so the loader skips that task.
  4. The framework chassis sets POSIX `sudo` become defaults, so the Windows play
     must continue to set `become: false`.
- **Workarounds in `ansible/playbooks/wsus.yml`:** playbook-level fact gathering,
  `wsus.temp_dir: false`, a pre-task that seeds an empty
  `ansible_facts.packages`, and play-level `become: false`.
- **Seed safety:** the pre-task uses
  `set_fact: packages: {} / cacheable: true`. It must not set a variable named
  `ansible_facts`; doing so shadows the live facts store and hides later facts-module
  results. The role must not treat the seeded empty package map as observed package
  state.
- **Override caveat:** an extra-vars `wsus:` dictionary replaces the playbook's
  dictionary. Any such override must restate `temp_dir: false` while the local
  v3.1.0 loader remains.
- **Remediation:** replace the local loader with the byte-identical v3.2.1 loader
  from the pinned framework. Its Windows guards skip `package_facts` and the POSIX
  temp-directory lifecycle, allowing the package seed and `temp_dir: false` to be
  removed. Verify the setup path independently before removing playbook fact
  gathering; retain `become: false` while the chassis still defaults to POSIX
  privilege escalation.
- **Exit criteria:** no Windows compatibility workaround remains in the playbook,
  and the remaining transport and privilege-escalation behavior is either supported
  directly by the pinned framework or documented as a play-level requirement.

## TD-002 — CLOSED: chassis ansible-lint config supports the `#region` idiom

- **Recorded:** 2026-07-15
- **Closed:** 2026-07-30 by framework pin
  `5f5cae8104a8a64fd923e5c20271d0591d891bc9`.
- **Original issue:** the framework chassis `.ansible-lint` safety profile treated every
  `#region` / `#endregion` banner as a fatal `yaml[comments]` violation, while the chassis
  `.yamllint.yml` already treated the same established idiom as a warning.
- **Resolution observed:** the pinned framework's `.ansible-lint` now includes
  `yaml[comments]` in `warn_list`. The plain composed-tree `ansible-lint` command therefore
  reports these comments as warnings without failing. No repository-side gate override is
  needed.

## TD-003 — local v3.1.0 loader differs from the pinned v3.2.1 loader

- **What:** `ansible/applications/wsus/tasks/main.yml` was advanced from v3.0.0 to
  v3.1.0 to add the generic `INIT | Validating Merged Configuration` hook. After
  merging the running configuration, the loader includes an optional
  `tasks/validate.yml` and passes the merged `config`.
- **Current framework state:** the framework pinned at
  `5f5cae8104a8a64fd923e5c20271d0591d891bc9` carries a shared v3.2.1 loader that
  includes the validation hook and Windows guards. The original missing-upstream-hook
  condition is resolved.
- **Remaining debt:** the local WSUS loader is still v3.1.0 and is not byte-identical
  to the pinned v3.2.1 loader. The pin bump alone does not update files overlaid from
  this repository.
- **Exit criteria:** replace `ansible/applications/wsus/tasks/main.yml` with the exact
  pinned v3.2.1 loader and verify byte identity. This also enables the TD-001 package
  and temporary-directory workaround removal.

## TD-004 — WsusPool tuning uses the deprecated `community.windows.win_iis_webapppool`

- **What:** the role tunes the WsusPool IIS app pool with
  `community.windows.win_iis_webapppool`. That module is **deprecated for removal in
  `community.windows` 4.0.0**, superseded by
  `microsoft.iis.web_app_pool`.
- **Why it remains:** `microsoft.iis` is not installed in this controller's
  collection set. Switching would add a collection dependency for a module that
  still works with the installed `community.windows 3.3.0`.
- **Debt:** the role depends on a module slated for removal; a future `community.windows` 4.x bump
  would break WsusPool tuning.
- **Rollout:** when the collection set is next bumped (or `microsoft.iis` is added as a dependency),
  migrate the `MAIN | Tune WsusPool Application Pool` task from `community.windows.win_iis_webapppool`
  to `microsoft.iis.web_app_pool` (verify the `attributes` mapping / parameter shape), add
  `microsoft.iis` to the composition's collection requirements, and verify
  convergence and idempotency before closing TD-004.
