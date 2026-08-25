# WSUS role migration contract

The WID-backed `wsus` role and its offline test were removed together when the repository moved to
SQL Server. Neither was discarded. Every behavioural contract they carried is recorded here with a
disposition the rebuilt role must satisfy, so that a removed test is a recorded obligation rather
than a silently lowered bar.

Four dispositions are used, and every named task and every test method carries exactly one:

| Disposition | Meaning |
|---|---|
| `reproduce` | The rebuilt role owes the same authority, unchanged. |
| `reproduce against SQL` | The authority survives; the mechanism, literal, or matrix changes. The note names what changes. |
| `invert` | The old authority is gone. The rebuild must assert its **absence**, not merely omit it. |
| `drop` | Genuinely not owed. The note gives the reason. |

## Source of record

Commit `9856be49d923f9628e52a5a16c71a75ca6b91c81` — `origin/main`'s tip for these paths and the last
revision in which the role existed:

```
ansible/applications/wsus/tasks/present_windows.yml    77 named tasks
ansible/applications/wsus/tasks/validate.yml            6 named tasks
ansible/applications/wsus/tasks/clean_windows.yml       1 named task
ansible/applications/wsus/tests/test_susdb_state_table.py   23 test methods, 384 assertion call sites
ansible/applications/wsus/defaults/main.yml
ansible/applications/wsus/vars/windows.yml
ansible/applications/wsus/README.md
```

A SHA and not a branch, because the branch does not match. `snapshot/pre-sql-rebuild`
(`f9580ac8ae316d1f956a2c8371b301c0194e5861`) asserts the WsusPool actor as
`microsoft.iis.web_app_pool`; the deleted revision asserts `community.windows.win_iis_webapppool`,
which is the module the pinned collection set actually provides (TD-004). Reconstructing from the
branch would therefore reproduce a contract that never ran.

## Why the role could not simply be edited

WID is not one setting in the old role. It is the feature set installed, the service reconciled
before every database probe, the named-pipe connection string every SUSDB query opens, a fixed
system-volume source directory, the ACL identity on the database volume, one of the four
post-install completion flags, and a clause in the final verifier. `wsusutil postinstall` selects
WID by the *absence* of `SQL_INSTANCE_NAME`, so the WID build is what you get by default and the
divergence is invisible at the call site. An in-place edit would have left WID assumptions in the
recovery and classification paths, which are exactly the paths that only execute after an
interruption and therefore fail late and unobserved.

The relocation arc compounds it. Under WID, SUSDB is created on the system volume and moved by
detach, copy, and reattach — the unsupported topology TD-005 records. Under SQL Server the instance
places SUSDB where its configured data and log directories point, so the entire arc is replaced by
one preparatory act before post-install rather than translated task for task.

## `tasks/present_windows.yml` — all 77 named tasks

Listed in file order, including block, `rescue`, and `always` children. The index is the position a
recursive walk yields, so this table diffs directly against the file.

