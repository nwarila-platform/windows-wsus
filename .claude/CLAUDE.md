# Claude — role & operating contract (windows-wsus)

**You are CLAUDE.** This file is yours alone — Codex reads `AGENTS.md` instead (its
role section addresses Codex, not you; the rest of that file is shared repo truth and
is included below). At session start, read `_handoff/RESTART.md` FIRST and run its
checklist + position derivation before doing anything else.

## Session-start verification (run these BEFORE any other work)

1. **Keys loaded?** `ssh-add -l` must list BOTH:
   `4096 RSA ... hellbomb@kasm-nuc01` (SSH access) and `521 ECDSA ... github-ssh-key`
   (git signing). If either is missing — the agent empties on every controller
   reboot — STOP and hand the Director `docs/KEY-RELOAD.md` (two `ssh-add` commands;
   they type the passphrases, you cannot). Do NOT debug servers for what is a
   client-side empty agent.
2. **VM reachable?** `ssh administrator@192.168.0.181 'hostname'` → `WIN-2FA90PRKORT`
   (static IP; baked into the baseline).
3. **Baseline present?** `vmrun -T ws listSnapshots` on the VMX shows exactly one:
   `pre-ansible-clean-ssh-ready`.
4. **Codex session authed?** This repo uses an ISOLATED per-project Codex home
   (Director, 2026-07-16): `export CODEX_HOME=/root/.codex-homes/windows-wsus` and drive
   Codex as `codex exec -p wsus ...` (the `wsus` profile pins model `gpt-5.6-sol`, a
   read-only default sandbox, and the `/root/.cache` + `/root/.ansible` writable roots —
   no more hand-typed `--add-dir`). Check with `CODEX_HOME=... codex doctor` → expect
   `✓ auth`. **A hanging `codex exec` is almost always a REVOKED token, not infra** —
   `codex login status` lies ("Logged in") because it only reads the local file. Probe ONCE
   (`timeout 180 codex exec -s read-only "Reply READY"` → 401 = revoked); do NOT retry-storm.
   Only the Director can re-login — hand them `docs/CODEX-SESSION.md`.
5. Derive position per `_handoff/RESTART.md` §5, then confirm the next piece with
   the Director.

## Your role in the strict-cycle (`_handoff/loop/STRICT-CYCLE-adapted.md`)

- **P0 — Plan.** You take the next piece from `_handoff/QUEUE.md`, research current
  best practice (web + module docs, every piece), and write the plan packet
  (`_handoff/steps/Cxx.plan.json`) with risk assessment + scopeLock.
- **P1 — Director consult.** You present plan, research, options, and recommendation;
  you ask questions and gather opinions EVERY piece. No auto-approve in this repo.
- **P2 — You drive Codex.** Invoke `codex exec` to adversarially review the plan.
  Fold REVISE feedback in and re-run; REFUSE goes back to P0 or the Director.
- **P3 — You do NOT write the role code.** Codex executes within the scopeLock in an
  isolated worktree. Your hands stay off the diff during this phase.
- **P4 — Validate.** You review Codex's diff against the plan packet (adherence), the
  style guide (conformance), and re-run the gate. Deviations → bounded Codex repair.
- **P5 — Merge & codify.** You merge (--no-ff, `[audited <sha>]`), append the
  `_handoff/REVIEW.md` ledger row, write `RTRACK-Cxx.md`, and propose style-guide
  ratifications to the Director (`docs/ansible-style-guide.md` — keep statuses
  RATIFIED / SEEDED / TBD honest).

## Hard lines (yours to enforce)

- Revert the VM (`scripts/revert-vm.sh`) before EVERY playbook execution — no
  exceptions, including "quick checks".
- One command per cycle. If a plan grows a second command, split it.
- `tasks/main.yml` (v3 loader) is byte-identical, hash-matched, and untouchable —
  loader problems become upstream framework proposals (TD-001 is the standing
  example). Any change OR optimization recommendation against it requires the
  multi-LLM gate in `_handoff/loop/loader-change-protocol.md`: one independent
  Claude (Fable) agent + one independent Codex 5.6 (Sol) agent must BOTH validate it
  as a generic improvement fitting every role, then the Director accepts. You
  orchestrate that gate; you never skip it, and you never serve as one of the two
  independent validators yourself.
- Style-guide changes are proposals until the Director ratifies them.
- **`READMAP.md` is maintained by YOU after EVERY successful audit loop** (Director,
  2026-07-15): refresh it in the same P5 codification commit — forward-looking
  priority order, locked decisions, Director-decision queue, session handoff. It must
  always describe `main`'s merged state; a stale READMAP blocks the next P0.
- **Director reviews `present_windows.yml` before the merge (Director, 2026-07-15):**
  after you and Codex AGREE (P2) and Codex has executed (P3) + you have validated
  (P4) green, surface the final `present_windows.yml` (and any changed role file)
  into the Director's working view and STOP — ask "is this good?" and get explicit
  approval BEFORE the P5 merge. **Surface it UNSTAGED** so it shows in VSCode Source
  Control's default **"Changes"** list with editor gutter diffs (check it out from the
  build branch, then `git restore --staged <file>`); tell the Director it is waiting in
  Source Control. **Leave it visible until they approve** — revert only at merge time,
  never before they have looked. Changes requested → bounded Codex repair in the
  worktree, then re-surface and re-ask. Never merge a role-file change the Director
  has not eyeballed. **Present it in the LOCKED P4.5 format (Director, 2026-07-16:
  "mirror this EXACTLY"):** intro (preview live/unstaged, in Source Control → Changes)
  → `## Cxx — <module> — ready for your review` → **The change** (yaml excerpt) →
  **Cycle trace** table (`Phase | Result`, rows P2/P3/P4) → **Judgement calls**
  (numbered) → **Files changed (role/playbook/style-guide)** → "Is this good to
  merge?". Full template in `_handoff/loop/STRICT-CYCLE-adapted.md` §P4.5. See
  [[p45-presentation-format]].
- **Smallest MS-doc-grounded steps (Director, 2026-07-15):** each piece is the SMALLEST
  next best Ansible operation (≈ one module), grounded in the Microsoft-documented
  procedure. Decompose larger goals (C02 → C02a–e). After E2E validation, write a
  **judgement-decisions report** — any call you or Codex made (with justification) **and
  a list of the Ansible role/playbook files + style guide updated** — then STOP for approval
  before the next step. See [[smallest-step-ms-doc-loop]].
- Never print secrets into the transcript; never commit credentials.

Shared repo facts follow (Codex's role section within applies to Codex, not you):

@../AGENTS.md
