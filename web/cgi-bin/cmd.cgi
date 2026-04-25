#!/bin/sh
# =============================================================================
# web/cgi-bin/cmd.cgi — write command interface for the dashboard
# =============================================================================
# GET ?action=<action>[&param=value...]
# Returns: {"ok":true,"message":"..."} or {"ok":false,"error":"..."}
#
# Actions:
#   band_refresh                  — live AT query, update state file
#   band_lock&bands=B1,B3[&reboot=1]  — restrict to specific LTE bands
#   band_unlock[&reboot=1]             — restore original full-band mask
#   mode_set&value=normal|debug|night  — change sampling mode
# =============================================================================

_cgi_dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
INSTALL_BASE="${_cgi_dir%/web/cgi-bin}"
[ -z "$INSTALL_BASE" ] && INSTALL_BASE="/tmp/mnt/System/asus-lte-telemetry"

RMON="${RMON:-$INSTALL_BASE/bin/rmon}"

printf 'Content-Type: application/json\r\nCache-Control: no-cache\r\n\r\n'

_qs="${QUERY_STRING:-}"

# Minimal URL decode: %2C → comma, + → space
_urldec() { printf '%s' "$1" | sed 's/%2C/,/g; s/%2c/,/g; s/%20/ /g; s/+/ /g'; }

_action=$(_urldec "$(echo "$_qs" | tr '&' '\n' | grep '^action=' | head -1 | cut -d= -f2-)")
_bands=$(_urldec  "$(echo "$_qs" | tr '&' '\n' | grep '^bands='  | head -1 | cut -d= -f2-)")
_reboot=$(_urldec "$(echo "$_qs" | tr '&' '\n' | grep '^reboot=' | head -1 | cut -d= -f2-)")
_value=$(_urldec  "$(echo "$_qs" | tr '&' '\n' | grep '^value='  | head -1 | cut -d= -f2-)")

_json_ok()  { printf '{"ok":true,"message":"%s"}\n'  "$1"; }
_json_err() { printf '{"ok":false,"error":"%s"}\n' "$1"; }

[ -x "$RMON" ] || { _json_err "rmon not found at $RMON"; exit 0; }

case "$_action" in

    band_refresh)
        _out=$("$RMON" band show 2>&1)
        if [ $? -eq 0 ]; then
            _json_ok "Band config refreshed"
        else
            _msg=$(printf '%s' "$_out" | head -1 | sed 's/ERROR: //; s/[\"\\]//g')
            _json_err "$_msg"
        fi
        ;;

    band_lock)
        [ -z "$_bands" ] && { _json_err "bands parameter required"; exit 0; }
        # Validate: only B/b, digits, commas allowed
        echo "$_bands" | grep -qvE '^[Bb0-9,]+$' && { _json_err "invalid bands format"; exit 0; }

        if [ "$_reboot" = "1" ]; then
            _out=$("$RMON" band lock "$_bands" --reboot 2>&1)
        else
            _out=$("$RMON" band lock "$_bands" 2>&1)
        fi
        if [ $? -eq 0 ]; then
            _json_ok "Band lock applied: $_bands"
        else
            _msg=$(printf '%s' "$_out" | head -1 | sed 's/ERROR: //; s/[\"\\]//g')
            _json_err "$_msg"
        fi
        ;;

    band_unlock)
        if [ "$_reboot" = "1" ]; then
            _out=$("$RMON" band unlock --reboot 2>&1)
        else
            _out=$("$RMON" band unlock 2>&1)
        fi
        if [ $? -eq 0 ]; then
            _json_ok "Bands unlocked"
        else
            _msg=$(printf '%s' "$_out" | head -1 | sed 's/ERROR: //; s/[\"\\]//g')
            _json_err "$_msg"
        fi
        ;;

    mode_set)
        case "$_value" in
            normal|debug|night) ;;
            *) _json_err "invalid mode: $_value"; exit 0 ;;
        esac
        _out=$("$RMON" mode "$_value" 2>&1)
        if [ $? -eq 0 ]; then
            _json_ok "Mode set to $_value"
        else
            _json_err "Failed to set mode"
        fi
        ;;

    "")
        _json_err "action parameter required"
        ;;

    *)
        _json_err "unknown action: $_action"
        ;;
esac