| # | Task | Disposition | Note |
|---:|---|---|---|
| 1 | `MAIN \| Resolve The Windows System Drive` | drop | Its only consumer is `__wid_source_dir__`. No SQL path is derived from `%SystemDrive%`. |
| 2 | `INFO \| Entering OS Tasks (present_windows - wsus)` | reproduce | Role entry marker and carrier of the seven block variables dispositioned separately below. |
| 3 | `MAIN \| Ensure WSUS Content Directory Exists` | reproduce | `<content letter>:\<content_subdir>`, created before post-install. |
| 4 | `MAIN \| Install WSUS Server Role (WID) And IIS HTTP Logging` | reproduce against SQL | Feature list becomes `UpdateServices`, `UpdateServices-DB`, `UpdateServices-Services`, `Web-Http-Logging` with `include_management_tools: true`. `UpdateServices-WidDB` inverts (see the WID table). The `include_sub_features` prohibition survives with its reason inverted: it previously had to be omitted because `-IncludeAllSubFeature` pulls `UpdateServices-DB`; it must now be omitted because that flag pulls `UpdateServices-WidDB`. |
| 5 | `MAIN \| Reboot After Windows Feature Installation When Required` | reproduce | One reboot inside the feature transaction, before post-install or any database mutation. |
| 6 | `MAIN \| Ensure WID Service Is Automatic And Running Before SUSDB Probes` | invert | See the WID table. |
| 7 | `MAIN \| Ensure WID Data Directory Exists` | reproduce against SQL | The directory obligation survives on the DB volume; the `WID\Data` path form inverts. |
| 8 | `MAIN \| Grant WID Service Account Rights On The Relocation Target` | invert | See the WID table. |
| 9 | `MAIN \| Grant Users Browse Access On The WID Data Directory` | reproduce against SQL | The `BUILTIN\Users` `ReadAndExecute` convention survives on the SQL data directory; the WID path inverts. Collides with the STIG surface — see *Conflicts*. |
| 10 | `MAIN \| Probe WSUS Post-Installation State` | reproduce against SQL | The `Installed Role Services` registry probe survives; the required flag set must be re-measured on a SQL build, and `UpdateServices-WidDatabase` may not appear in it. |
| 11 | `MAIN \| Observe SUSDB Attachment Before Post-Installation Repair` | reproduce against SQL | Same query (`sys.master_files` for `DB_ID('SUSDB')`) over a local SQL instance connection; the `source` verdict has no SQL analogue, `absent`, `target`, and `other` remain. |
| 12 | `MAIN \| Observe SUSDB File Pairs Before Post-Installation Repair` | reproduce against SQL | The `target-mdf`/`target-ldf` half survives. The `source-mdf`/`source-ldf` half drops with the fixed WID source directory. |
| 13 | `MAIN \| Resolve The Pre-Postinstall SUSDB Observation` | reproduce against SQL | Source count collapses to zero by construction. |
| 14 | `MAIN \| Classify The Pre-Postinstall SUSDB Action` | reproduce against SQL | Exact matrix recorded under `PrePostinstallSusdbAuthorityTest`. |
| 15 | `MAIN \| Refuse Ambiguous SUSDB Authority Before Post-Installation Repair` | reproduce | Fail-closed guard before post-install may create a database. Unchanged in intent. |
| 16 | `MAIN \| Adopt And Verify The Preserved SUSDB Before Post-Installation Repair` | reproduce against SQL | `CREATE DATABASE ... FOR ATTACH` against the SQL instance, behind four health gates, all four required: `state_desc` is `ONLINE`, `is_read_only` is `0`, `$files.Count` is at least 2, and no `physical_name` falls outside the target directory. Rollback detaches only when `$attachedHere` is true — a database this invocation did not attach is never detached by its own failure path. This is what makes the operating system replaceable while the data volume survives. The offline test pinned three of the four gates and omitted the file count; the source is the contract, so the rebuilt suite owes all four. |
| 17 | `MAIN \| Run WSUS Post-Installation (WID, content on F:)` | reproduce against SQL | `wsusutil postinstall SQL_INSTANCE_NAME=<instance> CONTENT_DIR=<content root>`, `argv` form, no trailing backslash. The WID form inverts; the task name must lose `WID`. |
| 18 | `MAIN \| Observe The Attached SUSDB Location` | reproduce against SQL | Per-run observation, not gated on post-install having changed in this run — the interruption lesson that gate cost. |
| 19 | `MAIN \| Observe SUSDB Source And Target File Pairs` | reproduce against SQL | Target half survives; source half drops with the WID source directory. |
| 20 | `MAIN \| Resolve The Observed SUSDB State` | reproduce against SQL | Resolves three facts from the two probes above: the trimmed location verdict, and two counts taken by **positional slice** of the four-item file probe — `results[0:2]` for the source pair, `results[2:4]` for the target pair. `__susdb_source_count__` disappears with the system-volume source pair, and the surviving target count moves to `results[0:2]`. The indices are load-bearing rather than cosmetic: left at `[2:4]` against a two-item loop they select an empty slice and count zero, so a host holding a complete target pair would resolve as though it held none. |
| 21 | `MAIN \| Discard Any Unattached Target While Source SUSDB Is Authoritative` | drop | Predicated on `location == 'source'`, which SQL cannot reach. A destructive rule whose precondition no longer exists must not be carried forward. |
| 22 | `MAIN \| Normalize The Source-Authoritative SUSDB Target State` | drop | Exists only to normalise the count that task 21 produced. |
| 23 | `MAIN \| Remove An Incomplete Recoverable Unattached SUSDB Target Pair` | invert | The deletion is gated on `location == 'absent'`, `source_count == 2`, `target_count == 1`: the complete source pair *is* the safety proof, and under SQL that count is zero by construction. Carrying the deletion forward without it leaves the sole durable fragment destructible under no recorded authority. The rebuild asserts the opposite — an unattached sole partial pair is left untouched and classifies fail-closed. Any future provenance-based deletion is a new reviewed authority, not a migration of this one. |
| 24 | `MAIN \| Normalize The Recoverable Unattached SUSDB Target State` | drop | It exists only to zero the count that task 23's deletion produced. With no deletion there is nothing to normalise, and normalising anyway would launder the partial state past the fail-closed guard. |
| 25 | `MAIN \| Classify The SUSDB Recovery Action` | reproduce against SQL | Exact matrix recorded under `SusdbStateTableTest`; the `rebuild_from_source` and `copy_from_source` verdicts drop with the relocation. |
| 26 | `MAIN \| Assert SUSDB Has One Recoverable State` | reproduce | Fail-closed guard: an unattached database with two complete pairs is never guessed. |
| 27 | `MAIN \| Converge SUSDB Attachment To The Data Volume` | drop | The relocation block. TD-005: SQL places SUSDB at post-install rather than moving it after the fact. |
| 28 | `MAIN \| Stop WSUS Consumers For SUSDB Relocation` | drop | Brackets the relocation only. |
| 29 | `MAIN \| Detach The System-Volume SUSDB` | drop | The unsupported operation TD-005 was opened for. |
| 30 | `MAIN \| Copy A Complete SUSDB Pair To The Data Volume` | drop | Relocation. |
| 31 | `MAIN \| Attach SUSDB From The Data Volume` | drop | Relocation. Its health gate survives in tasks 16 and 37, which is where the assertion belongs. |
| 32 | `RECOVER \| Reattach The Best Complete SUSDB Pair` | drop | Rescue for a block that no longer exists. |
| 33 | `RECOVER \| Fail After SUSDB Relocation Recovery` | drop | The rule it encodes — a best-effort recovery may restore service but must never let the run report success — is a standing rule for any `rescue` the rebuild adds, not a task that is owed. |
| 34 | `RECOVER \| Restore WSUS Consumer Services` | drop | `always` half of the relocation bracket. |
| 35 | `MAIN \| Ensure WSUS Services Are Running After SUSDB Convergence` | reproduce | `W3SVC` then `WsusService`, started. |
| 36 | `MAIN \| Reconcile Existing WSUS HTTPS Listener Before API Access` | reproduce | Verbatim, including its `win_powershell` transport. See `HttpsListenerContractTest`. |
| 37 | `MAIN \| Verify SUSDB Relocation Health` | reproduce against SQL | Becomes a placement-health check: ONLINE, `is_read_only = 0`, at least two files, every `physical_name` under the declared data directory. Rename off `Relocation`. |
| 38 | `MAIN \| Remove SUSDB Originals From System Volume` | invert | Nothing may place a SUSDB file on the system volume under SQL, so the rebuild asserts the absence instead of performing the deletion. |
| 39 | `MAIN \| Reconcile The WSUS Content Location` | reproduce | Copying `movecontent` (never `-skipcopy`), registry/API/IIS triple verified, registry-only split brain fails closed. |
| 40 | `MAIN \| Grant Users Browse Access On The Content Root` | reproduce | Collides with the STIG surface — see *Conflicts*. |
| 41 | `MAIN \| Grant WSUS Service Rights On The Content Cache` | reproduce | `NT AUTHORITY\NETWORK SERVICE` FullControl, inheritable. |
| 42 | `MAIN \| Assert WsusPool Exists Before Tuning` | reproduce | Refuses to let the pool module create a bogus generic pool when post-install did not run. |
| 43 | `MAIN \| Tune WsusPool Application Pool` | reproduce against SQL | Same six attributes and values; the module changes under TD-004. Extend with rapid-fail protection, required by IIS Site STIG V-218777/V-218778 and not WSUS-exempt. |
| 44 | `MAIN \| Restrict WSUS Update Languages` | reproduce | `AllUpdateLanguagesEnabled = false` plus an order-insensitive compare and post-`Save()` re-read. |
| 45 | `MAIN \| Configure Upstream WSUS Source` | reproduce | Five-field diff, stop any in-flight sync before `Save()`, verify the persisted five. |
| 46 | `MAIN \| Wait For The Configured Upstream WSUS Endpoint` | reproduce | Conditional on `sync.bootstrap_enabled`. |
| 47 | `INFO \| Synchronization Proof Is Deliberately Disabled` | reproduce | The honesty marker: with the bootstrap off the run is a configuration smoke and claims nothing about reachability. |
| 48 | `MAIN \| Bootstrap WSUS Category Sync To Terminal Success` | reproduce | Full invocation-ownership contract under `BootstrapInvocationContractTest`. |
| 49 | `MAIN \| Relocate IIS Logs To G:` | reproduce | `siteDefaults` and every site's `logFile.directory`/`enabled`, literal drive-qualified path, `%VAR%` treated as drift. |
| 50 | `MAIN \| Validate + Normalize IIS wwwroot Target` | reproduce | Validate before any native module can expand a bad override. |
| 51 | `MAIN \| Copy IIS wwwroot Content To G:` | reproduce | Content before repoint, so the relocated root is populated. |
| 52 | `MAIN \| Repoint InetStp PathWWWRoot To G:` | reproduce | Both registry views, including `Wow6432Node`. |
| 53 | `MAIN \| Repoint Default Web Site Root To G:` | reproduce | Default Web Site only; the WSUS Administration site is untouched. |
| 54 | `MAIN \| Set IIS Log Directory ACLs (SYSTEM/Admins FullControl, Users R&X)` | reproduce | Three ACEs, additive. Collides with the STIG surface — see *Conflicts*. |
| 55 | `MAIN \| Resolve The TLS Enablement Flag` | reproduce | Pinned as a host fact because the block conditional is re-evaluated inside the included delivery role, where a lazy `config` binding resolves against that role's name. |
| 56 | `MAIN \| Deliver, Validate, Import, And Bind The TLS Certificate` | reproduce | Block wrapper; its `always` children are the cleanup contract. |
| 57 | `MAIN \| Resolve The Pinned TLS Identity` | reproduce | Normalises the pin once, `trim \| upper`, so every later thumbprint comparison runs against one canonical form. |
| 58 | `MAIN \| Probe The Pinned Certificate In The Machine Store` | reproduce | Converged-pass short circuit; enforces private key, validity window, EKU, and DNS/wildcard identity. |
| 59 | `MAIN \| Create A Unique TLS Staging Directory On The Controller` | reproduce | Controller-side `tempfile` with prefix `windows-wsus-tls-`, delegated to localhost with `become: false` and `changed_when: false`. |
| 60 | `MAIN \| Restrict The Controller TLS Staging Directory` | reproduce | Mode `0700`. |
| 61 | `MAIN \| Resolve The Unique TLS Delivery Coordinates` | reproduce | Host facts, because the included role's scope boundary discards task vars. |
| 62 | `MAIN \| Download The TLS Certificate And Password To The Controller` | reproduce | Controller-side `s3_artifact_delivery`; the target never holds an S3 credential. |
| 63 | `MAIN \| Read The PFX Password Into Protected Memory` | reproduce | `no_log`. |
| 64 | `MAIN \| Create A Unique TLS Staging Directory On The Target` | reproduce | `win_tempfile` with the same `windows-wsus-tls-` prefix. Unique per run, so a failed or concurrent run cannot leave PFX bytes for the next one to reuse. |
| 65 | `MAIN \| Copy The Certificate To The Unique Target Path` | reproduce | `changed_when: false` — delivering the artifact is not convergence, and only the import and binding below may report change. |
| 66 | `MAIN \| Validate The PFX Before Import` | reproduce | `EphemeralKeySet` with the documented `MachineKeySet` fallback for legacy CAPI keys; sanitised verdict markers only. |
| 67 | `MAIN \| Enforce The PFX Validation Verdict` | reproduce | Separate task because `no_log` censors the validator's own output. |
| 68 | `MAIN \| Import The Validated Certificate Into The Machine Store` | reproduce | `key_exportable: false`. |
| 69 | `MAIN \| Assert The Pinned Leaf Exists In The Machine Store` | reproduce | Queries the converged store rather than trusting the import module's returned thumbprints. |
| 70 | `MAIN \| Bind The Pinned Certificate To The WSUS HTTPS Endpoint` | reproduce | Full contract under `test_binding_converges_and_verifies_exact_wildcard_empty_host_listener`. |
| 71 | `MAIN \| Require SSL On The Client-Facing WSUS Endpoints` | reproduce | The five-vdir list is vendor-fixed; written out below. |
| 72 | `MAIN \| Activate And Verify The WSUS HTTPS Listener` | reproduce | Same shared reconciler as task 36. |
| 73 | `VERIFY \| Complete A Live HTTPS Request To The WSUS Client Endpoint` | reproduce | 12 retries, 5s apart, `until rc == 0`. |
| 74 | `CLEANUP \| Remove The Unique TLS Staging Directory From The Target` | reproduce | `always`. |
| 75 | `CLEANUP \| Remove The Unique TLS Staging Directory From The Controller` | reproduce | `always`. |
| 76 | `CLEANUP \| Clear The In-Memory PFX Password Fact` | reproduce | `always`, `no_log`. |
| 77 | `VERIFY \| Assert The Complete WSUS Runtime Contract` | reproduce against SQL | Independent read-only acceptance gate. Its WID service clause inverts; everything else survives. Full assertion list below. |

