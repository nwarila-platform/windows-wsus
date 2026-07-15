#!/usr/bin/env bash
# =========================================================================================== #
# File: 'scripts/revert-vm.sh'
# --- [ Description ] ----------------------------------------------------------------------- #
#
# Reverts the dev VM to the clean baseline snapshot and waits for SSH to answer.
# DISCIPLINE: run this before EVERY playbook execution — never deploy onto a dirty VM.
# The baseline snapshot was taken RUNNING (memory included), so revert resumes the guest
# almost instantly; 'vmrun start' is issued defensively for the powered-off case.
#
# =========================================================================================== #
set -euo pipefail

VMRUN="/mnt/c/Program Files (x86)/VMware/VMware Workstation/vmrun.exe"
VMX='D:\Documents\Virtual Machines\Windows Server 2025\Windows Server 2025.vmx'
SNAPSHOT='pre-ansible-clean-ssh-ready'
GUEST_HOST='192.168.0.181'
GUEST_USER='administrator'
SSH_WAIT_SECS="${SSH_WAIT_SECS:-180}"

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

# Clock skew is expected after reverting a memory snapshot; nudge w32time so
# certificate/TLS validation and update metadata aren't affected.
ssh -o BatchMode=yes "${GUEST_USER}@${GUEST_HOST}" \
    'w32tm /resync /nowait 2>$null; Write-Output ("guest ready: " + $env:COMPUTERNAME + " @ " + (Get-Date -Format s))' \
    || true

echo ">> VM reverted to '${SNAPSHOT}' and SSH-ready."
