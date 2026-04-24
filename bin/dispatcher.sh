#!/bin/sh
# =============================================================================
# bin/dispatcher.sh — main orchestrator
# =============================================================================
# Part of: asus-lte-telemetry
# https://github.com/pajus1337/asus-lte-telemetry
#
# Called every 60s by the init script loop (S99asus-lte-telemetry).
# Dispatches collectors based on sampling mode intervals.
# Handles: auto-switch (night/debug), event detection, retention, log rotation.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "${SCRIPT_DIR}/lib/common.sh"
. "${SCRIPT_DIR}/lib/config.sh"
. "${SCRIPT_DIR}/lib/db.sh"

COMPONENT="dispatcher"

# Temp files for state tracking between runs
STATE_DIR="${INSTALL_BASE}/state"
LOW_SINR_FILE="${STATE_DIR}/low-sinr-count"
LAST_CELL_FILE="${STATE_DIR}/last-cell"
DEBUG_TRIGGER_FILE="${STATE_DIR}/debug-trigger-ts"

# ---------------------------------------------------------------------------
# Collector runners
# ---------------------------------------------------------------------------
run_collector() {
    _name="$1"
    _script="${SCRIPT_DIR}/bin/collector-${_name}.sh"

    if [ ! -f "$_script" ]; then
        log_error "$COMPONENT" "Collector script not found: ${_script}"
        return 1
    fi

    log_debug "$COMPONENT" "Running collector: ${_name}"
    /bin/sh "$_script" 2>&1
    return $?
}

# should_run COLLECTOR_NAME INTERVAL — returns 0 if collector is due
should_run() {
    _name="$1"
    _interval="$2"

    _elapsed=$(db_seconds_since_last_run "$_name")
    if [ "$_elapsed" -ge "$_interval" ]; then
        return 0
    fi
    log_debug "$COMPONENT" "Skipping ${_name} (${_elapsed}s < ${_interval}s)"
    return 1
}

