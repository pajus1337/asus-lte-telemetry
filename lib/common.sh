#!/bin/sh
# =============================================================================
# lib/common.sh — shared utilities: logging, locking, error handling
# =============================================================================
# Part of: asus-lte-telemetry
# https://github.com/pajus1337/asus-lte-telemetry
#
# Sourced by collectors and dispatcher. Never executed directly.
# POSIX sh compatible (BusyBox 1.25.1 on ASUS 4G-AC86U stock firmware).
# =============================================================================

# ---------------------------------------------------------------------------
# Paths — match install.sh defaults; overridable via environment
# ---------------------------------------------------------------------------
INSTALL_BASE="${INSTALL_BASE:-/tmp/mnt/System/asus-lte-telemetry}"
DB_PATH="${DB_PATH:-${INSTALL_BASE}/db/metrics.db}"
CONFIG_FILE="${CONFIG_FILE:-${INSTALL_BASE}/config/config.ini}"
LOG_DIR="${LOG_DIR:-${INSTALL_BASE}/logs}"
LOG_FILE="${LOG_FILE:-${LOG_DIR}/monitor.log}"
LOCK_DIR="${LOCK_DIR:-/tmp/asus-lte-telemetry}"

SQLITE="${SQLITE:-/opt/bin/sqlite3}"
SLEEP_BIN="${SLEEP_BIN:-/opt/bin/sleep}"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
# Levels: debug=0 info=1 warning=2 error=3
LOG_LEVEL="${LOG_LEVEL:-1}"

_log_level_num() {
    case "$1" in
        debug)   echo 0 ;;
        info)    echo 1 ;;
        warning) echo 2 ;;
        error)   echo 3 ;;
        *)       echo 1 ;;
    esac
}

# log LEVEL COMPONENT MESSAGE
log() {
    _level="$1"; shift
    _component="$1"; shift
    _msg="$*"

    _level_num=$(_log_level_num "$_level")
    if [ "$_level_num" -lt "$LOG_LEVEL" ]; then
        return 0
    fi

    _ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "????-??-?? ??:??:??")
    _line="[${_ts}] [${_level}] [${_component}] ${_msg}"

    # Always to stderr for immediate visibility
    echo "$_line" >&2

    # Append to log file if directory exists
    if [ -n "$LOG_FILE" ] && [ -d "$(dirname "$LOG_FILE")" ]; then
        echo "$_line" >> "$LOG_FILE" 2>/dev/null
    fi
}

log_debug()   { log debug   "$@"; }
log_info()    { log info    "$@"; }
log_warning() { log warning "$@"; }
log_error()   { log error   "$@"; }

# ---------------------------------------------------------------------------
# Log rotation (call from dispatcher; keeps last 2 files)
# ---------------------------------------------------------------------------
log_rotate() {
    _max_bytes="${1:-1048576}"  # 1 MB default
    if [ -f "$LOG_FILE" ]; then
        _size=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
        if [ "$_size" -gt "$_max_bytes" ]; then
            rm -f "${LOG_FILE}.2"
            [ -f "${LOG_FILE}.1" ] && mv "${LOG_FILE}.1" "${LOG_FILE}.2"
            mv "$LOG_FILE" "${LOG_FILE}.1"
            log_info "common" "Log rotated (was ${_size} bytes)"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Locking (flock-free, BusyBox-safe via atomic mkdir)
# ---------------------------------------------------------------------------
# acquire_lock COMPONENT [MAX_AGE_SECONDS]
# Returns 0 on success, 1 if already locked
acquire_lock() {
    _lock_name="$1"
    _max_age="${2:-300}"  # stale lock timeout: 5 min default
    _lock_path="${LOCK_DIR}/${_lock_name}.lock"

    # Ensure lock directory exists
    mkdir -p "$LOCK_DIR" 2>/dev/null

    # Check for stale lock
    if [ -d "$_lock_path" ]; then
        _pid_file="${_lock_path}/pid"
        if [ -f "$_pid_file" ]; then
            _old_pid=$(cat "$_pid_file" 2>/dev/null)
            if [ -n "$_old_pid" ] && kill -0 "$_old_pid" 2>/dev/null; then
                # Process alive — check age
                _lock_ts_file="${_lock_path}/ts"
                if [ -f "$_lock_ts_file" ]; then
                    _lock_ts=$(cat "$_lock_ts_file" 2>/dev/null)
                    _now=$(date '+%s' 2>/dev/null)
                    if [ -n "$_lock_ts" ] && [ -n "$_now" ]; then
                        _age=$(( _now - _lock_ts ))
                        if [ "$_age" -gt "$_max_age" ]; then
                            log_warning "common" "Stale lock '${_lock_name}' (pid=${_old_pid}, age=${_age}s) — removing"
                            rm -rf "$_lock_path"
                        else
                            log_debug "common" "Lock '${_lock_name}' held by pid=${_old_pid} (age=${_age}s)"
                            return 1
                        fi
                    fi
                fi
            else
                # Process dead — orphaned lock
                log_warning "common" "Removing orphaned lock '${_lock_name}' (pid=${_old_pid} dead)"
                rm -rf "$_lock_path"
            fi
        else
            rm -rf "$_lock_path"
        fi
    fi

    # Atomic mkdir
    if mkdir "$_lock_path" 2>/dev/null; then
        echo $$ > "${_lock_path}/pid"
        date '+%s' > "${_lock_path}/ts" 2>/dev/null
        return 0
    else
        return 1
    fi
}

# release_lock COMPONENT
release_lock() {
    _lock_name="$1"
    _lock_path="${LOCK_DIR}/${_lock_name}.lock"
    rm -rf "$_lock_path"
}

# ---------------------------------------------------------------------------
# Trap helper — auto-cleanup locks on exit
# ---------------------------------------------------------------------------
# Usage: setup_trap COMPONENT_NAME
_TRAP_COMPONENT=""

setup_trap() {
    _TRAP_COMPONENT="$1"
    trap '_trap_handler' EXIT INT TERM HUP
}

_trap_handler() {
    if [ -n "$_TRAP_COMPONENT" ]; then
        release_lock "$_TRAP_COMPONENT"
        log_debug "$_TRAP_COMPONENT" "Lock released on exit"
    fi
}

# ---------------------------------------------------------------------------
# Error handling
# ---------------------------------------------------------------------------

# die MESSAGE — log error and exit 1
die() {
    log_error "${_TRAP_COMPONENT:-common}" "$*"
    exit 1
}

# check_dependency CMD [PACKAGE_HINT]
# For full paths (starting with /) uses [ -x ]; for bare names uses command -v.
# BusyBox ash's command -v does not find full-path binaries when the containing
# directory is absent from PATH (common in nohup/init environments).
check_dependency() {
    _cmd="$1"
    _hint="${2:-$1}"
    case "$_cmd" in
        /*)
            if [ ! -x "$_cmd" ]; then
                die "Required command '${_cmd}' not found. Install: opkg install ${_hint}"
            fi
            ;;
        *)
            if ! command -v "$_cmd" >/dev/null 2>&1; then
                die "Required command '${_cmd}' not found. Install: opkg install ${_hint}"
            fi
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Utility helpers
# ---------------------------------------------------------------------------

# now_epoch — current unix timestamp
now_epoch() {
    date '+%s' 2>/dev/null
}

# is_integer VALUE — returns 0 if VALUE is an integer (positive or negative)
is_integer() {
    case "$1" in
        ''|*[!0-9-]*) return 1 ;;
        -)            return 1 ;;
        *)            return 0 ;;
    esac
}