### Block variables carried by task 2

The entry task's `vars` are where the WID literals actually live, so a task-name table alone would
miss them.

| Variable | Disposition | Note |
|---|---|---|
| `__content_dir__` | reproduce | `<content letter>:\<content_subdir>`. |
| `__wid_data_dir__` | reproduce against SQL | The DB-volume path survives; the name and the `WID\Data` default do not. |
| `__wid_source_dir__` | invert | `<SystemDrive>\Windows\WID\Data`. |
| `__wid_conn_master__` | invert | `server=\\.\pipe\MICROSOFT##WID\tsql\query;database=master;trusted_connection=true;` |
| `__postinstall_flags__` | reproduce against SQL | `['UpdateServices-API', 'UpdateServices-Services', 'UpdateServices-UI', 'UpdateServices-WidDatabase']`, each required `== 2`. The fourth element inverts. |
| `__wsus_api_invoker__` | reproduce | Verbatim. The single API connection primitive; contract under `WsusApiConnectionContractTest`. |
| `__wsus_https_listener_reconciler__` | reproduce | Verbatim. Contract under `HttpsListenerContractTest`. |

## `tasks/validate.yml` — all 6 named tasks

Every task is gated on `state == 'present'`; the TLS pair is additionally gated on
`config.tls.enabled`.

| # | Task | Disposition | Note |
|---:|---|---|---|
| 1 | `BEGIN \| Assert Data Disk Drive Letters Are Distinct` | reproduce | Three distinct `^[D-Z]$` letters. The disk-manager role validates its own declaration and cannot see this role's independently overrideable targets. |
| 2 | `BEGIN \| Assert Application Paths Match Their Declared Disks` | reproduce against SQL | Same predicates — relative, non-traversing, no `:`/`%`/`..`, IIS paths literal on the IIS letter — with `db_subdir` no longer defaulting to a WID-shaped name. |
| 3 | `BEGIN \| Assert Upstream WSUS Server Provided` | reproduce | Required input, no default. |
| 4 | `BEGIN \| Assert Synchronization Contract` | reproduce | Port 1–65535; unique `^[a-z]{2}(-[a-z0-9]+)?$` languages; accept timeout `>= 30`, completion `>= 300`, poll `2..60`; and `wsus-upstream.corp.local` is refused whenever `bootstrap_enabled` is true, so the repository placeholder can never be mistaken for proof. |
| 5 | `BEGIN \| Assert TLS Delivery Inputs` | reproduce | Bucket name pattern, non-traversing non-absolute `pfx_key`, port 1–65535, `minimum_validity_days >= 1`, and a multi-label FQDN `dns_name`. |
| 6 | `BEGIN \| Assert TLS Thumbprint Pin Format` | reproduce | Exactly 40 hex characters, checked before delivery so a malformed pin cannot fail after the import. |

The rebuild owes one addition here that the deleted file could not have: the SQL instance name is
now required input, and the same fail-early argument that justifies tasks 3 and 6 applies to it.

## `tasks/clean_windows.yml` — 1 named task

| # | Task | Disposition | Note |
|---:|---|---|---|
| 1 | `INFO \| Nothing To Clean (no role-owned caches yet)` | drop | It asserts nothing. It exists so `state: clean` resolves to a task file instead of failing resolution. If the rebuilt role dispatches a `clean` state it needs the same no-op, but that is a loader requirement, not a preserved contract. |

## WID authorities that must be inverted

Marking only the service — as the previous revision of this document did — leaves a SQL build free
to install the WID database feature, connect over the WID named pipe, and grant the WID virtual
account rights on the data volume, with nothing failing. Each row below is an authority the deleted
role asserted positively; the rebuild owes an assertion that it is gone.

| WID authority | Where it lived | Inversion the rebuild owes | Positive SQL counterpart |
|---|---|---|---|
| `UpdateServices-WidDB` Windows feature | `present_windows.yml` task 4, lines 837–845 | The feature is absent | `UpdateServices-DB` present |
| `MSSQL$MICROSOFT##WID` service, `start_mode: auto`, `state: started` | task 6, lines 859–869; re-asserted in the runtime verifier via `Get-CimInstance -ClassName Win32_Service -Filter 'Name = "MSSQL$MICROSOFT##WID"'` with `StartMode = 'Auto'` and `State = 'Running'` | The WID service is not installed | The SQL Server instance service Automatic and Running before the first SUSDB probe, with the same ordering obligation |
| `NT SERVICE\MSSQL$MICROSOFT##WID` FullControl, `ContainerInherit, ObjectInherit`, on the DB directory | task 8, lines 881–891 | That ACE is absent | The SQL instance's per-service SID granted FullControl on the SQL data directory — the grant is still load-bearing, because without it an attached SUSDB comes up read-only and WSUS silently stops syncing |
| WID master named pipe `server=\\.\pipe\MICROSOFT##WID\tsql\query;database=master;trusted_connection=true;` | block var `__wid_conn_master__`, passed as `WID_CONN` to seven scripts | No `MICROSOFT##WID` literal survives anywhere in the role | A local connection to the SQL instance's `master` |
| `<SystemDrive>\Windows\WID\Data` as the fixed SUSDB source, and its `SUSDB.mdf` / `SUSDB_log.ldf` pair | block var `__wid_source_dir__`; probed by tasks 12 and 19; deleted by task 38 | No SUSDB file exists on the system volume | Every SUSDB file under the declared DB-volume data directory, asserted by the placement check |
| `UpdateServices-WidDatabase` as one of the four required `Installed Role Services` completion flags (`== 2`) | block var `__postinstall_flags__` | It is not in the required set | The SQL build's own flag set, re-measured on the target, carrying `UpdateServices-Database` |
| `db_subdir` default `WID\Data` | `defaults/main.yml` | The default does not name WID | A SQL-shaped relative name on the same DB letter |
| Absence of `SQL_INSTANCE_NAME` on `wsusutil postinstall` as the backend selector | task 17 | The argument is present and non-empty | The instance name is required, validated input |
| Detach / copy / attach relocation of SUSDB | tasks 27–34 | No detach or attach of SUSDB occurs on a converged run | The SQL instance's default data and log directories pinned to the DB volume **before** post-install, so placement is creation rather than movement |

