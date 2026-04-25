#!/bin/sh
# =============================================================================
# web/cgi-bin/api.cgi — current status JSON API
# =============================================================================
# Returns a single JSON object with all current telemetry state.
# Served by lighttpd; called by the dashboard every 30s.
# =============================================================================

_cgi_dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
INSTALL_BASE="${_cgi_dir%/web/cgi-bin}"
[ -z "$INSTALL_BASE" ] && INSTALL_BASE="/tmp/mnt/System/asus-lte-telemetry"

SQLITE="${SQLITE:-/opt/bin/sqlite3}"
DB_PATH="${DB_PATH:-${INSTALL_BASE}/db/metrics.db}"
CONFIG_FILE="${CONFIG_FILE:-${INSTALL_BASE}/config/config.ini}"

printf 'Content-Type: application/json\r\n\r\n'

if [ ! -f "$DB_PATH" ] || [ ! -x "$SQLITE" ]; then
    printf '{"error":"database_unavailable"}\n'
    exit 0
fi

_now=$(/opt/bin/date +%s 2>/dev/null || date +%s)

# ---------------------------------------------------------------------------
# signal — latest lte_samples row
# ---------------------------------------------------------------------------
_sig_row=$("$SQLITE" -separator '|' "$DB_PATH" \
    "SELECT ts, rrc_state, rat, duplex, mcc, mnc, cell_id_hex, cell_id_dec, pci,
            earfcn, band, rsrp, rsrq, rssi, sinr, cqi, tx_power,
            operator, net_type
     FROM lte_samples ORDER BY ts DESC LIMIT 1;" 2>/dev/null)

if [ -n "$_sig_row" ]; then
    _sig_json=$(echo "$_sig_row" | awk -F'|' '
    function n(v) { return (v=="" ? "null" : v) }
    function s(v) { return (v=="" ? "null" : "\"" v "\"") }
    {
        printf "{\"ts\":%s,\"rrc_state\":%s,\"rat\":%s,\"duplex\":%s,",
            n($1), s($2), s($3), s($4)
        printf "\"mcc\":%s,\"mnc\":%s,\"cell_id_hex\":%s,\"cell_id_dec\":%s,\"pci\":%s,",
            n($5), n($6), s($7), n($8), n($9)
        printf "\"earfcn\":%s,\"band\":%s,\"rsrp\":%s,\"rsrq\":%s,",
            n($10), n($11), n($12), n($13)
        printf "\"rssi\":%s,\"sinr\":%s,\"cqi\":%s,\"tx_power\":%s,",
            n($14), n($15), n($16), n($17)
        printf "\"operator\":%s,\"net_type\":%s}", s($18), s($19)
    }')
else
    _sig_json="null"
fi

# ---------------------------------------------------------------------------
# ca — latest ca_samples rows
# ---------------------------------------------------------------------------
_ca_ts=$("$SQLITE" "$DB_PATH" "SELECT MAX(ts) FROM ca_samples;" 2>/dev/null)
if [ -n "$_ca_ts" ]; then
    _ca_json=$("$SQLITE" -separator '|' "$DB_PATH" \
        "SELECT cc_type, cc_index, band, bandwidth, rsrp, rsrq, sinr
         FROM ca_samples WHERE ts = ${_ca_ts}
         ORDER BY cc_index;" 2>/dev/null | awk -F'|' '
    function n(v) { return (v=="" ? "null" : v) }
    function s(v) { return (v=="" ? "null" : "\"" v "\"") }
    BEGIN { printf "["; sep="" }
    {
        printf "%s{\"type\":%s,\"index\":%s,\"band\":%s,\"bw\":%s,\"rsrp\":%s,\"rsrq\":%s,\"sinr\":%s}",
            sep, s($1), n($2), n($3), n($4), n($5), n($6), n($7)
        sep=","
    }
    END { printf "]" }')
else
    _ca_json="[]"
fi

# ---------------------------------------------------------------------------
# system — latest system_samples row
# ---------------------------------------------------------------------------
_sys_row=$("$SQLITE" -separator '|' "$DB_PATH" \
    "SELECT ts, uptime_sec, load_1min, load_5min,
            mem_used_kb, mem_total_kb, swap_used_kb, swap_total_kb,
            disk_data_used_pct, cpu_temp
     FROM system_samples ORDER BY ts DESC LIMIT 1;" 2>/dev/null)

if [ -n "$_sys_row" ]; then
    _sys_json=$(echo "$_sys_row" | awk -F'|' '
    function n(v) { return (v=="" ? "null" : v) }
    {
        printf "{\"ts\":%s,\"uptime_sec\":%s,\"load_1min\":%s,\"load_5min\":%s,",
            n($1), n($2), n($3), n($4)
        printf "\"mem_used_kb\":%s,\"mem_total_kb\":%s,",
            n($5), n($6)
        printf "\"swap_used_kb\":%s,\"swap_total_kb\":%s,",
            n($7), n($8)
        printf "\"disk_data_pct\":%s,\"cpu_temp\":%s}", n($9), n($10)
    }')
else
    _sys_json="null"
fi

# ---------------------------------------------------------------------------
# neighbours — cells from latest neighbour scan (linked to latest lte_sample)
# ---------------------------------------------------------------------------
_neigh_sample_id=$("$SQLITE" "$DB_PATH" \
    "SELECT id FROM lte_samples ORDER BY ts DESC LIMIT 1;" 2>/dev/null)
_neigh_json="[]"
if [ -n "$_neigh_sample_id" ]; then
    _neigh_json=$("$SQLITE" -separator '|' "$DB_PATH" \
        "SELECT neighbour_type, rat, earfcn, pci, rsrp, rsrq, sinr
         FROM neighbour_cells WHERE sample_id = ${_neigh_sample_id}
         ORDER BY rsrp DESC LIMIT 20;" 2>/dev/null | awk -F'|' '
    function n(v) { return (v=="" ? "null" : v) }
    function s(v) { return (v=="" ? "null" : "\"" v "\"") }
    BEGIN { printf "["; sep="" }
    {
        printf "%s{\"type\":%s,\"rat\":%s,\"earfcn\":%s,\"pci\":%s,\"rsrp\":%s,\"rsrq\":%s,\"sinr\":%s}",
            sep, s($1), s($2), n($3), n($4), n($5), n($6), n($7)
        sep=","
    }
    END { printf "]" }')
    [ -z "$_neigh_json" ] && _neigh_json="[]"
fi

# ---------------------------------------------------------------------------
# ping — latest ping_samples grouped by target
# ---------------------------------------------------------------------------
_ping_ts=$("$SQLITE" "$DB_PATH" "SELECT MAX(ts) FROM ping_samples;" 2>/dev/null)
if [ -n "$_ping_ts" ]; then
    _ping_json=$("$SQLITE" -separator '|' "$DB_PATH" \
        "SELECT target, target_label, loss_pct, rtt_avg_ms, rtt_min_ms, rtt_max_ms
         FROM ping_samples WHERE ts = ${_ping_ts}
         ORDER BY target_label;" 2>/dev/null | awk -F'|' '
    function n(v) { return (v=="" ? "null" : v) }
    function s(v) { return (v=="" ? "null" : "\"" v "\"") }
    BEGIN { printf "["; sep="" }
    {
        printf "%s{\"target\":%s,\"label\":%s,\"loss_pct\":%s,\"rtt_avg_ms\":%s,\"rtt_min_ms\":%s,\"rtt_max_ms\":%s}",
            sep, s($1), s($2), n($3), n($4), n($5), n($6)
        sep=","
    }
    END { printf "]" }')
else
    _ping_json="[]"
fi

# ---------------------------------------------------------------------------
# temp — latest temp_samples row
# ---------------------------------------------------------------------------
_temp_row=$("$SQLITE" -separator '|' "$DB_PATH" \
    "SELECT ts, xo_therm_buf, mdm_case_therm, pa_therm1,
            tsens_tz_sensor0, tsens_tz_sensor1, tsens_tz_sensor2,
            tsens_tz_sensor3, tsens_tz_sensor4
     FROM temp_samples ORDER BY ts DESC LIMIT 1;" 2>/dev/null)

if [ -n "$_temp_row" ]; then
    _temp_json=$(echo "$_temp_row" | awk -F'|' '
    function n(v) { return (v=="" ? "null" : v) }
    {
        printf "{\"ts\":%s,\"xo_therm\":%s,\"mdm_case\":%s,\"pa_therm\":%s",
            n($1), n($2), n($3), n($4)
        printf ",\"tsens0\":%s,\"tsens1\":%s,\"tsens2\":%s,\"tsens3\":%s,\"tsens4\":%s}",
            n($5), n($6), n($7), n($8), n($9)
    }')
else
    _temp_json="null"
fi

# ---------------------------------------------------------------------------
# collectors — state table
# ---------------------------------------------------------------------------
_col_json=$("$SQLITE" -separator '|' "$DB_PATH" \
    "SELECT collector_name, last_run_ts, last_status, COALESCE(last_error,'')
     FROM collector_state ORDER BY collector_name;" 2>/dev/null | \
awk -F'|' -v now="$_now" '
function s(v) { return (v=="" ? "null" : "\"" v "\"") }
BEGIN { printf "{"; sep="" }
{
    age = now - ($2+0)
    printf "%s%s:{\"last_run_ts\":%s,\"age_sec\":%s,\"status\":%s,\"error\":%s}",
        sep, s($1), ($2+0 > 0 ? $2 : "0"),
        (age > 0 ? age : 0), s($3), s($4)
    sep=","
}
END { printf "}" }')

# ---------------------------------------------------------------------------
# mode + config — from config.ini
# ---------------------------------------------------------------------------
_mode="normal"
_cfg_json="null"
if [ -f "$CONFIG_FILE" ]; then
    _mode=$(grep -E '^[[:space:]]*mode[[:space:]]*=' "$CONFIG_FILE" 2>/dev/null \
            | head -1 | sed 's/.*=[[:space:]]*//' | sed 's/[[:space:]]*$//')
    [ -z "$_mode" ] && _mode="normal"

    _cfg_json=$(awk '
        /^\[/ { cur=substr($0,2,length($0)-2); next }
        /^[[:space:]]*[^#;]/ && /=/ {
            k=$0; v=$0
            sub(/[[:space:]]*=.*/, "", k); sub(/^[[:space:]]*/, "", k)
            sub(/[^=]*=[[:space:]]*/, "", v); sub(/[[:space:]]*#.*$/, "", v); sub(/[[:space:]]*$/, "", v)
            if (cur == "general"     && k == "at_port")             cfg["at_port"]       = v
            if (cur == "general"     && k == "log_level")           cfg["log_level"]     = v
            if (cur == "general"     && k == "wan_interface")       cfg["wan_iface"]     = v
            if (cur == "mode.normal" && k == "lte_interval_sec")    cfg["lte_interval"]  = v
            if (cur == "mode.normal" && k == "system_interval_sec") cfg["sys_interval"]  = v
            if (cur == "mode.normal" && k == "ping_interval_sec")   cfg["ping_interval"] = v
            if (cur == "dashboard"   && k == "port")                cfg["dash_port"]     = v
            if (cur == "retention"   && k == "days")                cfg["retention_days"]= v
            if (cur == "auto_switch" && k == "enabled")             cfg["auto_switch"]   = v
            if (cur == "events"      && k == "sinr_low_threshold")  cfg["sinr_threshold"]= v
        }
        END {
            printf "{"
            sep=""
            for (k in cfg) { printf "%s\"%s\":\"%s\"", sep, k, cfg[k]; sep="," }
            printf "}"
        }
    ' "$CONFIG_FILE" 2>/dev/null)
    [ -z "$_cfg_json" ] && _cfg_json="null"
fi

# ---------------------------------------------------------------------------
# bands — from state file written by rmon band / cmd.cgi (no live AT call)
# ---------------------------------------------------------------------------
_bands_json="null"
_band_state="${INSTALL_BASE}/state/band_config"
if [ -f "$_band_state" ]; then
    _bm=$(grep '^lte_mask='      "$_band_state" 2>/dev/null | cut -d= -f2-)
    _ba=$(grep '^active_bands='  "$_band_state" 2>/dev/null | cut -d= -f2-)
    _bl=$(grep '^locked='        "$_band_state" 2>/dev/null | cut -d= -f2-)
    _bo=$(grep '^original_mask=' "$_band_state" 2>/dev/null | cut -d= -f2-)
    _locked_bool="false"
    [ "$_bl" = "yes" ] && _locked_bool="true"
    _ba_arr=$(echo "${_ba:-}" | awk 'BEGIN{RS=",";ORS=""} NF>0{printf sep"\""$1"\"";sep=","} BEGIN{print "["} END{print "]"}')
    _bands_json=$(printf '{"lte_mask":"%s","active":%s,"locked":%s,"original_mask":"%s"}' \
        "${_bm:-}" "${_ba_arr:-[]}" "$_locked_bool" "${_bo:-}")
fi

# ---------------------------------------------------------------------------
# events — last 5
# ---------------------------------------------------------------------------
_ev_json=$("$SQLITE" -separator '|' "$DB_PATH" \
    "SELECT ts, event_type, severity, details
     FROM events ORDER BY ts DESC LIMIT 50;" 2>/dev/null | awk -F'|' '
function s(v) { return (v=="" ? "null" : "\"" v "\"") }
function n(v) { return (v=="" ? "null" : v) }
BEGIN { printf "["; sep="" }
{
    det = $4; for (i=5; i<=NF; i++) det = det "|" $i
    printf "%s{\"ts\":%s,\"type\":%s,\"severity\":%s,\"details\":%s}",
        sep, n($1), s($2), s($3), (det=="" ? "null" : det)
    sep=","
}
END { printf "]" }')

# ---------------------------------------------------------------------------
# assemble
# ---------------------------------------------------------------------------
printf '{'
printf '"generated_ts":%s,' "$_now"
printf '"mode":"%s",' "$_mode"
printf '"signal":%s,' "$_sig_json"
printf '"ca":%s,' "$_ca_json"
printf '"neighbours":%s,' "$_neigh_json"
printf '"system":%s,' "$_sys_json"
printf '"ping":%s,' "$_ping_json"
printf '"temp":%s,' "$_temp_json"
printf '"collectors":%s,' "$_col_json"
printf '"config":%s,' "$_cfg_json"
printf '"bands":%s,' "$_bands_json"
printf '"events":%s' "$_ev_json"
printf '}\n'
