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
2. **WSUS install spine — C03/C04/C05 ✅ merged (WSUS IS ALIVE: Get-WsusServer OK :8530), C06 🔄
   ✅ COMPLETE** (SUSDB relocation C:→E:, C06a–i all merged; **SUSDB fully on E:**, C: originals retired,
   WSUS operational — Get-WsusServer OK :8530, idempotent); **C07 (END verify) NEXT — the final piece**.
3. **§3 Director decisions** — can land any time; none block C02, but style §4b/§5
   ratification is cheapest before more pieces cite them.
4. **C08+ — sync config, products/classifications, GPO-facing settings** (💤 scoped later).
5. **Upstream debt retirement** — TD-001 loader v3.1 proposal (gated by
   `loader-change-protocol.md`) + TD-002 chassis lint warn_list PR (normal PR, no
   gate). Deferred by Director decision until the local role is the priority no more.
6. **Endgame:** backport to a `*-template` repo → import to GitHub (`nwarila-platform`
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
| C06 | SUSDB relocation C:→E: — DECOMPOSED C06a–i (QUEUE.md; research + live probe 2026-07-16: zero-install SqlClient over the WID pipe, administrator=sysadmin, sys.master_files three-state gate, COPY-don't-move, ACL-before-attach) | 🔄 in-flight | C06a-c ✅ + U1 ✅ + C05r ✅ + C06d ✅ + **C06e ✅** (detach: sys.master_files 0 rows, files still on C:, idempotency orphaned-skip). **NEXT: C06f** — `win_copy remote_src` copy `.mdf`+`.ldf` C:→E: (gated pending\|orphaned). Then C06g attach → C06h start → C06i delete C: originals. |
| C06d | `win_service` — stop `WsusService` + `W3SVC` (gated pending\|orphaned); WID engine STAYS running for the C06e detach | ✅ merged `ec9a0cb [audited 5bca897]` 2026-07-16 | P2 AGREE (7-point review); P3 5bca897; P4 green: converge both stop + WID Running + failed=0, idempotency changed=0, C05r cross-check (postinstall skips with services down). First cycle under per-step snapshot proof (`pre-C06d`). RTRACK-C06d. |
| C06e | `win_shell` (SqlClient/WID pipe) — `SET SINGLE_USER WITH ROLLBACK IMMEDIATE` + `sp_detach_db 'SUSDB'` (gated ==pending); leaves files on C: (copy-don't-move) | ✅ merged `f961735 [audited 50b0079]` 2026-07-16 | P2 AGREE (8-point MS-cited); P3 50b0079; P4 green: converge detached (sys.master_files 0 rows) + .mdf/.ldf still on C: + failed=0, idempotency orphaned→skip changed=0. RTRACK-C06e. |
| C06f | `win_copy remote_src` — copy SUSDB `.mdf`/`.ldf` `%SystemDrive%\Windows\WID\Data` → `E:\WID\Data` (gated pending\|orphaned; copy-don't-move) | ✅ merged `00696a1 [audited 0b9d2fe]` 2026-07-16 | P2 REVISE r1 (SystemDrive-derived source + MS 'copies') → AGREE r2; P3 0b9d2fe; P4 green: converge E: sizes match C: + C: intact + WID-svc ACE inherited=True on E: files + failed=0, idempotency changed=0 (checksum). RTRACK-C06f. |
| C06g | `win_shell` (SqlClient/WID pipe) — `CREATE DATABASE SUSDB ... FOR ATTACH` from E: + fail-closed health gate (ONLINE + is_read_only=0 + all files on E:) + DROP-on-failure revert. The relocation pivot | ✅ merged `f4b39ae [audited 036d635]` 2026-07-16 | P2 REVISE r1→r2→r3 → AGREE r4 (4-round hardening: registered-but-unhealthy restart hole, DROP vs sp_detach_db, env-path injection, reader-close); P3 036d635; P4 green: converge SUSDB ONLINE+rw on E: + C: intact, idempotency relocated → all d/e/f/g SKIP changed=0. RTRACK-C06g. |
| C06h | `win_service` state:started loop [W3SVC, WsusService], UNGATED terminal desired-state — returns WSUS to operational on the E: SUSDB | ✅ merged `afd14d6 [audited 4400687]` 2026-07-16 | P2 AGREE (7-point); P3 4400687; P4 green: converge both start + Get-WsusServer OK :8530 + SUSDB ONLINE on E:, idempotency changed=0. RTRACK-C06h. |
| C06i | Independent health probe + `win_file state:absent` — delete the C: SUSDB originals ONLY when SUSDB is verified ONLINE+read_write+all-on-E. **Closes the C06 arc** | ✅ merged `5e240ad [audited 2bb17fe]` 2026-07-16 | P2 AGREE (predicate covers every unsafe state); P3 2bb17fe; P4 green: fixture 6/6, converge C: deleted + E: intact + WID system DBs untouched + Get-WsusServer OK :8530 + SUSDB ONLINE, idempotency changed=0. RTRACK-C06i. |
| C07 | END verify: `WsusService` running + `Get-WsusServer` + console port 8530 + DB on E: / content on F: | ⛏️ | Retry-loop idiom (style §4). |
| C08+ | Sync config, products/classifications, GPO-facing settings | 💤 | Scoped later, after C07 proves the spine. |

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

## 4. Parking Lot (Director drops new items here)

_empty_

---

## ⏱️ SESSION HANDOFF — 2026-07-16 — for the next fresh session

**STATE: C06i merged — the C06 SUSDB RELOCATION ARC IS COMPLETE.** `main` @ the C06i codification
commit (merge `5e240ad [audited 2bb17fe]`). A composed run now converges a fresh box to a WORKING WSUS
with **SUSDB living entirely on `E:\WID\Data`** (ONLINE + read-write), **content on `F:\WSUS`**,
services RUNNING, `Get-WsusServer OK :8530`, C: holding only the WID system DBs. FULLY IDEMPOTENT (a
re-run is `changed=0`: probe `relocated`, all destructive actors skip). **NEXT: C07 — the FINAL piece**:
END verify (a read-only assertion block confirming `WsusService` running + `Get-WsusServer` +
console :8530 answering + SUSDB on E: + content on F: — style §4 retry-loop idiom where a service/port
needs settle time). After C07 the role is fully operational (mission #1 done) → endgame T-track
(backport to `*-template`, GitHub import). `pre-C07` rolling snapshot from the converged post-C06i state
(fully relocated, WSUS operational). Older handoff detail below is historical. `present_windows.yml`: read-only
guards (block-var resolution → one `win_disk_facts` gather → fail-closed Attached → C02b safety
guard) + THREE disk mutations (`win_initialize_disk` → `win_partition` → `win_format`) + the
**`Main: WSUS Installation`** region (C03 content root → C04 `win_feature` WSUS role → **C05r**
`win_reg_stat` completion-flags probe → probe-gated `wsusutil postinstall`) + the opening of the
**`Main: SUSDB Relocation`** region (C06a dir → C06b WID-svc ACL → U1 Users ACL → C06c three-state
gate probe). A composed run delivers a WORKING WSUS: `Get-WsusServer` OK :8530, WsusService
Running/Automatic, WSUSContent on F:, **SUSDB (10.2 MB) in WID at `C:\Windows\WID\Data` — the C06
relocation source**, IRS completion flags all =2. §8 escape-hatch policy PROPOSED (G-track).
⚠️ **The dev VM is DIRTY** (C05r proofs — live WSUS, converged, services Running, gate 'pending').
**NEXT: C06d** (`win_service` stop WsusService+W3SVC, gated pending|orphaned; WID stays running).
Actor contract (C06c binding): `stdout|trim`; d/f/g fire on pending|orphaned, e on pending only.

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
§4). From-baseline E2E re-proven once at C07. **`pre-C06d` snapshot taken at this P5 from the verified
post-C05r converged state.**

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

**Next action:** **C06d re-enters P2** (its packet `_handoff/steps/C06d.plan.json` is P0-refreshed
with the per-step-snapshot proofs + a p2History entry recording the flap catch that spawned C05r).
`win_service` stop WsusService+W3SVC, loop, gated `__susdb_probe__.stdout | trim in ['pending',
'orphaned']`; WID service (`MSSQL$MICROSOFT##WID`) STAYS RUNNING (executes the later detach). Drive it
FAST with the fixed Codex pattern (bounded audits, `< /dev/null`, xhigh); P4 via `REVERT_TO=pre-C06d`;
P4.5 LOCKED format. Then C06e detach → C06f copy → C06g attach → C06h start → C06i delete C: originals
→ C07 (END verify: WsusService + Get-WsusServer + :8530 + DB on E: / content on F:). Ground truth
(RTRACK-C05): `SqlServerName=MICROSOFT##WID`, SUSDB.mdf 10.2 MB + log 1.1 MB; C06 relocation uses
zero-install `System.Data.SqlClient` over the WID pipe (administrator = WID sysadmin), COPY-don't-move,
`sys.master_files` three-state gate (C06c LIVE). Open G-track: Director ratification of the PROPOSED §8
policy.
