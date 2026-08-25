# WSUS role migration contract

The WSUS role and its offline test were removed together when the repository moved from WID to
SQL Server. Neither was discarded: the role's behavioural contracts are recorded here, and each
carries a disposition that the rebuilt roles must satisfy.

This exists because a removed test is only acceptable when the authority it guarded is removed
with it and its contract is written down. Nothing below may be dropped silently. A contract marked
*reproduce* is a debt against the rebuild; one marked *invert* must become an assertion that the
old authority is **absent**.

Source of record: `ansible/applications/wsus/tests/test_susdb_state_table.py` and
`ansible/applications/wsus/tasks/present_windows.yml`, both preserved on branch
`snapshot/pre-sql-rebuild`.

## Why the role could not simply be edited

The old role's database authority is WID. WSUS on WID and WSUS on SQL Server differ at the
postinstall boundary — `wsusutil postinstall` takes `SQL_INSTANCE_NAME` instead of creating a WID
instance — and every SUSDB probe, recovery classifier and health check downstream is written
against the WID service. Editing in place would have left WID assumptions in the recovery paths
where they are hardest to see.

## Task contracts

| Contract | Disposition |
|---|---|
| `INFO \| Entering OS Tasks (present_windows - wsus)` | reproduce — role entry marker |
| `MAIN \| Ensure WID Service Is Automatic And Running Before SUSDB Probes` | **invert** — assert the WID service and its SUSDB authority are absent |
| `MAIN \| Classify The Pre-Postinstall SUSDB Action` | reproduce against SQL |
| `MAIN \| Refuse Ambiguous SUSDB Authority Before Post-Installation Repair` | reproduce — fail-closed guard, unchanged in intent |
| `MAIN \| Adopt And Verify The Preserved SUSDB Before Post-Installation Repair` | reproduce against SQL |
| `MAIN \| Run WSUS Post-Installation (WID, content on F:)` | reproduce with `SQL_INSTANCE_NAME`; the WID form must not survive |
| `MAIN \| Classify The SUSDB Recovery Action` | reproduce against SQL |
| `MAIN \| Verify SUSDB Relocation Health` | reproduce against SQL |
| `MAIN \| Remove SUSDB Originals From System Volume` | reproduce |
| `MAIN \| Ensure WSUS Services Are Running After SUSDB Convergence` | reproduce |
| `MAIN \| Reconcile The WSUS Content Location` | reproduce |
| `MAIN \| Grant Users Browse Access On The Content Root` | reproduce — but see the log-ACL conflict below |
| `MAIN \| Grant WSUS Service Rights On The Content Cache` | reproduce |
| `MAIN \| Restrict WSUS Update Languages` | reproduce |
| `MAIN \| Configure Upstream WSUS Source` | reproduce |
| `MAIN \| Bootstrap WSUS Category Sync To Terminal Success` | reproduce |
| `MAIN \| Tune WsusPool Application Pool` | reproduce, **and extend** — rapid-fail protection is required by IIS Site STIG V-218777/V-218778 and is not WSUS-exempt |
| `MAIN \| Probe The Pinned Certificate In The Machine Store` | reproduce |
| `MAIN \| Validate The PFX Before Import` | reproduce |
| `MAIN \| Bind The Pinned Certificate To The WSUS HTTPS Endpoint` | reproduce |
| `MAIN \| Require SSL On The Client-Facing WSUS Endpoints` | reproduce exactly — the five-vdir list is vendor-fixed |
| `MAIN \| Reconcile Existing WSUS HTTPS Listener Before API Access` | reproduce |
| `MAIN \| Activate And Verify The WSUS HTTPS Listener` | reproduce |
| `VERIFY \| Complete A Live HTTPS Request To The WSUS Client Endpoint` | reproduce |
| `VERIFY \| Assert The Complete WSUS Runtime Contract` | reproduce |

## Test methods

Twenty-three offline assertions guarded the contracts above. Each must reappear against the
rebuilt role or be recorded here as deliberately dropped with a reason.

- Authority-state coverage: allowed states; ambiguous and incomplete states fail closed; target
  authority survives every source-cleanup kill boundary; the matrix fails closed before
  postinstall; adoption is health-gated and precedes postinstall.
- Content: reconcile uses copying `movecontent` and fails closed on split brain; reconcile has an
  explicit idempotent no-change path; service ACL and runtime verifier cover the exact content
  contract.
- Sync: a stale marker stops old work and starts exactly one owned category sync; the runtime
  verifier recomputes the exact bootstrap fingerprint.
- API session: persisted SSL uses a process-scoped pinned loopback session; every WSUS API actor
  uses the shared session and no direct cmdlet; the MWA runtime factories are
  indentation-normalised identical.
- TLS: every certificate gate requires an explicit Server Authentication EKU; binding converges and
  verifies an exact wildcard empty-host listener; the live probe sends an HTTP request with the
  intended SNI and Host; listener activation is bounded, idempotent and site-scoped; SSL vdir
  convergence uses an applicationHost commit and a two-phase proof; a null vdir default is
  repairable but a missing schema is fatal.
- Pool and site: the runtime verifier rechecks every declared pool tuning value, and rechecks site
  start and auto-start before the API.
- Safety: remaining `win_shell` commands stay below the safe `CreateProcess` budget.

## Conflicts the rebuild inherits

Two contracts above collide with the STIG surface the rebuild adds, and neither is resolved here:

- **`Grant Users Browse Access On The Content Root`** and the log-directory equivalent grant
  `BUILTIN\Users` read access as a ratified organisational convention (Director, 2026-07-18). IIS
  Site STIG **V-283673** permits only SYSTEM, Administrators, and an approved Web Administrators
  group. One must yield.
- **`Tune WsusPool Application Pool`** sets `idleTimeout` and the recycle interval to `0` on
  Microsoft's instruction. IIS Site STIG **V-218762** forbids an idle timeout of `0`, and its WSUS
  exemption is conditional on the host serving no other content — which the relocated Default Web
  Site may void.
