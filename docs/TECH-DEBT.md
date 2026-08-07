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
