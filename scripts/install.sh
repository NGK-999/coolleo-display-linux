#!/usr/bin/env bash
# Managed by coolleo-display-linux
set -Eeuo pipefail

readonly PROJECT="coolleo-display-linux"
readonly VERSION="0.1.0-alpha.1"
readonly SERVICE_USER="coolleo-display"
readonly SERVICE_GROUP="coolleo-display"
readonly BINARY_DEST="/usr/local/bin/coolleo-display"
readonly SERVICE_DEST="/etc/systemd/system/coolleo-display.service"
readonly RULE_DEST="/etc/udev/rules.d/70-coolleo-display.rules"
readonly STATE_DIR="/var/lib/coolleo-display"
readonly MANIFEST="${STATE_DIR}/install-manifest"
readonly UNINSTALLED_MARKER="${STATE_DIR}/uninstalled-state"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
readonly BINARY_SOURCE="${REPO_ROOT}/src/coolleo_display.py"
readonly SERVICE_SOURCE="${REPO_ROOT}/packaging/coolleo-display.service"
readonly RULE_SOURCE="${REPO_ROOT}/packaging/70-coolleo-display.rules"

ALLOW_MISSING_DISPLAY=0
FORCE=0
COMMITTED=0
CREATED_USER_THIS_RUN=0
CREATED_GROUP_THIS_RUN=0
CURRENT_HAD_BINARY=0
CURRENT_HAD_SERVICE=0
CURRENT_HAD_RULE=0
PREVIOUS_ACTIVE=0
PREVIOUS_ENABLED=0
CURRENT_ACTIVE=0
CURRENT_ENABLED=0
TRANSACTION_DIR=""
TRANSACTION_READY=0
MANIFEST_TMP=""
HAVE_MANIFEST=0
EXPECTED_SERVICE_UID=""
EXPECTED_SERVICE_GID=""
PRESERVE_BINARY=0
PRESERVE_SERVICE=0
PRESERVE_RULE=0
NEW_BINARY_INSTALLED=0
TRUSTED_BINARY_SHA256=""
CURRENT_BINARY_TRUSTED=0
CURRENT_SERVICE_TRUSTED=0
BASELINE_CREATED_THIS_RUN=0
HAD_UNINSTALLED_MARKER=0

usage() {
    cat <<'EOF'
Usage: sudo ./scripts/install.sh [--allow-missing-display] [--force]

  --allow-missing-display   Install while the tested USB display is
                            disconnected. Intel sensors are still required.
  --force                   Back up and replace an unknown or locally modified
                            destination file. Review the backup before using it.
                            Stop an active unverified service manually first.
EOF
}

die() {
    printf 'install: %s\n' "$*" >&2
    exit 1
}

