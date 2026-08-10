# Tech debt register

Only open debt should require attention. Closed entries remain as a short decision record so old
workarounds are not accidentally restored.

## TD-001 — CLOSED: Windows loader workarounds

- **Recorded:** 2026-07-15
- **Closed:** 2026-08-07 by the byte-identical v3.3.0 loader from ansible-framework commit
  `24a8ec74a7965b3a6f9cc827455962d541ff6d73`.
- **Resolution:** Windows guards now skip POSIX package and temporary-directory paths. The
  playbook's package-fact seed and `wsus.temp_dir: false` workaround were removed. The play keeps
  `become: false` because the elevated Windows SSH account must not inherit the framework's POSIX
  `sudo` default; that is a transport setting, not a loader workaround.

## TD-002 — CLOSED: chassis lint supports the `#region` idiom

- **Recorded:** 2026-07-15
- **Closed:** 2026-07-30 by framework pin
  `5f5cae8104a8a64fd923e5c20271d0591d891bc9`.
- **Resolution:** the framework lint profile treats the established region comments as warnings,
  while safety violations remain fatal.

## TD-003 — CLOSED: local loader diverged from the framework

- **Closed:** 2026-08-07.
- **Resolution:** `ansible/applications/wsus/tasks/main.yml` is byte-identical to the v3.3.0
  loader at the current ansible-framework pin. The composed quality gate checks the pinned chassis
  on every change.

## TD-004 — deprecated IIS application-pool module

- **What:** WsusPool tuning uses `community.windows.win_iis_webapppool`, which is deprecated for
  removal in `community.windows` 4.0.0 in favor of `microsoft.iis.web_app_pool`.
- **Why it remains:** the pinned collection set is `community.windows` 3.3.0 and does not yet carry
  `microsoft.iis`; changing module families without a live convergence proof is higher risk than
  retaining the pinned implementation.
- **Exit criteria:** add an exact `microsoft.iis` collection pin, migrate and validate the attribute
  mapping, prove two live converges with `changed=0` on the second pass, then remove the deprecated
  collection dependency if no other task consumes it.

## TD-005 — SUSDB relocation is outside Microsoft support guidance

- **What:** the role relocates the WID-backed SUSDB from the system volume to the declared database
  volume by detaching, copying, and reattaching it. The implementation now observes state on every
  run, fails closed on ambiguous file pairs, restores services, and attempts a healthy reattach on
  failure, but those controls do not make the topology Microsoft-supported.
- **Risk:** a Windows/WSUS/WID change can invalidate the recovery procedure, and a hard interruption
  inside the relocation window remains more complex than leaving WID in its default location.
- **Exit criteria:** choose one supported operating model: keep WID/SUSDB on its default volume, or
  move the service to a separately supported SQL Server design. Remove the detach/copy/attach path
  and prove greenfield, reboot, interrupted-run recovery, and second-converge behavior live.

## TD-006 — cleanup and proof freshness are GitHub-dependent

- **What:** the lifecycle destroys its own stack and the hourly GitHub reaper is provenance- and
  age-gated, but GitHub status checks are not an atomic AWS lease. Public-repository schedules can
  also be delayed or disabled after inactivity.
- **Current containment:** deploy and reaper have separate non-cancelling concurrency groups; the
  reaper refuses missing provenance, all nonterminal lifecycle states, resources younger than four
  hours, and stale Terraform locks. Incident reporting is deduplicated.
- **Exit criteria:** deploy an AWS-native conditional lease with expiry/heartbeat, a janitor with a
  dedicated least-privilege cleanup role, and external alarms for an eight-day-old proof, expired
  resources, stale locks, and certificates within 45 days of expiry. Keep the GitHub reaper only as
  a secondary signal or remove its mutation authority after the native guardrail is proven.

## TD-007 — exact quality-tool version/checksum tuples lack atomic update discovery

- **What:** Renovate maintains the GitHub Actions, exact Python requirements, and Ansible Galaxy
  collection pins, while the dedicated framework updater owns both framework commit pins. Neither
  automation updates the coupled Actionlint, ShellCheck package, Terraform CLI, and AWS Session
  Manager plugin version/checksum values in `quality-tools.env`.
- **Current containment:** every clean CI run installs or verifies the exact set, and the recurring
  AWS proof exercises the runtime pins. Breakage is loud, but a compatible old release can age
  silently.
