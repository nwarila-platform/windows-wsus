# windows-wsus — READMAP (single ordered source of priority)

_Created 2026-07-15 by Claude. This is the **forward-looking, what-remains** view in
priority order. It does NOT replace:_
- **`_handoff/QUEUE.md`** — the piece-level build queue (per-command detail).
- **`_handoff/REVIEW.md`** — the append-only audit ledger (what passed P2/P4, what merged).
- **`_handoff/steps/`** — plan packets + RTRACK per-cycle history.
- **`_handoff/RESTART.md`** — session re-entry protocol (read FIRST, always).

_**HARD RULE (Director, 2026-07-15):** Claude refreshes this file at P5 of EVERY
successful audit loop, in the same codification commit. It must always describe
`main`'s merged state; a stale READMAP blocks the next cycle's P0. When an item
lands, its ledger row goes to REVIEW.md and the Status here flips. Director: drop
new items into §4 (Parking Lot) or tell Claude where to slot them._

Status legend: ✅ done · 🔄 in-flight · 📐 designed/ratified (ready to build) ·
💤 designed/deferred · ⛏️ not-started · ❓ director-decision-open

---

## 1. Recommended global order (the one-swoop view)

Two standing rules from the Director shape everything:
- **One command per cycle** — every piece runs the full P0–P5 strict-cycle; never batch.
- **Revert-first** — the VM is restored to `pre-ansible-clean-ssh-ready` before every
  playbook execution, no exceptions.

Sequence:

1. **C02 disk-provisioning arc — COMPLETE** (✅ C02a–e all merged; idempotent E:/F: volumes at MS
   allocation units, safety-guard-gated).
2. **WSUS install + relocation spine — ✅ COMPLETE.** C03/C04/C05 merged (WSUS alive) + C05r (service-
   independent postinstall guard) + C06a–i (SUSDB relocation C:→E:). **SUSDB fully on E:\WID\Data**
   (ONLINE, read-write), content on F:\WSUS, WSUS operational (Get-WsusServer OK :8530), fully
   idempotent, proven by a from-baseline E2E converge (`ok=34 changed=16 failed=0`). **C07 (END verify)
   DROPPED** (Director: theater — every check is guaranteed by an upstream fail-closed gate; §4b).
   **THE ROLE IS COMPLETE** — mission #1 done; next is the T-track endgame (backport → GitHub import).
3. **§3 Director decisions** — can land any time; none block C02, but style §4b/§5
   ratification is cheapest before more pieces cite them.
4. **C08+ optimization/maintenance arc — COMPLETE.** C08 WsusPool IIS tuning ✅ + C09a reindex tooling ✅
   + C09b scheduled reindex ✅ + C10a cleanup runner ✅ + C10b monthly cleanup schedule ✅. **THE
   MAINTENANCE CORE (tuning + reindex + cleanup) IS COMPLETE.**
5. **C11 sync arc — ✅ COMPLETE / "good enough"** (Director pull-back 2026-07-17): **C11a ✅** (restrict
   update languages) + **C11b ✅** (gated category-only bootstrap, PROVE-STARTED — trigger + confirm-accepted
   + durable ServerId registry marker, no block on the ~1-2hr sync) + **C11d ✅** (configure the UPSTREAM
   WSUS source — downstream/replica topology; REQUIRED `upstream_server` var). **C11c (products) built +
   P4-green + P4.5-presented then DROPPED**, and **C11e/C11f (schedule/auto-approval) ABANDONED** — a
   downstream/replica INHERITS products, classifications, schedule, and approvals from its upstream WSUS, so
   those pieces are unnecessary. **THE ROLE IS FEATURE-COMPLETE (feature core).**
