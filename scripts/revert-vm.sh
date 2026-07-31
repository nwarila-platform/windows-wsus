#!/usr/bin/env bash
# =========================================================================================== #
# File: 'scripts/revert-vm.sh'
# --- [ Description ] ----------------------------------------------------------------------- #
#
# Reverts the dev VM to a clean snapshot, waits for SSH to answer, and verifies the
# target's OS-disk identity before sending a mutating command to the guest.
# DISCIPLINE: run this before EVERY playbook execution — never deploy onto a dirty VM.
# Default target is the fresh-OS baseline. Per-step discipline (Director, 2026-07-16):
# REVERT_TO=pre-<piece> reverts to the rolling pre-change snapshot instead (taken by
# scripts/snapshot-step.sh from the previous piece's verified, merged state) — prior
# pieces then no-op fast instead of re-converging from scratch. The target must EXIST;
# a typo fails loud here rather than silently reverting somewhere unexpected.
# Snapshots are taken RUNNING (memory included), so revert resumes the guest almost
# instantly; 'vmrun start' is issued defensively for the powered-off case.
#
# =========================================================================================== #
set -euo pipefail

VMRUN="/mnt/c/Program Files (x86)/VMware/VMware Workstation/vmrun.exe"
VMX='D:\Documents\Virtual Machines\Windows Server 2025\Windows Server 2025.vmx'
BASELINE='pre-ansible-clean-ssh-ready'
SNAPSHOT="${REVERT_TO:-${BASELINE}}"
GUEST_HOST='192.168.0.181'
GUEST_USER='administrator'
SSH_WAIT_SECS="${SSH_WAIT_SECS:-180}"
EXPECTED_OS_DISK_ID='eui.D71C311D211B6731000C296D8345C5CC'
IDENTITY_PROBE_SECS=30
IDENTITY_PROBE_KILL=10

# Validate the target snapshot exists (exact-name match) before reverting.
# vmrun.exe is a Windows binary — its output is CRLF; strip \r or the -x match fails.
if ! "${VMRUN}" -T ws listSnapshots "${VMX}" | tr -d '\r' | grep -qxF "${SNAPSHOT}"; then
    echo "!! snapshot '${SNAPSHOT}' not found on the VM — refusing to revert." >&2
    "${VMRUN}" -T ws listSnapshots "${VMX}" >&2
    exit 1
fi

echo ">> Reverting to snapshot '${SNAPSHOT}' ..."
"${VMRUN}" -T ws revertToSnapshot "${VMX}" "${SNAPSHOT}"

# Revert may leave the VM powered off/suspended depending on snapshot type; a start on an
# already-running VM errors harmlessly — tolerate it.
if ! "${VMRUN}" list | grep -qF 'Windows Server 2025.vmx'; then
    echo ">> VM not running post-revert — starting (nogui) ..."
    "${VMRUN}" -T ws start "${VMX}" nogui || true
fi

echo ">> Waiting up to ${SSH_WAIT_SECS}s for SSH (${GUEST_USER}@${GUEST_HOST}) ..."
deadline=$(( $(date +%s) + SSH_WAIT_SECS ))
until ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
        "${GUEST_USER}@${GUEST_HOST}" 'exit 0' 2>/dev/null; do
    if [ "$(date +%s)" -ge "${deadline}" ]; then
        echo "!! SSH did not come back within ${SSH_WAIT_SECS}s" >&2
        exit 1
    fi
    sleep 5
done

[ -n "${EXPECTED_OS_DISK_ID}" ] || { echo "!! no expected OS-disk id configured" >&2; exit 1; }

echo ">> Verifying target identity (OS disk) ..."
probe_err="$(mktemp)"
trap 'rm -f "${probe_err}"' EXIT

if os_disk_probe="$(timeout --kill-after="${IDENTITY_PROBE_KILL}" "${IDENTITY_PROBE_SECS}" \
        ssh -o BatchMode=yes -o ConnectTimeout=5 "${GUEST_USER}@${GUEST_HOST}" \
        '(Get-Disk -Number 0).UniqueId' 2>"${probe_err}")"; then
    probe_rc=0
else
    probe_rc=$?
fi
os_disk_id="${os_disk_probe%$'\r'}"

if [ "${probe_rc}" -ne 0 ] || [ -z "${os_disk_id}" ] \
   || [ "${os_disk_id}" != "${EXPECTED_OS_DISK_ID}" ]; then
    echo "!! IDENTITY NOT CONFIRMED at ${GUEST_HOST} — refusing to proceed." >&2
    echo "!!   expected OS disk: ${EXPECTED_OS_DISK_ID}" >&2
    echo "!!   probe exit:       ${probe_rc}" >&2
    echo "!!   value read:       ${os_disk_id:-<none>}" >&2
    if [ -s "${probe_err}" ]; then
        echo "!!   probe stderr:" >&2
        sed 's/^/!!     /' "${probe_err}" >&2
    fi
    if [ "${probe_rc}" -eq 0 ] && [ -n "${os_disk_id}" ]; then
        echo "!! Disk 0 did not present the recorded id. The LIKELY cause is that a different" >&2
        echo "!! machine answered — a clone of this VM replies with the same hostname — in which" >&2
        echo "!! case nothing observed on it is evidence about this VM. Same-machine causes are" >&2
        echo "!! possible too (disk renumbering, a replaced or reset OS disk). Establish which" >&2
        echo "!! before concluding." >&2
    else
        echo "!! The probe exit status or returned value was unusable, so identity is UNKNOWN — not proven" >&2
        echo "!! wrong. Check reachability first; conclude nothing about which machine answered." >&2
    fi
    exit 1
fi
echo ">> Identity confirmed: ${os_disk_id}"

# Clock skew is expected after reverting a memory snapshot; nudge w32time so
# certificate/TLS validation and update metadata aren't affected.
ssh -o BatchMode=yes "${GUEST_USER}@${GUEST_HOST}" \
    'w32tm /resync /nowait 2>$null; Write-Output ("guest ready: " + $env:COMPUTERNAME + " @ " + (Get-Date -Format s))' \
    || true

echo ">> VM reverted to '${SNAPSHOT}' and SSH-ready."