## Test contracts

23 test methods across nine classes, carrying 384 assertion call sites. The prose summary the
previous revision offered is not a contract: the assertions are exact literals, exact matrices, and
exact orderings, and those values are what the rebuilt suite must re-encode. They are recorded here
by the method that carried them, each under its own disposition: 12 `reproduce`, 9
`reproduce against SQL`, 2 `invert`, none dropped. Nothing here is owed less than it was.

### Fixture contracts

Three module-level helpers impose obligations of their own, independent of any method, and all
three `reproduce`:

- `walk_tasks` recurses `block`, `rescue`, and `always`, so every ordering and set assertion below
  covers nested tasks.
- `named_task(name)` raises unless **exactly one** task carries that name. Task names are therefore
  unique identifiers, not labels.
- `powershell_script(task)` raises unless a task carries **exactly one** inline script. A task may
  not carry both `ansible.windows.win_shell` and `ansible.windows.win_powershell`.

### `PowerShellTransportContractTest`

**`test_remaining_win_shell_commands_stay_below_the_safe_createprocess_budget`** —
`reproduce against SQL`. The budget model and the `< 30000` bound survive unchanged; the
largest-task pin is a measurement of the deleted script set and must be re-taken against the rebuilt
one. For every task carrying `ansible.windows.win_shell`, `community.windows.win_shell`, or bare
`win_shell` (string or `cmd:` mapping form), with `{{ __wsus_api_invoker__ }}` and
`{{ __wsus_https_listener_reconciler__ }}` textually expanded from task 2's `vars`:

