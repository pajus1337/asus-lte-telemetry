#!/bin/sh
# =============================================================================
# asus-lte-telemetry: Uninstaller
# =============================================================================
#
# What this script does:
#   1. Stops the dispatcher if running
#   2. Removes init script
#   3. Removes symlinks (/opt/etc/asus-lte-telemetry, /opt/bin/at-send, /opt/bin/rmon)
#   4. Optionally backs up the database before removal
#   5. Optionally removes the install directory
#
# What this script does NOT do:
#   - Remove Entware packages (they may be used by other things)
#   - Touch nvram or firmware settings
#   - Remove anything outside /opt/etc, /opt/bin, /tmp/mnt/System/asus-lte-telemetry
#
# Usage:
#   sh uninstall.sh
# =============================================================================

set -u

INSTALL_BASE="${INSTALL_BASE:-/tmp/mnt/System/asus-lte-telemetry}"
SYMLINK_PATH="${SYMLINK_PATH:-/opt/etc/asus-lte-telemetry}"

# ----- colours --------------------------------------------------------------
if [ -t 1 ]; then
    C_RED="$(printf '\033[31m')"
    C_GREEN="$(printf '\033[32m')"
    C_YELLOW="$(printf '\033[33m')"
    C_BLUE="$(printf '\033[34m')"
    C_BOLD="$(printf '\033[1m')"
    C_RST="$(printf '\033[0m')"
else
    C_RED="" ; C_GREEN="" ; C_YELLOW="" ; C_BLUE="" ; C_BOLD="" ; C_RST=""
fi

msg()  { printf '%s\n' "$*"; }
info() { printf '%s[info]%s %s\n' "$C_BLUE" "$C_RST" "$*"; }
ok()   { printf '%s[ ok ]%s %s\n' "$C_GREEN" "$C_RST" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$C_YELLOW" "$C_RST" "$*" >&2; }
err()  { printf '%s[err ]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }

ask_yn() {
    prompt="$1"
    default="${2:-default_n}"
    if [ "$default" = "default_y" ]; then hint="[Y/n]"; else hint="[y/N]"; fi
    printf '%s %s ' "$prompt" "$hint"
    read -r reply
    case "$reply" in
        [Yy]*) return 0 ;;
        [Nn]*) return 1 ;;
        "")
            [ "$default" = "default_y" ] && return 0
            return 1
            ;;
        *) return 1 ;;
    esac
}

cat <<'EOF'

   asus-lte-telemetry uninstaller
   -----------------------

EOF

info "Install base:  $INSTALL_BASE"
info "Symlink:       $SYMLINK_PATH"
echo ""

if ! ask_yn "Continue with uninstallation?" default_n; then
    msg "Aborted."
    exit 0
fi

# --- step 1: stop the dispatcher --------------------------------------------
info "Stopping dispatcher..."
if [ -x "/opt/etc/init.d/S99asus-lte-telemetry" ]; then
    /opt/etc/init.d/S99asus-lte-telemetry stop 2>/dev/null || true
fi
# Also kill any leftover dispatcher processes
/opt/bin/pkill -f "asus-lte-telemetry" 2>/dev/null || true
/opt/bin/pkill -f "dispatcher.sh" 2>/dev/null || true
ok "Dispatcher stopped"

# --- step 2: backup database ------------------------------------------------
DB_PATH="$INSTALL_BASE/db/metrics.db"
if [ -f "$DB_PATH" ]; then
    if ask_yn "Backup database before removal?" default_y; then
        BACKUP_DIR="/tmp/mnt/Data/asus-lte-telemetry-backups"
        mkdir -p "$BACKUP_DIR" 2>/dev/null || BACKUP_DIR="/tmp"
        BACKUP_FILE="$BACKUP_DIR/metrics-$(date +%Y%m%d-%H%M%S).db"
        cp "$DB_PATH" "$BACKUP_FILE" && ok "Backup saved: $BACKUP_FILE" \
                                     || warn "Backup failed"
    fi
fi

# --- step 3: remove init script ---------------------------------------------
if [ -f "/opt/etc/init.d/S99asus-lte-telemetry" ]; then
    rm -f "/opt/etc/init.d/S99asus-lte-telemetry"
    ok "Init script removed"
fi

# --- step 4: remove symlinks ------------------------------------------------
for link in "$SYMLINK_PATH" /opt/bin/at-send /opt/bin/rmon; do
    if [ -L "$link" ]; then
        rm -f "$link"
        ok "Removed symlink: $link"
    fi
done

# --- step 5: remove install directory ---------------------------------------
if [ -d "$INSTALL_BASE" ]; then
    info "Install directory contents:"
    du -sh "$INSTALL_BASE"/* 2>/dev/null | sed 's/^/    /'
    echo ""
    if ask_yn "Remove entire install directory ($INSTALL_BASE)?" default_n; then
        rm -rf "$INSTALL_BASE"
        ok "Install directory removed"
    else
        info "Install directory kept at $INSTALL_BASE"
        info "(You can remove it manually later: rm -rf $INSTALL_BASE)"
    fi
fi

cat <<EOF

${C_GREEN}Uninstallation complete.${C_RST}

Note: Entware packages were NOT removed. If you want to remove them:
  opkg remove vnstat sqlite3-cli

EOF
