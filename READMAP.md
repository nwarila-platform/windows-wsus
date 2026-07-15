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

1. **Guard refactor → C02c–e — data volumes** (⛏️ next: R4). Assert policy (§4b "guards
   earn their keep") ratified; **V** + **R1** (Windows-family assert dropped) + **R2** (gathers
   collapsed) + **R3** (block-var resolution, no set_fact) merged. Guard trim remaining: R4 drop
   the Provided assert. Then the mutations: C02c `win_initialize_disk` (online+GPT) → C02d
   `win_partition` (100%+letter, disk_number from `item.matches | first`) → C02e `win_format`
   (NTFS+label; MS-rec allocation-unit — 64 KiB SQL/WID DB, MS-rec content). The C02b safety
   guard gates the first mutation (C02c).
2. **C03–C07 — the WSUS install spine** (staging dir → features → postinstall →
   SUSDB relocation → END verify), strictly in queue order.
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
- **C02e allocation (Director 2026-07-15):** `win_format` uses the MS-recommended
  allocation-unit size — 64 KiB for the SQL/WID `SUSDB` DB volume (E:), and the
  MS-recommended size for the WSUS content volume (F:, to research at C02e P0).
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
| R4 | Guard trim: drop the Provided assert (delegated to the resolution + `win_initialize_disk`); harden survivors | ⛏️ NEXT | Last guard trim; read-only. |
| C02c | `win_initialize_disk` — online + GPT-init the two data disks | ⛏️ | `uniqueid=`, `online: true` (clears offline/read-only), `force: false` (idempotent). FIRST mutation; gated by the C02b safety guard; runs after the R-refactor. |
| C02d | `win_partition` — 100% partition (`partition_size: -1`) + drive letter | ⛏️ | disk_number resolved from `unique_id` via `win_disk_facts`; drive_letter mandatory for idempotency. |
| C02e | `win_format` — NTFS + label (WSUSDB/WSUSDATA); **MS-recommended allocation-unit** (Director): 64 KiB SQL/WID `SUSDB` (E:), MS-rec content (F:, research at P0) | ⛏️ | `force: false` + preserved labels = idempotent; adds label/fs/alloc to defaults. |
| C03 | Role-owned staging dir via `ansible.windows.win_tempfile` (TD-001 stand-in) | ⛏️ | |
| C04 | Install `UpdateServices` + `UpdateServices-WidDB` + `UpdateServices-Services` | ⛏️ | |
| C05 | WSUS postinstall (`wsusutil.exe postinstall CONTENT_DIR=F:\WSUS…`) — idempotent guard | ⛏️ | `win_shell` escape-hatch policy (style §8) gets decided here at the latest. |
| C06 | Relocate SUSDB to `E:` via WID named pipe (detach/move/attach) | ⛏️ | Move-before-first-sync. |
| C07 | END verify: `WsusService` running + console port 8530 + DB/content on E:/F: | ⛏️ | Retry-loop idiom (style §4). |
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

## ⏱️ SESSION HANDOFF — 2026-07-15 — for the next fresh session

**STATE: R3 merged; repo is read-only guards + config-validation home.** `main` @ the R3
codification commit. Loader is **v3.1.0** (generic `tasks/validate.yml` hook, Director
exception, TD-003). Guard trims underway (V + R1 + R2 + R3 merged; **R4 last**). A composed
run SUCCEEDS doing nothing but read-only guards — green recap ≠ "WSUS deployed" or "disks
prepared" (see RTRACK-R3). Worktrees/branches removed; tree clean. **R4 next, then C02c
(first mutation).**

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

**Next action:** confirm **R4** with the Director → P0. The LAST guard trim per §4b "guards
earn their keep" (R1-R3 done): **R4** drop the Provided (defined/string/non-empty) assert —
type/required/non-empty is delegated to the `item.matches | length == 1` resolution ("found 0")
and `win_initialize_disk`'s own failure on a bad `uniqueid` (§4b prong a). All read-only. THEN
the mutations: C02c
`win_initialize_disk` (online+GPT) → C02d `win_partition` (100%+letter) → C02e
`win_format` (NTFS+label; **MS-recommended allocation unit** — 64 KiB SQL/WID DB, MS-rec
content, research at C02e P0). Module research banked; ground each step in MS docs.