- No `{{` or `{%` survives expansion, and no helper name survives its own substitution.
- Budget model: prefix `` [Console]::InputEncoding = New-Object Text.UTF8Encoding `$false;  ``,
  encode UTF-16LE, base64 as `4 * ((bytes + 2) // 3)`, add 512 characters of fixed headroom. The
  result must be `< 30000`.
- At least one measurement exists, and the single largest is
  `MAIN | Require SSL On The Client-Facing WSUS Endpoints`.

That last equality is the load-bearing half: it pins which task is closest to the
`CreateProcessW` rc206 boundary, so a rebuild that grows a different script past it fails here
rather than on the host.

### `SusdbStateTableTest` — the post-post-install recovery matrix

The classifier is rendered as a Jinja template against `(location, source_count, target_count)`,
after the two pre-classification normalisation rules the test mirrors: `source`/2/`>0` sets target
to 0, and `absent`/2/1 sets target to 0.

**`test_allowed_authority_states`** — `reproduce against SQL`. The matrix is owed; its shape is
not. With no fixed source directory the `source` location and the `source_count` dimension both
collapse, taking `rebuild_from_source` and `copy_from_source` with them, and the two normalisation
rules the test mirrors go with tasks 21–24. The rebuilt matrix must be re-derived and tabulated in
full rather than trimmed from this one. The nine states with a verdict:

| location | source | target | verdict |
|---|---:|---:|---|
| source | 2 | 0 | `rebuild_from_source` |
| source | 2 | 1 | `rebuild_from_source` |
| source | 2 | 2 | `rebuild_from_source` |
| target | 0 | 2 | `converged` |
| target | 1 | 2 | `converged` |
| target | 2 | 2 | `converged` |
| absent | 2 | 0 | `copy_from_source` |
| absent | 2 | 1 | `copy_from_source` |
| absent | 0 | 2 | `attach_target` |

**`test_ambiguous_or_incomplete_states_fail_closed`** — `reproduce against SQL`. The
enumerate-everything-and-default-to-`invalid` discipline survives verbatim; the named regression
changes, because `("absent", 2, 2)` is unreachable once the source dimension is gone. Its SQL
analogue is the sole partial pair `("absent", 0, 1)` that task 23's inversion makes fail-closed. The
full cross product of `location ∈ {source, target, absent, other}` × `source ∈ {0,1,2}` ×
`target ∈ {0,1,2}`, less the nine above, must classify `invalid`. The destructive regression is
asserted a second time on its own: `("absent", 2, 2) -> invalid`. Without an attachment neither
complete pair is authoritative, so the target must never win merely by existing.

**`test_target_authority_survives_every_source_cleanup_kill_boundary`** — `invert`. The whole method
exists because a system-volume source pair could linger after an interrupted cleanup; under SQL
there is no source pair and task 38 no longer deletes one. The rebuilt suite asserts the absence:
no task deletes SUSDB files from the system volume, and none exist there. Source cleanup is a
two-item loop, so a kill lands before either deletion, between them, or after both.
`("target", 2, 2)`, `("target", 1, 2)`, and `("target", 0, 2)` all classify `converged`. The
cleanup task's `loop` is exactly `["SUSDB.mdf", "SUSDB_log.ldf"]`, and
`MAIN | Verify SUSDB Relocation Health` precedes `MAIN | Remove SUSDB Originals From System Volume`
in walk order — health before deletion, never the reverse.

### `PrePostinstallSusdbAuthorityTest` — the pre-post-install authority matrix

No normalisation applies here; the raw observation classifies directly.

**`test_authority_matrix_fails_closed_before_postinstall`** — `reproduce against SQL`. The two
data-loss boundaries are the reason for the matrix and survive intact; `source_attached` disappears
with the source dimension, and the `("absent", 2, 2)` / `("source", 2, 2)` regressions become their
SQL analogues. The full 4 × 3 × 3 cross product,
where anything not listed classifies `invalid`:

| location | source | target | verdict |
|---|---:|---:|---|
| absent | 0 | 0 | `fresh` |
| absent | 0 | 2 | `adopt_target` |
| target | 0 | 2 | `target_attached` |
| target | 1 | 2 | `target_attached` |
| target | 2 | 2 | `target_attached` |
| source | 2 | 0 | `source_attached` |

The two data-loss boundaries are asserted again individually: `("absent", 0, 2) -> adopt_target`
(post-install must not create a fresh database over a sole preserved target) and both
`("absent", 2, 2)` and `("source", 2, 2) -> invalid` (it must not choose between competing complete
pairs).

**`test_adoption_is_health_gated_and_precedes_postinstall`** — `reproduce against SQL`. Same
fragments against the SQL connection, plus the file-count gate the test omitted (see task 16); the
`changed_when` literal and all three ordering relations reproduce as written. The adoption script
contains `CREATE DATABASE SUSDB`, `$state -ne 'ONLINE'`, `$readOnly -ne 0`, and
`$offTarget.Count -gt 0`; its `changed_when` is exactly
`__prepostinstall_adoption__.stdout | trim == 'adopted-target'`. Walk order: classify < refuse <
post-install, and adopt < post-install.

### `WidServiceContractTest`

**`test_service_is_reconciled_before_every_sql_connection_and_reverified`** — `invert`, and the
inversion must keep the method's *shape*, which is the part worth preserving. It asserted:

- The `win_service` mapping is exactly
  `{"name": "MSSQL$MICROSOFT##WID", "start_mode": "auto", "state": "started"}`.
- At least one task's `win_shell` contains `SqlConnection($env:WID_CONN)`, and the service task's
  walk index is less than **every** such task's index.
- The runtime verifier contains `Get-CimInstance -ClassName Win32_Service`,
  `Name = "MSSQL$MICROSOFT##WID"`, `$widService.StartMode -ne 'Auto'`, and
  `$widService.State -ne 'Running'`.

The rebuild owes the literals inverted (no `MICROSOFT##WID` anywhere) and the structure reproduced:
the SQL instance service reconciled to Automatic/Running before every task that opens a connection,
and re-verified independently at the end.

### `ContentStateContractTest`

**`test_reconcile_uses_copying_movecontent_and_fails_closed_on_split_brain`** — `reproduce`. The
script contains `LocalContentCachePath`, `ContentDir`, and `IIS:\Sites\WSUS Administration\Content`;
exactly one line invokes the utility and it is exactly
`$out = & $wsusutil movecontent $wantRoot $moveLog 2>&1` with no `-skipcopy`; the split-brain
messages `API already names` and `Refusing an unsupported direct registry repair` are present.

**`test_reconcile_has_an_explicit_idempotent_nochange_path`** — `reproduce against SQL`. The
idempotence contract reproduces literally; the ordering assertion needs a new anchor and a new
reason. It anchored on the renamed placement-health task, and it existed because a killed
relocation had to remain able to reach its reattach code. With no relocation the ordering still
holds, now because content reconciliation calls the WSUS API and the API needs a healthy SUSDB.
The literals: `$changed = $false`;
`if (-not (Test-ContentPath $apiBefore $wantCache))`; the exact line
`if ($changed) { Write-Output 'changed' } else { Write-Output 'nochange' }`; `changed_when` exactly
`__wsus_content_location__.stdout | trim == 'changed'`. Ordering: SUSDB health precedes content
reconciliation.

**`test_service_acl_and_runtime_verifier_cover_the_exact_content_contract`** — `reproduce`. Two
literal ACLs:

| Path | Identity | Rights | Inherit |
|---|---|---|---|
| `{{ __content_dir__ }}` | `BUILTIN\Users` | `ReadAndExecute` | `ContainerInherit, ObjectInherit` |
| `{{ __content_dir__ }}\WsusContent` | `NT AUTHORITY\NETWORK SERVICE` | `FullControl` | `ContainerInherit, ObjectInherit` |

and the runtime verifier contains `LocalContentCachePath`, `ContentDir`,
`IIS:\Sites\WSUS Administration\Content`, `S-1-5-32-545`, `S-1-5-20`, and `Test-RequiredAllowAce`.
The verifier resolves by SID, not by name, so a localised or renamed principal cannot satisfy it.

### `BootstrapInvocationContractTest`

**`test_stale_marker_stops_old_work_and_starts_one_owned_category_sync`** — `reproduce`. Ordering
inside the script: `$s.StopSynchronization()` < `$preHistoryIds = @{}` <
`$s.StartSynchronizationForCategoryOnly()`. Required fragments:
`$preHistoryIds[[string]$entry.Id] = $true`; `-not $preHistoryIds.ContainsKey([string]$_.Id)`;
`[bool]$_.StartedManually`; `$_.StartTime.ToUniversalTime() -ge $requestFloorUtc`;
`$invocationHistory.Count -ne 1`; `[string]$completed.Result -ne 'Succeeded'`;
`category_bootstrap_history_id`; `-Value ([string]$completed.Id)`. The history-ID marker is written
before the fingerprint marker, so a kill between registry writes cannot make work under an older
contract look current. Forbidden: `$startedHere` and `Write-Output 'completed'` — the two shapes of
"accepted" being mistaken for "succeeded". `changed_when` is exactly
`__wsus_bootstrap__.stdout | trim == 'changed'`.

**`test_runtime_verifier_recomputes_the_exact_bootstrap_fingerprint`** — `reproduce`. The verifier
contains `$expectedFingerprint`, `$marker.category_bootstrap_fingerprint -ne $expectedFingerprint`,
`$marker.category_bootstrap_history_id`, `$markedHistory.Count -ne 1`, and
`[string]($markedHistory[0].Result) -ne 'Succeeded'`, and must **not** contain
`[string]::IsNullOrWhiteSpace($marker.category_bootstrap_fingerprint)` — an empty fingerprint is a
mismatch, not an excuse. Five environment values are byte-identical between the bootstrap task and
the verifier:

```
UPSTREAM_SERVER  {{ config.upstream_server | string | trim }}
UPSTREAM_PORT    {{ config.sync.upstream_port }}
UPSTREAM_SSL     {{ config.sync.upstream_use_ssl | bool | lower }}
REPLICA          {{ config.sync.replica | bool | lower }}
WSUS_LANGS       {{ config.sync.update_languages | map("lower") | sort | join(",") }}
```

The fingerprint itself, computed independently by the bootstrap task and by the verifier, in full:

```
$fingerprintInput = @(
    $env:UPSTREAM_SERVER.Trim().ToLowerInvariant(),
    $env:UPSTREAM_PORT,
    $env:UPSTREAM_SSL.ToLowerInvariant(),
    $env:REPLICA.ToLowerInvariant(),
    $env:WSUS_LANGS.ToLowerInvariant()
) -join '|'
$sha = [System.Security.Cryptography.SHA256]::Create()
try {
    $fingerprint = ([System.BitConverter]::ToString(
        $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($fingerprintInput))
    )).Replace('-', '')
} finally {
    $sha.Dispose()
}
```

The two copies are the same fifteen lines at different indentation; the verifier's differs only in
assigning `$expectedFingerprint`. Four of the five inputs are lowercased and the port is passed
through as read. The joined string is encoded UTF-8 before hashing, the provider is `SHA256` and
is disposed in a `finally`, and the outer parentheses apply `.Replace('-', '')` to the whole
`BitConverter::ToString(...)` result rather than to the inner hash call. Encoding,
case-folding, the hash algorithm and that parenthesisation are all part of the contract: either
side diverging on any of them recomputes a different fingerprint, and the verifier then rejects a
marker that is in fact current.

### `WsusApiConnectionContractTest`

**`test_persisted_ssl_uses_a_process_scoped_pinned_loopback_session`** — `reproduce`. The helper
contains `$usingSsl = [int]$setup.UsingSSL`; `if ($usingSsl -eq 0)`; `IIS:\SslBindings\0.0.0.0!`;
`$boundThumbprint -notmatch '^[0-9A-F]{40}$'`; `$certificate.GetCertHashString().Replace(' ', '')`;
`}.GetNewClosure()`; `[System.Net.Security.RemoteCertificateValidationCallback]$pinnedCallback`;
`Get-WsusServer -Name '127.0.0.1' -PortNumber $port -UseSsl -ErrorAction Stop`; `} finally {`; and
`[System.Net.ServicePointManager]::ServerCertificateValidationCallback = $previousCallback`. Three
prohibitions apply to the whole task file, not just the helper: no `win_hosts`, no
`LocalMachine\Root`, no `X509Store('Root', 'LocalMachine')`. The role never writes a hosts-file
override or a machine trust anchor; client DNS and trust distribution stay external.

**`test_every_wsus_api_actor_uses_the_shared_session_and_no_direct_cmdlet`** —
`reproduce against SQL`. Set equality in both directions is the authority and must not be relaxed
to a subset check; the membership changes, since the health task is renamed and any API actor the
rebuild adds or removes rewrites the set. No task's inline
PowerShell may contain `Get-WsusServer` (the helper reaches the target through the Jinja expansion,
so a direct call is always a bypass), and the set of tasks whose script contains
`Invoke-LocalWsusApi` is exactly:

```
MAIN | Verify SUSDB Relocation Health
MAIN | Reconcile The WSUS Content Location
MAIN | Restrict WSUS Update Languages
MAIN | Configure Upstream WSUS Source
MAIN | Bootstrap WSUS Category Sync To Terminal Success
VERIFY | Assert The Complete WSUS Runtime Contract
```

Each also contains the literal `{{ __wsus_api_invoker__ }}`. Set equality in both directions: a new
API actor that skips the primitive fails, and so does one that quietly disappears.

### `WsusPoolContractTest`

**`test_runtime_verifier_rechecks_every_declared_pool_tuning_value`** — `reproduce against SQL`. The
six values and the independent verifier re-check survive unchanged; the module key the test indexes
by, and possibly the attribute names, move with the successor collection under TD-004. The actor's
`attributes` key set is exactly:

```
queueLength
recycling.periodicRestart.privateMemory
recycling.periodicRestart.memory
recycling.periodicRestart.time
processModel.idleTimeout
processModel.pingingEnabled
```

The verifier contains `$pool.<path>` for each of the six and the message
`WsusPool tuning differs from the desired`. The verifier's `WSUSPOOL_*` environment map is exactly:

```
WSUSPOOL_QUEUE_LENGTH       {{ config.wsuspool.queue_length | int }}
WSUSPOOL_PRIVATE_MEMORY_KB  {{ config.wsuspool.private_memory_kb | int }}
WSUSPOOL_VIRTUAL_MEMORY_KB  {{ config.wsuspool.virtual_memory_kb | int }}
WSUSPOOL_PERIODIC_RESTART   {{ config.wsuspool.periodic_restart }}
WSUSPOOL_IDLE_TIMEOUT       {{ config.wsuspool.idle_timeout }}
WSUSPOOL_PINGING_ENABLED    {{ config.wsuspool.pinging_enabled | bool | lower }}
```

The declared defaults those expressions resolve to: `2000`, `0`, `0`, `00:00:00`, `00:00:00`,
`false`. The actor module at the deleted revision is `community.windows.win_iis_webapppool` — the
literal `snapshot/pre-sql-rebuild` disagrees with, and the reason TD-004 is open.

### `HttpsListenerContractTest`

#### Shared helper: `assert_runtime_mwa_factory(script, expected_manager_count)`

Three methods call it, with counts 2 (listener reconciler), 2 (Require SSL), and 1 (runtime
verifier). It asserts, per script:

- The literal `[Microsoft.Web.Administration.ServerManager]` appears nowhere — the type is resolved
  at runtime, never bound at parse time.
- Exactly one `function New-WsusServerManager`, and exactly `expected_manager_count` occurrences of
  `$serverManager = New-WsusServerManager`.
- Factory body contains `[System.Environment]::Is64BitOperatingSystem`,
  `[System.Environment]::Is64BitProcess`, `if (-not $process64) {`,
  `64-bit PowerShell is required for IIS management`, `$PSVersionTable.PSVersion`,
  `$PSVersionTable.PSEdition`, `function Resolve-LoadedWsusServerManagerType`,
  `[System.AppDomain]::CurrentDomain.GetAssemblies()`, `$loadedAssembly.GetName().Name`,
  `$loadedAssembly.GetType(`, `$windowsDirectory = [string]$env:WINDIR`,
  `'System32\inetsrv\Microsoft.Web.Administration.dll'`,
  `Test-Path -LiteralPath $assemblyPath -PathType Leaf`,
  `$null = Add-Type -LiteralPath $assemblyPath`, `IIS management TypeNotFound`,
  `[System.Activator]::CreateInstance($serverManagerType)`, `$_.FullyQualifiedErrorId`,
  `$_.Exception.ToString()`, and `return $serverManager`; and contains no `Write-Output`.
- Exactly two `Resolve-LoadedWsusServerManagerType` calls and exactly one `Add-Type`.
- Strict order: first resolve < `if ($null -eq $serverManagerType) {` < `Add-Type` < second resolve
  < `Activator::CreateInstance` < the first `$serverManager = New-WsusServerManager`. Load from disk
  only after the already-loaded assembly has been searched and found wanting.

**`test_mwa_runtime_factories_are_indentation_normalized_identical`** — `reproduce`. The factory
extracted from the listener reconciler, from
`MAIN | Require SSL On The Client-Facing WSUS Endpoints`, and from
`VERIFY | Assert The Complete WSUS Runtime Contract` are byte-identical after `dedent`. Three copies
that drift are three different behaviours under one name.

**`test_every_certificate_gate_requires_explicit_server_authentication_eku`** — `reproduce`. Three
gates, each with its exact call form:

| Task | Call |
|---|---|
| `MAIN \| Probe The Pinned Certificate In The Machine Store` | `Test-ServerAuthenticationEku $cert` |
| `MAIN \| Validate The PFX Before Import` | `Test-ServerAuthenticationEku $cert` |
| `VERIFY \| Assert The Complete WSUS Runtime Contract` | `Test-ServerAuthenticationEku $certificate` |

Each script contains `$extension.Oid.Value -ne '2.5.29.37'`,
`$usage.Value -eq '1.3.6.1.5.5.7.3.1'`, and `return $false`, and must not contain `2.5.29.37.0`. The
PFX validator additionally carries `an absent EKU extension is not accepted`: a leaf with no EKU
extension is rejected rather than read as unrestricted use.

**`test_binding_converges_and_verifies_exact_wildcard_empty_host_listener`** — `reproduce`.
Transport: `ansible.windows.win_powershell` with `error_action: stop`, no `win_shell`, no
`changed_when`, `register: __tls_binding__`. Change reporting: `$Ansible.Changed = $false` precedes
`$changed = $false`, and `$Ansible.Changed = $changed` precedes
`if ($changed) { Write-Output 'changed'`. Exactly one `Write-Output 'changed'` and one
`Write-Output 'nochange'`.

Desired listener: `$desiredBinding = '*:' + $port + ':'` — wildcard address, empty host, non-SNI.
Enumeration is protocol-agnostic (`Get-WebBinding -Name $configuredSite.Name -ErrorAction Stop`,
and explicitly **not** the `-Protocol` form), with both port parses present:
`'^(?<address>.*):(?<port>[0-9]{1,5}):(?<host>.*)$'` matched from the right so a bracketed IPv6
address cannot shift the port field, and `'^(?<port>[0-9]{1,5})(?::|$)'` as the fallback for other
IIS protocols. Records carry `Site = [string]$configuredSite.Name` and
`Protocol = [string]$configuredBinding.protocol`.

Ownership before mutation: `if ($foreignBindings.Count -gt 0)` precedes
`if ($bindingDrift -or $certificateDriftBefore)`, and `refusing mutation` appears between them.
Drift detection: `function Get-WsusHttpsBindingRecords`, `$ownedHttpsBindings.Count -ne 1`,
`$desiredBindings.Count -ne 1`, `$nonDesiredTargetPortBindings.Count -gt 0`,
`[int]($desiredBindings[0].SslFlags) -ne 0`, `$boundBefore = Get-Item $sslPath`,
`$certificateDriftBefore = -not $boundBefore`.

Mutation order, all asserted: mutation guard < bounded stop
(`Stop-Website -Name $siteName -ErrorAction Stop | Out-Null`) < `Remove-WebBinding -Name $siteName`;
stop < `New-WebBinding -Name $siteName -Protocol https` < the post-binding probe
`$bound = Get-Item $sslPath -ErrorAction SilentlyContinue` < `$certificateDrift = -not $bound` <
`Remove-Item $sslPath -ErrorAction Stop`. Re-reading the provider mapping *after* recreating the
binding is the point: recreation can discard it, so the pre-mutation snapshot cannot authorise the
replacement. The stop is bounded by `for ($attempt = 0; $attempt -lt 20; $attempt++)` with
`did not stop within 10 seconds`.

Removal set and creation: `-Confirm:$false | Out-Null`;
`foreach ($candidate in @($ownedHttpsBindings) + @($ownedTargetPortBindings))` de-duplicated through
`$seenBindings.ContainsKey($key)`; the comment `WSUS HTTP payload binding on 8530` marks what is
deliberately never removed; `-IPAddress '*' -SslFlags 0`.

Post-verification: `$verifyOwnedBindings.Count -ne 1`, `$verifyOwnedHttpsBindings.Count -ne 1`,
`exactly one HTTPS binding total`, `[int]($verifyOwnedBindings[0].SslFlags) -ne 0`. Prohibited in
this task: `Restart-Service`, `Stop-Service`, `Start-Website` — binding convergence stops the site
and leaves starting it to the shared listener reconciler.

The runtime verifier repeats the same shape independently:
`$desiredBinding = '*:' + [int]$env:TLS_PORT + ':'`, `$siteBindings = @(Get-WebBinding`,
`$desiredSiteBindings = @($siteBindings`, `$siteBindings.Count -ne 1`,
`$desiredSiteBindings.Count -ne 1`, `[int]($desiredSiteBindings[0].sslFlags) -ne 0`, and
`exactly one HTTPS binding total`.

**`test_live_probe_sends_http_request_with_intended_sni_and_host`** — `reproduce`.
`$ssl.AuthenticateAsClient($env:TLS_DNS_NAME)`, `GET /ClientWebService/client.asmx HTTP/1.1`,
`Host: $($env:TLS_DNS_NAME):$($env:TLS_PORT)`, `did not return HTTP 200`, and
`changed_when: False`. A TLS handshake alone would not prove the wildcard listener honours the
intended SNI and Host contract; the GET does.

**`test_listener_activation_is_bounded_idempotent_and_site_scoped`** — `reproduce against SQL`.
Everything about the listener reproduces verbatim; only the global ordering anchors move, because
they name the WSUS services task and the six API actors, and those names change. The largest single
method.
Against the shared reconciler helper:

*Input validation and ordering.* `$usingSslText -notmatch '^[01]$'` <
`$portText = [string]$setup.PortNumber` < `if ($usingSsl -eq 0)`;
`if (-not (Test-Path -LiteralPath $sitePath))` <
`Set-ItemProperty -LiteralPath $sitePath -Name serverAutoStart -Value $true | Out-Null`. Port range
`$port -lt 1 -or $port -gt 65535`. The helper must **not** reference `$env:TLS_PORT`: the port comes
from the persisted WSUS Setup key, so the reconciler repairs the host's actual listener rather than
the one the play wished for.

*Bounded state machine.* `Get-WebItemState -PSPath $sitePath -ErrorAction Stop`;
`function Start-WsusWebsiteBounded`; exactly one
`Start-Website -Name $siteName -ErrorAction Stop | Out-Null` in the whole helper;
`$siteState -eq 'Started'`; `for ($attempt = 0; $attempt -lt 10; $attempt++)`;
`if (Test-LoopbackListener $port)`; `if (-not $listenerReady)`; `$connect.Wait(1000)`;
`for ($attempt = 0; $attempt -lt 30; $attempt++)`; `$siteState -eq 'Started' -and $listenerReady`;
`serverAutoStart=true`; `Stop-Website -Name $siteName -ErrorAction Stop | Out-Null`. Forbidden:
`Restart-Service`, `Stop-Service`, and the fact `$tlsChanged` — the reconciler is site-scoped and
never bounces a service. Two exception-walk requirements are asserted against the whole helper
rather than any slice of it, because their definitions precede the retry helper:
`[int64]$current.HResult -eq -2147024713` and `$current = $current.InnerException`. The
already-exists HResult must be recognised by walking the inner-exception chain, not by matching the
outermost exception alone. Auto-start settle order: the `serverAutoStart` mutation < the comment
`# reconciliation a bounded chance to start the site before issuing an explicit start.` < the last
`Start-WsusWebsiteBounded $port`.

*Retry helper* (the slice from `function Start-WsusWebsiteBounded` to
`function Test-LoopbackListener`): `for ($attempt = 0; $attempt -lt 20; $attempt++)`;
`if (-not (Test-AlreadyExistsHResult $_.Exception))`;
`Start-Website failed with a non-retryable exception`; `Format-ExceptionChain $_.Exception`;
`Get-WsusListenerFailureDetailsSafe $listenerPort`; `Assert-WsusPortExclusive $listenerPort`;
`view=requestq`; `Test-HttpSysPortRegistration`; `if ($currentState -eq 'Started')`;
`lastAlreadyExists=[`; no `Write-Output`. The message
`WSUS site target-port bindings became unnormalized` precedes the start command: re-prove
normalisation, then start.

*Binding repair.* `function Repair-WsusOwnedPortBindings`,
`if (Repair-WsusOwnedPortBindings $port)`, `Remove-WebBinding -Name $siteName`,
`New-WebBinding -Name $siteName -Protocol https -Port $listenerPort`, and the normalisation test
`$owned.Count -eq 1 -and $desired.Count -eq 1`.

*SSL mapping recovery.* `function Get-OrRepairCurrentSslMapping`; the comment
`Preserve the currently serving certificate here`; the recovery pin
`$recoveryThumbprint = '{{ config.tls.thumbprint | trim | upper }}'`;
`configured TLS recovery thumbprint is invalid`; `the exact pinned recovery leaf with`;
`Stop-WsusWebsiteBounded 'pre-API SSL mapping recovery'`;
`New-Item $sslPath -Value $recoveryCertificate | Out-Null`;
`pre-API SSL mapping recovery did not persist thumbprint`;
`$mapping = Get-OrRepairCurrentSslMapping $listenerPort`;
`New-Item $mapping.Path -Value $mapping.Certificate | Out-Null`;
`$verifyMapping = Get-Item $mapping.Path -ErrorAction Stop`; `$currentSslMapping.Changed`. Order:
`$currentSslMapping = Get-OrRepairCurrentSslMapping $port` <
`if (Repair-WsusOwnedPortBindings $port)` < the last `Start-WsusWebsiteBounded $port`. Recovery may
restore only the exact reviewed leaf with its private key; if that is absent it fails closed,
because artifact delivery is the sole authority that may introduce a certificate.

*Pre-SSL API access rollback.* `function Repair-PreSslWsusApiAccess` and
`if (Repair-PreSslWsusApiAccess)`, called before `Start-WsusWebsiteBounded $port $false`. Its vdir
list is exactly, in order:

```
ApiRemoting30
ClientWebService
DSSAuthWebService
ServerSyncWebService
SimpleAuthWebService
```

The reader, writer, and rollback slices may not use `Get-WebConfigurationProperty` or
`Set-WebConfigurationProperty`, and may not `Write-Output`. The reader constructs a manager, calls
`GetApplicationHostConfiguration()`, contains the exact wrapped form
`.GetSection(\n                'system.webServer/security/access', $location)`,
`$section.GetAttribute('sslFlags')`, `$value = $attribute.Value`, and disposes in `finally` via
`[void]$serverManager.Dispose()`. The writer adds the null-section and null-attribute guards
(`IIS returned no access section for`, `IIS returned no access.sslFlags attribute for`),
`$section.SetAttributeValue('sslFlags', $desiredValue)`, and `[void]$serverManager.CommitChanges()`.
The rollback writes `Set-WsusAccessSslValue $location 'None'`, reads back immediately with
`$afterWrite = Get-WsusAccessSslState $location`, and only then reaches the full-verify failure
`pre-SSL WSUS API access rollback did not persist`; both failure messages render
`expected=[None|0]` with the observed `.Type`. This exists for exactly one state: a run interrupted
between requiring SSL on the vdirs and `configuressl` persisting `UsingSSL=1`, which would otherwise
leave the HTTP API unreachable and the host unable to converge again.

*Diagnostics.* `function Limit-DiagnosticText` with `$text.Substring(0, $maxLength)`; the truncation
limits `2048`, `4096`, and `512` all present; and the six failure-report labels `W3SVC=`,
`allBindings=[`, `httpSysSsl=[`, `httpSysIpListen=[`, `httpSysServiceState=[`,
`recentWasW3svcHttpEvents=[`.

*Invocation set.* Exactly two tasks invoke `Invoke-LocalWsusHttpsListenerReconcile`:
`MAIN | Reconcile Existing WSUS HTTPS Listener Before API Access` and
`MAIN | Activate And Verify The WSUS HTTPS Listener`. Both are `win_powershell` with
`error_action: stop`, carry no `environment` and no `changed_when` and no `win_shell`, and each
contains `{{ __wsus_https_listener_reconciler__ }}`, `$listenerResult = @(`,
`$listenerResult.Count -ne 1`, `-notin @('changed', 'nochange')`, `$Ansible.Changed = $false`
(before `$listenerResult = @(`),
`$Ansible.Changed = [string]$listenerResult[0] -eq 'changed'`, and
`Write-Output ([string]$listenerResult[0])`.

*Global ordering.* `MAIN | Ensure WSUS Services Are Running After SUSDB Convergence` <
`MAIN | Reconcile Existing WSUS HTTPS Listener Before API Access` < each of the six API actors
listed under `WsusApiConnectionContractTest`; `Bind` < `Activate`; `Require SSL` < `Activate`;
`Activate` < the live probe; live probe < the runtime verifier.

**`test_ssl_vdir_convergence_uses_apphost_commit_and_two_phase_proof`** — `reproduce`. The task's
`$vdirs` block is exactly, in order:

```
ApiRemoting30
ClientWebService
DSSAuthWebService
ServerSyncWebService
SimpleAuthWebService
```

and the block must not name `Content`, `Inventory`, `ReportingWebService`, or `SelfUpdate`. Those
four are excluded deliberately: requiring SSL on the content or self-update paths breaks clients.

Structure: functions `Get-WsusAccessSslState`, `Set-WsusAccessSslValue`, `Test-ExactRequiredSsl`,
`Assert-WsusVdirsRequireSsl`, `Repair-WsusVdirsRequireSsl`; no `Get-WebConfigurationProperty` or
`Set-WebConfigurationProperty` anywhere in the task; the shared MWA factory contract with manager
count 2. Reader and writer each construct a manager, call `GetApplicationHostConfiguration()`,
dispose in `finally`, and never `Write-Output`.

Acceptance is exact: `$state.Text -eq 'Ssl' -or $state.Text -eq '8'`, written with
`Set-WsusAccessSslValue $location 'Ssl'`. Two-phase proof order: write < immediate read-back
`$afterWrite = Get-WsusAccessSslState $location` < `IIS access.sslFlags write did not persist` <
`Assert-WsusVdirsRequireSsl`. Exactly two `if (Repair-WsusVdirsRequireSsl)` call sites, ordered
first < `$out = & $wsusutil configuressl $dns` < second <
`$after = Get-ItemProperty -Path $setupPath -ErrorAction Stop`. The pre-pass preserves Microsoft's
IIS-before-`configuressl` ordering; the post-pass closes the commit/read-back gap and the
interrupted-transition boundary.

Messages: `does not require exact SSL`, `location=' + $state.Location`, `type=[' + $state.Type`,
`expected=[Ssl|8]`. Exactly one `Write-Output 'changed'` and one `Write-Output 'nochange'`;
`changed_when` exactly `__tls_configuressl__.stdout | trim == 'changed'`.

The verifier re-checks the same five names as one literal line —
`foreach ($name in @('ApiRemoting30', 'ClientWebService', 'DSSAuthWebService', 'ServerSyncWebService', 'SimpleAuthWebService')) {`
— with MWA count 1, and its access slice is read-only: no `SetAttributeValue`, no `CommitChanges`,
and the task's `changed_when` is falsy.

**`test_ssl_vdir_null_default_is_repairable_but_missing_schema_is_fatal`** — `reproduce`. The
modelled decision table for `(section present, attribute present, value)`:

| section | attribute | value | action |
|---|---|---|---|
| absent | absent | `None` | fatal |
| present | absent | `None` | fatal |
| present | present | `None` (null) | repair |
| present | present | `"None"` | repair |
| present | present | `"0"` | repair |
| present | present | `"Ssl"` | exact |
| present | present | `8` | exact |
| present | present | `"SslNegotiateCert"` | repair |

A null *value* is IIS's schema default and is repairable; a missing section or missing attribute
means the schema itself is wrong and is fatal. `SslNegotiateCert` is repaired rather than accepted:
only exactly `Ssl` or `8` satisfies the contract, so a superset flag is normalised down.

Reader guard order: `if ($null -eq $section)` < `if ($null -eq $attribute)` <
`$value = $attribute.Value` < `if ($null -ne $value)`, with `$valueText = '<null>'` and
`$valueType = '<null>'` initialised before the read. The verifier carries the same shape with
`$flags = '<null>'` and `$valueType = '<null>'`.

**`test_runtime_verifier_rechecks_site_start_and_auto_start_before_the_api`** — `reproduce`.
`ansible.windows.win_powershell` with `error_action: stop`, no `win_shell`, no `changed_when`; the
script's first line is exactly `$ErrorActionPreference = 'Stop'` and the second exactly
`$Ansible.Changed = $false`; exactly one `Write-Output 'healthy'`; `$wsusSiteState -ne 'Started'`
appears before `{{ __wsus_api_invoker__ }}`; and the script contains
`IIS:\Sites\WSUS Administration`, `Get-WebItemState -PSPath $wsusSitePath -ErrorAction Stop`, and
`$wsusSite.serverAutoStart`. The site check precedes the API helper so a stopped site fails as a
stopped site rather than as an unexplained API error.

### What the runtime verifier asserts

Task 77 re-derives externally meaningful state instead of trusting task return values, and no test
method names most of its clauses. The full list, so the rebuilt verifier can be diffed against it:

- WSUS Administration site present, `Started`, and `serverAutoStart` true (TLS builds).
- `MSSQL$MICROSOFT##WID` Automatic and Running — **invert**; the SQL instance service takes its
  place.
- `W3SVC` and `WsusService` both Running.
- All four declared directories exist as containers: content root, DB data directory, IIS log
  directory, IIS wwwroot.
- `WsusContent` exists under the content root; registry `ContentDir`, API `LocalContentCachePath`,
  and the IIS `Content` vdir `physicalPath` agree with the desired root and cache.
- Inheritable allow ACEs by SID: `S-1-5-32-545` `ReadAndExecute` on the content root, `S-1-5-20`
  `FullControl` on the cache. A `Deny` ACE intersecting the rights fails immediately.
- Upstream contract: `SyncFromMicrosoftUpdate` false and the four upstream fields match.
- `WsusPool` state `Started` and all six tuning values match, with `TimeSpan` comparison for the two
  interval values.
- Default Web Site `physicalPath` equals the declared wwwroot.
- `siteDefaults` logging enabled and at the declared directory, and the same for **every** site.
- TLS: exactly one HTTPS binding at `*:<port>:` with `sslFlags=0`; the SSL provider mapping carries
  the pinned thumbprint; the pinned leaf explicitly permits Server Authentication EKU; registry
  `UsingSSL=1`, `PortNumber`, and `ServerCertificateName` match; the five vdirs require exact SSL.
- Bootstrap (when enabled): the marker's server ID and fingerprint match a locally recomputed
  fingerprint, and the referenced history record still exists exactly once, is manual, and is
  `Succeeded`.

## Conflicts the rebuild inherits

Four collisions are recorded here rather than resolved, because each needs a decision the rebuild
cannot make on its own.

- **`BUILTIN\Users` browse access.** Tasks 9, 40, and 54 grant `BUILTIN\Users` `ReadAndExecute` as a
  ratified organisational convention (Director, 2026-07-18): every interactive user on these servers
  is an administrator, and an unreadable folder makes Explorer offer *Continue*, which stamps that
  administrator's personal ACE onto the ACL and leaves a stale SID when they depart. IIS Site STIG
  V-283673 permits only SYSTEM, Administrators, and an approved Web Administrators group on the
  content path, and V-218790 constrains the log directory the same way. One must yield.
- **WsusPool idle and recycle intervals.** Task 43 sets `processModel.idleTimeout` and
  `recycling.periodicRestart.time` to `00:00:00` on Microsoft's instruction, to prevent the
  scan-storm/HTTP-503 cascade a recycle triggers when it drops the metadata cache. IIS Site STIG
  V-218762 forbids an idle timeout of `0`, and its WSUS exemption is conditional on the host serving
  no other content — which the relocated Default Web Site may void.
- **The pool module (TD-004).** The tuning contract is written against
  `community.windows.win_iis_webapppool`, deprecated for removal in `community.windows` 4.0.0. The
  pinned collection set carries no `microsoft.iis`, so the successor cannot simply be adopted, and
  the attribute mapping must be re-validated when it is.
- **The synchronization half is unproven.** The AWS play sets `sync.bootstrap_enabled: false`
  because its placeholder upstream is deliberately unreachable, so tasks 46 and 48 and the marker
  and fingerprint contracts above have never executed against a real source. They are transcribed
  obligations, not demonstrated behaviour, and reproducing them buys nothing until an upstream
  exists.
