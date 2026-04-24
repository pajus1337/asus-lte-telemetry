#!/bin/sh
# =============================================================================
# lib/db.sh — SQLite helpers
# =============================================================================
# Part of: asus-lte-telemetry
# https://github.com/pajus1337/asus-lte-telemetry
#
# Sourced by collectors and dispatcher. Never executed directly.
# Requires: lib/common.sh sourced first, sqlite3 (Entware) available.
#
# All timestamps are unix epoch INTEGER, matching schema.sql convention.
# =============================================================================

# ---------------------------------------------------------------------------
# Core query helpers
# ---------------------------------------------------------------------------

# db_exec SQL — execute statement, no output expected
db_exec() {
    "$SQLITE" "$DB_PATH" "$1" 2>/dev/null
    _rc=$?
    if [ $_rc -ne 0 ]; then
        log_error "db" "Query failed (rc=${_rc}): $(echo "$1" | head -1)"
    fi
    return $_rc
}

# db_query SQL — execute query, return pipe-separated rows
db_query() {
    "$SQLITE" -separator '|' "$DB_PATH" "$1" 2>/dev/null
}

# db_query_csv SQL — execute query, return CSV with header
db_query_csv() {
    "$SQLITE" -csv -header "$DB_PATH" "$1" 2>/dev/null
}

# db_scalar SQL — return single value
db_scalar() {
    "$SQLITE" "$DB_PATH" "$1" 2>/dev/null | head -1
}

# ---------------------------------------------------------------------------
# Escaping
# ---------------------------------------------------------------------------

# db_escape STRING — escape single quotes for SQLite
db_escape() {
    printf '%s' "$1" | sed "s/'/''/g"
}

# db_quote STRING — wrap in single quotes with escaping
db_quote() {
    printf "'%s'" "$(db_escape "$1")"
}

# ---------------------------------------------------------------------------
# Collector state tracking (matches collector_state table in schema.sql)
# Columns: collector_name TEXT PK, last_run_ts INTEGER, last_status TEXT, last_error TEXT
# ---------------------------------------------------------------------------

# db_update_collector_state COLLECTOR_NAME [STATUS] [ERROR_MSG]
db_update_collector_state() {
    _collector="$1"
    _status="${2:-ok}"
    _errmsg="${3:-}"
    _now=$(now_epoch)
    db_exec "UPDATE collector_state SET last_run_ts = ${_now}, last_status = '${_status}', last_error = $(db_quote "$_errmsg") WHERE collector_name = '$(db_escape "$_collector")';"
}

# db_get_last_run_ts COLLECTOR_NAME — returns epoch or 0
db_get_last_run_ts() {
    _ts=$(db_scalar "SELECT last_run_ts FROM collector_state WHERE collector_name = '$(db_escape "$1")';")
    echo "${_ts:-0}"
}

# db_seconds_since_last_run COLLECTOR_NAME — returns seconds since last run
db_seconds_since_last_run() {
    _last=$(db_get_last_run_ts "$1")
    _now=$(now_epoch)
    echo $(( _now - _last ))
}

# ---------------------------------------------------------------------------
# Retention / maintenance
# ---------------------------------------------------------------------------

# db_purge_old DAYS — delete rows older than N days from all sample tables
db_purge_old() {
    _days="$1"
    _now=$(now_epoch)
    _cutoff=$(( _now - (_days * 86400) ))

    log_info "db" "Purging data older than epoch ${_cutoff} (${_days} days)"

    _total=0
    for _t in lte_samples ca_samples neighbour_cells temp_samples system_samples process_health ping_samples modem_counters; do
        _count=$(db_scalar "SELECT COUNT(*) FROM ${_t} WHERE ts < ${_cutoff};")
        if [ "${_count:-0}" -gt 0 ]; then
            db_exec "DELETE FROM ${_t} WHERE ts < ${_cutoff};"
            log_info "db" "Purged ${_count} rows from ${_t}"
            _total=$(( _total + _count ))
        fi
    done

    # Events: check retention policy
    _keep_events=$(cfg_get_bool retention keep_events_forever 1)
    if [ "$_keep_events" -eq 0 ]; then
        _count=$(db_scalar "SELECT COUNT(*) FROM events WHERE ts < ${_cutoff};")
        if [ "${_count:-0}" -gt 0 ]; then
            db_exec "DELETE FROM events WHERE ts < ${_cutoff};"
            _total=$(( _total + _count ))
        fi
    fi

    log_info "db" "Total purged: ${_total} rows"
    return 0
}

# db_vacuum — reclaim space
db_vacuum() {
    log_info "db" "Running VACUUM..."
    db_exec "VACUUM;"
    _size=$(wc -c < "$DB_PATH" 2>/dev/null || echo "?")
    log_info "db" "VACUUM complete. DB size: ${_size} bytes"
}

# ---------------------------------------------------------------------------
# Health check
# ---------------------------------------------------------------------------

# db_check — verify DB is accessible and has expected tables
db_check() {
    if [ ! -f "$DB_PATH" ]; then
        log_error "db" "Database file not found: ${DB_PATH}"
        return 1
    fi

    if [ ! -x "$SQLITE" ]; then
        log_error "db" "sqlite3 not found at ${SQLITE}"
        return 1
    fi

    _table_count=$(db_scalar "SELECT COUNT(*) FROM sqlite_master WHERE type='table';")
    if [ "${_table_count:-0}" -lt 13 ]; then
        log_error "db" "Expected ≥13 tables, found ${_table_count}"
        return 1
    fi

    _journal=$(db_scalar "PRAGMA journal_mode;")
    if [ "$_journal" != "wal" ]; then
        log_warning "db" "Journal mode is '${_journal}', expected 'wal'. Setting WAL..."
        db_exec "PRAGMA journal_mode=WAL;"
    fi

    log_debug "db" "DB check passed (${_table_count} tables, journal=${_journal})"
    return 0
}

# ---------------------------------------------------------------------------
# Transaction wrapper
# ---------------------------------------------------------------------------

# db_transaction SQL_BLOCK — wrap multiple statements in BEGIN/COMMIT
db_transaction() {
    "$SQLITE" "$DB_PATH" "BEGIN TRANSACTION; $1 COMMIT;" 2>/dev/null
    _rc=$?
    if [ $_rc -ne 0 ]; then
        log_error "db" "Transaction failed, rolling back"
        db_exec "ROLLBACK;" 2>/dev/null
    fi
    return $_rc
}

# ---------------------------------------------------------------------------
# Insert the last lte_samples rowid (for FK references in ca/neighbour tables)
# ---------------------------------------------------------------------------
db_last_insert_rowid() {
    db_scalar "SELECT last_insert_rowid();"
}
