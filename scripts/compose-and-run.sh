#!/usr/bin/env bash
# =========================================================================================== #
# File: 'scripts/compose-and-run.sh'
# --- [ Description ] ----------------------------------------------------------------------- #
#
# Composition runner: builds the combined execution tree and runs the playbook.
#
#   1. Clones/updates nwarila-platform/ansible-framework into .compose/ansible-framework
#      and checks out the commit pinned in .framework-pin (tags once upstream releases).
#   2. Overlays this repo's role into the framework's applications/ namespace (rsync
#      --delete so stale files never linger).
#   3. Runs ansible/playbooks/wsus.yml with the framework's ansible.cfg as the chassis
#      (its roles_path resolves the role by bare name).
#
# Usage: scripts/compose-and-run.sh [-e env=int] [any extra ansible-playbook args...]
#        SKIP_REVERT=1 to bypass the snapshot-revert gate (composition testing only).
#        REVERT_TO=pre-<piece> to revert to the rolling per-step snapshot instead of
#        the fresh-OS baseline (passed through to revert-vm.sh; VM-LIFECYCLE.md §2).
#
# =========================================================================================== #
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_DIR="${REPO_ROOT}/.compose"
FRAMEWORK_DIR="${COMPOSE_DIR}/ansible-framework"
FRAMEWORK_REMOTE='git@github.com:nwarila-platform/ansible-framework.git'
PIN_FILE="${REPO_ROOT}/.framework-pin"
ROLE_NAME='wsus'
ANSIBLE_PLAYBOOK="${ANSIBLE_PLAYBOOK:-/root/.local/bin/ansible-playbook}"

[ -f "${PIN_FILE}" ] || { echo "!! missing ${PIN_FILE}" >&2; exit 1; }
PIN="$(tr -d '[:space:]' < "${PIN_FILE}")"

# --- 0a. SSH mux isolation (stale ControlMaster sockets hang runs indefinitely) ------------ #
# A VM revert invalidates any live SSH multiplex socket to the guest, and a killed run can
# leave a zombie socket behind — either one stalls the next play at its first task. Keep
# Ansible's control sockets repo-local and start every run with a clean dir. (Proven: S3
# proof-out 2026-07-15 stalled on a stale ~/.ansible/cp socket; clean run after removal.)
export ANSIBLE_SSH_CONTROL_PATH_DIR="${COMPOSE_DIR}/.cp"
rm -rf "${ANSIBLE_SSH_CONTROL_PATH_DIR}"
mkdir -p "${ANSIBLE_SSH_CONTROL_PATH_DIR}"

# --- 0b. Snapshot-revert gate (discipline: clean VM before every run) ---------------------- #
if [ "${SKIP_REVERT:-0}" != "1" ]; then
    "${REPO_ROOT}/scripts/revert-vm.sh"
else
    echo ">> SKIP_REVERT=1 — running against the VM's CURRENT (possibly dirty) state."
fi

# --- 1. Framework checkout at the pin ------------------------------------------------------- #
mkdir -p "${COMPOSE_DIR}"
if [ ! -d "${FRAMEWORK_DIR}/.git" ]; then
    echo ">> Cloning ansible-framework ..."
    git clone --quiet "${FRAMEWORK_REMOTE}" "${FRAMEWORK_DIR}"
fi
git -C "${FRAMEWORK_DIR}" fetch --quiet origin
git -C "${FRAMEWORK_DIR}" checkout --quiet --detach "${PIN}"
echo ">> Framework pinned at $(git -C "${FRAMEWORK_DIR}" rev-parse --short HEAD)"

# --- 2. Overlay the role into the framework namespace --------------------------------------- #
rsync -a --delete \
    "${REPO_ROOT}/ansible/applications/${ROLE_NAME}/" \
    "${FRAMEWORK_DIR}/applications/${ROLE_NAME}/"
echo ">> Overlaid role '${ROLE_NAME}' into framework applications/"

# --- 3. Execute with the framework chassis --------------------------------------------------- #
cd "${FRAMEWORK_DIR}"
export ANSIBLE_CONFIG="${FRAMEWORK_DIR}/ansible.cfg"
exec "${ANSIBLE_PLAYBOOK}" \
    -i "${REPO_ROOT}/ansible/inventory/vmware.yml" \
    "${REPO_ROOT}/ansible/playbooks/wsus.yml" \
    "$@"
