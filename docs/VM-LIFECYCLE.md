# VM lifecycle — dev target ownership & procedures

The dev VM is a **disposable execution target with a durable baseline**. Everything
here exists to protect one invariant: *every playbook run starts from the identical,
known-clean state.*

## 1. Baseline snapshot contract

- Name: **`pre-ansible-clean-ssh-ready`** (always exactly one snapshot with this name).
- Contents (what "clean" means): fresh Windows Server 2025, VMware Tools installed,
  OpenSSH server with key auth for `administrator`
  (`administrators_authorized_keys`), `DefaultShell` = PowerShell, **static IP
  192.168.0.181/24** (gw/dns 192.168.0.1), **2 vCPU / 4 GB RAM**, **two attached but
  BLANK/RAW data disks** (Disk 1 = 20 GB, Disk 2 = 30 GB — un-initialized, no
  partitions, no letters), **no WSUS bits, no role side-effects, no staged files**.
  Taken RUNNING with memory (revert resumes in seconds; capture ~5 min at 4 GB).
  Current baseline: **v5**, 2026-07-15.
- **The data disks are RAW on purpose.** Guest-side disk init (GPT/format/label/
  letter) is the `wsus` role's job (style guide §4a — the role configures the handed
  machine end-to-end). The baseline provides only the *hardware*; a formatted disk in
  the baseline would be a forbidden un-diffable artifact. Every clean revert therefore
  hands the role blank disks, exercising its init path each run.
- Baseline history: v1 clean+SSH → v2 +static IP → v3 +2 vCPU/4 GB → v4 +2 disks
  (formatted; superseded) → **v5 disks wiped RAW** (the E2E-role decision).
- A baseline must NEVER be taken from a VM that has had a playbook run against it
  since the last revert. Clean chain only: revert → (baseline-level change) → snapshot.

## 2. Daily loop (the only three supported modes)

- **Normal:** `scripts/compose-and-run.sh -e env=int` — reverts first (gate built in),
  then composes and runs. Equivalent manual form: `scripts/revert-vm.sh` then run.
- **Per-step (Director, 2026-07-16):** `REVERT_TO=pre-<piece> scripts/compose-and-run.sh
  -e env=int` — reverts to the rolling pre-change snapshot (the previous piece's
  verified, merged state; see §4) so all merged pieces no-op fast instead of
  re-converging from the fresh OS. This IS a clean-revert run for P4 evidence — the
  pre-change point is a known-verified state. The from-baseline E2E guarantee is
  re-proven once at the END-verify piece (C07), from `pre-ansible-clean-ssh-ready`.
- **Debug exception:** `SKIP_REVERT=1 scripts/compose-and-run.sh ...` — re-run against
  the CURRENT (dirty) state to iterate on a failure or inspect post-mortem. Rules:
  never draw idempotency or correctness conclusions from a dirty run; never snapshot
  in this state; the cycle's P4 evidence must come from a clean-revert run.

## 3. Re-baselining (when the baseline itself must change)

Triggers: credential rotation, Tools/OS servicing worth baking in, **hardware**
changes (vCPU/RAM, adding/removing disks — a fresh raw disk is hardware; formatting
it is NOT, that's the role's job per §4a), TD-001 exit (loader v3.1), transport
changes. Note: adding a disk requires the VM **powered off** AND the snapshot
**deleted first** (memory snapshots pin the old hardware set) — see the v4 disk-add
in this file's history.

Procedure (Director-approved change only):
```bash
VMRUN="/mnt/c/Program Files (x86)/VMware/VMware Workstation/vmrun.exe"
VMX='D:\Documents\Virtual Machines\Windows Server 2025\Windows Server 2025.vmx'
scripts/revert-vm.sh                                   # 1. start from the CURRENT baseline
# 2. apply ONLY the baseline-level change (no role runs!)
"$VMRUN" -T ws deleteSnapshot "$VMX" pre-ansible-clean-ssh-ready   # 3. exactly-one-name invariant
"$VMRUN" -T ws snapshot       "$VMX" pre-ansible-clean-ssh-ready  # 4. retake
"$VMRUN" -T ws listSnapshots  "$VMX"                                # 5. verify: exactly 1
scripts/revert-vm.sh                                   # 6. prove the new baseline reverts + SSH-ready
```
Then update the baseline description in §1 and the date/contents note in `AGENTS.md`,
and run the smoke proof (S3 in the session runbook §6 / first composed run) before
any cycle uses it.

