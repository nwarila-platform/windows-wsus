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

1. **C02 — data volumes** (⛏️ next): the direct successor; consumes C01's guard
   contract. ⚠️ C02 must NOT assume matched disks are online/writable (C01 recorded
   limitation) — onlining is C02's job.
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
- **Handed-machine contract (§4a, RATIFIED)** — role owns ALL guest-OS state E2E;
  hardware provisioning belongs to the deploy layer; disk selection is declarative
  (size/characteristics), never disk-number-coupled.
- **Division of labor** — Claude plans/validates/merges; Codex reviews (P2) and
  executes (P3); Director consulted EVERY piece; no auto-approve.
- **C01 (2026-07-15):** wazuh BEGIN/gather styling is the template idiom; defaults
  stay minimal (keys land with the piece that consumes them); no total-disk-count
  pin; negative proofs are standard for guard pieces.
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
| C02 | Data volumes: init/GPT/NTFS/label/letter — 20 GB→`E:` `WSUSDB`, 30 GB→`F:` `WSUSDATA` | ⛏️ NEXT | Size-selected, idempotent. Owns disk onlining (C01 does not prove online/writable). Consumes `wsus_defaults.data_disks`; adds letters/labels/fs keys same cycle. |
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
| G3 | Ratify style proposals: §4b BEGIN-stage contract, §5 `ansible_facts` set_fact ban | ❓ | Marked PROPOSED (C01) in the style guide. |
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

**STATE: C01 merged; repo is guards-only.** A composed run now SUCCEEDS while doing
nothing but BEGIN guards — green recap ≠ "WSUS deployed" (see RTRACK-C01). `main`
@ `8df979d`; worktree/branch for C01 removed; tree clean.

**Verified live 2026-07-15:** both agent keys loaded; VM `WIN-2FA90PRKORT` @
192.168.0.181 SSH-ready; single snapshot `pre-ansible-clean-ssh-ready`; baseline =
GPT 60 GB system disk + RAW 20 GiB + RAW 30 GiB (enumerated in the C01 absence-proof
fail_msg).

**Operational gotchas banked this session:** proof-run overrides of the `wsus:` dict
must re-state `temp_dir: false` (extra-vars replace, not merge) · run
`scripts/revert-vm.sh` explicitly before `compose-and-run.sh` (permission classifier)
· Codex sandbox cannot commit (no `.git` writes / no signing-agent socket) — Codex
stages, Claude performs the mechanical commit with `Executed-by: Codex` trailers ·
plain-gate ansible-lint exits 2 on `#region` banners (TD-002) — use
`--warn-list 'yaml[comments]'`.

**Next action:** confirm C02 with the Director → P0 (research: `win_initialize_disk`
/ `win_partition` / `win_format` idempotency, online/read-only handling, GPT,
allocation unit size for SQL-style workloads on the DB volume).