- **Exit criteria:** add a supported, primary-source-backed updater that changes each version and
  checksum atomically, validates the downloaded artifacts, couples Terraform to the pinned
  framework's exact requirement, and maintains one reviewable PR without credentials or
  auto-merge. Do not replace this with arbitrary or unauthenticated version scraping.

## TD-008 — CLOSED: dependency automation conforms to the Renovate-only org policy

- **Recorded:** 2026-08-07 after `.github/dependabot.yml` opened PRs #5 and #6 contrary to the
  accepted Renovate-only organization policy.
- **Closed:** 2026-08-07. The Dependabot configuration was deleted and both PRs were closed
  unmerged. The installed, unsuspended organization Renovate app covers this repository after the
  local configuration lands on `main`.
- **Resolution:** `.github/renovate.json5` extends exactly the canonical Terraform-runner preset,
  adds bounded Python/Galaxy and Actions groups, disables auto-merge, excludes framework-pin files,
  and is CODEOWNED. The offline required gate enforces Renovate presence and Dependabot absence.
  Exact `quality-tools.env` tuple discovery deliberately remains TD-007; do not reintroduce a
  second dependency bot to conceal it.

## TD-009 — the Windows image is a pinned vendor AMI, not a self-published one

- **What:** `terraform/aws.tfvars` addresses the image by literal id
  (`ami-04807a1de3f592cc5`, `Windows_Server-2025-English-STIG-Full-2026.07.15`, owner
  `801119661308`). The pinned framework accepts that only through a vendor allowlist its own
  source marks `TEMPORARY — hardcoded until those images are mirrored into the catalog`.
  Catalog selectors remain locked to images the deploying account published.
- **Consequence:** the pin does not track upstream. Amazon republishes the STIG images roughly
  monthly, and nothing in this repository detects that ours has aged — a green proof badge can
  therefore attest to a months-old image. This is accepted deliberately, not overlooked.
- **Current containment:** the id is reviewed source, changed only through the required gate,
  and the proof exercises whatever image is pinned. Staleness is silent; freshness is manual.
- **Exit criteria:** a self-published, account-owned Windows Server 2025 image stamped with
  `ImageFamily`/`ImageVersion` and pointed at by `/nwarila/ami/windows/*`. At that point `ami`
  becomes the catalog selector `windows@2025`, the framework's vendor allowlist collapses back
  to `["self"]`, and version currency becomes the publisher's monotonicity guarantee rather
  than a human noticing. Close this entry only when the selector is a catalog address.

## TD-010 — the role's embedded PowerShell has no parse, lint, or unit gate

- **Recorded:** 2026-08-10
- **What:** 2,288 of `present_windows.yml`'s 3,195 lines are PowerShell stored as YAML string
  literals, including a 704-line HTTPS listener reconciler interpolated into two tasks and
  roughly 500 lines of verbatim helper duplication (`New-WsusServerManager` exists three times;
  the SUSDB location probe twice, byte-identical). No gate parses that code: `verify.sh` runs
  no `pwsh`, so a quoting error in a rescue-path block ships green and first executes during an
  incident — the C12c failure class at larger scale. Part of the offline suite pins source
  substrings to hold the duplicates identical, a test standing in for a missing abstraction.
  One interpolation (`config.tls.thumbprint` at the listener reconciler's recovery path)
  violates the style guide's §5 env-only input rule and is likewise pinned by a test.
- **Current containment:** the split-args gate covers the free-form `win_shell` transport
  hazard; the offline suite pins the load-bearing contracts; the live lifecycle with its
  second-converge `changed=0` assertion remains the only executable proof of the PowerShell.
- **Exit criteria:** extract the embedded programs to role `files/*.ps1` invoked through
  `win_powershell` `path:` with typed `parameters:` (available at the pinned `ansible.windows`
  3.7.0), one arc per change, each proven by the live lifecycle; keep the native-module tasks
  and the `block`/`rescue`/`always` boundaries exactly where they are. Gate every extracted
  file with a PowerShell parse check, PSScriptAnalyzer, and Pester scoped to the pure
  functions, pinned in `quality-tools.env` like the other tools. Shared helpers end up defined
  once; the substring-synchronization tests are replaced by unit tests on the extracted
  functions, never deleted ahead of that replacement. If migration empties the `win_shell`
  inventory, invert the split-args gate to assert absence. Close this entry when
  `present_windows.yml` carries orchestration only and every `.ps1` parses and lints in the
  credential-free gate.