## 4. Snapshot hygiene

- AT MOST TWO snapshots exist (amended from exactly-one — Director, 2026-07-16):
  1. **The baseline** `pre-ansible-clean-ssh-ready` — the fresh-OS anchor. NEVER
     touched outside the re-baseline procedure (§3).
  2. **One rolling per-step snapshot** `pre-<piece>` (e.g. `pre-C06d`) — the
     pre-change point for the NEXT piece, taken by `scripts/snapshot-step.sh` ONLY
     from a **verified, merged** post-piece state (after P4.5 approval + P5 merge —
     never mid-proof, never from a failed run). The script deletes the previous
     rolling snapshot first, so the count never exceeds two.
- `vmrun snapshot` with an existing name creates a DUPLICATE chain entry — always
  `deleteSnapshot` first (`snapshot-step.sh` and the §3 procedure both enforce this).
- No ad-hoc/experimental snapshots on this VM; a debug state worth keeping is a sign
  the piece needs a better proof, not a snapshot.
- Snapshot deltas grow the disk over time; after many re-baselines, consolidate
  (delete + retake) and check host disk headroom (snapshot includes guest RAM).

## 5. Network identity

- NIC: bridged to the physical LAN; guest MAC **`00:0C:29:98:E2:69`**;
  **`192.168.0.181/24` is STATIC in-guest** (gw/dns `192.168.0.1`), converted from
  DHCP and baked into the baseline on 2026-07-15 — no router dependency.
- If the LAN itself ever changes (subnet/gateway), that is a baseline-level change:
  set the new static config, then re-baseline (§3), then update
  `ansible/inventory/vmware.yml`, `scripts/revert-vm.sh`, and the session runbook
  §4/§6 together — grep the old IP repo-wide.
- Discovery fallback if the guest is ever unreachable at the expected address:
  `"$VMRUN" getGuestIPAddress "$VMX"` (needs Tools running).

## 6. Failure playbook

| Symptom | Likely cause | Action |
|---|---|---|
| `revertToSnapshot` errors | snapshot name drift / duplicate chain | `listSnapshots`, restore exactly-one-name invariant (§4) |
| SSH never returns post-revert | VM left powered off; IP moved; guest firewall | `vmrun list` → `start nogui`; `getGuestIPAddress`; console via Workstation GUI |
| `getGuestIPAddress` errors | Tools not running (baseline damage) | boot fully, check `Get-Service VMTools`; if truly gone, re-baseline from scratch |
| Key auth suddenly fails | controller agent empty after reboot (NOT the VM) | `ssh-add -l` first — two-command fix in `docs/KEY-RELOAD.md` |
| Guest clock skew after revert | memory-snapshot resume | expected; `revert-vm.sh` fires `w32tm /resync` |
| Play stalls silently at its first task (often Gathering Facts) | stale SSH ControlMaster socket (killed run, or mux invalidated by a VM revert) | `compose-and-run.sh` pre-cleans its repo-local mux dir (`.compose/.cp`); for manual runs, clear `~/.ansible/cp/` |

## 7. Ownership boundaries

- Guest-OS state changes come from exactly two sources: **the role under build**
  (reverted away every run) or **the re-baseline procedure** (§3, Director-approved).
  Hand-edits to the guest outside those two paths invalidate the baseline guarantee.
- VM hardware/config changes (disks, NIC mode, CPU/RAM) are Director-level decisions
  and always end with a re-baseline (§3).
