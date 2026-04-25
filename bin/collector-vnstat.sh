#!/bin/sh
# =============================================================================
# bin/collector-vnstat.sh — vnstat traffic snapshot collector
# =============================================================================
# Part of: asus-lte-telemetry
# https://github.com/pajus1337/asus-lte-telemetry
#
# Captures vnstat summary for wwan0 and stores as event snapshot.
# vnstat tracks at OS/interface level (complements modem-level QGDCNT).
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "${SCRIPT_DIR}/lib/common.sh"
. "${SCRIPT_DIR}/lib/config.sh"
. "${SCRIPT_DIR}/lib/db.sh"

COMPONENT="vnstat"

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
collect_vnstat() {
    log_info "$COMPONENT" "Starting vnstat collection"

    # Entware installs vnstat to /opt/bin/ which may not be in PATH in nohup/init context
    _vnstat_bin=""
    if [ -x /opt/bin/vnstat ]; then
        _vnstat_bin=/opt/bin/vnstat
    elif command -v vnstat >/dev/null 2>&1; then
        _vnstat_bin=$(command -v vnstat)
    fi

    if [ -z "$_vnstat_bin" ]; then
        log_warning "$COMPONENT" "vnstat not installed, skipping"
        db_update_collector_state "$COMPONENT" "skipped" "vnstat not installed"
        return 0
    fi

    _iface=$(cfg_get general wan_interface "wwan0")
    _ts=$(now_epoch)

    # Try --oneline first (most reliable across vnstat versions)
    # Format: id;nickname;day_rx;day_tx;month_rx;month_tx;total_rx;total_tx;...
    _oneline=$("$_vnstat_bin" -i "$_iface" --oneline 2>/dev/null)

    if [ -n "$_oneline" ]; then
        _day_rx=$(echo "$_oneline" | cut -d';' -f4)
        _day_tx=$(echo "$_oneline" | cut -d';' -f5)
        _month_rx=$(echo "$_oneline" | cut -d';' -f9)
        _month_tx=$(echo "$_oneline" | cut -d';' -f10)
        _total_rx=$(echo "$_oneline" | cut -d';' -f12)
        _total_tx=$(echo "$_oneline" | cut -d';' -f13)

        _details="{\"source\":\"vnstat\",\"interface\":\"${_iface}\",\"day_rx\":\"${_day_rx}\",\"day_tx\":\"${_day_tx}\",\"month_rx\":\"${_month_rx}\",\"month_tx\":\"${_month_tx}\",\"total_rx\":\"${_total_rx}\",\"total_tx\":\"${_total_tx}\"}"

        db_exec "INSERT INTO events (
            ts, event_type, severity, details
        ) VALUES (
            ${_ts}, 'vnstat_snapshot', 'info', $(db_quote "$_details")
        );"

        db_update_collector_state "$COMPONENT" "ok"
        log_info "$COMPONENT" "vnstat snapshot saved (${_iface}: day=${_day_rx}/${_day_tx})"
    else
        log_warning "$COMPONENT" "vnstat returned no data for ${_iface}"
        db_update_collector_state "$COMPONENT" "error" "No vnstat data for ${_iface}"
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if [ "$(basename "$0")" = "collector-vnstat.sh" ]; then
    setup_trap "$COMPONENT"
    if ! acquire_lock "$COMPONENT"; then
        die "Another instance of ${COMPONENT} is running"
    fi
    collect_vnstat
    release_lock "$COMPONENT"
fi
