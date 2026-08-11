#!/usr/bin/env bash
# Managed by coolleo-display-linux
set -Eeuo pipefail

readonly SERVICE_USER="coolleo-display"
readonly SERVICE_GROUP="coolleo-display"
readonly BINARY_DEST="/usr/local/bin/coolleo-display"
readonly SERVICE_DEST="/etc/systemd/system/coolleo-display.service"
readonly RULE_DEST="/etc/udev/rules.d/70-coolleo-display.rules"
readonly STATE_DIR="/var/lib/coolleo-display"
readonly MANIFEST="${STATE_DIR}/install-manifest"
readonly UNINSTALLED_MARKER="${STATE_DIR}/uninstalled-state"
readonly VERSION="0.1.0-alpha.1"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
readonly BINARY_SOURCE="${REPO_ROOT}/src/coolleo_display.py"

FORCE=0
PURGE=0
COMMITTED=0
CURRENT_ACTIVE=0
CURRENT_ENABLED=0
CURRENT_HAD_BINARY=0
CURRENT_HAD_SERVICE=0
CURRENT_HAD_RULE=0
TRANSACTION_DIR=""
TRANSACTION_READY=0
TRUSTED_BINARY=0
TRUSTED_SERVICE=0
PRESERVE_BINARY=0
PRESERVE_SERVICE=0
PRESERVE_RULE=0
CURRENT_HAD_UNINSTALLED_MARKER=0

usage() {
    cat <<'EOF'
Usage: sudo ./scripts/uninstall.sh [--force] [--purge]

  --force  Back up and remove managed files even if they were modified after
           installation. An active modified service must be stopped manually.
  --purge  Also delete retained installation backups after a successful removal.
EOF
}

die() {
    printf 'uninstall: %s\n' "$*" >&2
    exit 1
}

warn() {
    printf 'uninstall: warning: %s\n' "$*" >&2
}

manifest_value() {
    local key="$1"
    awk -F= -v wanted="${key}" '$1 == wanted { print substr($0, length($1) + 2); exit }' "${MANIFEST}"
}

validate_secure_directory() {
    local path="$1"
    [[ -d "${path}" && ! -L "${path}" ]] || die "missing or unsafe project directory: ${path}"
    [[ "$(stat -c '%u:%g' -- "${path}")" == "0:0" ]] || die "project directory is not owned by root:root: ${path}"
    local mode
    mode="$(stat -c '%a' -- "${path}")"
    (( (8#${mode} & 8#022) == 0 )) || die "project directory is writable by non-root users: ${path}"
}

validate_uninstalled_marker() {
    [[ -f "${UNINSTALLED_MARKER}" && ! -L "${UNINSTALLED_MARKER}" ]] || die "invalid uninstalled-state marker"
    [[ "$(stat -c '%u:%g' -- "${UNINSTALLED_MARKER}")" == "0:0" ]] || die "uninstalled-state marker is not owned by root:root"
    local mode
    mode="$(stat -c '%a' -- "${UNINSTALLED_MARKER}")"
    (( (8#${mode} & 8#022) == 0 )) || die "uninstalled-state marker is writable by non-root users"
    [[ "$(awk 'END { print NR }' "${UNINSTALLED_MARKER}")" == "1" ]] || die "invalid uninstalled-state marker content"
    grep -qxF 'FORMAT=1' "${UNINSTALLED_MARKER}" || die "invalid uninstalled-state marker content"
}

hash_or_dash() {
    local enabled="$1" path="$2"
    if [[ "${enabled}" == "1" ]]; then
        sha256sum -- "${path}" | awk '{print $1}'
    else
        printf '%s\n' '-'
    fi
}

verify_hash() {
    local path="$1" expected="$2"
    [[ -e "${path}" || -L "${path}" ]] || die "managed file is missing: ${path}; reinstall before uninstalling"
    if [[ -L "${path}" ]]; then
        die "managed destination became a symbolic link: ${path}"
    fi
    [[ -f "${path}" ]] || die "managed destination is not a regular file: ${path}"
    local actual
    actual="$(sha256sum -- "${path}" | awk '{print $1}')"
    if [[ "${actual}" == "${expected}" ]]; then
        case "${path}" in
            "${BINARY_DEST}") TRUSTED_BINARY=1 ;;
            "${SERVICE_DEST}") TRUSTED_SERVICE=1 ;;
        esac
    else
        if (( FORCE == 1 )); then
            warn "removing locally modified file: ${path}"
            case "${path}" in
                "${BINARY_DEST}") PRESERVE_BINARY=1 ;;
                "${SERVICE_DEST}") PRESERVE_SERVICE=1 ;;
                "${RULE_DEST}") PRESERVE_RULE=1 ;;
                *) die "internal backup target is unknown: ${path}" ;;
            esac
        else
            die "${path} changed after installation; inspect it and use --force only if removal is intentional"
        fi
    fi
}

