#!/usr/bin/env bash
# =========================================================================================== #
# File: 'scripts/compose-and-run.sh'
# --- [ Description ] ----------------------------------------------------------------------- #
#
# Composition runner: builds the combined execution tree and runs the playbook.
#
#   1. Clones/updates nwarila-platform/ansible-framework into .compose/ansible-framework
#      and checks out the commit pinned in .github/ansible-framework-pin (tags once upstream releases).
#   2. Overlays this repo's roles into the framework's applications/ namespace (rsync
#      --delete so stale files never linger), joins its scripts/*.ps1 to the framework's
#      scripts/, and materializes every role's <Name>.ps1.stub.
#   3. Runs the selected playbook with the framework's ansible.cfg as the chassis
#      (its roles_path resolves roles by bare name).
#
# Usage: scripts/compose-and-run.sh [-e env=test] [any extra ansible-playbook args...]
#        COMPOSE_PLAYBOOK=<name>.yml to select a playbook under ansible/playbooks/ (default wsus-aws.yml).
#        COMPOSE_INVENTORY=<path> to select a repository-relative inventory file.
#        ANSIBLE_SSH_AGENT or SSH_AUTH_SOCK must name an agent socket.
#
# =========================================================================================== #
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_DIR="${REPO_ROOT}/.compose"
FRAMEWORK_DIR="${COMPOSE_DIR}/ansible-framework"
FRAMEWORK_REMOTE='git@github.com:nwarila-platform/ansible-framework.git'
PIN_FILE="${REPO_ROOT}/.github/ansible-framework-pin"
ANSIBLE_PLAYBOOK="${ANSIBLE_PLAYBOOK:-ansible-playbook}"
command -v "${ANSIBLE_PLAYBOOK}" >/dev/null || { echo "!! ${ANSIBLE_PLAYBOOK} not on PATH" >&2; exit 1; }

[ -f "${PIN_FILE}" ] || { echo "!! missing ${PIN_FILE}" >&2; exit 1; }
PIN="$(tr -d '[:space:]' < "${PIN_FILE}")"
COMPOSE_PLAYBOOK_VALUE="${COMPOSE_PLAYBOOK-wsus-aws.yml}"

# --- 0a. Playbook selection (fail closed before any side effect) ---------------------------- #
if [ -z "${COMPOSE_PLAYBOOK_VALUE}" ]; then
    echo "!! COMPOSE_PLAYBOOK resolved path is empty" >&2
    exit 1
fi

