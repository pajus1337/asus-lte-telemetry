#!/bin/sh
# =============================================================================
# bin/collector-system.sh — system metrics collector
# =============================================================================
# Part of: asus-lte-telemetry
# https://github.com/pajus1337/asus-lte-telemetry
#
# Collects: uptime, load, RAM, SWAP, disk, wwan0 counters/errors, CPU temp
# Inserts into: system_samples, process_health
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "${SCRIPT_DIR}/lib/common.sh"
. "${SCRIPT_DIR}/lib/config.sh"
. "${SCRIPT_DIR}/lib/db.sh"

COMPONENT="system"

# ---------------------------------------------------------------------------
# System metrics from /proc
# ---------------------------------------------------------------------------
collect_system_metrics() {
    # Uptime (seconds, integer part)
    SYS_UPTIME=$(cut -d'.' -f1 /proc/uptime 2>/dev/null)

    # Load averages
    SYS_LOAD_1=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null)
    SYS_LOAD_5=$(cut -d' ' -f2 /proc/loadavg 2>/dev/null)
    SYS_LOAD_15=$(cut -d' ' -f3 /proc/loadavg 2>/dev/null)

    # Memory from /proc/meminfo (all in kB)
    _meminfo=$(cat /proc/meminfo 2>/dev/null)
    SYS_MEM_TOTAL=$(echo "$_meminfo" | awk '/^MemTotal:/ {print $2}')
    SYS_MEM_FREE=$(echo "$_meminfo" | awk '/^MemFree:/ {print $2}')
    _buffers=$(echo "$_meminfo" | awk '/^Buffers:/ {print $2}')
    _cached=$(echo "$_meminfo" | awk '/^Cached:/ {print $2}')
    SYS_MEM_USED=$(( SYS_MEM_TOTAL - SYS_MEM_FREE - _buffers - _cached ))
    SYS_SWAP_TOTAL=$(echo "$_meminfo" | awk '/^SwapTotal:/ {print $2}')
    _swap_free=$(echo "$_meminfo" | awk '/^SwapFree:/ {print $2}')
    SYS_SWAP_USED=$(( SYS_SWAP_TOTAL - _swap_free ))

    # Disk usage percentages
    # System partition (firmware)
    SYS_DISK_SYSTEM_PCT=$(df / 2>/dev/null | tail -1 | awk '{gsub(/%/,""); print $5}')
    # Data partition (where our DB lives)
    SYS_DISK_DATA_PCT=$(df /tmp/mnt/System 2>/dev/null | tail -1 | awk '{gsub(/%/,""); print $5}')

    # CPU temperature (from /sys/class/thermal if available)
    SYS_CPU_TEMP=""
    for _tz in /sys/class/thermal/thermal_zone*/temp; do
        if [ -f "$_tz" ]; then
            _raw=$(cat "$_tz" 2>/dev/null)
            if [ -n "$_raw" ] && [ "$_raw" -gt 1000 ] 2>/dev/null; then
                SYS_CPU_TEMP=$(( _raw / 1000 ))
            else
                SYS_CPU_TEMP="$_raw"
            fi
            break
        fi
    done

    # wwan0 counters from /proc/net/dev
    _wwan=$(grep 'wwan0' /proc/net/dev 2>/dev/null | tr ':' ' ')
    if [ -n "$_wwan" ]; then
        # Fields: iface rx_bytes rx_packets rx_errs rx_drop ... tx_bytes tx_packets tx_errs tx_drop
        SYS_WWAN_RX_BYTES=$(echo "$_wwan" | awk '{print $2}')
        SYS_WWAN_TX_BYTES=$(echo "$_wwan" | awk '{print $10}')
        SYS_WWAN_RX_ERRORS=$(echo "$_wwan" | awk '{print $4}')
        SYS_WWAN_TX_ERRORS=$(echo "$_wwan" | awk '{print $12}')
        SYS_WWAN_RX_DROPPED=$(echo "$_wwan" | awk '{print $5}')
        SYS_WWAN_TX_DROPPED=$(echo "$_wwan" | awk '{print $13}')
    else
        SYS_WWAN_RX_BYTES=0 ; SYS_WWAN_TX_BYTES=0
        SYS_WWAN_RX_ERRORS=0 ; SYS_WWAN_TX_ERRORS=0
        SYS_WWAN_RX_DROPPED=0 ; SYS_WWAN_TX_DROPPED=0
    fi

    log_debug "$COMPONENT" "uptime=${SYS_UPTIME}s load=${SYS_LOAD_1} mem_used=${SYS_MEM_USED}kB swap_used=${SYS_SWAP_USED}kB"
}