warn() {
    printf 'install: warning: %s\n' "$*" >&2
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

manifest_value() {
    local key="$1"
    awk -F= -v wanted="${key}" '$1 == wanted { print substr($0, length($1) + 2); exit }' "${MANIFEST}"
}

assert_safe_manifest() {
    local owner mode
    [[ -f "${MANIFEST}" && ! -L "${MANIFEST}" ]] || die "invalid install manifest"
    owner="$(stat -c '%u' -- "${MANIFEST}")"
    mode="$(stat -c '%a' -- "${MANIFEST}")"
    [[ "${owner}" == "0" ]] || die "install manifest is not owned by root"
    (( (8#${mode} & 8#022) == 0 )) || die "install manifest is writable by non-root users"
    [[ "$(manifest_value FORMAT)" == "1" ]] || die "unsupported install manifest format"
}

secure_project_directory() {
    local path="$1"
    if [[ -L "${path}" ]]; then
        die "project state directory must not be a symbolic link: ${path}"
    fi
    if [[ -e "${path}" && ! -d "${path}" ]]; then
        die "project state path is not a directory: ${path}"
    fi
    if [[ ! -d "${path}" ]]; then
        install -d -o root -g root -m 0700 -- "${path}"
    fi
    [[ "$(stat -c '%u:%g' -- "${path}")" == "0:0" ]] || die "project state directory is not owned by root:root: ${path}"
    local mode
    mode="$(stat -c '%a' -- "${path}")"
    (( (8#${mode} & 8#022) == 0 )) || die "project state directory is writable by non-root users: ${path}"
    chmod 0700 -- "${path}"
}

validate_baseline_directory() {
    [[ "${BASELINE_DIR}" =~ ^/var/lib/coolleo-display/backups/original-[0-9]{8}T[0-9]{6}Z(-[A-Za-z0-9]{6})?$ ]] || die "invalid backup path in install manifest"
    [[ -d "${BASELINE_DIR}" && ! -L "${BASELINE_DIR}" ]] || die "baseline backup directory is missing or unsafe"
    [[ "$(realpath -e -- "${BASELINE_DIR}")" == "${BASELINE_DIR}" ]] || die "baseline backup path is not canonical"
    [[ "$(stat -c '%u:%g' -- "${BASELINE_DIR}")" == "0:0" ]] || die "baseline backup is not owned by root:root"
    local mode
    mode="$(stat -c '%a' -- "${BASELINE_DIR}")"
    (( (8#${mode} & 8#022) == 0 )) || die "baseline backup is writable by non-root users"
}

validate_uninstalled_marker() {
    [[ -f "${UNINSTALLED_MARKER}" && ! -L "${UNINSTALLED_MARKER}" ]] || die "invalid uninstalled-state marker"
    [[ "$(stat -c '%u:%g' -- "${UNINSTALLED_MARKER}")" == "0:0" ]] || die "uninstalled-state marker is not owned by root:root"
    local mode
    mode="$(stat -c '%a' -- "${UNINSTALLED_MARKER}")"
    (( (8#${mode} & 8#022) == 0 )) || die "uninstalled-state marker is writable by non-root users"
    [[ "$(awk 'END { print NR }' "${UNINSTALLED_MARKER}")" == "1" ]] || die "invalid uninstalled-state marker content"
    grep -qxF 'FORMAT=1' "${UNINSTALLED_MARKER}" || die "invalid uninstalled-state marker content"
    HAD_UNINSTALLED_MARKER=1
}

assert_replaceable() {
    local path="$1"
    [[ ! -e "${path}" && ! -L "${path}" ]] && return 0
    if [[ -L "${path}" ]]; then
        die "refusing symbolic-link destination: ${path}"
    fi
    if [[ -e "${path}" && ! -f "${path}" ]]; then
        die "refusing non-regular destination: ${path}"
    fi
    if grep -Fq 'Managed by coolleo-display-linux' "${path}"; then
        return 0
    fi
    if (( FORCE == 1 )); then
        warn "adopting unknown file after backup: ${path}"
        return 0
    fi
    die "refusing to overwrite unknown file ${path}; inspect it, then rerun with --force if intentional"
}

verify_current_hash() {
    local path="$1" expected="$2"
    [[ ( ! -e "${path}" && ! -L "${path}" ) || -z "${expected}" ]] && return 0
    if [[ -L "${path}" ]]; then
        die "managed destination became a symbolic link: ${path}"
    fi
    [[ ! -e "${path}" || -f "${path}" ]] || die "managed destination is not a regular file: ${path}"
    local actual
    actual="$(sha256sum -- "${path}" | awk '{print $1}')"
    if [[ "${actual}" == "${expected}" ]]; then
        case "${path}" in
            "${BINARY_DEST}") CURRENT_BINARY_TRUSTED=1 ;;
            "${SERVICE_DEST}") CURRENT_SERVICE_TRUSTED=1 ;;
        esac
    else
        if (( FORCE == 1 )); then
            warn "replacing locally modified managed file after backup: ${path}"
            case "${path}" in
                "${BINARY_DEST}") PRESERVE_BINARY=1 ;;
                "${SERVICE_DEST}") PRESERVE_SERVICE=1 ;;
                "${RULE_DEST}") PRESERVE_RULE=1 ;;
                *) die "internal backup target is unknown: ${path}" ;;
            esac
        else
            die "managed file was modified locally: ${path}; rerun with --force only after reviewing it"
        fi
    fi
}

hash_or_dash() {
    local enabled="$1" path="$2"
    if [[ "${enabled}" == "1" ]]; then
        sha256sum -- "${path}" | awk '{print $1}'
    else
        printf '%s\n' '-'
    fi
}

copy_if_present() {
    local source="$1" destination_dir="$2"
    if [[ -f "${source}" && ! -L "${source}" ]]; then
        cp -a -- "${source}" "${destination_dir}/"
    fi
}

cleanup_transaction() {
    [[ -n "${TRANSACTION_DIR}" && -d "${TRANSACTION_DIR}" && ! -L "${TRANSACTION_DIR}" ]] || return 0
    rm -f -- "${TRANSACTION_DIR}/coolleo-display" "${TRANSACTION_DIR}/coolleo-display.service" "${TRANSACTION_DIR}/70-coolleo-display.rules" "${TRANSACTION_DIR}/install-manifest" "${TRANSACTION_DIR}/uninstalled-state" || true
    rmdir -- "${TRANSACTION_DIR}" 2>/dev/null || true
}

cleanup_new_baseline() {
    (( BASELINE_CREATED_THIS_RUN == 1 )) || return 0
    if [[ "${BASELINE_DIR}" =~ ^/var/lib/coolleo-display/backups/original-[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9]{6}$ ]] &&
       [[ -d "${BASELINE_DIR}" && ! -L "${BASELINE_DIR}" ]] &&
       [[ "$(realpath -e -- "${BASELINE_DIR}")" == "${BASELINE_DIR}" ]] &&
       [[ "$(stat -c '%u:%g' -- "${BASELINE_DIR}")" == "0:0" ]]; then
        rm -f -- "${BASELINE_DIR}/coolleo-display" "${BASELINE_DIR}/coolleo-display.service" "${BASELINE_DIR}/70-coolleo-display.rules"
        rmdir -- "${BASELINE_DIR}" 2>/dev/null || warn "new baseline backup contains unexpected files and was preserved: ${BASELINE_DIR}"
    else
        warn "new baseline backup could not be safely removed: ${BASELINE_DIR}"
    fi
}

restore_transaction_file() {
    local had_file="$1" saved_name="$2" destination="$3"
    rm -f -- "${destination}" || return 1
    if [[ "${had_file}" == "1" ]]; then
        cp -a -- "${TRANSACTION_DIR}/${saved_name}" "${destination}" || return 1
    fi
    return 0
}

trigger_tested_hidraw() {
    local hidraw uevent
    shopt -s nullglob
    for hidraw in /sys/class/hidraw/hidraw*; do
        uevent="${hidraw}/device/uevent"
        if [[ -r "${uevent}" ]] && grep -Fq 'HID_ID=0003:00001A2C:00004D84' "${uevent}"; then
            udevadm trigger --action=change "${hidraw}" || true
        fi
    done
    shopt -u nullglob
}

rollback() {
    local status="${1:-1}"
    local access_cleanup_ok=1
    local files_restore_ok=1
    local remove_group_ok=1
    trap - EXIT INT TERM
    set +e
    if (( COMMITTED == 0 && TRANSACTION_READY == 1 )) && [[ -n "${TRANSACTION_DIR}" && -d "${TRANSACTION_DIR}" ]]; then
        warn "installation failed; restoring the files present before this run"
        if (( NEW_BINARY_INSTALLED == 1 || (CURRENT_BINARY_TRUSTED == 1 && CURRENT_SERVICE_TRUSTED == 1) )); then
            systemctl stop coolleo-display.service >/dev/null 2>&1 || true
            if systemctl is-active --quiet coolleo-display.service; then
                warn "service did not stop during rollback; service accounts will be preserved"
                access_cleanup_ok=0
            fi
        fi
        if (( NEW_BINARY_INSTALLED == 1 )); then
            if [[ -x "${BINARY_DEST}" && ! -L "${BINARY_DEST}" ]] &&
               [[ "$(sha256sum -- "${BINARY_DEST}" | awk '{print $1}')" == "${TRUSTED_BINARY_SHA256}" ]]; then
                "${BINARY_DEST}" --restore-access >/dev/null 2>&1 || { warn "could not restore Intel RAPL access during rollback"; access_cleanup_ok=0; }
                "${BINARY_DEST}" --lock-hidraw-access >/dev/null 2>&1 || { warn "could not restrict hidraw access during rollback"; access_cleanup_ok=0; }
            else
                warn "new binary could not be verified during rollback; it was not executed"
                access_cleanup_ok=0
            fi
        fi
        restore_transaction_file "${CURRENT_HAD_BINARY}" coolleo-display "${BINARY_DEST}" || { warn "could not restore ${BINARY_DEST}"; files_restore_ok=0; }
        restore_transaction_file "${CURRENT_HAD_SERVICE}" coolleo-display.service "${SERVICE_DEST}" || { warn "could not restore ${SERVICE_DEST}"; files_restore_ok=0; }
        restore_transaction_file "${CURRENT_HAD_RULE}" 70-coolleo-display.rules "${RULE_DEST}" || { warn "could not restore ${RULE_DEST}"; files_restore_ok=0; }
        restore_transaction_file "${HAVE_MANIFEST}" install-manifest "${MANIFEST}" || { warn "could not restore ${MANIFEST}"; files_restore_ok=0; }
        restore_transaction_file "${HAD_UNINSTALLED_MARKER}" uninstalled-state "${UNINSTALLED_MARKER}" || { warn "could not restore ${UNINSTALLED_MARKER}"; files_restore_ok=0; }
        if (( files_restore_ok == 0 )); then
            access_cleanup_ok=0
        fi
        systemctl daemon-reload >/dev/null 2>&1 || true
        udevadm control --reload-rules >/dev/null 2>&1 || true
        trigger_tested_hidraw
        if (( access_cleanup_ok == 1 && files_restore_ok == 1 )); then
            if (( CREATED_USER_THIS_RUN == 1 )); then
                userdel "${SERVICE_USER}" >/dev/null 2>&1 || { warn "could not remove the service user during rollback"; remove_group_ok=0; }
            fi
            if (( CREATED_GROUP_THIS_RUN == 1 && remove_group_ok == 1 )); then
                groupdel "${SERVICE_GROUP}" >/dev/null 2>&1 || warn "could not remove the service group during rollback"
            fi
        elif (( CREATED_USER_THIS_RUN == 1 || CREATED_GROUP_THIS_RUN == 1 )); then
            warn "service user/group were preserved because access cleanup was not confirmed"
        fi
        if (( files_restore_ok == 1 )); then
            systemctl disable coolleo-display.service >/dev/null 2>&1 || true
            if (( CURRENT_ENABLED == 1 )); then
                systemctl enable coolleo-display.service >/dev/null 2>&1 || true
            fi
            if (( CURRENT_ACTIVE == 1 )); then
                systemctl start coolleo-display.service >/dev/null 2>&1 || true
            fi
            cleanup_transaction
        else
            warn "rollback copies were preserved for manual recovery in ${TRANSACTION_DIR}"
        fi
    fi
    if (( COMMITTED == 0 )); then
        if [[ -n "${MANIFEST_TMP}" && "${MANIFEST_TMP}" =~ ^/var/lib/coolleo-display/install-manifest\.tmp\.[0-9]+$ ]]; then
            rm -f -- "${MANIFEST_TMP}"
        fi
        if (( TRANSACTION_READY == 0 || files_restore_ok == 1 )); then
            cleanup_transaction
            cleanup_new_baseline
        else
            warn "new baseline backup was preserved for manual recovery: ${BASELINE_DIR}"
        fi
    fi
    exit "${status}"
}

while (( $# > 0 )); do
    case "$1" in
        --allow-missing-display) ALLOW_MISSING_DISPLAY=1 ;;
        --force) FORCE=1 ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; die "unknown argument: $1" ;;
    esac
    shift
done

[[ "$(id -u)" == "0" ]] || die "run this installer with sudo"
[[ "$(uname -s)" == "Linux" ]] || die "this installer supports Linux only"
for command_name in awk chmod chown cp date getent grep groupadd groupdel install mktemp mv python3 realpath runuser sha256sum stat systemctl systemd-analyze udevadm uname useradd userdel; do
    require_command "${command_name}"
done
for source_file in "${BINARY_SOURCE}" "${SERVICE_SOURCE}" "${RULE_SOURCE}"; do
    [[ -f "${source_file}" && ! -L "${source_file}" ]] || die "missing repository file: ${source_file}"
done
python3 -c 'import sys; raise SystemExit(sys.version_info < (3, 9))' || die "Python 3.9 or newer is required"
[[ "$(PYTHONDONTWRITEBYTECODE=1 python3 "${BINARY_SOURCE}" --version)" == "coolleo_display.py ${VERSION}" ]] || die "application version mismatch"
TRUSTED_BINARY_SHA256="$(sha256sum -- "${BINARY_SOURCE}" | awk '{print $1}')"

assert_replaceable "${BINARY_DEST}"
assert_replaceable "${SERVICE_DEST}"
assert_replaceable "${RULE_DEST}"

if [[ -e "${UNINSTALLED_MARKER}" || -L "${UNINSTALLED_MARKER}" ]]; then
    validate_uninstalled_marker
fi

if [[ ! -e "${MANIFEST}" && ! -L "${MANIFEST}" && -d "${STATE_DIR}" && ! -L "${STATE_DIR}" ]] &&
   [[ -e "${BINARY_DEST}" || -L "${BINARY_DEST}" || -e "${SERVICE_DEST}" || -L "${SERVICE_DEST}" || -e "${RULE_DEST}" || -L "${RULE_DEST}" ]] &&
   (( HAD_UNINSTALLED_MARKER == 0 )); then
    shopt -s nullglob
    previous_state=(
        "${STATE_DIR}"/backups/original-*
        "${STATE_DIR}"/backups/overwritten-*
        "${STATE_DIR}"/transactions/*
    )
    shopt -u nullglob
    if (( ${#previous_state[@]} > 0 )); then
        die "install manifest is missing while previous installer state remains; do not reinstall over it; follow the recovery guidance in docs/SUPPORT.md"
    fi
fi
if [[ ! -e "${MANIFEST}" && ! -L "${MANIFEST}" ]] && systemctl is-active --quiet coolleo-display.service; then
    die "refusing to stop an active service without a trusted install manifest; inspect and stop it manually before installing"
fi

HAD_BINARY=0
HAD_SERVICE=0
HAD_RULE=0
CREATED_USER=0
CREATED_GROUP=0
BASELINE_DIR=""
BASELINE_BINARY_SHA256="-"
BASELINE_SERVICE_SHA256="-"
BASELINE_RULE_SHA256="-"

secure_project_directory "${STATE_DIR}"
secure_project_directory "${STATE_DIR}/backups"
secure_project_directory "${STATE_DIR}/transactions"
trap 'rollback $?' EXIT
trap 'exit 130' INT TERM

if [[ -L "${MANIFEST}" ]]; then
    die "install manifest must not be a symbolic link"
elif [[ -f "${MANIFEST}" ]]; then
    assert_safe_manifest
    HAVE_MANIFEST=1
    HAD_BINARY="$(manifest_value HAD_BINARY)"
    HAD_SERVICE="$(manifest_value HAD_SERVICE)"
    HAD_RULE="$(manifest_value HAD_RULE)"
    CREATED_USER="$(manifest_value CREATED_USER)"
    CREATED_GROUP="$(manifest_value CREATED_GROUP)"
    PREVIOUS_ACTIVE="$(manifest_value PREVIOUS_ACTIVE)"
    PREVIOUS_ENABLED="$(manifest_value PREVIOUS_ENABLED)"
    BASELINE_DIR="$(manifest_value BASELINE_DIR)"
    EXPECTED_SERVICE_UID="$(manifest_value SERVICE_UID)"
    EXPECTED_SERVICE_GID="$(manifest_value SERVICE_GID)"
    BASELINE_BINARY_SHA256="$(manifest_value BASELINE_BINARY_SHA256)"
    BASELINE_SERVICE_SHA256="$(manifest_value BASELINE_SERVICE_SHA256)"
    BASELINE_RULE_SHA256="$(manifest_value BASELINE_RULE_SHA256)"
    EXPECTED_BINARY_SHA256="$(manifest_value BINARY_SHA256)"
    EXPECTED_SERVICE_SHA256="$(manifest_value SERVICE_SHA256)"
    EXPECTED_RULE_SHA256="$(manifest_value RULE_SHA256)"
    for boolean_value in "${HAD_BINARY}" "${HAD_SERVICE}" "${HAD_RULE}" "${CREATED_USER}" "${CREATED_GROUP}" "${PREVIOUS_ACTIVE}" "${PREVIOUS_ENABLED}"; do
        [[ "${boolean_value}" =~ ^[01]$ ]] || die "invalid boolean in install manifest"
    done
    [[ "${EXPECTED_SERVICE_UID}" =~ ^[0-9]+$ && "${EXPECTED_SERVICE_GID}" =~ ^[0-9]+$ ]] || die "invalid service identity in install manifest"
    [[ "$(manifest_value VERSION)" == "${VERSION}" ]] || die "install manifest version does not match this installer"
    validate_baseline_directory
    [[ "${BASELINE_BINARY_SHA256}" =~ ^(-|[0-9a-f]{64})$ && "${BASELINE_SERVICE_SHA256}" =~ ^(-|[0-9a-f]{64})$ && "${BASELINE_RULE_SHA256}" =~ ^(-|[0-9a-f]{64})$ ]] || die "invalid baseline hash in install manifest"
    [[ "${EXPECTED_BINARY_SHA256}" =~ ^[0-9a-f]{64}$ && "${EXPECTED_SERVICE_SHA256}" =~ ^[0-9a-f]{64}$ && "${EXPECTED_RULE_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "invalid managed-file hash in install manifest"
    [[ "$(hash_or_dash "${HAD_BINARY}" "${BASELINE_DIR}/coolleo-display")" == "${BASELINE_BINARY_SHA256}" ]] || die "original binary backup hash mismatch"
    [[ "$(hash_or_dash "${HAD_SERVICE}" "${BASELINE_DIR}/coolleo-display.service")" == "${BASELINE_SERVICE_SHA256}" ]] || die "original service backup hash mismatch"
    [[ "$(hash_or_dash "${HAD_RULE}" "${BASELINE_DIR}/70-coolleo-display.rules")" == "${BASELINE_RULE_SHA256}" ]] || die "original udev-rule backup hash mismatch"
    verify_current_hash "${BINARY_DEST}" "${EXPECTED_BINARY_SHA256}"
    verify_current_hash "${SERVICE_DEST}" "${EXPECTED_SERVICE_SHA256}"
    verify_current_hash "${RULE_DEST}" "${EXPECTED_RULE_SHA256}"
else
    [[ ! -e "${MANIFEST}" ]] || die "install manifest path is not a regular file"
    [[ -e "${BINARY_DEST}" || -L "${BINARY_DEST}" ]] && HAD_BINARY=1
    [[ -e "${SERVICE_DEST}" || -L "${SERVICE_DEST}" ]] && HAD_SERVICE=1
    [[ -e "${RULE_DEST}" || -L "${RULE_DEST}" ]] && HAD_RULE=1
    if systemctl is-active --quiet coolleo-display.service; then PREVIOUS_ACTIVE=1; fi
    if systemctl is-enabled --quiet coolleo-display.service; then PREVIOUS_ENABLED=1; fi
    BASELINE_DIR="$(mktemp -d "${STATE_DIR}/backups/original-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"
    BASELINE_CREATED_THIS_RUN=1
    chown root:root -- "${BASELINE_DIR}"
    chmod 0700 -- "${BASELINE_DIR}"
    copy_if_present "${BINARY_DEST}" "${BASELINE_DIR}"
    copy_if_present "${SERVICE_DEST}" "${BASELINE_DIR}"
    copy_if_present "${RULE_DEST}" "${BASELINE_DIR}"
    BASELINE_BINARY_SHA256="$(hash_or_dash "${HAD_BINARY}" "${BASELINE_DIR}/coolleo-display")"
    BASELINE_SERVICE_SHA256="$(hash_or_dash "${HAD_SERVICE}" "${BASELINE_DIR}/coolleo-display.service")"
    BASELINE_RULE_SHA256="$(hash_or_dash "${HAD_RULE}" "${BASELINE_DIR}/70-coolleo-display.rules")"
fi

if systemctl is-active --quiet coolleo-display.service; then CURRENT_ACTIVE=1; fi
if (( CURRENT_ACTIVE == 1 && (CURRENT_BINARY_TRUSTED == 0 || CURRENT_SERVICE_TRUSTED == 0) )); then
    die "refusing to stop an active service whose binary or unit is not verified by the install manifest; inspect and stop it manually before installing"
fi

if (( PRESERVE_BINARY == 1 || PRESERVE_SERVICE == 1 || PRESERVE_RULE == 1 )); then
    OVERRIDE_BACKUP_DIR="$(mktemp -d "${STATE_DIR}/backups/overwritten-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"
    chown root:root -- "${OVERRIDE_BACKUP_DIR}"
    chmod 0700 -- "${OVERRIDE_BACKUP_DIR}"
    if (( PRESERVE_BINARY == 1 )); then copy_if_present "${BINARY_DEST}" "${OVERRIDE_BACKUP_DIR}"; fi
    if (( PRESERVE_SERVICE == 1 )); then copy_if_present "${SERVICE_DEST}" "${OVERRIDE_BACKUP_DIR}"; fi
    if (( PRESERVE_RULE == 1 )); then copy_if_present "${RULE_DEST}" "${OVERRIDE_BACKUP_DIR}"; fi
    warn "durable copies of locally modified files were saved in ${OVERRIDE_BACKUP_DIR}"
fi

if systemctl is-enabled --quiet coolleo-display.service; then CURRENT_ENABLED=1; fi
CURRENT_HAD_BINARY=0
CURRENT_HAD_SERVICE=0
CURRENT_HAD_RULE=0
[[ -f "${BINARY_DEST}" && ! -L "${BINARY_DEST}" ]] && CURRENT_HAD_BINARY=1
[[ -f "${SERVICE_DEST}" && ! -L "${SERVICE_DEST}" ]] && CURRENT_HAD_SERVICE=1
[[ -f "${RULE_DEST}" && ! -L "${RULE_DEST}" ]] && CURRENT_HAD_RULE=1
TRANSACTION_DIR="$(mktemp -d "${STATE_DIR}/transactions/install-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"
chown root:root -- "${TRANSACTION_DIR}"
chmod 0700 -- "${TRANSACTION_DIR}"
copy_if_present "${BINARY_DEST}" "${TRANSACTION_DIR}"
copy_if_present "${SERVICE_DEST}" "${TRANSACTION_DIR}"
copy_if_present "${RULE_DEST}" "${TRANSACTION_DIR}"
copy_if_present "${MANIFEST}" "${TRANSACTION_DIR}"
copy_if_present "${UNINSTALLED_MARKER}" "${TRANSACTION_DIR}"
TRANSACTION_READY=1

if (( CURRENT_ACTIVE == 1 )); then
    systemctl stop coolleo-display.service >/dev/null 2>&1 || true
fi
if systemctl is-active --quiet coolleo-display.service; then
    die "existing service did not stop; no files were replaced"
fi

if ! getent group "${SERVICE_GROUP}" >/dev/null; then
    groupadd --system "${SERVICE_GROUP}"
    CREATED_GROUP=1
    CREATED_GROUP_THIS_RUN=1
fi
group_record="$(getent group "${SERVICE_GROUP}")"
SERVICE_GID="$(printf '%s' "${group_record}" | awk -F: '{print $3}')"
group_members="$(printf '%s' "${group_record}" | awk -F: '{print $4}')"
[[ -z "${group_members}" || "${group_members}" == "${SERVICE_USER}" ]] || die "existing ${SERVICE_GROUP} group has unrelated supplementary members"
other_primary_user="$(getent passwd | awk -F: -v gid="${SERVICE_GID}" -v user="${SERVICE_USER}" '$4 == gid && $1 != user {print $1; exit}')"
[[ -z "${other_primary_user}" ]] || die "existing ${SERVICE_GROUP} group is the primary group of another user: ${other_primary_user}"
if ! getent passwd "${SERVICE_USER}" >/dev/null; then
    useradd --system --gid "${SERVICE_GROUP}" --home-dir /nonexistent --no-create-home --shell /usr/sbin/nologin "${SERVICE_USER}"
    CREATED_USER=1
    CREATED_USER_THIS_RUN=1
else
    user_record="$(getent passwd "${SERVICE_USER}")"
    [[ "$(printf '%s' "${user_record}" | awk -F: '{print $4}')" == "${SERVICE_GID}" ]] || die "existing ${SERVICE_USER} user has a different primary group"
    [[ "$(printf '%s' "${user_record}" | awk -F: '{print $6}')" == "/nonexistent" ]] || die "existing ${SERVICE_USER} user has an unexpected home directory"
    user_shell="$(printf '%s' "${user_record}" | awk -F: '{print $7}')"
    [[ "${user_shell}" == "/usr/sbin/nologin" || "${user_shell}" == "/sbin/nologin" || "${user_shell}" == "/bin/false" ]] || die "existing ${SERVICE_USER} user has a login shell"
fi
user_record="$(getent passwd "${SERVICE_USER}")"
SERVICE_UID="$(printf '%s' "${user_record}" | awk -F: '{print $3}')"
[[ "${SERVICE_UID}" =~ ^[0-9]+$ && "${SERVICE_GID}" =~ ^[0-9]+$ ]] || die "invalid service UID or GID"
(( SERVICE_UID < 1000 )) || die "service account UID is not in the system-account range"
if (( HAVE_MANIFEST == 1 )); then
    [[ "${SERVICE_UID}" == "${EXPECTED_SERVICE_UID}" && "${SERVICE_GID}" == "${EXPECTED_SERVICE_GID}" ]] || die "service UID/GID changed since installation"
fi

rm -f -- "${BINARY_DEST}" "${SERVICE_DEST}" "${RULE_DEST}"
install -o root -g root -m 0755 -- "${BINARY_SOURCE}" "${BINARY_DEST}"
install -o root -g root -m 0644 -- "${SERVICE_SOURCE}" "${SERVICE_DEST}"
install -o root -g root -m 0644 -- "${RULE_SOURCE}" "${RULE_DEST}"
[[ "$(sha256sum -- "${BINARY_DEST}" | awk '{print $1}')" == "${TRUSTED_BINARY_SHA256}" ]] || die "installed application hash mismatch"
NEW_BINARY_INSTALLED=1

[[ "$(PYTHONDONTWRITEBYTECODE=1 "${BINARY_DEST}" --version)" == "coolleo-display ${VERSION}" ]] || die "installed application version mismatch"
systemd-analyze verify "${SERVICE_DEST}"
if udevadm --help 2>&1 | grep -qE '(^|[[:space:]])verify([[:space:]]|$)'; then
    udevadm verify "${RULE_DEST}"
else
    warn "this udevadm version cannot pre-validate rule syntax"
fi

udevadm control --reload-rules
trigger_tested_hidraw
udevadm settle
"${BINARY_DEST}" --prepare-access
SENSOR_CHECK=0
DISPLAY_CHECK=0
runuser -u "${SERVICE_USER}" -- "${BINARY_DEST}" --dry-run --interval 0.25 || SENSOR_CHECK=$?
if (( SENSOR_CHECK == 0 )); then
    runuser -u "${SERVICE_USER}" -- "${BINARY_DEST}" --check --interval 0.25 || DISPLAY_CHECK=$?
fi
"${BINARY_DEST}" --restore-access
if (( SENSOR_CHECK != 0 )); then
    die "Intel coretemp/RAPL check failed as the unprivileged service user"
fi
if (( DISPLAY_CHECK != 0 )); then
    if (( ALLOW_MISSING_DISPLAY == 0 )); then
        die "display check failed; connect the tested USB display, or rerun with --allow-missing-display"
    fi
    warn "hardware check failed; the service will wait and retry after installation"
fi

systemctl daemon-reload
systemctl enable --now coolleo-display.service
systemctl is-active --quiet coolleo-display.service || die "service did not become active"

rm -f -- "${UNINSTALLED_MARKER}"
MANIFEST_TMP="${MANIFEST}.tmp.$$"
umask 077
cat >"${MANIFEST_TMP}" <<EOF
FORMAT=1
VERSION=${VERSION}
HAD_BINARY=${HAD_BINARY}
HAD_SERVICE=${HAD_SERVICE}
HAD_RULE=${HAD_RULE}
CREATED_USER=${CREATED_USER}
CREATED_GROUP=${CREATED_GROUP}
SERVICE_UID=${SERVICE_UID}
SERVICE_GID=${SERVICE_GID}
PREVIOUS_ACTIVE=${PREVIOUS_ACTIVE}
PREVIOUS_ENABLED=${PREVIOUS_ENABLED}
BASELINE_DIR=${BASELINE_DIR}
BASELINE_BINARY_SHA256=${BASELINE_BINARY_SHA256}
BASELINE_SERVICE_SHA256=${BASELINE_SERVICE_SHA256}
BASELINE_RULE_SHA256=${BASELINE_RULE_SHA256}
BINARY_SHA256=$(sha256sum -- "${BINARY_DEST}" | awk '{print $1}')
SERVICE_SHA256=$(sha256sum -- "${SERVICE_DEST}" | awk '{print $1}')
RULE_SHA256=$(sha256sum -- "${RULE_DEST}" | awk '{print $1}')
EOF
chown root:root -- "${MANIFEST_TMP}"
chmod 0600 -- "${MANIFEST_TMP}"
mv -f -- "${MANIFEST_TMP}" "${MANIFEST}"

COMMITTED=1
cleanup_transaction
trap - EXIT INT TERM
printf 'Installed %s %s. Service status: active.\n' "${PROJECT}" "${VERSION}"
printf 'Uninstall with: sudo %s/scripts/uninstall.sh\n' "${REPO_ROOT}"
