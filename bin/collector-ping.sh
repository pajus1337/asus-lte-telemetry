#!/bin/sh
# =============================================================================
# bin/collector-ping.sh — multi-target ping collector
# =============================================================================
# Part of: asus-lte-telemetry
# https://github.com/pajus1337/asus-lte-telemetry
#
# Pings multiple targets from config.ini [ping] section.
# Inserts into: ping_samples
# BusyBox ping compatible.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "${SCRIPT_DIR}/lib/common.sh"
. "${SCRIPT_DIR}/lib/config.sh"
. "${SCRIPT_DIR}/lib/db.sh"

COMPONENT="ping"

# ---------------------------------------------------------------------------
# Detect default gateway
# ---------------------------------------------------------------------------
get_gateway() {
    _gw=$(ip route 2>/dev/null | awk '/^default/ {print $3; exit}')
    if [ -z "$_gw" ]; then
        _gw=$(route -n 2>/dev/null | awk '/^0\.0\.0\.0/ {print $2; exit}')
    fi
    echo "$_gw"
}

# ---------------------------------------------------------------------------
# Ping a single target
# ---------------------------------------------------------------------------
# Sets: PING_SENT PING_RECV PING_LOSS PING_RTT_MIN PING_RTT_AVG PING_RTT_MAX PING_RTT_MDEV
PING_SENT="" PING_RECV="" PING_LOSS=""
PING_RTT_MIN="" PING_RTT_AVG="" PING_RTT_MAX="" PING_RTT_MDEV=""

ping_one() {
    _host="$1"
    _count="$2"
    _timeout="$3"

    PING_SENT="$_count" ; PING_RECV="" ; PING_LOSS=""
    PING_RTT_MIN="" ; PING_RTT_AVG="" ; PING_RTT_MAX="" ; PING_RTT_MDEV=""

    # BusyBox ping: ping -c COUNT -W TIMEOUT HOST
    _output=$(ping -c "$_count" -W "$_timeout" "$_host" 2>/dev/null)
    _rc=$?

    if [ $_rc -ne 0 ] && [ -z "$_output" ]; then
        PING_RECV=0
        PING_LOSS=100
        log_debug "$COMPONENT" "Ping ${_host}: total failure"
        return 1
    fi

    # Parse "3 packets transmitted, 3 received, 0% packet loss"
    _stats_line=$(echo "$_output" | grep 'packets transmitted')
    if [ -n "$_stats_line" ]; then
        PING_SENT=$(echo "$_stats_line" | awk '{print $1}')
        PING_RECV=$(echo "$_stats_line" | awk '{print $4}')
        PING_LOSS=$(echo "$_stats_line" | grep -o '[0-9]*%' | tr -d '%')
    fi
    [ -z "$PING_LOSS" ] && PING_LOSS=100
    [ -z "$PING_RECV" ] && PING_RECV=0

    # Parse RTT: "round-trip min/avg/max = 12.3/15.6/20.1 ms"
    # or: "rtt min/avg/max/mdev = 12.3/15.6/20.1/2.3 ms"
    _rtt_line=$(echo "$_output" | grep -iE 'min/avg/max')
    if [ -n "$_rtt_line" ]; then
        _rtts=$(echo "$_rtt_line" | grep -o '[0-9.]*\/[0-9.]*\/[0-9.]*' | head -1)
        if [ -n "$_rtts" ]; then
            PING_RTT_MIN=$(echo "$_rtts" | cut -d'/' -f1)
            PING_RTT_AVG=$(echo "$_rtts" | cut -d'/' -f2)
            PING_RTT_MAX=$(echo "$_rtts" | cut -d'/' -f3)
        fi
        # mdev (4th field, if present)
        _rtts4=$(echo "$_rtt_line" | grep -o '[0-9.]*\/[0-9.]*\/[0-9.]*\/[0-9.]*' | head -1)
        if [ -n "$_rtts4" ]; then
            PING_RTT_MDEV=$(echo "$_rtts4" | cut -d'/' -f4)
        fi
    fi

    log_debug "$COMPONENT" "Ping ${_host}: loss=${PING_LOSS}% avg=${PING_RTT_AVG}ms"
    return 0
}

