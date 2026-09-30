# Tech debt register

Only open debt should require attention. Closed entries remain as a short decision record so old
workarounds are not accidentally restored.

## TD-001 — CLOSED: Windows loader workarounds

- **Recorded:** 2026-07-15
- **Closed:** 2026-08-07 by the byte-identical v3.3.0 loader from ansible-framework commit
  `24a8ec74a7965b3a6f9cc827455962d541ff6d73`.
- **Resolution:** Windows guards now skip POSIX package and temporary-directory paths. The
  playbook's package-fact seed and `wsus.temp_dir: false` workaround were removed. The play
  keeps `become: false` because the elevated Windows SSH account must not inherit the
  framework's POSIX `sudo` default; that is a transport setting, not a loader workaround.

## TD-002 — CLOSED: chassis lint supports the `#region` idiom

- **Recorded:** 2026-07-15
- **Closed:** 2026-07-30 by framework pin `5f5cae8104a8a64fd923e5c20271d0591d891bc9`.
- **Resolution:** the framework lint profile treats the established region comments as
  warnings, while safety violations remain fatal.

## TD-003 — CLOSED: local loader diverged from the framework

- **Closed:** 2026-08-07.
- **Resolution:** the role's loader was made byte-identical to the v3.3.0 loader at the current
  ansible-framework pin, and the composed quality gate checked the pinned chassis on every
  change.
- **Superseded:** the WSUS role was removed on 2026-08-23 for the SQL Server rebuild. The
  loader contract carries forward to every role the rebuild introduces; see [the migration
  contract](wsus-role-migration-contract.md).

## TD-004 — deprecated IIS application-pool module

- **What:** a constraint on the WSUS role being rebuilt, not on code that exists today.
  WsusPool tuning was written against `community.windows.win_iis_webapppool`, deprecated for
  removal in `community.windows` 4.0.0 in favour of `microsoft.iis.web_app_pool`.
- **Why it remains open:** the pinned collection set is `community.windows` 3.3.0 and carries
  no `microsoft.iis`, so the rebuilt role cannot simply adopt the successor.
- **Exit criteria:** the rebuilt role tunes WsusPool through an exactly pinned `microsoft.iis`,
  with the attribute mapping validated and two live converges reporting `changed=0` on the
  second.

## TD-005 — PARTIALLY CLOSED: SUSDB relocation was outside Microsoft support guidance

- **What:** the role relocated the WID-backed SUSDB from the system volume to the declared
  database volume by detaching, copying, and reattaching it. No amount of state observation
  made that topology Microsoft-supported.
- **Resolved:** 2026-08-23. The detach/copy/attach path was removed with the role. The exit
  criteria offered two supported models, and the second was taken — SQL Server, where SUSDB is
  placed by `wsusutil postinstall` rather than moved after the fact.
- **Residual:** the SQL design is chosen, not yet proven. Greenfield, reboot, interrupted-run
  recovery, and second-converge behaviour must all be demonstrated live before this closes. The
  contracts the replacement owes are enumerated in [the migration
  contract](wsus-role-migration-contract.md).

## TD-006 — cleanup depends on one workflow finishing

- **Recorded:** 2026-08-07. Amended 2026-08-25, when the age-gated reaper was removed.
- **What:** the lifecycle destroys its own stack on every path its job survives to reach. There
  is no AWS-native lease, so a job that is cancelled or exhausts its budget strands paid
  resources, and a public repository's scheduled runs can themselves be delayed or disabled.
- **Consequence:** larger than when this was recorded. The hourly reaper that used to sweep
  stranded resources went with the chassis rebuild, so nothing outside the run cleans up after it.
- **Current containment:** the workflow destroys interrupted predecessor state before it applies,
  and a singleton non-cancelling concurrency group keeps two runs from racing. Both live inside
  the same workflow whose failure is the hazard.
- **Exit criteria:** an AWS-native conditional lease with expiry and heartbeat, a janitor holding
  its own least-privilege cleanup role, and external alarms for a stale proof, expired resources
  and stale locks.

## TD-009 — the Windows image is a pinned vendor AMI, not a self-published one

- **What:** `terraform/aws.tfvars` addresses four images by literal id, all owner `801119661308`:
  `ami-0c1499dbc4eaf1bf6` (`Windows_Server-2022-English-Full-SQL_2022_Standard-2026.09.17`),
  `ami-0373950d5ba064b67` (`EC2LaunchV2-Windows_Server-2019-English-Full-Base-2026.09.17`),
  `ami-0ed58a129008c2cc2` (`Windows_Server-2022-English-Full-Base-2026.09.17`), and
  `ami-00d8aa800578d8b12` (`Windows_Server-2025-English-Full-Base-2026.09.17`). The pinned
  framework accepts them only through a vendor allowlist its own source marks `TEMPORARY —
  hardcoded until those images are mirrored into the catalog`. Catalog selectors remain locked
  to images the deploying account published.
- **Consequence:** the pin does not track upstream. Amazon republishes these images roughly
  monthly, and nothing in this repository detects that ours has aged — a green proof badge can
  therefore attest to a months-old image. This is accepted deliberately, not overlooked.
- **Current containment:** the id is reviewed source, changed only through the required gate,
  and the proof exercises whatever image is pinned. Staleness is silent; freshness is manual.
- **Exit criteria:** a self-published, account-owned Windows Server image stamped with
  `ImageFamily`/`ImageVersion` and pointed at by `/nwarila/ami/windows/*`. At that point `ami`
  becomes a catalog selector, the framework's vendor allowlist collapses back to `["self"]`,
  and version currency becomes the publisher's monotonicity guarantee rather than a human
  noticing. A self-published image must still carry a licensed SQL Server, which is what the
  vendor image supplies today. Close this entry only when the selector is a catalog address.

## TD-012 — CLOSED: the lab WSUS server matches the Server 2022 production target

- **Recorded:** 2026-08-23 as a Server 2025 pin, closed 2026-08-24 by repinning to Server 2022,
  and reopened 2026-08-25 when the image had to carry a licensed SQL Server.
- **Closed:** 2026-09-29. The WSUS server now runs the Server 2022 SQL image
  `ami-0c1499dbc4eaf1bf6` (`Windows_Server-2022-English-Full-SQL_2022_Standard-2026.09.17`). The
  pinned framework installs OpenSSH from the staged Feature-on-Demand cab, reachable through the
  S3 managed prefix list, before Ansible connects.

## TD-013 — SUPERSEDED: no PowerShell gate, and the org template it will return to is defective

- **Recorded:** 2026-08-25, when `aws_windows_disk_manager` and its `Set-DiskOnlineState` pair
  were deleted and `.github/workflows/powershell.yml` went with them.
- **Superseded:** 2026-09-30. The gate returned with the first WSUS pair (#46), and the pairs now
  live under `scripts/` (owner decision, 2026-09-30: "Scripts + Stub"), the directory holding them
  directly. There the template's SARIF naming — relative to `scan-path` in `pester-matrix.yaml`,
  bare in `harness/Invoke-PairTests.ps1` — agrees, as it always has for `pdq-deploy-inventory`,
  so the exit criteria, an upstream fix and a caller naming the role tree, describe nothing this
  repository still needs.