if [[ "${COMPOSE_PLAYBOOK_VALUE}" = /* ]]; then
    echo "!! COMPOSE_PLAYBOOK resolved path is absolute: ${COMPOSE_PLAYBOOK_VALUE}" >&2
    exit 1
fi

root_real="$(realpath -e "${REPO_ROOT}/ansible/playbooks")"
target_candidate="${root_real}/${COMPOSE_PLAYBOOK_VALUE}"
if ! target="$(realpath -e "${target_candidate}" 2>/dev/null)"; then
    echo "!! COMPOSE_PLAYBOOK resolved path does not exist: ${target_candidate}" >&2
    exit 1
fi

if [ ! -f "${target}" ]; then
    echo "!! COMPOSE_PLAYBOOK resolved path is not a file: ${target}" >&2
    exit 1
fi

case "${target}" in
    "${root_real}"/*) ;;
    *)
        echo "!! COMPOSE_PLAYBOOK resolved path escapes ${root_real}: ${target}" >&2
        exit 1
        ;;
esac
COMPOSE_PLAYBOOK_PATH="${target}"

# --- 0b. Inventory selection (optional override, fail closed before any side effect) --------- #
COMPOSE_INVENTORY_PATH="${REPO_ROOT}/ansible/inventory/aws_ec2.yml"
if [[ -v COMPOSE_INVENTORY ]]; then
    if [ -z "${COMPOSE_INVENTORY}" ]; then
        printf '!! COMPOSE_INVENTORY resolved path is empty: %q\n' "${COMPOSE_INVENTORY}" >&2
        exit 1
    fi

    if [[ "${COMPOSE_INVENTORY}" = /* ]]; then
        printf '!! COMPOSE_INVENTORY resolved path is absolute: %q\n' "${COMPOSE_INVENTORY}" >&2
        exit 1
    fi

    inventory_root_real="$(realpath -e "${REPO_ROOT}")"
    inventory_candidate="${inventory_root_real}/${COMPOSE_INVENTORY}"
    if ! inventory_target="$(realpath -e "${inventory_candidate}" 2>/dev/null)"; then
        printf '!! COMPOSE_INVENTORY resolved path does not exist: %q\n' "${COMPOSE_INVENTORY}" >&2
        exit 1
    fi

    if [ ! -f "${inventory_target}" ]; then
        printf '!! COMPOSE_INVENTORY resolved path is not a file: %q\n' "${COMPOSE_INVENTORY}" >&2
        exit 1
    fi

    case "${inventory_target}" in
        "${inventory_root_real}"/*) ;;
        *)
            printf '!! COMPOSE_INVENTORY resolved path escapes repository root: %q\n' \
                "${COMPOSE_INVENTORY}" >&2
            exit 1
            ;;
    esac
    COMPOSE_INVENTORY_PATH="${inventory_target}"
fi

# --- 0d. Agent selection (fail closed before any side effect) ------------------------------- #
if [[ -v ANSIBLE_SSH_AGENT ]]; then
    selected_agent="${ANSIBLE_SSH_AGENT}"
else
    selected_agent="${SSH_AUTH_SOCK-}"
fi

case "${selected_agent}" in
    ''|auto|none)
        echo "!! ANSIBLE_SSH_AGENT or SSH_AUTH_SOCK must name an existing agent socket" >&2
        exit 1
        ;;
esac
export ANSIBLE_SSH_AGENT="${selected_agent}"

# --- 0c. SSH mux isolation (stale ControlMaster sockets hang runs indefinitely) ------------ #
# An interrupted or killed run can leave a stale SSH multiplex socket to the target, which
# stalls the next play at its first task. Keep Ansible's control sockets repo-local and start
# every run with a clean dir. (Observed 2026-07-15: a stale ~/.ansible/cp socket stalled a run,
# which completed after the socket was removed.)
export ANSIBLE_SSH_CONTROL_PATH_DIR="${COMPOSE_DIR}/.cp"
rm -rf "${ANSIBLE_SSH_CONTROL_PATH_DIR}"
mkdir -p "${ANSIBLE_SSH_CONTROL_PATH_DIR}"

# --- 1. Framework checkout at the pin ------------------------------------------------------- #
mkdir -p "${COMPOSE_DIR}"
if [ ! -d "${FRAMEWORK_DIR}/.git" ]; then
    echo ">> Cloning ansible-framework ..."
    git clone --quiet "${FRAMEWORK_REMOTE}" "${FRAMEWORK_DIR}"
fi
git -C "${FRAMEWORK_DIR}" fetch --quiet origin
# The checkout is persistent across runs, so the composed tree is only trustworthy if both halves
# are forced back to source. --force discards edits to tracked framework files, which a plain
# checkout keeps when HEAD is already at the pin — leaving the banner below printing a pin the
# tree no longer matches.
git -C "${FRAMEWORK_DIR}" checkout --quiet --force --detach "${PIN}"
echo ">> Framework pinned at $(git -C "${FRAMEWORK_DIR}" rev-parse --short HEAD)"

# The other half: a role this repository has since renamed or deleted survives in applications/
# from an earlier run and stays resolvable by roles_path. -x is required, not optional — the
# framework repository is deny-all too, so an overlaid role is IGNORED rather than merely
# untracked and a plain clean walks straight past it. The second -f reaches an overlay carrying
# nested Git metadata, which a single -f preserves. Framework-owned roles are tracked, and clean
# never touches those. Sources joined to scripts/ by an earlier run are ignored the same way; the
# clean clears them, or a script deleted here would be materialized again from its stale copy.
git -C "${FRAMEWORK_DIR}" clean --quiet -ffdx -- applications/ scripts/

# --- 2. Overlay roles into the framework namespace ------------------------------------------ #
shopt -s nullglob
role_sources=("${REPO_ROOT}"/ansible/applications/*)
shopt -u nullglob

# An empty overlay set is legitimate, not a broken path — this repository overlays only the roles
# it owns, and the framework owns the roles the play uses.
if [ "${#role_sources[@]}" -eq 0 ]; then
    echo ">> No repository roles to overlay; the play runs on framework roles alone"
else
    mapfile -t role_sources < <(printf '%s\n' "${role_sources[@]}" | LC_ALL=C sort)
fi
validated_roles=()

# Pass 1 — VALIDATE EVERY candidate before mutating anything. Deliberately separate from the
# rsync pass: validating and overlaying in one loop lets a valid role be written to the
# framework tree before a later invalid one aborts the run, leaving a partial overlay behind.
# Same rule the composer already applies to COMPOSE_PLAYBOOK (0a) — no side effect precedes
# validation.
for role_source in "${role_sources[@]}"; do
    role_name="$(basename "${role_source}")"

    if [[ ! "${role_name}" =~ ^[a-z][a-z0-9_]*$ ]]; then
        echo "!! invalid role basename '${role_name}' at ${role_source}" >&2
        exit 1
    fi

    # -L before -d: -d follows symlinks, so a symlink-to-dir would otherwise pass as a role
    # and rsync's trailing slash would read through it, outside the intended tree.
    if [ -L "${role_source}" ]; then
        echo "!! refusing symlinked role source: ${role_source}" >&2
        exit 1
    fi

    if [ ! -d "${role_source}" ]; then
        echo "!! role source is not a directory: ${role_source}" >&2
        exit 1
    fi

    if [ ! -f "${role_source}/tasks/main.yml" ]; then
        echo "!! role source missing tasks/main.yml: ${role_source}/tasks/main.yml" >&2
        exit 1
    fi

    # The real guard on rsync --delete: prove the destination is not a framework-OWNED role.
    # Reads the index, so a tracked-but-absent working-tree file still trips it.
    tracked_role_files="$(git -C "${FRAMEWORK_DIR}" ls-files -- "applications/${role_name}/")"
    if [ -n "${tracked_role_files}" ]; then
        echo "!! refusing to overlay framework-tracked role path: ${FRAMEWORK_DIR}/applications/${role_name}" >&2
        echo "${tracked_role_files}" >&2
        exit 1
    fi

    validated_roles+=("${role_name}")
done

# Pass 2 — overlay only after every candidate has passed.
for role_name in "${validated_roles[@]}"; do
    rsync -a --delete \
        "${REPO_ROOT}/ansible/applications/${role_name}/" \
        "${FRAMEWORK_DIR}/applications/${role_name}/"
    echo ">> Overlaid role '${role_name}' into framework applications/"
done

# --- 2b. Join this repository's scripts to the framework's, then materialize every stub ------ #
# The roles above carry <Name>.ps1.stub markers naming sources under scripts/, and the framework's
# materializer resolves every stub against the framework's scripts/. Validated in full before any
# copy, as the roles are; a name the framework already tracks is refused rather than replaced.
shopt -s nullglob
script_sources=("${REPO_ROOT}"/scripts/*.ps1)
shopt -u nullglob
for script_source in "${script_sources[@]}"; do
    script_name="$(basename "${script_source}")"
    if [ -L "${script_source}" ]; then
        echo "!! refusing symlinked script source: ${script_source}" >&2
        exit 1
    fi
    if [ -n "$(git -C "${FRAMEWORK_DIR}" ls-files -- "scripts/${script_name}")" ]; then
        echo "!! refusing to overlay framework-tracked script path: scripts/${script_name}" >&2
        exit 1
    fi
done
for script_source in "${script_sources[@]}"; do
    cp "${script_source}" "${FRAMEWORK_DIR}/scripts/$(basename "${script_source}")"
done
echo ">> Joined ${#script_sources[@]} script file(s) to framework scripts/"

# Every stub, the framework's and this repository's, becomes files/<Name>.ps1 here. Without it a
# role's lookup('file', ...) fails on a name that exists only as a stub, and a local run would
# diverge from CI at exactly the point that is hardest to attribute.
(cd "${FRAMEWORK_DIR}" && ./scripts/materialize-role-scripts.sh)

# --- 3. Execute with the framework chassis --------------------------------------------------- #
cd "${FRAMEWORK_DIR}"
export ANSIBLE_CONFIG="${FRAMEWORK_DIR}/ansible.cfg"

snapshot_agent_keys() {
    local destination="$1"
    local snapshot_status

    if SSH_AUTH_SOCK="${ANSIBLE_SSH_AGENT}" ssh-add -L > "${destination}"; then
        return 0
    else
        snapshot_status=$?
    fi

    # ssh-add returns 1 when the selected agent is healthy but empty.
    if [ "${snapshot_status}" -eq 1 ]; then
        : > "${destination}"
        return 0
    fi
    return "${snapshot_status}"
}

agent_custody_dir="$(mktemp -d)"
agent_keys_before="${agent_custody_dir}/before.pub"
agent_keys_after="${agent_custody_dir}/after.pub"

cleanup_agent_keys() {
    local run_status=$?
    local cleanup_status=0
    local snapshot_status=0
    local key_line
    local key_type
    local key_blob

    trap - EXIT
    set +e

    snapshot_agent_keys "${agent_keys_after}"
    snapshot_status=$?
    if [ "${snapshot_status}" -ne 0 ]; then
        echo "!! could not snapshot the selected SSH agent during cleanup" >&2
        cleanup_status="${snapshot_status}"
    else
        while IFS= read -r key_line; do
            case "${key_line}" in
                *'[added by ansible: PID='*) ;;
                *) continue ;;
            esac

            read -r key_type key_blob _ <<< "${key_line}"
            if awk -v type="${key_type}" -v blob="${key_blob}" \
                '$1 == type && $2 == blob { found = 1 } END { exit !found }' \
                "${agent_keys_before}"; then
                continue
            fi

            if ! printf '%s\n' "${key_line}" \
                | SSH_AUTH_SOCK="${ANSIBLE_SSH_AGENT}" ssh-add -d -; then
                echo "!! could not remove a key added to the selected agent by this run" >&2
                cleanup_status=1
            fi
        done < "${agent_keys_after}"
    fi

    if ! rm -rf -- "${agent_custody_dir}"; then
        echo "!! could not remove the SSH-agent custody directory" >&2
        cleanup_status=1
    fi

    if [ "${run_status}" -ne 0 ]; then
        exit "${run_status}"
    fi
    exit "${cleanup_status}"
}

trap cleanup_agent_keys EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if ! snapshot_agent_keys "${agent_keys_before}"; then
    echo "!! could not snapshot ANSIBLE_SSH_AGENT before the playbook run" >&2
    exit 1
fi

set +e
"${ANSIBLE_PLAYBOOK}" \
    -i "${COMPOSE_INVENTORY_PATH}" \
    "${COMPOSE_PLAYBOOK_PATH}" \
    "$@"
playbook_status=$?
set -e
exit "${playbook_status}"