restore_or_remove() {
    local had_file="$1" saved_name="$2" destination="$3" baseline_dir="$4"
    rm -f -- "${destination}" || return 1
    if [[ "${had_file}" == "1" ]]; then
        [[ -e "${baseline_dir}/${saved_name}" || -L "${baseline_dir}/${saved_name}" ]] || die "required backup is missing: ${baseline_dir}/${saved_name}"
        cp -a -- "${baseline_dir}/${saved_name}" "${destination}" || return 1
    fi
    return 0
}

copy_if_present() {
    local source="$1" destination_dir="$2"
    if [[ -f "${source}" && ! -L "${source}" ]]; then
        cp -a -- "${source}" "${destination_dir}/"
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

cleanup_transaction() {
    [[ -n "${TRANSACTION_DIR}" && -d "${TRANSACTION_DIR}" && ! -L "${TRANSACTION_DIR}" ]] || return 0
    rm -f -- "${TRANSACTION_DIR}/coolleo-display" "${TRANSACTION_DIR}/coolleo-display.service" "${TRANSACTION_DIR}/70-coolleo-display.rules" "${TRANSACTION_DIR}/install-manifest" "${TRANSACTION_DIR}/previous-uninstalled-state" "${TRANSACTION_DIR}/uninstalled-state.new" || true
    rmdir -- "${TRANSACTION_DIR}" 2>/dev/null || true
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
    local files_restore_ok=1
    trap - EXIT INT TERM
    set +e
    if (( COMMITTED == 0 && TRANSACTION_READY == 1 )) && [[ -n "${TRANSACTION_DIR}" && -d "${TRANSACTION_DIR}" ]]; then
        warn "uninstall failed; restoring the installation present before this run"
        restore_transaction_file "${CURRENT_HAD_BINARY}" coolleo-display "${BINARY_DEST}" || { warn "could not restore ${BINARY_DEST}"; files_restore_ok=0; }
        restore_transaction_file "${CURRENT_HAD_SERVICE}" coolleo-display.service "${SERVICE_DEST}" || { warn "could not restore ${SERVICE_DEST}"; files_restore_ok=0; }
        restore_transaction_file "${CURRENT_HAD_RULE}" 70-coolleo-display.rules "${RULE_DEST}" || { warn "could not restore ${RULE_DEST}"; files_restore_ok=0; }
        restore_transaction_file 1 install-manifest "${MANIFEST}" || { warn "could not restore ${MANIFEST}"; files_restore_ok=0; }
        restore_transaction_file "${CURRENT_HAD_UNINSTALLED_MARKER}" previous-uninstalled-state "${UNINSTALLED_MARKER}" || { warn "could not restore ${UNINSTALLED_MARKER}"; files_restore_ok=0; }
        systemctl daemon-reload >/dev/null 2>&1 || true
        udevadm control --reload-rules >/dev/null 2>&1 || true
        trigger_tested_hidraw
        udevadm settle >/dev/null 2>&1 || true
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
            warn "rollback copies were preserved for manual recovery in ${TRANSACTION_DIR}; the service was left stopped"
        fi
    fi
    if (( COMMITTED == 0 )); then
        if (( TRANSACTION_READY == 0 || files_restore_ok == 1 )); then
            cleanup_transaction
        fi
    fi
    exit "${status}"
}

remove_created_accounts_safely() {
    local preserve_group=0 user_record user_uid user_gid user_home user_shell
    local group_record group_gid members other_primary
    if [[ "${CREATED_USER}" == "1" ]] && getent passwd "${SERVICE_USER}" >/dev/null; then
        user_record="$(getent passwd "${SERVICE_USER}")"
        user_uid="$(printf '%s' "${user_record}" | awk -F: '{print $3}')"
        user_gid="$(printf '%s' "${user_record}" | awk -F: '{print $4}')"
        user_home="$(printf '%s' "${user_record}" | awk -F: '{print $6}')"
        user_shell="$(printf '%s' "${user_record}" | awk -F: '{print $7}')"
        if [[ "${user_uid}" == "${SERVICE_UID}" && "${user_gid}" == "${SERVICE_GID}" && "${user_home}" == "/nonexistent" ]]; then
            if [[ "${user_shell}" == "/usr/sbin/nologin" || "${user_shell}" == "/sbin/nologin" || "${user_shell}" == "/bin/false" ]]; then
                userdel "${SERVICE_USER}" || { warn "could not remove service user; preserving its group"; preserve_group=1; }
            else
                warn "service user shell changed; the account was preserved"
                preserve_group=1
            fi
        else
            warn "service user identity changed; the account was preserved"
            preserve_group=1
        fi
    fi

    if [[ "${CREATED_GROUP}" == "1" ]] && getent group "${SERVICE_GROUP}" >/dev/null; then
        group_record="$(getent group "${SERVICE_GROUP}")"
        group_gid="$(printf '%s' "${group_record}" | awk -F: '{print $3}')"
        members="$(printf '%s' "${group_record}" | awk -F: '{print $4}')"
        other_primary="$(getent passwd | awk -F: -v gid="${SERVICE_GID}" -v user="${SERVICE_USER}" '$4 == gid && $1 != user {print $1; exit}')"
        if (( preserve_group == 0 )) && [[ "${group_gid}" == "${SERVICE_GID}" && -z "${members}" && -z "${other_primary}" ]]; then
            groupdel "${SERVICE_GROUP}" || warn "could not remove service group; it was preserved"
        else
            warn "service group identity or membership changed; it was preserved"
        fi
    fi
}

purge_known_state() {
    local backup_dir entry mode
    local -a backup_dirs backup_entries state_entries transaction_entries
    shopt -s nullglob
    backup_dirs=("${STATE_DIR}"/backups/original-* "${STATE_DIR}"/backups/overwritten-*)
    backup_entries=("${STATE_DIR}"/backups/* "${STATE_DIR}"/backups/.[!.]* "${STATE_DIR}"/backups/..?*)
    state_entries=("${STATE_DIR}"/* "${STATE_DIR}"/.[!.]* "${STATE_DIR}"/..?*)
    transaction_entries=("${STATE_DIR}"/transactions/* "${STATE_DIR}"/transactions/.[!.]* "${STATE_DIR}"/transactions/..?*)
    shopt -u nullglob

    if [[ -e "${UNINSTALLED_MARKER}" || -L "${UNINSTALLED_MARKER}" ]]; then
        validate_uninstalled_marker
    fi

    (( ${#transaction_entries[@]} == 0 )) || { warn "transaction recovery files were preserved; purge was not started"; return 1; }
    for entry in "${state_entries[@]}"; do
        case "$(basename -- "${entry}")" in
            backups|transactions|uninstalled-state) ;;
            *) warn "unknown project state entry was preserved: ${entry}"; return 1 ;;
        esac
    done
    for entry in "${backup_entries[@]}"; do
        case "$(basename -- "${entry}")" in
            original-*|overwritten-*) ;;
            *) warn "unknown backup entry was preserved: ${entry}"; return 1 ;;
        esac
    done

    # Validate every retained backup before deleting any of them.
    for backup_dir in "${backup_dirs[@]}"; do
        [[ "${backup_dir}" =~ ^/var/lib/coolleo-display/backups/(original|overwritten)-[0-9]{8}T[0-9]{6}Z(-[A-Za-z0-9]{6})?$ ]] || { warn "unknown backup path preserved: ${backup_dir}"; return 1; }
        [[ -d "${backup_dir}" && ! -L "${backup_dir}" ]] || { warn "unsafe backup path preserved: ${backup_dir}"; return 1; }
        [[ "$(realpath -e -- "${backup_dir}")" == "${backup_dir}" ]] || { warn "non-canonical backup preserved: ${backup_dir}"; return 1; }
        [[ "$(stat -c '%u:%g' -- "${backup_dir}")" == "0:0" ]] || { warn "non-root backup preserved: ${backup_dir}"; return 1; }
        mode="$(stat -c '%a' -- "${backup_dir}")"
        (( (8#${mode} & 8#022) == 0 )) || { warn "writable backup preserved: ${backup_dir}"; return 1; }
        for entry in "${backup_dir}"/* "${backup_dir}"/.[!.]* "${backup_dir}"/..?*; do
            [[ -e "${entry}" || -L "${entry}" ]] || continue
            [[ -f "${entry}" && ! -L "${entry}" ]] || { warn "non-regular backup entry preserved: ${entry}"; return 1; }
            case "$(basename -- "${entry}")" in
                coolleo-display|coolleo-display.service|70-coolleo-display.rules) ;;
                *) warn "unknown backup entry preserved: ${entry}"; return 1 ;;
            esac
        done
    done

    for backup_dir in "${backup_dirs[@]}"; do
        rm -f -- "${backup_dir}/coolleo-display" "${backup_dir}/coolleo-display.service" "${backup_dir}/70-coolleo-display.rules"
        rmdir -- "${backup_dir}" || return 1
    done
    rm -f -- "${UNINSTALLED_MARKER}"
    rmdir -- "${STATE_DIR}/transactions" 2>/dev/null || { warn "non-empty transactions directory was preserved"; return 1; }
    rmdir -- "${STATE_DIR}/backups" 2>/dev/null || { warn "other retained backups were preserved"; return 1; }
    rmdir -- "${STATE_DIR}" 2>/dev/null || { warn "project state directory contains unknown files and was preserved"; return 1; }
}

while (( $# > 0 )); do
    case "$1" in
        --force) FORCE=1 ;;
        --purge) PURGE=1 ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; die "unknown argument: $1" ;;
    esac
    shift
done

[[ "$(id -u)" == "0" ]] || die "run this uninstaller with sudo"
for command_name in awk basename chmod chown cp date getent grep groupdel mktemp mv realpath rm rmdir sha256sum stat systemctl udevadm userdel; do
    command -v "${command_name}" >/dev/null 2>&1 || die "required command not found: ${command_name}"
done

if [[ ! -e "${MANIFEST}" && ! -L "${MANIFEST}" ]]; then
    if [[ -e "${UNINSTALLED_MARKER}" || -L "${UNINSTALLED_MARKER}" ]]; then
        validate_secure_directory "${STATE_DIR}"
        validate_secure_directory "${STATE_DIR}/backups"
        validate_secure_directory "${STATE_DIR}/transactions"
        validate_uninstalled_marker
        if (( PURGE == 1 )); then
            purge_known_state
            printf 'coolleo-display-linux is already absent; retained backups were purged and pre-installation files were preserved.\n'
        else
            printf 'coolleo-display-linux is already absent; pre-installation files and retained backups were preserved.\n'
        fi
        exit 0
    fi
    if [[ ! -e "${BINARY_DEST}" && ! -L "${BINARY_DEST}" && ! -e "${SERVICE_DEST}" && ! -L "${SERVICE_DEST}" && ! -e "${RULE_DEST}" && ! -L "${RULE_DEST}" ]]; then
        if (( PURGE == 1 )) && [[ -e "${STATE_DIR}" || -L "${STATE_DIR}" ]]; then
            validate_secure_directory "${STATE_DIR}"
            validate_secure_directory "${STATE_DIR}/backups"
            validate_secure_directory "${STATE_DIR}/transactions"
            purge_known_state
            printf 'coolleo-display-linux is already absent; retained backups were purged.\n'
            exit 0
        fi
        printf 'coolleo-display-linux is already absent.\n'
        exit 0
    fi
    die "install manifest is missing; do not reinstall over these files because their original state cannot be inferred; follow the recovery guidance in docs/SUPPORT.md"
fi
[[ -f "${MANIFEST}" && ! -L "${MANIFEST}" ]] || die "invalid install manifest"
command -v python3 >/dev/null 2>&1 || die "required command not found: python3"
[[ -f "${BINARY_SOURCE}" && ! -L "${BINARY_SOURCE}" ]] || die "missing trusted repository file: ${BINARY_SOURCE}"
[[ "$(PYTHONDONTWRITEBYTECODE=1 python3 "${BINARY_SOURCE}" --version)" == "coolleo_display.py ${VERSION}" ]] || die "trusted cleanup application version mismatch"
validate_secure_directory "${STATE_DIR}"
validate_secure_directory "${STATE_DIR}/backups"
validate_secure_directory "${STATE_DIR}/transactions"
if [[ -e "${UNINSTALLED_MARKER}" || -L "${UNINSTALLED_MARKER}" ]]; then
    validate_uninstalled_marker
    CURRENT_HAD_UNINSTALLED_MARKER=1
fi
[[ "$(stat -c '%u' -- "${MANIFEST}")" == "0" ]] || die "install manifest is not root-owned"
manifest_mode="$(stat -c '%a' -- "${MANIFEST}")"
(( (8#${manifest_mode} & 8#022) == 0 )) || die "install manifest is writable by non-root users"
[[ "$(manifest_value FORMAT)" == "1" ]] || die "unsupported install manifest format"

HAD_BINARY="$(manifest_value HAD_BINARY)"
HAD_SERVICE="$(manifest_value HAD_SERVICE)"
HAD_RULE="$(manifest_value HAD_RULE)"
CREATED_USER="$(manifest_value CREATED_USER)"
CREATED_GROUP="$(manifest_value CREATED_GROUP)"
PREVIOUS_ACTIVE="$(manifest_value PREVIOUS_ACTIVE)"
PREVIOUS_ENABLED="$(manifest_value PREVIOUS_ENABLED)"
BASELINE_DIR="$(manifest_value BASELINE_DIR)"
SERVICE_UID="$(manifest_value SERVICE_UID)"
SERVICE_GID="$(manifest_value SERVICE_GID)"
BASELINE_BINARY_SHA256="$(manifest_value BASELINE_BINARY_SHA256)"
BASELINE_SERVICE_SHA256="$(manifest_value BASELINE_SERVICE_SHA256)"
BASELINE_RULE_SHA256="$(manifest_value BASELINE_RULE_SHA256)"
EXPECTED_BINARY_SHA256="$(manifest_value BINARY_SHA256)"
EXPECTED_SERVICE_SHA256="$(manifest_value SERVICE_SHA256)"
EXPECTED_RULE_SHA256="$(manifest_value RULE_SHA256)"
for boolean_value in "${HAD_BINARY}" "${HAD_SERVICE}" "${HAD_RULE}" "${CREATED_USER}" "${CREATED_GROUP}" "${PREVIOUS_ACTIVE}" "${PREVIOUS_ENABLED}"; do
    [[ "${boolean_value}" =~ ^[01]$ ]] || die "invalid boolean in install manifest"
done
[[ "${BASELINE_DIR}" =~ ^/var/lib/coolleo-display/backups/original-[0-9]{8}T[0-9]{6}Z(-[A-Za-z0-9]{6})?$ ]] || die "invalid baseline backup path"
[[ "${SERVICE_UID}" =~ ^[0-9]+$ && "${SERVICE_GID}" =~ ^[0-9]+$ ]] || die "invalid service identity in install manifest"
[[ "$(manifest_value VERSION)" == "${VERSION}" ]] || die "install manifest version does not match this uninstaller"
[[ "${BASELINE_BINARY_SHA256}" =~ ^(-|[0-9a-f]{64})$ && "${BASELINE_SERVICE_SHA256}" =~ ^(-|[0-9a-f]{64})$ && "${BASELINE_RULE_SHA256}" =~ ^(-|[0-9a-f]{64})$ ]] || die "invalid baseline hash in install manifest"
[[ "${EXPECTED_BINARY_SHA256}" =~ ^[0-9a-f]{64}$ && "${EXPECTED_SERVICE_SHA256}" =~ ^[0-9a-f]{64}$ && "${EXPECTED_RULE_SHA256}" =~ ^[0-9a-f]{64}$ ]] || die "invalid managed-file hash in install manifest"
[[ -d "${BASELINE_DIR}" && ! -L "${BASELINE_DIR}" ]] || die "baseline backup directory is missing or unsafe"
[[ "$(realpath -e -- "${BASELINE_DIR}")" == "${BASELINE_DIR}" ]] || die "baseline backup path is not canonical"
validate_secure_directory "${BASELINE_DIR}"

verify_hash "${BINARY_DEST}" "${EXPECTED_BINARY_SHA256}"
verify_hash "${SERVICE_DEST}" "${EXPECTED_SERVICE_SHA256}"
verify_hash "${RULE_DEST}" "${EXPECTED_RULE_SHA256}"

[[ "${HAD_BINARY}" == "0" || -e "${BASELINE_DIR}/coolleo-display" || -L "${BASELINE_DIR}/coolleo-display" ]] || die "original binary backup is missing"
[[ "${HAD_SERVICE}" == "0" || -e "${BASELINE_DIR}/coolleo-display.service" || -L "${BASELINE_DIR}/coolleo-display.service" ]] || die "original service backup is missing"
[[ "${HAD_RULE}" == "0" || -e "${BASELINE_DIR}/70-coolleo-display.rules" || -L "${BASELINE_DIR}/70-coolleo-display.rules" ]] || die "original udev-rule backup is missing"
if [[ "${HAD_BINARY}" == "1" ]]; then [[ -f "${BASELINE_DIR}/coolleo-display" && ! -L "${BASELINE_DIR}/coolleo-display" ]] || die "original binary backup is not a regular file"; fi
if [[ "${HAD_SERVICE}" == "1" ]]; then [[ -f "${BASELINE_DIR}/coolleo-display.service" && ! -L "${BASELINE_DIR}/coolleo-display.service" ]] || die "original service backup is not a regular file"; fi
if [[ "${HAD_RULE}" == "1" ]]; then [[ -f "${BASELINE_DIR}/70-coolleo-display.rules" && ! -L "${BASELINE_DIR}/70-coolleo-display.rules" ]] || die "original udev-rule backup is not a regular file"; fi
[[ "$(hash_or_dash "${HAD_BINARY}" "${BASELINE_DIR}/coolleo-display")" == "${BASELINE_BINARY_SHA256}" ]] || die "original binary backup hash mismatch"
[[ "$(hash_or_dash "${HAD_SERVICE}" "${BASELINE_DIR}/coolleo-display.service")" == "${BASELINE_SERVICE_SHA256}" ]] || die "original service backup hash mismatch"
[[ "$(hash_or_dash "${HAD_RULE}" "${BASELINE_DIR}/70-coolleo-display.rules")" == "${BASELINE_RULE_SHA256}" ]] || die "original udev-rule backup hash mismatch"

if systemctl is-active --quiet coolleo-display.service; then CURRENT_ACTIVE=1; fi
if systemctl is-enabled --quiet coolleo-display.service; then CURRENT_ENABLED=1; fi
if (( CURRENT_ACTIVE == 1 && (TRUSTED_BINARY == 0 || TRUSTED_SERVICE == 0) )); then
    die "refusing to stop an active service whose binary or unit was modified; inspect and stop it manually before rerunning with --force"
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
CURRENT_HAD_BINARY=1
CURRENT_HAD_SERVICE=1
CURRENT_HAD_RULE=1
TRANSACTION_DIR="$(mktemp -d "${STATE_DIR}/transactions/uninstall-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"
chown root:root -- "${TRANSACTION_DIR}"
chmod 0700 -- "${TRANSACTION_DIR}"
trap 'rollback $?' EXIT
trap 'exit 130' INT TERM
copy_if_present "${BINARY_DEST}" "${TRANSACTION_DIR}"
copy_if_present "${SERVICE_DEST}" "${TRANSACTION_DIR}"
copy_if_present "${RULE_DEST}" "${TRANSACTION_DIR}"
copy_if_present "${MANIFEST}" "${TRANSACTION_DIR}"
if (( CURRENT_HAD_UNINSTALLED_MARKER == 1 )); then
    cp -a -- "${UNINSTALLED_MARKER}" "${TRANSACTION_DIR}/previous-uninstalled-state"
fi
TRANSACTION_READY=1

if (( TRUSTED_BINARY == 1 && TRUSTED_SERVICE == 1 )); then
    systemctl stop coolleo-display.service >/dev/null 2>&1 || true
fi
if systemctl is-active --quiet coolleo-display.service; then
    die "service did not stop; installed files were kept"
fi
systemctl disable coolleo-display.service >/dev/null 2>&1 || die "could not disable the service; installed files were kept"
PYTHONDONTWRITEBYTECODE=1 python3 "${BINARY_SOURCE}" --restore-access || die "could not restore Intel RAPL permissions; installed files were kept"
PYTHONDONTWRITEBYTECODE=1 python3 "${BINARY_SOURCE}" --lock-hidraw-access || die "could not restrict the connected hidraw node; installed files were kept"

restore_or_remove "${HAD_BINARY}" coolleo-display "${BINARY_DEST}" "${BASELINE_DIR}"
restore_or_remove "${HAD_SERVICE}" coolleo-display.service "${SERVICE_DEST}" "${BASELINE_DIR}"
restore_or_remove "${HAD_RULE}" 70-coolleo-display.rules "${RULE_DEST}" "${BASELINE_DIR}"

systemctl daemon-reload
udevadm control --reload-rules
trigger_tested_hidraw
udevadm settle

if [[ "${HAD_SERVICE}" == "1" ]]; then
    if [[ "${PREVIOUS_ENABLED}" == "1" ]]; then
        systemctl enable coolleo-display.service
    fi
fi

printf 'FORMAT=1\n' >"${TRANSACTION_DIR}/uninstalled-state.new"
chown root:root -- "${TRANSACTION_DIR}/uninstalled-state.new"
chmod 0600 -- "${TRANSACTION_DIR}/uninstalled-state.new"
mv -f -- "${TRANSACTION_DIR}/uninstalled-state.new" "${UNINSTALLED_MARKER}"
rm -f -- "${MANIFEST}"
COMMITTED=1
trap - EXIT INT TERM
cleanup_transaction
remove_created_accounts_safely
if [[ "${HAD_SERVICE}" == "1" && "${PREVIOUS_ACTIVE}" == "1" ]]; then
    systemctl start coolleo-display.service || warn "pre-installation service was restored but could not be restarted"
fi
if (( PURGE == 1 )); then
    if purge_known_state; then
        printf 'Removed coolleo-display-linux and its retained backups.\n'
    else
        printf 'Removed coolleo-display-linux; some unknown or older backups were preserved.\n'
    fi
else
    printf 'Removed coolleo-display-linux. Backups remain under %s.\n' "${STATE_DIR}/backups"
fi