# ---------------------------------------------------------------------------
# Parse config [ping] targets
# ---------------------------------------------------------------------------
# Format in config.ini:
#   targets =
#       cloudflare|1.1.1.1|3
#       google|8.8.8.8|3
#       gateway|gateway|3

parse_ping_targets() {
    _timeout=$(cfg_get_int ping timeout_sec 2)
    _gateway=$(get_gateway)

    # Read targets section — multi-line value: grab everything after "targets ="
    # until next key or section
    awk '
    /^\[ping\]/ { in_section=1; next }
    /^\[/ { in_section=0 }
    in_section && /^[[:space:]]*targets[[:space:]]*=/ {
        sub(/^[[:space:]]*targets[[:space:]]*=[[:space:]]*/, "")
        if ($0 != "") print $0
        reading=1
        next
    }
    reading && /^[[:space:]]+[a-zA-Z]/ {
        gsub(/^[[:space:]]+/, "")
        print
        next
    }
    reading { reading=0 }
    ' "$CONFIG_FILE" 2>/dev/null | while IFS='|' read -r _label _addr _count; do
        _label=$(echo "$_label" | tr -d ' ')
        _addr=$(echo "$_addr" | tr -d ' ')
        _count=$(echo "$_count" | tr -d ' ')
        [ -z "$_label" ] && continue
        [ -z "$_count" ] && _count=3

        # Resolve "gateway" keyword
        if [ "$_addr" = "gateway" ]; then
            if [ -n "$_gateway" ]; then
                _addr="$_gateway"
            else
                log_warning "$COMPONENT" "Cannot resolve gateway for ping target '${_label}'"
                continue
            fi
        fi

        echo "${_label}|${_addr}|${_count}|${_timeout}"
    done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
collect_ping() {
    log_info "$COMPONENT" "Starting ping collection"

    _ts=$(now_epoch)
    _targets=$(parse_ping_targets)

    if [ -z "$_targets" ]; then
        # Fallback if config parsing fails
        log_warning "$COMPONENT" "No targets from config, using defaults"
        _targets="cloudflare|1.1.1.1|3|2
google|8.8.8.8|3|2"
        _gw=$(get_gateway)
        if [ -n "$_gw" ]; then
            _targets="${_targets}
gateway|${_gw}|3|2"
        fi
    fi

    _ok=0
    echo "$_targets" | while IFS='|' read -r _label _addr _count _timeout; do
        [ -z "$_addr" ] && continue

        ping_one "$_addr" "$_count" "$_timeout"

        db_exec "INSERT INTO ping_samples (
            ts, target, target_label,
            sent, received, loss_pct,
            rtt_min_ms, rtt_avg_ms, rtt_max_ms, rtt_mdev_ms
        ) VALUES (
            ${_ts},
            $(db_quote "$_addr"), $(db_quote "$_label"),
            ${PING_SENT:-NULL}, ${PING_RECV:-NULL}, ${PING_LOSS:-NULL},
            ${PING_RTT_MIN:-NULL}, ${PING_RTT_AVG:-NULL},
            ${PING_RTT_MAX:-NULL}, ${PING_RTT_MDEV:-NULL}
        );"
    done

    db_update_collector_state "$COMPONENT" "ok"
    log_info "$COMPONENT" "Ping data collected"
    return 0
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if [ "$(basename "$0")" = "collector-ping.sh" ]; then
    setup_trap "$COMPONENT"
    if ! acquire_lock "$COMPONENT"; then
        die "Another instance of ${COMPONENT} is running"
    fi
    collect_ping
    release_lock "$COMPONENT"
fi