# ---------------------------------------------------------------------------
# Auto-switch logic
# ---------------------------------------------------------------------------
check_auto_switch() {
    if [ "$AUTO_SWITCH_ENABLED" != "1" ]; then
        return
    fi

    _current_mode="$SAMPLE_MODE"

    # --- Night mode check ---
    _hour=$(date '+%H')
    _minute=$(date '+%M')
    _now_hm="${_hour}:${_minute}"

    _night_active=0
    if [ "$NIGHT_START" \< "$NIGHT_END" ]; then
        # Simple range (e.g., 01:00 to 06:00)
        if [ "$_now_hm" \> "$NIGHT_START" ] || [ "$_now_hm" = "$NIGHT_START" ]; then
            [ "$_now_hm" \< "$NIGHT_END" ] && _night_active=1
        fi
    else
        # Wrapping range (e.g., 23:00 to 06:00)
        if [ "$_now_hm" \> "$NIGHT_START" ] || [ "$_now_hm" = "$NIGHT_START" ] || [ "$_now_hm" \< "$NIGHT_END" ]; then
            _night_active=1
        fi
    fi

    if [ "$_night_active" -eq 1 ] && [ "$_current_mode" != "night" ] && [ "$_current_mode" != "debug" ]; then
        log_info "$COMPONENT" "Auto-switch: entering night mode (${_now_hm})"
        cfg_set sampling mode night
        load_sampling_config
        return
    fi

    if [ "$_night_active" -eq 0 ] && [ "$_current_mode" = "night" ]; then
        log_info "$COMPONENT" "Auto-switch: leaving night mode (${_now_hm})"
        cfg_set sampling mode normal
        load_sampling_config
        return
    fi

    # --- Debug mode linger timeout ---
    if [ "$_current_mode" = "debug" ] && [ -f "$DEBUG_TRIGGER_FILE" ]; then
        _trigger_ts=$(cat "$DEBUG_TRIGGER_FILE" 2>/dev/null)
        _now_ts=$(now_epoch)
        if [ -n "$_trigger_ts" ]; then
            _debug_age=$(( _now_ts - _trigger_ts ))
            if [ "$_debug_age" -gt "$DEBUG_LINGER_SEC" ]; then
                log_info "$COMPONENT" "Auto-switch: debug linger expired (${_debug_age}s > ${DEBUG_LINGER_SEC}s)"
                rm -f "$DEBUG_TRIGGER_FILE"
                if [ "$_night_active" -eq 1 ]; then
                    cfg_set sampling mode night
                else
                    cfg_set sampling mode normal
                fi
                load_sampling_config
                return
            fi
        fi
    fi

    # --- SINR drop detection → debug mode ---
    _last_sinr=$(db_scalar "SELECT sinr FROM lte_samples ORDER BY ts DESC LIMIT 1;")
    if [ -n "$_last_sinr" ] && is_integer "$_last_sinr"; then
        if [ "$_last_sinr" -le "$SINR_LOW_THRESHOLD" ]; then
            _count=$(cat "$LOW_SINR_FILE" 2>/dev/null || echo 0)
            _count=$(( _count + 1 ))
            echo "$_count" > "$LOW_SINR_FILE"

            if [ "$_count" -ge "$SINR_LOW_CONSECUTIVE" ] && [ "$_current_mode" != "debug" ]; then
                log_info "$COMPONENT" "Auto-switch: SINR=${_last_sinr} for ${_count} samples → debug mode"
                cfg_set sampling mode debug
                now_epoch > "$DEBUG_TRIGGER_FILE"
                load_sampling_config
                _ts=$(now_epoch)
                db_exec "INSERT INTO events (ts, event_type, severity, details) VALUES (${_ts}, 'sinr_low', 'warning', '{\"sinr\":${_last_sinr},\"consecutive\":${_count}}');"
            fi
        else
            # SINR recovered — reset counter
            if [ -f "$LOW_SINR_FILE" ]; then
                rm -f "$LOW_SINR_FILE"
            fi
        fi
    fi

    # --- Cell change detection ---
    if [ "$DEBUG_ON_CELL_CHANGE" = "1" ]; then
        _last_cell=$(db_scalar "SELECT cell_id_hex FROM lte_samples ORDER BY ts DESC LIMIT 1;")
        if [ -n "$_last_cell" ]; then
            _prev_cell=$(cat "$LAST_CELL_FILE" 2>/dev/null)
            if [ -n "$_prev_cell" ] && [ "$_prev_cell" != "$_last_cell" ]; then
                _ts=$(now_epoch)
                log_info "$COMPONENT" "Cell change detected: ${_prev_cell} → ${_last_cell}"
                db_exec "INSERT INTO events (ts, event_type, severity, details) VALUES (${_ts}, 'cell_change', 'info', '{\"from\":\"${_prev_cell}\",\"to\":\"${_last_cell}\"}');"

                if [ "$_current_mode" = "normal" ]; then
                    cfg_set sampling mode debug
                    now_epoch > "$DEBUG_TRIGGER_FILE"
                    load_sampling_config
                fi
            fi
            echo "$_last_cell" > "$LAST_CELL_FILE"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Event detection (post-collection)
# ---------------------------------------------------------------------------
detect_events() {
    _ts=$(now_epoch)

    # --- SCC drop/up detection ---
    _latest_ts=$(db_scalar "SELECT MAX(ts) FROM ca_samples;")
    _prev_ts=$(db_scalar "SELECT MAX(ts) FROM ca_samples WHERE ts < ${_latest_ts:-0};")

    if [ -n "$_latest_ts" ] && [ -n "$_prev_ts" ]; then
        _current_scc=$(db_scalar "SELECT COUNT(*) FROM ca_samples WHERE ts = ${_latest_ts} AND cc_type = 'scc';")
        _prev_scc=$(db_scalar "SELECT COUNT(*) FROM ca_samples WHERE ts = ${_prev_ts} AND cc_type = 'scc';")

        if [ "${_prev_scc:-0}" -gt 0 ] && [ "${_current_scc:-0}" -eq 0 ]; then
            log_info "$COMPONENT" "Event: SCC dropped"
            db_exec "INSERT INTO events (ts, event_type, severity, details) VALUES (${_ts}, 'scc_drop', 'warning', '{\"prev_scc_count\":${_prev_scc}}');"
        elif [ "${_prev_scc:-0}" -eq 0 ] && [ "${_current_scc:-0}" -gt 0 ]; then
            log_info "$COMPONENT" "Event: SCC up"
            db_exec "INSERT INTO events (ts, event_type, severity, details) VALUES (${_ts}, 'scc_up', 'info', '{\"scc_count\":${_current_scc}}');"
        fi
    fi

    # --- Reboot detection (uptime reset) ---
    _current_uptime=$(db_scalar "SELECT uptime_sec FROM system_samples ORDER BY ts DESC LIMIT 1;")
    _prev_uptime=$(db_scalar "SELECT uptime_sec FROM system_samples ORDER BY ts DESC LIMIT 1 OFFSET 1;")
    if [ -n "$_current_uptime" ] && [ -n "$_prev_uptime" ]; then
        if [ "$_current_uptime" -lt "$_prev_uptime" ] 2>/dev/null; then
            log_info "$COMPONENT" "Event: Reboot detected (uptime ${_prev_uptime} → ${_current_uptime})"
            db_exec "INSERT INTO events (ts, event_type, severity, details) VALUES (${_ts}, 'reboot', 'warning', '{\"prev_uptime\":${_prev_uptime},\"new_uptime\":${_current_uptime}}');"
        fi
    fi

    # --- Ping loss detection ---
    _latest_ping_ts=$(db_scalar "SELECT MAX(ts) FROM ping_samples;")
    if [ -n "$_latest_ping_ts" ]; then
        _avg_loss=$(db_scalar "SELECT AVG(loss_pct) FROM ping_samples WHERE ts = ${_latest_ping_ts};")
        _loss_threshold=$(cfg_get_int ping loss_alert_pct 20)
        if [ -n "$_avg_loss" ]; then
            _loss_int=$(echo "$_avg_loss" | cut -d'.' -f1)
            if [ "${_loss_int:-0}" -ge "$_loss_threshold" ]; then
                log_info "$COMPONENT" "Event: High ping loss (${_avg_loss}%)"
                db_exec "INSERT INTO events (ts, event_type, severity, details) VALUES (${_ts}, 'ping_loss', 'warning', '{\"avg_loss_pct\":${_avg_loss}}');"
            fi
        fi
    fi

    # --- RRC disconnect detection ---
    _rrc_threshold=$(cfg_get_int events rrc_disconnect_after_sec 300)
    _rrc_state=$(db_scalar "SELECT rrc_state FROM lte_samples ORDER BY ts DESC LIMIT 1;")
    if [ "$_rrc_state" = "NOCONN" ]; then
        # Check how long we've been in NOCONN
        _first_noconn=$(db_scalar "SELECT MIN(ts) FROM (SELECT ts, rrc_state FROM lte_samples ORDER BY ts DESC LIMIT 20) WHERE rrc_state = 'NOCONN';")
        if [ -n "$_first_noconn" ]; then
            _noconn_duration=$(( _ts - _first_noconn ))
            if [ "$_noconn_duration" -ge "$_rrc_threshold" ]; then
                # Check wwan0 is up (has an IP)
                if ip addr show wwan0 2>/dev/null | grep -q 'inet '; then
                    log_info "$COMPONENT" "Event: RRC disconnect (${_noconn_duration}s with active wwan0)"
                    db_exec "INSERT INTO events (ts, event_type, severity, details) VALUES (${_ts}, 'rrc_disconnect', 'warning', '{\"duration_sec\":${_noconn_duration}}');"
                fi
            fi
        fi
    fi
}

# ---------------------------------------------------------------------------
# Retention
# ---------------------------------------------------------------------------
run_retention() {
    # Run once per day — check via events table
    _today=$(date '+%Y-%m-%d')
    _last_purge=$(db_scalar "SELECT details FROM events WHERE event_type = 'retention_purge' ORDER BY ts DESC LIMIT 1;")

    if echo "$_last_purge" | grep -q "$_today"; then
        return 0  # Already purged today
    fi

    log_info "$COMPONENT" "Running daily retention (${RETENTION_DAYS} days)"
    db_purge_old "$RETENTION_DAYS"

    _ts=$(now_epoch)
    db_exec "INSERT INTO events (ts, event_type, severity, details) VALUES (${_ts}, 'retention_purge', 'info', '{\"date\":\"${_today}\",\"days\":${RETENTION_DAYS}}');"

    # Weekly vacuum (check config interval)
    _vacuum_interval=$(cfg_get_int retention vacuum_interval_days 7)
    _last_vacuum=$(db_scalar "SELECT ts FROM events WHERE event_type = 'vacuum' ORDER BY ts DESC LIMIT 1;")
    _vacuum_age=999999
    if [ -n "$_last_vacuum" ]; then
        _vacuum_age=$(( _ts - _last_vacuum ))
    fi
    _vacuum_threshold=$(( _vacuum_interval * 86400 ))

    if [ "$_vacuum_age" -ge "$_vacuum_threshold" ]; then
        db_vacuum
        db_exec "INSERT INTO events (ts, event_type, severity, details) VALUES (${_ts}, 'vacuum', 'info', '{}');"
    fi
}

# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------
dispatch() {
    log_info "$COMPONENT" "Dispatcher starting (pid=$$)"

    # Ensure state dir exists
    mkdir -p "$STATE_DIR" 2>/dev/null

    # Preflight checks
    check_dependency "$SQLITE" "sqlite3-cli"
    db_check || die "Database check failed"
    load_sampling_config

    log_info "$COMPONENT" "Mode=${SAMPLE_MODE} LTE=${INTERVAL_LTE}s SYS=${INTERVAL_SYSTEM}s PING=${INTERVAL_PING}s VNSTAT=${INTERVAL_VNSTAT}s"

    # Auto-switch (before collection — may change intervals)
    check_auto_switch

    # Dispatch collectors based on per-collector intervals
    if should_run lte "$INTERVAL_LTE"; then
        run_collector lte
    fi

    if should_run system "$INTERVAL_SYSTEM"; then
        run_collector system
    fi

    if should_run ping "$INTERVAL_PING"; then
        run_collector ping
    fi

    if should_run vnstat "$INTERVAL_VNSTAT"; then
        run_collector vnstat
    fi

    # Post-collection: event detection + retention
    detect_events
    run_retention

    # Log rotation
    _log_max=$(cfg_get_int logging max_size 1048576)
    log_rotate "$_log_max"

    log_info "$COMPONENT" "Dispatch cycle complete"
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
setup_trap "$COMPONENT"
if ! acquire_lock "$COMPONENT" 120; then
    log_warning "$COMPONENT" "Another dispatcher instance running, exiting"
    exit 0
fi

dispatch
release_lock "$COMPONENT"
