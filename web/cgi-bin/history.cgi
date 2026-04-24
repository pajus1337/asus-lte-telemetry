#!/bin/sh
# =============================================================================
# web/cgi-bin/history.cgi — historical data JSON for sparklines
# =============================================================================
# Query params: metric=rsrp|sinr|rsrq|rssi  n=<count> (max 500)
# Returns: {"metric":"rsrp","data":[{"ts":1234,"v":-92},...],"min":-110,"max":-80}
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
_n=$(printf '%s' "${QUERY_STRING:-}" | grep -o 'n=[^&]*' | cut -d'=' -f2)

# Validate metric — whitelist only, prevents SQL injection
case "${_metric:-rsrp}" in
    rsrp|sinr|rsrq|rssi) ;;
    *) _metric="rsrp" ;;
esac

# Validate n
printf '%s' "${_n:-60}" | grep -qE '^[0-9]+$' || _n=60
[ -z "$_n" ] && _n=60
[ "$_n" -gt 500 ] && _n=500

"$SQLITE" -separator '|' "$DB_PATH" \
    "SELECT ts, ${_metric} FROM (
         SELECT ts, ${_metric} FROM lte_samples
         WHERE ${_metric} IS NOT NULL
         ORDER BY ts DESC LIMIT ${_n}
     ) ORDER BY ts ASC;" 2>/dev/null | \
awk -F'|' -v metric="$_metric" '
BEGIN { printf "{\"metric\":\"%s\",\"data\":[", metric; sep=""; mn=9999; mx=-9999 }
{
    v = $2 + 0
    printf "%s{\"ts\":%s,\"v\":%s}", sep, $1, $2
    sep=","
    if (v < mn) mn=v
    if (v > mx) mx=v
}
END { printf "],\"min\":%s,\"max\":%s}\n", (NR>0 ? mn : "null"), (NR>0 ? mx : "null") }
'