5b. **Post-feature roadmap (Director autonomy on items 1–4) — item 3 (IIS on its own drive) ✅ CLOSED.**
   (1) ✅ C11e from-baseline Save-conflict fix. (2) ✅ VM re-baselined to 3 disks (v6). (3) ✅ **IIS `inetpub`
   → G:** — C12a (provision G:) + C12b (site logs) + C12c (wwwroot + PathWWWRoot). (4) ⛏️ industry
   best-practices logging (incl. making C12b's IIS log file materialize) — **NEXT** (after the maturity pass).
   ✅ **Inline-PowerShell-maturity pass COMPLETE (piece M, `f8b1d6a`)** — hardened the 5 C06-era SqlClient
   blocks to the native-module template + added the `scripts/check-winshell-splitargs.py` gate. (5) 💤 PARKED
   — AWS/proxmox OS-disk swap.
6. **Upstream debt retirement** — TD-001 loader v3.1 proposal (gated by
   `loader-change-protocol.md`) + TD-002 chassis lint warn_list PR (normal PR, no
   gate). Deferred by Director decision until the local role is the priority no more.
7. **Endgame:** backport to a `*-template` repo → import to GitHub (`nwarila-platform`
   org). Only after the role is fully operational (mission #3).

---

## 2. Locked decisions ledger (one place, so nothing re-litigates)

- **Composition, not vendoring** — role overlays into the `.framework-pin`ned
  ansible-framework checkout; never runs repo-side (kickoff, 2026-07-15).
- **v3 loader untouchable** — byte-identical `tasks/main.yml`; ANY change or even an
  optimization recommendation goes through the multi-LLM Fable+Sol gate
  (`loader-change-protocol.md`) + Director acceptance (RATIFIED 2026-07-15).
- **Transport = SSH** (`ansible_shell_type: powershell`), **`become: false`** play-level
  (org standard; chassis become=sudo is POSIX-only).
- **Handed-machine contract (§4a, RATIFIED; amended C01r)** — role owns ALL guest-OS
  state E2E; hardware provisioning belongs to the deploy layer; disk selection is
  declarative by a stable `unique_id`, never size- nor disk-number-coupled.
- **Division of labor** — Claude plans/validates/merges; Codex reviews (P2) and
  executes (P3); Director consulted EVERY piece; no auto-approve.
- **C01 (2026-07-15):** wazuh BEGIN/gather styling is the template idiom; defaults
  stay minimal (keys land with the piece that consumes them); no total-disk-count
  pin; negative proofs are standard for guard pieces.
- **C01r (2026-07-15):** data disks are selected by a declared stable `unique_id`
  (Get-Disk UniqueId / `win_disk_facts.unique_id`, `eui.<hex>`) supplied as REQUIRED
  top-level vars `wid_disk_id` (DB→E:WSUSDB) / `wsus_disk_id` (content→F:WSUSDATA) —
  never by size, never by enumeration number. Presence-only guard (drops C01 size +
  RAW; `unique_id` is populated on RAW disks and stable through GPT init → closes the
  second-run idempotency hole). (C01r declared the ids top-level; C02a moved them into
  the `wsus:` dict → `config` — see below.)
- **Director reviews `present_windows.yml` before merge (P4.5, C01r):** eyes-on the
  role file + "is this good?" gate between P4 and P5. See [[STRICT-CYCLE-adapted.md]].
- **P4.5 presentation format LOCKED (Director 2026-07-16, "mirror this EXACTLY"):** every
  P4.5 surface uses the canonical shape — intro (unstaged preview in Source Control →
  Changes) → `## Cxx — <module>` → **The change** (yaml excerpt) → **Cycle trace** table
  (`Phase | Result`, P2/P3/P4) → **Judgement calls** (numbered) → **Files changed
  (role/playbook/style-guide)** → "Is this good to merge?". Template in
  `STRICT-CYCLE-adapted.md` §P4.5.
- **C02a (2026-07-15):** disk ids are declared in the `wsus:` override dict and read as
  `config.wid_disk_id` / `config.wsus_disk_id` (framework idiom) — this REVERSED the
  C01r §5-ext (top-level inputs). `temp_dir` + ids co-locate in ONE `wsus:` declaration
  (loader reads temp_dir from the raw `wsus` var; no cross-precedence dict merge; a
  `-e '{"wsus":{…}}'` replaces the whole dict).
- **Smallest-step MS-doc loop (Director 2026-07-15):** one operation/module per cycle,
  MS-doc-grounded; Claude proposes → Codex audits/executes → Claude validates + E2E
  tests → judgement-decisions report (with the role/playbook/style-guide files updated)
  → STOP for Director approval before the next step.
- **Assert policy — §4b "guards earn their keep" (RATIFIED V, 2026-07-15):** prefer the
  Ansible action; assert only when SILENT-WRONG or DESTRUCTIVE with no module alternative
  (don't-assert-what-fails-anyway; configure-don't-assert). Config-contract validation lives
  in `tasks/validate.yml`, run by the loader's v3.1.0 hook — NOT argument_specs (§8, blind to
  merged config).
- **Loader v3.1.0 validate hook (Director exception, TD-003):** the byte-identical loader was
  bumped 3.0.0→3.1.0 to add a GENERIC validate.yml hook (Fable+Sol panel APPROVE). Local
  divergence from the framework until v3.1.0 is upstreamed atomically (TD-003).
- **C02b (2026-07-15):** before any disk mutation, a state-aware safety guard refuses a
  non-target/system disk (NOT RAW AND a foreign drive letter), recognizing 'ours' by our
  declared drive letter — no size selection (style §4c SEED).
- **C02e allocation (RESOLVED 2026-07-16):** `win_format` formats E: at **64 KiB (65536 B)** —
  CONFIRMED vs MS SQL Server storage best practice ("64-KB for data, logs, TempDB"), inherited by WID
  as a SQL engine variant — and F: at **4 KiB (4096 B) = NTFS default** — RESEARCH result: MS's WSUS
  docs require only NTFS and are silent on cluster size; 64 KiB is MS-reserved for Dedup/large-files,
  which a 30 GiB varied-file content volume is not. `force:false` idempotent (verified vs module source
  + a live RAW-volume probe: FileSystem empty / Size 0 / BlockSize null → pristine format, no FailJson).
  Director approved F:=4 KiB at P4.5 (would flip to 64 KiB only if Data Dedup on F: becomes intended).
- **WSUS install spine + SUSDB location (RESOLVED 2026-07-16, from MS research):** the WSUS
  install is `Install-WindowsFeature` + `wsusutil postinstall` — NO downloaded installer, NO
  staging/temp dir, so the queued **C03 (win_tempfile staging dir) is DROPPED** (no MS consumer).
  Reshaped spine: create `F:\WSUS` (content dir) → install `UpdateServices`(+WidDB+Services) →
  `wsusutil postinstall CONTENT_DIR=F:\WSUS` → **relocate SUSDB to E:** → verify. **SUSDB reality:**
  WID always installs `SUSDB.mdf` to `C:\Windows\WID\Data`; MS exposes NO supported way to place it
  elsewhere (only `CONTENT_DIR`), and calls moving the WID DB "not recommended." **Director decision
  (2026-07-16): do the community detach/move/attach relocation to E:** (the just-provisioned WSUSDB /
  64 KiB volume) — preserves the WID backend (mission) AND the E: disk's purpose; MS-unsupported but
  reversible + snapshot-protected. Alternatives rejected: accept SUSDB on C: (orphans E:), WID→SQL
  (abandons the WID mission). See [[susdb-wid-relocation-decision]].
- **TD-001 stays playbook-carried** (Director 2026-07-15): loader Windows gaps are
  marked workarounds in `wsus.yml`, evidence base for the future upstream v3.1 PR.
- **Interim lint gate (C01/P4):** `ansible-lint --warn-list 'yaml[comments]'` from
  the composed tree until TD-002 is fixed upstream (❓ pending formal Director
  blessing, see §3).
- **Never `set_fact` the name `ansible_facts`** (C01/P4, proposed style §5) — it
  shadows the live facts store and silently hides every later facts module's results.

---

## 3. The ordered roadmap

### Track W — the wsus role build (THE mission lane)
| ID | Piece (single command) | Status | Notes / gating |
|----|------------------------|--------|----------------|
| C01 | BEGIN guards: Windows family, data_disks inputs, blank-disk presence | ✅ merged `888ce9c [audited 78cad4f]` 2026-07-15 | All 3 proofs green (presence / absence / ambiguity). Found+fixed TD-001 seed-shadow; recorded TD-002. RTRACK-C01. |
| C01r | Identifier-based selection: required `wid_disk_id`/`wsus_disk_id` (`unique_id`); presence-only; drops C01 size+RAW | ✅ merged `96dc197 [audited 6afe43f]` 2026-07-15 | Director-directive reshape. Proof-matrix a–g + VM presence/absence green; `win_disk_facts.unique_id`==`eui` confirmed. Ratified §4a(amended)/§4b/§5-ext; +new P4.5 review gate. RTRACK-C01r. |
| C02a | Disk ids → `config` (declared in the `wsus:` dict, read as `config.wid_disk_id`/`config.wsus_disk_id`); reverse §5-ext | ✅ merged `d181f2f [audited e52eede]` 2026-07-15 | Smallest step of the C02 decomposition. Controller fixture + VM presence (no -e) / negative green; P4.5 approved. §5-ext REVERSED. RTRACK-C02a. |
| C02b | State-aware safety guard: refuse a non-target/system disk (NOT RAW AND a foreign drive letter), recognize 'ours' by drive letter, no size selection | ✅ merged `b13a530 [audited f0efa69]` 2026-07-15 | Read-only. Controller fixture a-g + VM safe-pass green; P4.5 approved. Truthiness predicate handles ''/null/omitted. SEED §4c. RTRACK-C02b. |
| V | Config-validation home: loader **v3.1.0** generic `validate.yml` hook + `tasks/validate.yml` (id distinctness, state-gated); Distinct removed from present_windows | ✅ merged `5f6a053 [audited 5e5db4a]` 2026-07-15 | Loader gate Fable+Sol APPROVE; VM safe-pass + distinctness proof green; P4.5 approved. Ratified §4b policy; §8; TD-003. RTRACK-V. |
| R1 | Guard trim: drop the Windows-family assert (loader `first_found` already enforces family) | ✅ merged `2ef0ad6 [audited cc987e2]` 2026-07-15 | Pure deletion; VM safe-pass ok=16; P4.5 approved. §4b(a). RTRACK-R1. |
| R2 | Guard trim: collapse the two `win_disk_facts` gathers into ONE canonical superset | ✅ merged `46f9d3d [audited deea6cf]` 2026-07-15 | −1 SSH round-trip; VM safe-pass ok=15; P4.5 approved. §4b gather-once. RTRACK-R2. |
| R3 | Resolve each disk once via a block-var `matches` (NO set_fact — no cross-role bleed); Attached + safety reuse it; feeds C02d | ✅ merged `09a73b4 [audited afeef0c]` 2026-07-15 | VM safe-pass ok=15 + negative (fail-closed); P4.5 approved. RATIFIED §4 avoid-set_fact + §4b block-var resolution. RTRACK-R3. |
| R4 | Guard trim: drop the Provided assert (§4b(a)) + refresh stale file-header | ✅ merged `fd206b4 [audited ed83585]` 2026-07-15 | VM safe-pass ok=14 + negative (id omitted → Attached 'found 0'); P4.5 approved. Guard refactor COMPLETE. RTRACK-R4. |
| C02c | `win_initialize_disk` — GPT-init the two data disks (FIRST mutation) | ✅ merged `a0fe69c [audited 1b96d8e]` 2026-07-16 | Convergence RAW→GPT (Get-Disk) + idempotency re-run changed=0; P4.5 approved. `online:true` scoped to RAW-online baseline (Codex P2). RTRACK-C02c. |
| C02d | `win_partition` — 100% partition (`partition_size: -1`) + drive letter | ✅ merged `92b3d6f [audited edd5c24]` 2026-07-16 | disk_number from `item.matches \| first` `.number`; drive_letter for idempotency; gpt_type basic_data. Convergence changed=2 + idempotency re-run changed=0; SSH-verified E:20GB/F:30GB RAW partitions; P4.5 approved. RTRACK-C02d. |
| C02e | `win_format` — NTFS + label (WSUSDB/WSUSDATA) at **MS allocation units**: 64 KiB SQL/WID `SUSDB` (E:), 4 KiB NTFS-default content (F:, researched — MS silent) | ✅ merged `954c538 [audited 274c9d0]` 2026-07-16 | `force:false` idempotent (verified vs module source + live RAW probe). Convergence changed=3 (format ran, no force error) + idempotency re-run changed=0; SSH-verified E:NTFS/WSUSDB/65536, F:NTFS/WSUSDATA/4096; P4.5 approved. Closes the C02 arc. RTRACK-C02e. |
| ~~C03~~ | ~~Role-owned staging dir via `win_tempfile`~~ | ❌ DROPPED 2026-07-16 | MS install spine needs no staging/temp dir (research). |
| C03 | Create the WSUS content dir on F: (derived `F:\WSUS`) via `ansible.windows.win_file` (state: directory); opens the 'Main: WSUS Installation' region | ✅ merged `c9ef489 [audited ef4ac89]` 2026-07-16 | `__content_dir__` derived from `data_disks.content.drive_letter` + `content_subdir` (no drift, no set_fact). Convergence changed=4 + idempotency changed=0; SSH-verified `F:\WSUS`; P4.5 approved. P3 unblocked by the isolated Codex session. RTRACK-C03. |
| C04 | Install the WSUS role (WID): `win_feature` explicit `UpdateServices`+`-WidDB`+`-Services` + mgmt tools; `include_sub_features` UNSET (would pull `-DB`/SQL); NO reboot machinery | ✅ merged `31ecee7 [audited 655706c]` 2026-07-16 | 33 features resolved; SSH-verified incl. the `UpdateServices-DB` NOT-installed negative; **reboot measured UNNECESSARY (all 3 signals)**; idempotency `NoChangeNeeded` changed=0; P4.5 approved. RTRACK-C04. |
| C05 | WSUS postinstall via `win_command` argv, gated by a read-only `Get-WsusServer` probe (FIRST §8 escape hatch — 0/118 modules cover WSUS server ops) | ✅ merged `28cee42 [audited 1a76964]` 2026-07-16 | WSUS ALIVE: SUSDB (10.2 MB) in WID on C:, WSUSContent on F:, IIS :8530/:8531 Started, WsusService Running/Automatic. Probe replaced the community `creates:` marker (P2: silent false convergence). Setup-key ground truth dumped (ContentDir=F:\WSUS, SqlServerName=MICROSOFT##WID, IRS flags all =2). Idempotency changed=0. §8 PROPOSED. RTRACK-C05. |
| C05r | Reshape the postinstall guard: `win_reg_stat` on the four 'Installed Role Services' completion flags replaces the `Get-WsusServer` win_shell — the C06 arc stops services mid-flight and Get-WsusServer FAILS then (flap, C06d P2 catch) | ✅ merged `e04c2e9 [audited 5799fc6]` 2026-07-16 | P2 REVISE r1→SOUND (atomicity via real postinstall-log forensics); P3 close-out via 3 bounded xhigh Codex audits (all PASS); P4 green incl. flap regression (services down → postinstall still skips, SCM forensics); P4.5 approved. Process this session: codex-exec stdin-drain hang root-caused+fixed (`</dev/null`), reasoning pinned xhigh, per-step rolling snapshot discipline added. RTRACK-C05r. |
| C06 | SUSDB relocation C:→E: — DECOMPOSED C06a–i (QUEUE.md; research + live probe 2026-07-16: zero-install SqlClient over the WID pipe, administrator=sysadmin, sys.master_files three-state gate, COPY-don't-move, ACL-before-attach) | ✅ COMPLETE | C06a-c + U1 + C05r + C06d-i all merged. **SUSDB fully on `E:\WID\Data`** (ONLINE, read-write), C: originals deleted (health-gated), WSUS operational. From-baseline E2E green. |
| C06d | `win_service` — stop `WsusService` + `W3SVC` (gated pending\|orphaned); WID engine STAYS running for the C06e detach | ✅ merged `ec9a0cb [audited 5bca897]` 2026-07-16 | P2 AGREE (7-point review); P3 5bca897; P4 green: converge both stop + WID Running + failed=0, idempotency changed=0, C05r cross-check (postinstall skips with services down). First cycle under per-step snapshot proof (`pre-C06d`). RTRACK-C06d. |
| C06e | `win_shell` (SqlClient/WID pipe) — `SET SINGLE_USER WITH ROLLBACK IMMEDIATE` + `sp_detach_db 'SUSDB'` (gated ==pending); leaves files on C: (copy-don't-move) | ✅ merged `f961735 [audited 50b0079]` 2026-07-16 | P2 AGREE (8-point MS-cited); P3 50b0079; P4 green: converge detached (sys.master_files 0 rows) + .mdf/.ldf still on C: + failed=0, idempotency orphaned→skip changed=0. RTRACK-C06e. |
| C06f | `win_copy remote_src` — copy SUSDB `.mdf`/`.ldf` `%SystemDrive%\Windows\WID\Data` → `E:\WID\Data` (gated pending\|orphaned; copy-don't-move) | ✅ merged `00696a1 [audited 0b9d2fe]` 2026-07-16 | P2 REVISE r1 (SystemDrive-derived source + MS 'copies') → AGREE r2; P3 0b9d2fe; P4 green: converge E: sizes match C: + C: intact + WID-svc ACE inherited=True on E: files + failed=0, idempotency changed=0 (checksum). RTRACK-C06f. |
| C06g | `win_shell` (SqlClient/WID pipe) — `CREATE DATABASE SUSDB ... FOR ATTACH` from E: + fail-closed health gate (ONLINE + is_read_only=0 + all files on E:) + DROP-on-failure revert. The relocation pivot | ✅ merged `f4b39ae [audited 036d635]` 2026-07-16 | P2 REVISE r1→r2→r3 → AGREE r4 (4-round hardening: registered-but-unhealthy restart hole, DROP vs sp_detach_db, env-path injection, reader-close); P3 036d635; P4 green: converge SUSDB ONLINE+rw on E: + C: intact, idempotency relocated → all d/e/f/g SKIP changed=0. RTRACK-C06g. |
| C06h | `win_service` state:started loop [W3SVC, WsusService], UNGATED terminal desired-state — returns WSUS to operational on the E: SUSDB | ✅ merged `afd14d6 [audited 4400687]` 2026-07-16 | P2 AGREE (7-point); P3 4400687; P4 green: converge both start + Get-WsusServer OK :8530 + SUSDB ONLINE on E:, idempotency changed=0. RTRACK-C06h. |
| C06i | Independent health probe + `win_file state:absent` — delete the C: SUSDB originals ONLY when SUSDB is verified ONLINE+read_write+all-on-E. **Closes the C06 arc** | ✅ merged `5e240ad [audited 2bb17fe]` 2026-07-16 | P2 AGREE (predicate covers every unsafe state); P3 2bb17fe; P4 green: fixture 6/6, converge C: deleted + E: intact + WID system DBs untouched + Get-WsusServer OK :8530 + SUSDB ONLINE, idempotency changed=0. RTRACK-C06i. |
| ~~C07~~ | ~~END verify: WsusService + Get-WsusServer + :8530 + DB on E: / content on F:~~ | ❌ DROPPED (Director 2026-07-16) | Engineering theater — every check is guaranteed by an upstream fail-closed gate (C06h/C06g/C06i/C05); conflicts with §4b. Role is self-verifying. RTRACK-C07. |
| C08 | Tune the WsusPool IIS app pool to MS best-practices (`win_iis_webapppool`: queueLength 2000, memory 0, periodicRestart/idleTimeout 0, ping false), fail-closed guard, overridable `wsus_defaults.wsuspool` | ✅ merged `1058e03 [audited 1ef3e8e]` 2026-07-16 | P2 REVISE r1 (guard, deprecation, defaults, atomicity) → AGREE r2; convergence 6 attrs + idempotency changed=0 (proves `\|int`/`\|bool`). TD-004 recorded. "Lean toward defaults" ratified. RTRACK-C08. |
| C09a | Deploy the SUSDB reindex tooling — MS `SUSDBMaint.sql` (verbatim) + `Invoke-SusdbReindex.ps1` (SqlClient/WID-pipe, GO-split) into `maintenance.dir`. First role `files/` | ✅ merged `a92295b [audited cf1a446]` 2026-07-16 | P2 REVISE r1 (InfoMessage capture + off-hours/no-overlap) → AGREE r2; RUNNER PROOF — reindexed SUSDB (3 batches, 5 indexes, ONLINE). RTRACK-C09a. |
| C09b | Schedule the reindex credential-free — grant `NT AUTHORITY\SYSTEM` a WID sysadmin login (SID-verified) + a weekly off-hours `win_scheduled_task` running the C09a runner as SYSTEM (no password), IgnoreNew, time-limited. Closes C09 | ✅ merged `79a71a8 [audited ab7899a]` 2026-07-16 | P2 REVISE r1 (s4u fatal → SYSTEM pivot) → r2 (db_owner insufficient → sysadmin) → AGREE; PRINCIPAL PROOF — task ran as SYSTEM, reindexed SUSDB, `sp_updatestats` ran, result 0. Credential-free SYSTEM-scheduled-maintenance pattern. RTRACK-C09b. |
| C10a | Deploy the WSUS Server Cleanup runner — `Invoke-WsusCleanup.ps1` (`Invoke-WsusServerCleanup`, ops splatted from an allowlist-validated comma-scalar) + `maintenance.cleanup_operations` default | ✅ merged `571d4da [audited ed7c984]` 2026-07-17 | P2 REVISE r1 (`-File` no arrays → scalar-split + allowlist blocks `-WhatIf` injection) → AGREE; RUNNER PROOF — positive all-6 + negative WhatIf-reject. RTRACK-C10a. |
| C10b | Schedule the cleanup MONTHLY (first-Sunday 00:00) as SYSTEM (credential-free; NO grant — pre-tested). Closes C10 + the maintenance core | ✅ merged `89c822b [audited d7bae97]` 2026-07-17 | P2 REVISE r1 (00:00 buffer before 03:00 reindex; assert real first-Sunday) → AGREE r2; PRINCIPAL PROOF — ran as SYSTEM → cleanup completed, NextRunTime 2027-01-03. **CLOSES the maintenance core.** RTRACK-C10b. |
| C11a | Restrict WSUS update languages before the first sync — `win_shell` on `Get-WsusServer.GetConfiguration()`: `AllUpdateLanguagesEnabled=false` + `SetEnabledUpdateLanguages(StringCollection of `sync.update_languages`, default `['en']`); opens 'Main: WSUS Sync Configuration' | ✅ merged `1c211bd [audited a25b136]` 2026-07-17 | P2 REVISE r1 (drop half-wired source/proxy; StringCollection + normalized compare + re-acquire-verify) → AGREE r2; convergence changed=1, SSH `AllUpdateLanguagesEnabled=False`/`[en]`, idempotency changed=0. Opens the C11 sync arc. RTRACK-C11a. |
| C11b | Gated bootstrap category-only sync (PROVE-STARTED) — `win_shell` gated on a durable role-owned registry marker (`HKLM:\SOFTWARE\nwarila-platform\wsus\category_bootstrap_server_id` == `GetConfiguration().ServerId`); if unmarked, `StartSynchronizationForCategoryOnly()` + confirm ACCEPTED (bounded `sync.bootstrap_accept_timeout_sec`=120s) + write marker. Does NOT block on the ~1-2hr completion | ✅ merged `5003474 [audited fb87098]` 2026-07-17 | P2 r1→r4 hardened wait-for-completion (durable ServerId marker over Result/history gates) → AGREE r4; **Director prove-started decision** (sync ~1-2hr, catalog loads early) → r5 REDESIGN (single trigger+confirm+mark) → AGREE r5; converge changed=1, SSH marker==ServerId/sync Running/catalog 17→77, idempotency changed=0. Establishes the role-owned registry-marker convention. RTRACK-C11b. |
| ~~C11c~~ | ~~Select products — `SetUpdateCategories()` from `sync.products`~~ | ❌ DROPPED (Director 2026-07-17) | Built + P2 AGREE (gpt-5.5 r2) + P3 `5af96d4` + P4 GREEN (selected=[Defender, Server-24H2]) + P4.5 presented, then dropped for the downstream topology (upstream dictates products). RTRACK-C11c. |
| C11d | Configure the upstream WSUS source (downstream/replica) — `win_shell` on `GetConfiguration()`: `SyncFromMicrosoftUpdate=false` + `UpstreamWsusServerName`/`Port`/`UseSsl` + `IsReplicaServer` from a REQUIRED `config.upstream_server` (validate.yml) + `sync.upstream_port`/`upstream_use_ssl`/`replica` defaults; five-field Save-on-diff + re-acquire-verify | ✅ merged `2cfb2fa [audited 89b8127]` 2026-07-17 | First Codex cycle on **gpt-5.5 @ xhigh**. P2 REVISE r1 (required-input contract → validate.yml, §4b/V) → AGREE r2; converge changed=1, SSH downstream config verified, idempotency changed=0, negative (no upstream_server) validate.yml fails at INIT. **CLOSES the C11 sync arc.** RTRACK-C11d. |
| ~~C11e/C11f~~ | ~~Daily sync schedule / auto-approval rule~~ | ❌ ABANDONED (Director 2026-07-17) | A downstream/replica inherits the schedule + approvals from its upstream WSUS. |

### Track I — IIS on its own drive (roadmap item 3; STIG "each application on its own drive")
| ID | Piece (single command) | Status | Notes / gating |
|----|------------------------|--------|----------------|
| C12a | Provision the 3rd data disk (G:, `WSUSIIS`, 4 KiB) for the IIS `inetpub` — generic `__data_disks__` `iis` entry + REQUIRED `iis_disk_id`; validate.yml 3-way distinctness; VM re-baselined to 3 disks (v6) | ✅ merged 2026-07-17 | The N-disk generic loop absorbed the 3rd disk (all disk tasks `loop: __data_disks__`); `iis_disk_id` required like the others ("found 0" assert). eui.BC9F0ECE9FBC4B9A000C296303722FC1. |
| C12b | Repoint IIS site logs → G: — `win_shell` config-object on `siteDefaults` + every site's `logFile.directory` → `iis.log_dir` (`G:\inetpub\logs\LogFiles`); literal-path guard (`%SystemDrive%` = drift) | ✅ merged 2026-07-17 | Config is STIG-correct + idempotent; the log **file** does NOT materialize on an idle VM (w3wp=0, no real WSUS clients — never logs on C: either). NOT a defect. Functional logging = roadmap item 4 (Director "merge then investigate"). |
| C12c | Relocate IIS wwwroot → G: (NATIVE-FIRST) — no-change validate+normalize preflight → `win_copy` content → `win_regedit` ×2 (`InetStp` `PathWWWRoot` native+Wow6432) → `win_shell` Default Web Site `physicalPath`; new `iis.wwwroot` default | ✅ merged `565b8d4 [audited 6069486]` 2026-07-17 | P2 REVISE r1 (native modules expand %VAR% in path params → no-change validate PREFLIGHT feeds all mutations) → AGREE r2. **Claude P4 repair: `\'` in win_shell free-form breaks Ansible `split_args` → `[char]92`** (also fixed the merged C12b task). Converge changed=3, SSH PathWWWRoot(both)+Default Web Site=G:, WSUS Admin site untouched, http 200; idempotency changed=0. **CLOSES item 3.** RTRACK-C12c. |

### Track M — inline-PowerShell maturity (Director initiative, 2026-07-17)
| ID | Piece | Status | Notes / gating |
|----|-------|--------|----------------|
| M | Behavior-preserving hardening of the 5 C06-era SqlClient `win_shell` blocks to the mature native-module template (M-1 `[char]92` kills the last latent split_args `\'`; M-2 `$EAP='Stop'`; M-3 try/finally close-only; M-4 env-pass the probe path; M-5 one env-passed `__wid_conn_master__`) + NEW `scripts/check-winshell-splitargs.py` gate | ✅ merged `f8b1d6a [audited 7013393]` 2026-07-17 | Audited all 15 inline-PS surfaces; role already mostly mature (C09b-onward). Codex P2 AGREE (gpt-5.5 xhigh); Claude reverted a win_copy scope-creep; **proved ansible-lint + `--syntax-check` both MISS the `\'` class — only the new gate catches it.** Converge `pre-maturity` ok=44 changed=0 failed=0 (behavior-preserving) + from-baseline E2E ok=49 changed=29 failed=0 (Detach/Attach exercised, delete-gate fired). **Native-module template RATIFIED (style §5).** RTRACK-M. |

### Track L — industry best-practices logging (roadmap item 4, Director initiative)
| ID | Piece | Status | Notes / gating |
|----|-------|--------|----------------|
| C13a | Install the `Web-Http-Logging` IIS role service (native `win_feature`) so IIS W3C logging writes to G: | ✅ merged `f614e58 [audited 1409070]` 2026-07-18 | **Root-caused the C12b gap:** log config was correct but no file wrote because the HTTP Logging module was never installed (WSUS's C04 pulls the web server, not HTTP Logging). Codex P2 AGREE (MS-researched: correct + sufficient, no over-install, no reboot). Converge ok=45 changed=1; **W3C logs materialize on G:\inetpub\logs\LogFiles\W3SVC*** (0 leaked to C:); idempotency changed=0. **Closes the C12b "merge then investigate" loop.** RTRACK-C13a. |
| ~~C13b~~ | ~~event-log MaxSize to STIG floors~~ | ❌ DROPPED (Director 2026-07-18) | GPO territory (`HKLM\SOFTWARE\Policies\...\EventLog`); GPOs own ~99% of STIG. Role = non-GPO IIS/WSUS only. [[role-vs-gpo-scope]] |
| C13c-e | IIS W3C log STIG hardening: log-dir ACL (V-218790) + 4 custom fields (V-218788/9) + `logTargetW3C=File,ETW` (V-218786) | ✅ merged `6c0a3e4 [audited ae4b031]` 2026-07-18 | Director-scoped IIS-specific items; ETW=ship, ACL=org-conv+STIG-FC. Codex P2 REVISE→folded (full-tuple guard). **2 Claude P4 repairs:** PS `@(pipe\|ConvertFrom-Json)` jaggedness → DISP_E_TYPEMISMATCH; logTargetW3C flags-enum returns String (read `[string]` not `.Value`). Converge ok=47 changed=3; 4 custom fields ACTIVE in the live G: log #Fields; idempotency changed=0. RTRACK-C13c-e. |
| C13f/g | IIS log-cleanup runner (retention 90d) + weekly SYSTEM schedule — IIS never auto-purges | ✅ merged `5f63d2b [audited 704443f]` 2026-07-18 | Mirrors C09a/b + C10a/b. Codex P2 AGREE. Runner proof: task ran as SYSTEM LastTaskResult=0 (NextRunTime 07/19 02:00), OLD.log deleted / FRESH.log+OLD.txt kept (`*.log`+age filter), folders kept; idempotency changed=0. RTRACK-C13f-g. |
| C13h/i | 3 Event Viewer custom views (WSUS/IIS-WsusPool/WID-SUSDB) + `Microsoft-IIS-Configuration/Operational` channel | ✅ merged `2b6fd4b [audited 8793271]` 2026-07-18 | Native win_copy XML + native `EventLogConfiguration` (Codex REVISE→folded: both-fields guard). Verified live pre-build. Converge ok=51 changed=7; **each view's XPath query executes (1 event each)**, channel enabled+20MB; idempotency changed=0. **CLOSES the item-4 build.** RTRACK-C13h-i. |
| ~~SoftwareDist reloc~~ | ~~move WSUS logs off C:~~ | ❌ DROPPED | MS-unsupported; self-bounded by `.old` rollover. |

### Track G — governance / Director decisions
| ID | Item | Status | Notes |
|----|------|--------|-------|
| G1 | Ratify C01 P4 scopeLock amendment + playbook repair | ❓ | Recorded in `C01.plan.json` + TD-001; merged under P4 bounded-repair authority. |
| G2 | TD-002 disposition: bless interim `--warn-list` gate; update `AGENTS.md` verification snippet; authorize upstream warn_list PR | ❓ | Config-only upstream change — normal PR, NOT loader governance. |
| G3 | Ratify remaining style proposal: §5 `ansible_facts` set_fact ban | ❓ | §4a (amended) / §4b RATIFIED via C01r. §5-ext RATIFIED (C01r) then REVERSED (C02a — role inputs in the `<role>:` dict → config). The §5 `ansible_facts` set_fact ban (C01) still PROPOSED — pending Director. |
| G4 | TD-001 upstream "loader v3.1 Windows support" proposal | 💤 deferred (Director 2026-07-15) | MUST pass `loader-change-protocol.md` (independent Fable + Sol validation) before any upstream PR. Evidence accumulates in TECH-DEBT. |

### Track T — template & publication (endgame)
| ID | Item | Status | Notes |
|----|------|--------|-------|
| T1 | Backport repo → `*-template` | 💤 | Only when the role is fully operational. |
| T2 | Import to GitHub (`nwarila-platform` org) | 💤 | Follows T1. |

## 4. Parking Lot / active roadmap (Director, 2026-07-17)

**Post-feature-complete roadmap — Director granted AUTONOMY on items 1–4** (drive the strict-cycle with
Codex gpt-5.5 P2 as the gate; checkpoint at arc boundaries, no per-piece P4.5 block). Theme: **get ALL
stateful data off the OS disk so the OS disk becomes disposable** (item 1 IIS-disk enables item 5 OS-swap).

1. ✅ **C11e — from-baseline Save-conflict fix** (`d2814cd`). The from-baseline E2E verify caught that C11d's
   config `Save()` fails while the C11b prove-started MU sync is running; C11d now stops the sync first.
   **`main` is GREEN from baseline** (ok=44 changed=25 failed=0). Done.
2. ✅ **Re-baselined the dev VM to 3 RAW disks** (baseline v5→v6). Added `nvme0:3` IIS disk; captured
   `eui.BC9F0ECE9FBC4B9A000C296303722FC1` → `iis_disk_id`.
3. ✅ **IIS `inetpub` → dedicated disk (G:) — CLOSED.** Director refined "whole site" → "leave WSUS where it
   is, just move the IIS (inetpub)"; EXPLICIT-REPOINT chosen. **C12a** (provision G:) + **C12b** (site logs)
   + **C12c** (wwwroot + `InetStp PathWWWRoot` + Default Web Site physicalPath). The WSUS Administration site
   stays in Program Files (untouched). Track I above.
4. ✅ **Industry best-practices logging — DONE (item-4 arc, Track L; CLOSED 2026-07-18).** Director-scoped to
   IIS/WSUS-specific NON-GPO items (GPOs own ~99% of STIG). **C13a** install `Web-Http-Logging` (root-caused the
   C12b gap → W3C logs write to G:); **C13c-e** log-dir ACL + STIG custom fields + `File,ETW`; **C13f-g** IIS
   log-cleanup runner + weekly SYSTEM schedule (retention 90d); **C13h-i** 3 Event Viewer custom views + enable
   `Microsoft-IIS-Configuration/Operational`. Dropped: event-log sizing (GPO), `SoftwareDistribution.log`
   relocation (MS-unsupported). From-baseline E2E `ok=56 changed=35 failed=0` + full-role idempotency changed=0.

   **✅ Inline-PowerShell-maturity pass — COMPLETE (piece M, `f8b1d6a`, 2026-07-17).** Audited all 15 inline-PS
   surfaces; the role was already mostly mature (the C09b Grant-SYSTEM template onward). Hardened the 5 C06-era
   SqlClient blocks (M-1..M-5: `[char]92`, `$EAP='Stop'`, try/finally close-only, env-passed inputs, one
   `__wid_conn_master__`) and added `scripts/check-winshell-splitargs.py` — the ONLY static check that catches
   the `\'` class (ansible-lint + `--syntax-check` both MISS it; that is exactly how C12c shipped the bug). The
   **native-module template is now RATIFIED (style guide §5)**: `$EAP='Stop'` + try/finally close-only +
   env-passed inputs + normalized-compare/re-acquire-verify + `[char]92` (never `\'`). Verify with the gate:
   `/root/.local/share/pipx/venvs/ansible-core/bin/python scripts/check-winshell-splitargs.py`.
5. 💤 **PARKED — AWS OS-disk replacement / adopt-existing-volumes.** PROD is **AWS** (AMI + EBS, NOT the
   proxmox path in AGENTS.md — a divergence to resolve): swap the AMI for a fresh fully-patched OS + re-attach
   the existing WSUS EBS volumes. The role goes **bi-modal** — detect populated data volumes (by `unique_id`)
   and take an "adopt existing" path: bring online (no format), reinstall the WSUS feature, **attach the
   existing SUSDB** (not relocate), re-point content + IIS. Dev-simulate via a VMX OS-vmdk swap keeping the
   data vmdks. Needs the Director's AWS-vs-proxmox deploy-direction call + an OS-swap test scenario.

---

## ⏱️ SESSION HANDOFF — 2026-07-20 (C15 arc opened; WDM-0 merged) — for the next fresh session

**STATE:** `main` @ `00f34a8` `[audited 95f5f9d]` + this codification. Item 5 (OS-disk replacement) closed at
C14h-j. The **C15 arc** is now open: a SECOND role, `windows_disk_manager`, replacing the `wsus` disk region
entirely. Plan of record: **`_handoff/steps/C15-arc.plan-v3.md`** (v1 and v2 kept for the record; both were
REVISEd twice by Fable + Sol). Memory: [[windows-disk-manager-arc]].

**PLATFORM MODEL (Director, 2026-07-20) — build in this order:**
1. **PHASE 1 — VMware (IMMEDIATE GOAL).** Everything platform-independent + `identity_vmware.yml`. Needs no
   AWS account, no Proxmox host, and none of M1/M2/M3.
2. **PHASE 2 — AWS.** `identity_aws.yml`. AWS is an **ephemeral E2E proof** — deploy, check, destroy per merge,
   minimal spend, and a portfolio artifact. Always greenfield; it never adopts.
3. **PHASE 3 — GitHub workflows,** AWS portion only. The workflow **calls** `compose-and-run.sh`
   (`SKIP_REVERT=1` + `INVENTORY=`) rather than reimplementing compose/overlay.
4. **DEFERRED — Proxmox = PRODUCTION** (real clients, daily). Follows the `talos-cluster` project. **M3**
   (does the authored `serial` reach `Get-Disk .SerialNumber`?) gates it — traced through PVE/QEMU source,
   never observed in a guest. **Pin `scsiN`, not `virtioN`.**

**ARCHITECTURE (both reviewers, independently: option D).** ONE role, per-platform adapter task files at
`tasks/identity_<platform>.yml` (directly under `tasks/` — the splitargs glob is non-recursive). `platform` is a
REQUIRED user variable, **verified** against `ansible_facts.system_vendor`, never auto-detected. The adapter
answers only *"which disk number is each purpose?"* and never mutates or authorizes. **The seam with `wsus` is a
DRIVE LETTER** — `wsus` keeps no disk-identity concept and its disk region is DELETED, not repaired. Letters are
declared once in shared play vars; completion is handed over as a namespaced non-cacheable readiness fact.
**Governing principle: select by what the pipeline AUTHORS, never what it DISCOVERS.**

**⚠️ FOUR CONFIRMED DEFECTS ON `main`** (verified at module source; ranked as deployed) — they leave with the
disk region at W-c rather than being patched, and **no AWS deploy should happen before that**:
**D-3** `unformatted` authorizes writes from ABSENCE of evidence (`win_disk_facts.ps1:215-216` — `Get-Partition
-ErrorAction SilentlyContinue`, `partitions` key only `if ($parts)`); **D-4** `partition_style RAW` treated as
blank though RAW means only "no recognised partition table"; **D-1** `win_partition` given `disk_number` +
`drive_letter` with no `partition_number` resolves `Get-Partition -DriveLetter` GLOBALLY and discards the disk
number (`win_partition.ps1:~101`; call site `present_windows.yml:228-233`); **D-2** `win_format` at `force:false`
reformats a populated volume on label mismatch (`win_format.ps1:206-213`; the ALU guard shields `db` but not
`content`↔`iis`, both 4096). Chains: D-1→D-2 destroys a disk never classified; D-3/D-4→D-2 destroys a
misclassified one.

**NEXT:** `WDM-1` (role skeleton, local v3.1.0 loader per Director) → WDM-2..11 → W-a..d. Every phase-1 piece is
provable on the dev VM.

**Also open:** the IIS letter leak (`defaults/main.yml:105,108` hardcode `G:\inetpub\...` independent of
`data_disks.iis.drive_letter`) — W-a. And `AGENTS.md`'s loader claim is now accurate: local **v3.1.0** =
upstream v3.0.0 + the `validate.yml` hook = **TD-003**, so it is NOT byte-identical to upstream today.

---

## ⏱️ SESSION HANDOFF — 2026-07-18 (item 4 CLOSED — role feature+maintenance+sync+logging complete) — historical

**STATE: the role is COMPLETE through roadmap item 4.** Feature core + IIS-on-its-own-drive arc + inline-PowerShell
maturity pass + **roadmap item 4 (industry best-practices logging) ALL DONE.** `main` @ the C13h-i codification
commit (`3d15b1d`). **The whole role is proven from a fresh OS: from-baseline E2E `ok=56 changed=35 failed=0`
+ full-role idempotency `changed=0`** (2026-07-18). Rolling snapshot refreshed to `pre-item5` (full role baked in).

**Item 4 (logging) — CLOSED (Director-scoped to IIS/WSUS-specific NON-GPO items; GPOs own ~99% of STIG,
[[role-vs-gpo-scope]]):** **C13a** (`f614e58`) install `Web-Http-Logging` — root-caused the C12b gap (config was
correct; the HTTP Logging role service was never installed) → W3C logs write to G:. **C13c-e** (`6c0a3e4`)
log-dir ACL (V-218790, SYSTEM/Admins FC + org Users R&X) + 4 STIG custom W3C fields (V-218788/9) +
`logTargetW3C=File,ETW` (V-218786) — 2 Claude P4 repairs (ConvertFrom-Json `@()` jaggedness; logTargetW3C
flags-enum `.Value`→`[string]`). **C13f-g** (`5f63d2b`) IIS log-cleanup runner (retention 90d) + weekly SYSTEM
schedule — IIS has no built-in retention. **C13h-i** (`2b6fd4b`) 3 Event Viewer custom views (WSUS/IIS-WsusPool/
WID-SUSDB, XPath queries proven to execute) + enable `Microsoft-IIS-Configuration/Operational` (native
`EventLogConfiguration`). **DROPPED** (GPO or MS-unsupported): event-log sizing (GPO), `SoftwareDistribution.log`
relocation (MS-unsupported). Event-log MaxSize + retention are GPO-owned; WSUS already logs to the Application
channel out of the box.

**NEXT — a Director scope decision** (the role is complete through item 4): (a) **item 5** (PARKED, §4) —
AWS/proxmox OS-disk swap / adopt-existing-volumes (bi-modal role); needs the Director's AWS-vs-proxmox
deploy-direction call + an OS-swap test scenario. (b) The **T-track endgame** — backport to a `*-template` repo
(parameterize dev-VM disk ids + upstream_server) → GitHub import (`nwarila-platform` org). (c) Optional G-track:
ratify the PROPOSED §8 escape-hatch policy (now exercised across C05/C06/C08–C13). The
inline-PowerShell-maturity native-module template is RATIFIED (style §5); the split_args gate
(`scripts/check-winshell-splitargs.py`) is part of the standard gate. The build spine (C01–C06i) delivers a working WSUS-on-WID: disk init (E:/F:) → `win_feature`
install → `wsusutil postinstall` → SUSDB relocated to `E:\WID\Data` (ONLINE, read-write; C: originals
health-gated-deleted) → content on `F:\WSUS`. Maintenance core: **C08** WsusPool IIS tuning, **C09** weekly
SUSDB reindex (SYSTEM), **C10** monthly WSUS Server Cleanup (SYSTEM). Sync: **C11a** languages + **C11b**
category bootstrap (prove-started) + **C11d** upstream/downstream source (+**C11e** stop-sync-before-Save
from-baseline fix). **IIS on G: (roadmap item 3, CLOSED):** **C12a** provision G: (3rd disk, VM re-baselined
v6) + **C12b** site logs → G: + **C12c** wwwroot + `InetStp PathWWWRoot` → G:. **C07 (END verify) DROPPED**
(theater; §4b).

**✅ Inline-PowerShell-maturity pass — DONE (piece M, `f8b1d6a [audited 7013393]`).** Hardened the 5 C06-era
SqlClient `win_shell` blocks to the RATIFIED native-module template ($EAP=Stop + try/finally close-only +
env-passed inputs + normalized-compare/re-acquire-verify + `[char]92`, never `\'`) and added
`scripts/check-winshell-splitargs.py` — the ONLY static check that catches the C12c `\'` class (ansible-lint +
`--syntax-check` both miss it). Behavior-preserving: converge `pre-maturity` ok=44 changed=0; from-baseline E2E
ok=49 changed=29 failed=0 (Detach/Attach exercised through a real relocation).

**★ IN PROGRESS: roadmap item 4 — industry best-practices logging.** **C13a DONE (`f614e58`)** — root-caused
the C12b IIS-log-not-materializing gap (the `Web-Http-Logging` role service was never installed; config was
already correct) and installed it → **W3C logs now write to G:** (proven; C12b loop CLOSED). Remaining, smaller
than first thought (WSUS event logging + SoftwareDistribution.log already work): **C13b** event-log sizing to
STIG minimums, **C13c** Event Viewer custom views for WSUS/IIS/WID, **C13d** (optional) relocate
`SoftwareDistribution.log` to G:. An exhaustive research workflow (`item4-logging-research`) is scoping the
concrete values (STIG sizes, custom-view XML/XPath, relocation feasibility). Then item 5 (PARKED — AWS/proxmox
OS-disk swap).

**C11 sync arc — COMPLETE / "good enough" (Director pull-back 2026-07-17).** **C11a** (`1c211bd`) — restrict
update languages to `['en']` (config-object idiom). **C11b** (`5003474 [audited fb87098]`) — gated
**category-only** bootstrap, PROVE-STARTED: `win_shell` gates on a **durable role-owned registry marker**
(`HKLM:\SOFTWARE\nwarila-platform\wsus\category_bootstrap_server_id` == `GetConfiguration().ServerId`); if
unmarked, `StartSynchronizationForCategoryOnly()` + confirm ACCEPTED (bounded 120s) + write marker; does NOT
block on the ~1-2hr sync. **C11d** (`2cfb2fa [audited 89b8127]`) — configure the **UPSTREAM WSUS source**
(downstream/replica topology): `GetConfiguration()` `SyncFromMicrosoftUpdate=false` + `UpstreamWsusServerName`/
`Port`/`UseSsl` + `IsReplicaServer` from a **REQUIRED** `config.upstream_server` (asserted in `validate.yml`,
inline `IsNullOrWhiteSpace` defense-in-depth) + `sync.upstream_port`(8530)/`upstream_use_ssl`(false)/
`replica`(true) defaults; five-field Save-on-diff + re-acquire-verify. **C11c (products) built + P4-green +
P4.5-presented then DROPPED; C11e/C11f (schedule/auto-approval) ABANDONED** — a downstream/replica INHERITS
products/classifications/schedule/approvals from its upstream, so those are unnecessary.

**Key C11 facts:** (1) the first category sync is ~1-2hr on this dev VM (WAN, 18745 items) but the usable
catalog (~375 products / 12 classifications) loads over that window; the SPECIFIC modern products
(Windows Server 2025 = **"Microsoft Server Operating System-24H2"**) land LATE. (2) The durable ServerId
registry marker beats `Result` (flips on a later failed sync) and `GetSynchronizationHistory()` (expires
~90d) as an idempotency gate. (3) `Save()` on the config object persists a downstream/upstream config
WITHOUT validating reachability — so C11d is provable on the dev VM (no real upstream) and does NOT trigger a
sync. Memory: [[c11-sync-arc-prove-started]].

**NEXT: the role is done — a Director scope decision.** Options: (a) an optional **from-baseline E2E verify**
(revert to `pre-ansible-clean-ssh-ready`, one composed pass, to re-prove the whole role from fresh OS — NOTE
it now REQUIRES `upstream_server`, which is declared as a DEV PLACEHOLDER in the playbook `wsus:` dict,
`4049218`); (b) the **T-track endgame** — backport to a `*-template` repo → GitHub import (`nwarila-platform`
org). **Rolling snapshot = `pre-C11c`** (clean full-catalog post-C11b state); C11d reverts there + re-applies
fast (needs `upstream_server`, now in the playbook). No new rolling snapshot taken (arc done; the from-baseline
verify uses the BASELINE, not the rolling snapshot).

**Standing notes:** **Codex model = `gpt-5.5` @ xhigh** (Director 2026-07-17, off `gpt-5.6-sol` "ultra" to
save quota; pin lives in `$CODEX_HOME/wsus.config.toml` — CLI 0.144.3 reads `<profile>.config.toml`, a
`[profiles.wsus]` table now errors; the loader-change gate still wants a Codex 5.6 **Sol** validator
specifically). **TD-004** (win_iis_webapppool → microsoft.iis.web_app_pool on the next collection bump).
**Ops:** empty ssh-agent → git signing hangs (`docs/KEY-RELOAD.md`); `%G?` misreports "No signature" but
commits ARE signed (check the `gpgsig` header). **Standing rule:** "lean toward defaults" (memory
`lean-toward-defaults`). **WSUS-config-object idiom:** normalized compare + Save-on-change +
RE-ACQUIRE-and-verify + `changed_when` (C11a/C11d).

**⛔ CODEX INVOCATION — the #1 gotcha (root-caused 2026-07-16, cost ~1h):** `codex exec` drains
stdin after the prompt arg (`Reading additional input from stdin...`); in any backgrounded/piped
shell stdin never EOFs → **codex blocks FOREVER before the model turn**, looking exactly like a slow
model / revoked token / "xhigh too slow" / contention. **FIX: append `< /dev/null` to EVERY
non-interactive `codex exec`.** The `wsus` profile now pins `model_reasoning_effort = "xhigh"` (the
model auto-picks `low` otherwise; its self-report is unreliable — trust otel `reasoning_effort=`).
**Fast pattern (Director directive):** decompose each P2/P3 into 2-3 razor-narrow `PASS|FAIL`-line-1
bounded audits (adherence/scope/gate-logic), each `< /dev/null` — each converges in seconds at xhigh
(C05r P3: 3 audits all PASS in ~30s). Full writeup: `docs/CODEX-SESSION.md` #1 + memory
`codex-driving-mechanics`. Isolated home `CODEX_HOME=/root/.codex-homes/windows-wsus`, `-p wsus`.

**⏱️ PER-STEP ROLLING SNAPSHOT (Director, 2026-07-16):** baseline `pre-ansible-clean-ssh-ready` stays
the sacred fresh-OS anchor; ONE rolling `pre-<piece>` snapshot (`scripts/snapshot-step.sh <piece>`,
taken post-merge only) is the usual revert target — `REVERT_TO=pre-<piece> scripts/compose-and-run.sh`
so merged pieces no-op fast instead of re-converging. At most TWO snapshots ever (`docs/VM-LIFECYCLE.md`
§4). **Rolling snapshot = `pre-item5`** (refreshed 2026-07-18 after item 4) — a CLEAN, FULLY-CONVERGED
**FULL-ROLE** 3-disk state (all of C01–C13 baked in: E:/F:/G:, SUSDB on E:, content on F:, inetpub+logs on G:,
sync configured, all IIS logging + Event Viewer views + IIS-Config channel), sync idle, SUSDB ONLINE, :8530
→ 200. Idempotency-proven (a full-role SKIP_REVERT re-run = changed=0). A future piece reverts there
(`REVERT_TO=pre-item5`) and re-applies fast. The from-baseline E2E uses the BASELINE
(`pre-ansible-clean-ssh-ready`, v6, 3 disks) — re-proven 2026-07-18: **ok=56 changed=35 failed=0**.

**Contract now:** disk ids are declared in the `wsus:` override dict and read as
`config.wid_disk_id` (DB→E:WSUSDB) / `config.wsus_disk_id` (content→F:WSUSDATA), each the
disk's `unique_id` (`eui.<hex>`). Dev values hardcoded in the playbook `wsus:` dict
(co-located with `temp_dir`): `wid_disk_id=eui.6C7076230CC23C55000C2968C7AE5760` (20 GiB),
`wsus_disk_id=eui.CF4AE05CEB88F43B000C29656D55634B` (30 GiB). OS disk, DO NOT touch:
`eui.D71C311D211B6731000C296D8345C5CC`. Disks are NVMe. Memory `wsus-dev-vm-disk-identity`.

**Verified live 2026-07-15:** both agent keys loaded; VM `WIN-2FA90PRKORT` @
192.168.0.181 SSH-ready; single snapshot `pre-ansible-clean-ssh-ready`; C02b
controller fixture + VM safe-pass green from a reverted baseline.

**Process rules in force (ratified this session):**
- **P4.5** — surface `present_windows.yml` for the Director + "is this good?" BEFORE the
  P5 merge. Never merge a role file the Director hasn't seen.
- **Smallest-step MS-doc loop** — one operation/module per cycle, MS-doc-grounded; Codex
  audits/executes; Claude validates + E2E tests; judgement-decisions report; STOP for
  approval before the next step. Memory `smallest-step-ms-doc-loop`.

**Operational gotchas in force:** revert before EVERY run (`scripts/revert-vm.sh`
explicitly before `compose-and-run.sh` — classifier) · Codex sandbox cannot commit,
run localhost fixtures, or reach the framework clone — Claude does staging/commit +
composed-tree lint + fixtures + VM proofs in P4 · plain-gate ansible-lint exits 2 on
`#region` (TD-002) → `--warn-list 'yaml[comments]'` · **ids now live in the `wsus:` dict,
so a `-e '{"wsus":{…}}'` proof override REPLACES the dict and MUST re-state
`temp_dir: false`** (presence proof needs no `-e`; footgun confined to `-e` overrides).

**Next action: the inline-PowerShell-maturity pass (Director 2026-07-17, ACTIVE INITIATIVE).** Audit EVERY
`win_shell` §8 task for full idempotency + native-module-like behavior. Recommended first move: an inventory
sweep of all win_shell/win_command tasks in `present_windows.yml` (+ the `files/*.ps1` runners), scored on
(a) `split_args` safety — no `\'` backslash-before-quote (the C12c finding; the systemic risk), (b) idempotency
— correct `changed_when`/gates, no blind mutation, (c) native-module-like behavior — normalized compare,
re-acquire-verify, fail-closed. Then decompose fixes into strict-cycle pieces (M-track). AFTER the maturity
pass: roadmap item 4 (functional logging, incl. C12b's IIS log file materializing on G:). Open G-track:
ratify the PROPOSED §8 escape-hatch policy (native-first; win_command argv; win_shell for cmdlets/shell
semantics) — now exercised across C05/C06/C08–C12c. **Codex is now `gpt-5.5` @ xhigh** (drive with `-p wsus`,
`< /dev/null`). Rolling snapshot to take at C12c P5 close = `pre-maturity` (fully-converged-through-C12c).