# ---------------------------------------------------------------------------
# Process health check (BusyBox ps compatible)
# ---------------------------------------------------------------------------
check_process() {
    _name="$1"
    _first=$(echo "$_name" | cut -c1)
    _rest=$(echo "$_name" | cut -c2-)
    if ps w 2>/dev/null | grep -q "[${_first}]${_rest}"; then
        echo 1
    else
        echo 0
    fi
}

collect_process_health() {
    PROC_QUECTEL_CM=$(check_process "quectel-CM")
    PROC_DNSMASQ=$(check_process "dnsmasq")
    # lighttpd (Entware) is the actual web server; fall back to generic 'httpd'
    PROC_HTTPD=$(check_process "lighttpd")
    [ "$PROC_HTTPD" = "0" ] && PROC_HTTPD=$(check_process "httpd")
    PROC_SMBD=$(check_process "smbd")
    PROC_CROND=$(check_process "crond")

    log_debug "$COMPONENT" "procs: quectel=${PROC_QUECTEL_CM} dnsmasq=${PROC_DNSMASQ} httpd=${PROC_HTTPD} smbd=${PROC_SMBD} crond=${PROC_CROND}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
collect_system() {
    log_info "$COMPONENT" "Starting system collection"

    collect_system_metrics
    collect_process_health

    _ts=$(now_epoch)

    _sql="
        INSERT INTO system_samples (
            ts, uptime_sec,
            load_1min, load_5min, load_15min,
            mem_free_kb, mem_used_kb, mem_total_kb,
            swap_used_kb, swap_total_kb,
            disk_system_used_pct, disk_data_used_pct,
            cpu_temp,
            wwan0_rx_bytes, wwan0_tx_bytes,
            wwan0_rx_errors, wwan0_tx_errors,
            wwan0_rx_dropped, wwan0_tx_dropped
        ) VALUES (
            ${_ts}, ${SYS_UPTIME:-NULL},
            ${SYS_LOAD_1:-NULL}, ${SYS_LOAD_5:-NULL}, ${SYS_LOAD_15:-NULL},
            ${SYS_MEM_FREE:-NULL}, ${SYS_MEM_USED:-NULL}, ${SYS_MEM_TOTAL:-NULL},
            ${SYS_SWAP_USED:-NULL}, ${SYS_SWAP_TOTAL:-NULL},
            ${SYS_DISK_SYSTEM_PCT:-NULL}, ${SYS_DISK_DATA_PCT:-NULL},
            ${SYS_CPU_TEMP:-NULL},
            ${SYS_WWAN_RX_BYTES:-0}, ${SYS_WWAN_TX_BYTES:-0},
            ${SYS_WWAN_RX_ERRORS:-0}, ${SYS_WWAN_TX_ERRORS:-0},
            ${SYS_WWAN_RX_DROPPED:-0}, ${SYS_WWAN_TX_DROPPED:-0}
        );

        INSERT INTO process_health (
            ts, quectel_cm_alive, dnsmasq_alive, httpd_alive, smbd_alive, crond_alive
        ) VALUES (
            ${_ts},
            ${PROC_QUECTEL_CM:-0}, ${PROC_DNSMASQ:-0},
            ${PROC_HTTPD:-0}, ${PROC_SMBD:-0}, ${PROC_CROND:-0}
        );
    "

    db_transaction "$_sql"
    if [ $? -eq 0 ]; then
        db_update_collector_state "$COMPONENT" "ok"
        log_info "$COMPONENT" "System data collected (load=${SYS_LOAD_1} mem_used=${SYS_MEM_USED}kB)"
    else
        db_update_collector_state "$COMPONENT" "error" "DB transaction failed"
        log_error "$COMPONENT" "DB transaction failed"
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if [ "$(basename "$0")" = "collector-system.sh" ]; then
    setup_trap "$COMPONENT"
    if ! acquire_lock "$COMPONENT"; then
        die "Another instance of ${COMPONENT} is running"
    fi
    collect_system
    release_lock "$COMPONENT"
fi
