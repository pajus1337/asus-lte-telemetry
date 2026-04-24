#!/bin/sh
# =============================================================================
# lib/config.sh — INI file parser and writer
# =============================================================================
# Part of: asus-lte-telemetry
# https://github.com/pajus1337/asus-lte-telemetry
#
# Sourced by collectors and dispatcher. Never executed directly.
# Requires: lib/common.sh sourced first.
# =============================================================================

# ---------------------------------------------------------------------------
# INI reader
# ---------------------------------------------------------------------------

# cfg_get SECTION KEY [DEFAULT]
# Reads a value from config.ini. Section names may contain dots (e.g. mode.normal).
# Example: cfg_get mode.normal lte_interval_sec 60
cfg_get() {
    _section="$1"
    _key="$2"
    _default="${3:-}"

    if [ ! -f "$CONFIG_FILE" ]; then
        log_warning "config" "Config file not found: ${CONFIG_FILE}"
        echo "$_default"
        return 1
    fi

    _value=$(awk -v section="$_section" -v key="$_key" '
    BEGIN { found=0; in_section=0 }
    /^[[:space:]]*\[/ {
        gsub(/^[[:space:]]*\[/, "")
        gsub(/\][[:space:]]*$/, "")
        in_section = ($0 == section)
        next
    }
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*[#;]/ { next }
    in_section {
        split($0, a, "=")
        k = a[1]
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
        if (k == key) {
            val = ""
            for (i=2; i<=length(a); i++) {
                if (i>2) val = val "="
                val = val a[i]
            }
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
            # Strip inline comments (space + # or space + ;)
            sub(/[[:space:]]+[#;].*$/, "", val)
            print val
            found=1
            exit
        }
    }
    END { exit !found }
    ' "$CONFIG_FILE" 2>/dev/null)

    if [ $? -eq 0 ] && [ -n "$_value" ]; then
        echo "$_value"
    else
        echo "$_default"
    fi
}

# cfg_get_int SECTION KEY DEFAULT — read integer with validation
cfg_get_int() {
    _val=$(cfg_get "$1" "$2" "$3")
    if is_integer "$_val"; then
        echo "$_val"
    else
        log_warning "config" "Non-integer for [${1}].${2}='${_val}', using default ${3}"
        echo "$3"
    fi
}

# cfg_get_bool SECTION KEY DEFAULT — returns 0/1
cfg_get_bool() {
    _val=$(cfg_get "$1" "$2" "$3")
    case "$_val" in
        true|yes|1|on)  echo 1 ;;
        false|no|0|off) echo 0 ;;
        *)
            log_warning "config" "Non-boolean for [${1}].${2}='${_val}', using default ${3}"
            echo "$3"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# INI writer (atomic: awk → tmpfile → mv)
# ---------------------------------------------------------------------------

# cfg_set SECTION KEY VALUE
cfg_set() {
    _section="$1"
    _key="$2"
    _value="$3"

    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "config" "Config file not found: ${CONFIG_FILE}"
        return 1
    fi

    _tmp=$(/opt/bin/mktemp "${CONFIG_FILE}.XXXXXX" 2>/dev/null || mktemp "${CONFIG_FILE}.XXXXXX")
    if [ -z "$_tmp" ]; then
        log_error "config" "Failed to create temp file"
        return 1
    fi

    awk -v section="$_section" -v key="$_key" -v value="$_value" '
    BEGIN { in_section=0; key_written=0; section_found=0 }
    /^[[:space:]]*\[/ {
        if (in_section && !key_written) {
            print key " = " value
            key_written = 1
        }
        gsub(/^[[:space:]]*\[/, "")
        gsub(/\][[:space:]]*$/, "")
        in_section = ($0 == section)
        if (in_section) section_found = 1
    }
    in_section && !key_written {
        k = $0
        sub(/[[:space:]]*=.*/, "", k)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
        if (k == key) {
            print key " = " value
            key_written = 1
            next
        }
    }
    { print }
    END {
        if (!section_found) {
            print ""
            print "[" section "]"
            print key " = " value
        } else if (!key_written) {
            print key " = " value
        }
    }
    ' "$CONFIG_FILE" > "$_tmp" 2>/dev/null

    if [ $? -eq 0 ]; then
        mv "$_tmp" "$CONFIG_FILE"
        log_debug "config" "Set [${_section}].${_key} = ${_value}"
    else
        rm -f "$_tmp"
        log_error "config" "Failed to write config"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Sampling configuration loader
# ---------------------------------------------------------------------------
# Populates globals used by dispatcher for scheduling.
# Reads from sections matching v0.1 config structure:
#   [sampling] mode = normal
#   [mode.normal] lte_interval_sec = 60
#   [auto_switch] enabled = true
#   [retention] days = 180

SAMPLE_MODE=""
INTERVAL_LTE=""
INTERVAL_SYSTEM=""
INTERVAL_PING=""
INTERVAL_VNSTAT=""
AUTO_SWITCH_ENABLED=""
SINR_LOW_THRESHOLD=""
SINR_LOW_CONSECUTIVE=""
DEBUG_ON_CELL_CHANGE=""
DEBUG_LINGER_SEC=""
NIGHT_START=""
NIGHT_END=""
RETENTION_DAYS=""

load_sampling_config() {
    SAMPLE_MODE=$(cfg_get sampling mode normal)

    # Load intervals for current mode from [mode.<name>]
    INTERVAL_LTE=$(cfg_get_int "mode.${SAMPLE_MODE}" lte_interval_sec 60)
    INTERVAL_SYSTEM=$(cfg_get_int "mode.${SAMPLE_MODE}" system_interval_sec 300)
    INTERVAL_PING=$(cfg_get_int "mode.${SAMPLE_MODE}" ping_interval_sec 300)
    INTERVAL_VNSTAT=$(cfg_get_int "mode.${SAMPLE_MODE}" vnstat_interval_sec 300)

    # Auto-switch settings
    AUTO_SWITCH_ENABLED=$(cfg_get_bool auto_switch enabled 1)
    SINR_LOW_THRESHOLD=$(cfg_get_int events sinr_low_threshold 5)
    SINR_LOW_CONSECUTIVE=$(cfg_get_int events sinr_low_consecutive 3)
    DEBUG_ON_CELL_CHANGE=$(cfg_get_bool auto_switch debug_on_cell_change 1)
    DEBUG_LINGER_SEC=$(cfg_get_int auto_switch debug_linger_sec 600)
    NIGHT_START=$(cfg_get auto_switch night_hours_start "01:00")
    NIGHT_END=$(cfg_get auto_switch night_hours_end "06:00")

    # Retention
    RETENTION_DAYS=$(cfg_get_int retention days 180)

    log_debug "config" "Mode=${SAMPLE_MODE} LTE=${INTERVAL_LTE}s SYS=${INTERVAL_SYSTEM}s PING=${INTERVAL_PING}s VNSTAT=${INTERVAL_VNSTAT}s"
}
