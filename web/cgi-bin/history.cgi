#!/bin/sh
# =============================================================================
# web/cgi-bin/history.cgi — historical data JSON for charts
# =============================================================================
# Query params:
#   metric=rsrp|sinr|rsrq|rssi  (default: rsrp)
#   hours=<1-168>               (default: 24; time window)
#   n=<1-2000>                  (default: 0 = no limit within window)
# Returns:
#   {"metric":"rsrp","data":[{"ts":1234,"v":-92},...],"min":-110,"max":-80}
# =============================================================================

_cgi_dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
INSTALL_BASE="${_cgi_dir%/web/cgi-bin}"
[ -z "$INSTALL_BASE" ] && INSTALL_BASE="/tmp/mnt/System/asus-lte-telemetry"

SQLITE="${SQLITE:-/opt/bin/sqlite3}"
DB_PATH="${DB_PATH:-${INSTALL_BASE}/db/metrics.db}"

printf 'Content-Type: application/json\r\n\r\n'

if [ ! -f "$DB_PATH" ] || [ ! -x "$SQLITE" ]; then
    printf '{"error":"database_unavailable"}\n'
    exit 0
fi

# Parse QUERY_STRING
_metric=$(printf '%s' "${QUERY_STRING:-}" | grep -o 'metric=[^&]*' | cut -d'=' -f2)
_hours=$(printf '%s' "${QUERY_STRING:-}" | grep -o 'hours=[^&]*' | cut -d'=' -f2)
_n=$(printf '%s' "${QUERY_STRING:-}" | grep -o '\bn=[^&]*' | cut -d'=' -f2)

# Validate metric — whitelist only, prevents SQL injection
case "${_metric:-rsrp}" in
    rsrp|sinr|rsrq|rssi) ;;
    *) _metric="rsrp" ;;
esac

# Validate hours
printf '%s' "${_hours:-24}" | grep -qE '^[0-9]+$' || _hours=24
[ -z "$_hours" ] && _hours=24
[ "$_hours" -lt 1 ]   && _hours=1
[ "$_hours" -gt 168 ] && _hours=168

# Validate n (0 = no extra limit)
printf '%s' "${_n:-0}" | grep -qE '^[0-9]+$' || _n=0
[ -z "$_n" ] && _n=0
[ "$_n" -gt 2000 ] && _n=2000

_since=$(( $(/opt/bin/date +%s 2>/dev/null || date +%s) - _hours * 3600 ))

if [ "$_n" -gt 0 ]; then
    _query="SELECT ts, ${_metric} FROM (
        SELECT ts, ${_metric} FROM lte_samples
        WHERE ${_metric} IS NOT NULL AND ts >= ${_since}
        ORDER BY ts DESC LIMIT ${_n}
    ) ORDER BY ts ASC;"
else
    _query="SELECT ts, ${_metric} FROM lte_samples
        WHERE ${_metric} IS NOT NULL AND ts >= ${_since}
        ORDER BY ts ASC;"
fi

"$SQLITE" -separator '|' "$DB_PATH" "$_query" 2>/dev/null | \
awk -F'|' -v metric="$_metric" -v since="$_since" -v hours="$_hours" '
BEGIN { printf "{\"metric\":\"%s\",\"hours\":%s,\"since\":%s,\"data\":[", metric, hours, since; sep=""; mn=9999; mx=-9999 }
{
    v = $2 + 0
    printf "%s{\"ts\":%s,\"v\":%s}", sep, $1, $2
    sep=","
    if (v < mn) mn=v
    if (v > mx) mx=v
}
END { printf "],\"min\":%s,\"max\":%s,\"count\":%s}\n", (NR>0 ? mn : "null"), (NR>0 ? mx : "null"), NR }
'
