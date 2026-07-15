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

1. **C02 — data volumes** (⛏️ next): consumes the C01r identifier contract
   (`wid_disk_id`/`wsus_disk_id`). Resolve `unique_id`→disk_number (win_partition
   needs it), online + clear read-only, GPT init, partition 100% (`partition_size:-1`),
   NTFS + label, assign letter. ⚠️ C02 owns onlining AND state-aware destructive
   safety — presence-only C01r does NOT authorize destruction; C02 must refuse to
   clobber a non-target/system disk without reintroducing size selection (C01r
   c02Handoff).
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
  second-run idempotency hole). Required inputs live OUTSIDE the `wsus:` dict.
- **Director reviews `present_windows.yml` before merge (P4.5, C01r):** eyes-on the
  role file + "is this good?" gate between P4 and P5. See [[STRICT-CYCLE-adapted.md]].
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
| C02 | Data volumes: resolve `unique_id`→disk_number, online+clear-RO, GPT init, partition 100%, NTFS+label, letter — `wid_disk_id`→`E:` `WSUSDB`, `wsus_disk_id`→`F:` `WSUSDATA` | ⛏️ NEXT | Identifier-based (C01r contract). `win_partition` needs disk_number → resolve from `win_disk_facts`; `partition_size:-1`=100%. Owns onlining AND state-aware destructive safety (refuse to clobber a non-target/system disk, no size selection — C01r c02Handoff). Adds letters/labels/fs to defaults same cycle. |
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
| G3 | Ratify remaining style proposal: §5 `ansible_facts` set_fact ban | ❓ | §4a (amended) / §4b / §5-ext RATIFIED via C01r (2026-07-15). The §5 `ansible_facts` set_fact ban (C01) is still PROPOSED — pending Director. |
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

**STATE: C01r merged; repo is guards-only (identifier-based).** `main` @ the C01r
codification commit. A composed run SUCCEEDS doing nothing but the identifier guards —
green recap ≠ "WSUS deployed" or "disks prepared" (see RTRACK-C01r). C01r
worktree/branch removed; tree clean.

**Contract now:** two REQUIRED top-level vars — `wid_disk_id` (DB→E:WSUSDB) and
`wsus_disk_id` (content→F:WSUSDATA), each the disk's `unique_id` (Get-Disk UniqueId /
`win_disk_facts.unique_id`, `eui.<hex>`). Baseline values (stable across revert —
live-probed): `wid_disk_id=eui.6C7076230CC23C55000C2968C7AE5760` (20 GiB),
`wsus_disk_id=eui.CF4AE05CEB88F43B000C29656D55634B` (30 GiB). OS disk, DO NOT touch:
`eui.D71C311D211B6731000C296D8345C5CC`. Disks are NVMe (not SCSI). See memory
`wsus-dev-vm-disk-identity`.

**Verified live 2026-07-15:** both agent keys loaded; VM `WIN-2FA90PRKORT` @
192.168.0.181 SSH-ready; single snapshot `pre-ansible-clean-ssh-ready`; C01r
presence+absence proofs green from a reverted baseline.

**New process rule — P4.5 (ratified this session):** after P2 AGREE + Codex P3 +
Claude P4, surface the final `present_windows.yml` into the Director's view and ask
"is this good?" BEFORE the P5 merge. Never merge a role file the Director hasn't seen.

**Operational gotchas in force:** revert before EVERY run (`scripts/revert-vm.sh`
explicitly before `compose-and-run.sh` — classifier) · Codex sandbox cannot commit,
run localhost fixtures, or reach the framework clone — Claude does staging/commit +
composed-tree lint + fixtures + VM proofs in P4 · plain-gate ansible-lint exits 2 on
`#region` (TD-002) → `--warn-list 'yaml[comments]'` · **id vars are now top-level
(outside the `wsus:` dict), so proof `-e` overrides NO LONGER need `temp_dir: false`**
(the C01 clobber footgun is gone for id-only overrides).

**Next action:** confirm C02 with the Director → P0. C02 = data-volume prep on the
C01r contract: resolve `unique_id`→disk_number (win_partition needs it), online + clear
read-only (Set-Disk), GPT init, partition 100% (`partition_size:-1`), NTFS + label,
assign letter; add letters/labels/fs to defaults same cycle. C02 owns state-aware
destructive safety — refuse to clobber a non-target/system disk WITHOUT reintroducing
size selection (C01r c02Handoff). Research: `win_initialize_disk` (uniqueid= / online),
`win_partition` (disk_number, partition_size:-1), `win_format` (allocation_unit_size
for the WID/SQL DB volume), idempotency across a second run.
