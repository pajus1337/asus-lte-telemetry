#!/bin/sh
# =============================================================================
# asus-lte-telemetry: Interactive installer
# =============================================================================
#
# What this script does:
#   1. Verifies the target environment (Entware, modem, ports, directories)
#   2. Asks for user confirmation on key decisions
#   3. Installs required Entware packages
#   4. Creates the directory layout at /tmp/mnt/System/asus-lte-telemetry/
#   5. Initialises the SQLite schema
#   6. Writes a default config.ini
#   7. Optionally registers the dispatcher in cron
#   8. Runs a smoke test (AT command to modem, DB read, one collection cycle)
#
# What this script does NOT do:
#   - Install or configure Entware itself (assumed already present)
#   - Modify nvram or router firmware
#   - Open any ports to the internet
#   - Send any data anywhere
#
# Usage:
#   sh install.sh           # interactive
#   sh install.sh --help
#
# After install, you can reconfigure with:
#   $INSTALL_DIR/install.sh --reconfigure
# =============================================================================

set -u

# ----- paths ----------------------------------------------------------------
INSTALL_BASE="${INSTALL_BASE:-/tmp/mnt/System/asus-lte-telemetry}"
SYMLINK_PATH="${SYMLINK_PATH:-/opt/etc/asus-lte-telemetry}"
RMON_SYMLINK="/opt/bin/rmon"

# ----- colours (only if terminal supports them) -----------------------------
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

# ----- logging --------------------------------------------------------------
msg()   { printf '%s\n' "$*"; }
info()  { printf '%s[info]%s %s\n' "$C_BLUE" "$C_RST" "$*"; }
ok()    { printf '%s[ ok ]%s %s\n' "$C_GREEN" "$C_RST" "$*"; }
warn()  { printf '%s[warn]%s %s\n' "$C_YELLOW" "$C_RST" "$*" >&2; }
err()   { printf '%s[err ]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }
step()  { printf '\n%s==>%s %s%s%s\n' "$C_BLUE" "$C_RST" "$C_BOLD" "$*" "$C_RST"; }

die()   { err "$@"; exit 1; }

ask_yn() {
    # ask_yn "prompt" [default_y|default_n]
    prompt="$1"
    default="${2:-default_y}"
    if [ "$default" = "default_y" ]; then
        hint="[Y/n]"
    else
        hint="[y/N]"
    fi
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

# ----- help -----------------------------------------------------------------
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    cat <<EOF
asus-lte-telemetry installer

Usage:
  sh install.sh               Interactive install
  sh install.sh --help        This help

The installer is interactive: it asks for confirmation before every
destructive step (package installation, directory creation, cron setup).

Environment overrides:
  INSTALL_BASE   Base install directory (default: /tmp/mnt/System/asus-lte-telemetry)
  SYMLINK_PATH   Symlink for /opt/etc (default: /opt/etc/asus-lte-telemetry)

EOF
    exit 0
fi

# =============================================================================
# Banner
# =============================================================================
cat <<'EOF'

   _ _                                _ _
  | | |_ ___ ____  __ _  ___  _ __  _| | |_ ___  _ __
  | | __/ _ \  _ \/ _` |/ _ \| '_ \| | | __/ _ \| '__|
  | | ||  __/ | | | (_| | (_) | | | | | | || (_) | |
  |_|\__\___|_| |_|\__,_|\___/|_| |_|_|_|\__\___/|_|

  LTE modem monitoring for ASUS 4G-AC86U (stock firmware + Entware)

EOF

# =============================================================================
# Step 1: environment checks
# =============================================================================
step "Step 1/7: Environment checks"

# -- user / shell ------------------------------------------------------------
# Detect current user. BusyBox on stock ASUS firmware may lack `id` and `whoami`,
# so we fall back through multiple methods.
detect_user() {
    # Try `id -un`
    if command -v id >/dev/null 2>&1; then
        id -un 2>/dev/null && return 0
    fi
    # Try `whoami`
    if command -v whoami >/dev/null 2>&1; then
        whoami 2>/dev/null && return 0
    fi
    # Try $USER or $LOGNAME
    if [ -n "${USER:-}" ]; then
        echo "$USER" && return 0
    fi
    if [ -n "${LOGNAME:-}" ]; then
        echo "$LOGNAME" && return 0
    fi
    # Last resort: read from /proc
    if [ -r /proc/self/status ]; then
        uid=$(awk '/^Uid:/ {print $2; exit}' /proc/self/status 2>/dev/null)
        if [ "$uid" = "0" ]; then
            echo "root" && return 0
        fi
    fi
    echo "unknown"
}

CURRENT_USER=$(detect_user)
if [ "$CURRENT_USER" != "root" ] && [ "$CURRENT_USER" != "admin" ] && [ "$CURRENT_USER" != "unknown" ]; then
    warn "Running as '$CURRENT_USER' (expected root or admin). Some steps may fail."
elif [ "$CURRENT_USER" = "unknown" ]; then
    info "Could not determine current user (no id/whoami). Continuing anyway."
fi

# -- architecture ------------------------------------------------------------
ARCH=$(uname -m)
if [ "$ARCH" != "aarch64" ]; then
    warn "Architecture is '$ARCH', expected 'aarch64'."
    ask_yn "Continue anyway?" default_n || die "Aborted by user"
fi
ok "Architecture: $ARCH"

# -- Entware -----------------------------------------------------------------
if [ ! -x /opt/bin/opkg ]; then
    die "Entware not found at /opt/bin/opkg. Install Entware first."
fi
ok "Entware detected at /opt"

# -- install base directory --------------------------------------------------
if [ ! -d "$(dirname "$INSTALL_BASE")" ]; then
    die "Parent of install directory does not exist: $(dirname "$INSTALL_BASE")
Is the USB stick mounted? Try: mount | grep /tmp/mnt"
fi
ok "Install target: $INSTALL_BASE"

# -- serial port -------------------------------------------------------------
# On ASUS 4G-AC86U stock firmware, ttyUSB2 is held by quectel-CM and LTE
# management daemons. ttyUSB3 is the free secondary AT port on Quectel EM12-G.
# Auto-select: prefer ttyUSB3 (free), fall back to ttyUSB2 if ttyUSB3 absent.
if [ -c /dev/ttyUSB3 ]; then
    AT_PORT="/dev/ttyUSB3"
elif [ -c /dev/ttyUSB2 ]; then
    AT_PORT="/dev/ttyUSB2"
else
    AT_PORT="/dev/ttyUSB3"
fi

if [ ! -c "$AT_PORT" ]; then
    warn "AT port $AT_PORT not present."
    warn "Available: $(ls /dev/ttyUSB* 2>/dev/null || echo 'none')"
    ask_yn "Continue anyway?" default_n || die "Aborted by user"
else
    ok "AT port present: $AT_PORT"
fi

# -- check if port is held exclusively --------------------------------------
if command -v fuser >/dev/null 2>&1; then
    if FUSER_OUT=$(fuser "$AT_PORT" 2>&1); then
        if [ -n "$FUSER_OUT" ] && echo "$FUSER_OUT" | grep -q '[0-9]'; then
            warn "Port $AT_PORT is held by a process — may cause AT errors."
            warn "  $FUSER_OUT"
            if [ "$AT_PORT" = "/dev/ttyUSB2" ] && [ -c /dev/ttyUSB3 ]; then
                info "Switching to /dev/ttyUSB3 (free secondary AT port)."
                AT_PORT="/dev/ttyUSB3"
            fi
        fi
    fi
fi

# =============================================================================
# Step 2: install required Entware packages
# =============================================================================
step "Step 2/7: Install Entware packages"

REQUIRED_PKGS="sqlite3-cli coreutils-sleep coreutils-mktemp coreutils-date coreutils-stat coreutils-timeout psmisc lsof"

# Packages may be listed as installed but binary missing (e.g. after USB remount).
# Check both the package list AND the actual binary for critical packages.
pkg_binary_ok() {
    case "$1" in
        sqlite3-cli)       [ -x /opt/bin/sqlite3 ] ;;
        coreutils-sleep)   [ -x /opt/bin/sleep ] ;;
        coreutils-mktemp)  [ -x /opt/bin/mktemp ] ;;
        coreutils-date)    [ -x /opt/bin/date ] ;;
        coreutils-timeout) [ -x /opt/bin/timeout ] ;;
        *)                 return 0 ;;
    esac
}

MISSING=""
for pkg in $REQUIRED_PKGS; do
    if /opt/bin/opkg list-installed | grep -q "^$pkg " && pkg_binary_ok "$pkg"; then
        :
    else
        MISSING="$MISSING $pkg"
    fi
done

if [ -z "$MISSING" ]; then
    ok "All required packages installed and binaries verified"
else
    info "Missing or incomplete packages:$MISSING"
    if ask_yn "Install them now?" default_y; then
        /opt/bin/opkg update || warn "opkg update failed (continuing)"
        # shellcheck disable=SC2086
        /opt/bin/opkg install $MISSING || die "opkg install failed"
        ok "Packages installed"
    else
        die "Cannot continue without required packages"
    fi
fi

# Optional: lighttpd for the web dashboard (CGI support via lighttpd-mod-cgi)
if command -v lighttpd >/dev/null 2>&1 || [ -x /opt/sbin/lighttpd ]; then
    ok "lighttpd available — web dashboard ready (rmon web start)"
elif command -v uhttpd >/dev/null 2>&1 || command -v httpd >/dev/null 2>&1; then
    ok "HTTP server available — web dashboard ready (rmon web start)"
else
    info "Web dashboard requires lighttpd with CGI support."
    if ask_yn "Install lighttpd and lighttpd-mod-cgi?" default_y; then
        /opt/bin/opkg update >/dev/null 2>&1 || true
        /opt/bin/opkg install lighttpd lighttpd-mod-cgi \
            && ok "lighttpd installed — start dashboard with: rmon web start" \
            || warn "Install failed; try manually: opkg install lighttpd lighttpd-mod-cgi"
    else
        info "Skipped. Install later with: opkg install lighttpd lighttpd-mod-cgi"
    fi
fi

# Optional: vnstat for WAN traffic stats (day/month totals on wwan0)
# Read wan_interface from existing config if present, otherwise default wwan0
_wan_iface=$(grep -E '^[[:space:]]*wan_interface[[:space:]]*=' \
    "$INSTALL_BASE/config/config.ini" "$INSTALL_BASE/config/config.ini.example" 2>/dev/null \
    | head -1 | sed 's/.*=[[:space:]]*//' | sed 's/[[:space:]]*$//')
_wan_iface="${_wan_iface:-wwan0}"

if [ -x /opt/bin/vnstat ] || command -v vnstat >/dev/null 2>&1; then
    ok "vnstat available — initialising interface ${_wan_iface} if needed"
    /opt/bin/vnstat --create -i "$_wan_iface" >/dev/null 2>&1 || true
else
    info "vnstat provides daily/monthly WAN transfer stats on ${_wan_iface}."
    if ask_yn "Install vnstat?" default_y; then
        /opt/bin/opkg install vnstat \
            && ok "vnstat installed" \
            || warn "Install failed; try manually: opkg install vnstat"
        # Initialise the interface database
        if [ -x /opt/bin/vnstat ]; then
            /opt/bin/vnstat --create -i "$_wan_iface" >/dev/null 2>&1 \
                && ok "vnstat initialised for ${_wan_iface}" \
                || warn "vnstat --create failed; run manually: vnstat --create -i ${_wan_iface}"
        fi
    else
        info "Skipped. Install later: opkg install vnstat && vnstat --create -i ${_wan_iface}"
    fi
fi

# =============================================================================
# Step 3: directory layout
# =============================================================================
step "Step 3/7: Create directory layout"

mkdir -p "$INSTALL_BASE/bin" \
         "$INSTALL_BASE/lib" \
         "$INSTALL_BASE/config" \
         "$INSTALL_BASE/web" \
         "$INSTALL_BASE/docs" \
         "$INSTALL_BASE/db" \
         "$INSTALL_BASE/logs" \
         "$INSTALL_BASE/backups" \
         "$INSTALL_BASE/state"

ok "Directories created under $INSTALL_BASE"

# -- copy files from the package source (same dir as this script) -----------
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

if [ "$SCRIPT_DIR" != "$INSTALL_BASE" ]; then
    info "Copying project files from $SCRIPT_DIR to $INSTALL_BASE"
    # Copy all project content except db/, logs/, state/, backups/
    for d in bin lib config web docs; do
        if [ -d "$SCRIPT_DIR/$d" ]; then
            cp -rf "$SCRIPT_DIR/$d/." "$INSTALL_BASE/$d/" 2>/dev/null || true
        fi
    done
    # Top-level files
    for f in README.md LICENSE CHANGELOG.md schema.sql install.sh uninstall.sh; do
        [ -f "$SCRIPT_DIR/$f" ] && cp -f "$SCRIPT_DIR/$f" "$INSTALL_BASE/$f"
    done
    ok "Project files copied"
else
    info "Running from install location, skipping copy"
fi

# -- mark scripts executable -------------------------------------------------
chmod +x "$INSTALL_BASE/bin/"* 2>/dev/null || true
chmod +x "$INSTALL_BASE/lib/"*.sh 2>/dev/null || true
chmod +x "$INSTALL_BASE/install.sh" 2>/dev/null || true
chmod +x "$INSTALL_BASE/uninstall.sh" 2>/dev/null || true

# -- symlink /opt/etc/asus-lte-telemetry -> install base ---------------------------
if [ -L "$SYMLINK_PATH" ] || [ -e "$SYMLINK_PATH" ]; then
    rm -f "$SYMLINK_PATH"
fi
ln -s "$INSTALL_BASE" "$SYMLINK_PATH"
ok "Symlink created: $SYMLINK_PATH -> $INSTALL_BASE"

# -- symlink at-send to /opt/bin --------------------------------------------
if [ -f "$INSTALL_BASE/bin/at-send" ]; then
    ln -sf "$INSTALL_BASE/bin/at-send" /opt/bin/at-send
    ok "Symlink created: /opt/bin/at-send"
fi

# -- symlink rmon to /opt/bin -----------------------------------------------
if [ -f "$INSTALL_BASE/bin/rmon" ]; then
    chmod +x "$INSTALL_BASE/bin/rmon"
    ln -sf "$INSTALL_BASE/bin/rmon" /opt/bin/rmon
    ok "Symlink created: /opt/bin/rmon"
fi

# -- ensure 'entware' symlink for .asusrouter / JFFS boot compatibility -----
# .asusrouter and JFFS fallback scripts reference /tmp/mnt/System/entware
# but the companion repo installer places Entware into asusware.arm/.
# Without this symlink all fallback autostart mechanisms exit silently at boot.
_usb_root=$(dirname "$INSTALL_BASE")
if [ -d "$_usb_root/asusware.arm" ]; then
    if [ ! -e "$_usb_root/entware" ]; then
        ln -s asusware.arm "$_usb_root/entware"
        ok "Created symlink: $_usb_root/entware → asusware.arm"
        info "  Enables .asusrouter / JFFS fallback scripts to find Entware at boot."
    else
        ok "Entware symlink already present: $_usb_root/entware"
    fi
fi

# =============================================================================
# Step 4: write default config (if not present)
# =============================================================================
step "Step 4/7: Configuration"

CONFIG_FILE="$INSTALL_BASE/config/config.ini"
CONFIG_EXAMPLE="$INSTALL_BASE/config/config.ini.example"

if [ -f "$CONFIG_FILE" ]; then
    info "Existing config found at $CONFIG_FILE"
    if ask_yn "Overwrite with defaults?" default_n; then
        cp "$CONFIG_EXAMPLE" "$CONFIG_FILE"
        ok "Default config written"
    else
        ok "Existing config kept"
    fi
else
    cp "$CONFIG_EXAMPLE" "$CONFIG_FILE"
    ok "Default config written to $CONFIG_FILE"
fi

# Patch at_port in config to match the detected/selected AT port
if [ -f "$CONFIG_FILE" ]; then
    sed -i "s|^at_port *=.*|at_port = ${AT_PORT}|" "$CONFIG_FILE"
    ok "AT port set to $AT_PORT in config.ini"
fi

# =============================================================================
# Step 5: initialise database
# =============================================================================
step "Step 5/7: Initialise SQLite database"

DB_PATH="$INSTALL_BASE/db/metrics.db"
SCHEMA_PATH="$INSTALL_BASE/schema.sql"

if [ ! -f "$SCHEMA_PATH" ]; then
    die "Schema file not found at $SCHEMA_PATH"
fi

if [ -f "$DB_PATH" ]; then
    info "Database already exists at $DB_PATH"
    DB_SIZE=$(wc -c < "$DB_PATH" 2>/dev/null || echo "?")
    info "  size: $DB_SIZE bytes"
    if ask_yn "Recreate database? (existing data will be lost)" default_n; then
        BACKUP_PATH="$INSTALL_BASE/backups/metrics-$(date +%Y%m%d-%H%M%S).db"
        cp "$DB_PATH" "$BACKUP_PATH"
        ok "Backup saved: $BACKUP_PATH"
        rm -f "$DB_PATH"
        /opt/bin/sqlite3 "$DB_PATH" < "$SCHEMA_PATH" >/dev/null || die "Schema creation failed"
        ok "Database recreated"
    else
        ok "Existing database kept"
        # Still run schema file — CREATE TABLE IF NOT EXISTS is safe
        /opt/bin/sqlite3 "$DB_PATH" < "$SCHEMA_PATH" >/dev/null || warn "Schema apply failed (continuing)"
    fi
else
    /opt/bin/sqlite3 "$DB_PATH" < "$SCHEMA_PATH" >/dev/null || die "Schema creation failed"
    ok "Database created at $DB_PATH"
fi

# Verify
if /opt/bin/sqlite3 "$DB_PATH" ".tables" >/dev/null 2>&1; then
    TABLES=$(/opt/bin/sqlite3 "$DB_PATH" ".tables" | tr -s ' ' '\n' | grep -v '^$' | wc -l)
    ok "Database accessible, $TABLES tables"
else
    die "Database verification failed"
fi

# =============================================================================
# Step 6: cron registration (optional)
# =============================================================================
step "Step 6/7: Cron registration"

info "The dispatcher must run every minute to collect data."
info "On stock firmware, cron_jobs nvram does not persist — we use a different approach:"
info "  - Add the dispatcher to /jffs/scripts/entware-boot.sh (runs at boot)"
info "  - Also add a crontab entry via crond's config file"

_autostart_web="no"
if [ -x /opt/sbin/lighttpd ] || command -v lighttpd >/dev/null 2>&1; then
    if ask_yn "Auto-start dashboard on boot?" default_n; then
        _autostart_web="yes"
    fi
fi

if ask_yn "Register dispatcher with cron now?" default_y; then
    # Add a wakeup loop to /opt/etc/init.d/ so it starts with Entware
    START_SCRIPT="/opt/etc/init.d/S99asus-lte-telemetry"

    cat > "$START_SCRIPT" <<EOF
#!/bin/sh
# Start asus-lte-telemetry dispatcher loop
# Created by install.sh

ENABLED=yes
PROCS=asus-lte-telemetry-dispatcher
ARGS=
PREARGS=
DESC="asus-lte-telemetry background dispatcher"
PATH=/opt/bin:/opt/sbin:/sbin:/bin:/usr/sbin:/usr/bin
INSTALL_BASE=$INSTALL_BASE
AUTOSTART_DASHBOARD=$_autostart_web

start_service() {
    sleep 3
    if [ -x "\$INSTALL_BASE/bin/dispatcher.sh" ]; then
        # Use sh -c with stdin from /dev/null instead of nohup.
        # In a boot/init context there may be no controlling terminal, making
        # nohup unreliable on some BusyBox builds. Redirecting stdin from
        # /dev/null detaches the process from the terminal session; the &
        # backgrounds it. dispatcher.sh redirects its own output to the log.
        sh -c "while true; do \$INSTALL_BASE/bin/dispatcher.sh >> \$INSTALL_BASE/logs/dispatcher.log 2>&1; /opt/bin/sleep 60; done" </dev/null >/dev/null 2>/dev/null &
        echo \$! > /tmp/asus-lte-telemetry-dispatcher.pid
        echo "asus-lte-telemetry dispatcher started (pid=\$(cat /tmp/asus-lte-telemetry-dispatcher.pid))"
    fi
    if [ "\$AUTOSTART_DASHBOARD" = "yes" ]; then
        sh "\$INSTALL_BASE/bin/rmon" web start >/dev/null 2>&1 || true
        echo "asus-lte-telemetry dashboard started"
    fi
}

stop_service() {
    /opt/bin/pkill -f "\$INSTALL_BASE/bin/dispatcher.sh" 2>/dev/null || true
    /opt/bin/pkill -f "asus-lte-telemetry-dispatcher" 2>/dev/null || true
    rm -f /tmp/asus-lte-telemetry-dispatcher.pid
    echo "asus-lte-telemetry dispatcher stopped"
    if [ "\$AUTOSTART_DASHBOARD" = "yes" ]; then
        sh "\$INSTALL_BASE/bin/rmon" web stop >/dev/null 2>&1 || true
    fi
}

case "\$1" in
    start)   start_service ;;
    stop)    stop_service ;;
    restart) stop_service; sleep 2; start_service ;;
    *)       echo "Usage: \$0 {start|stop|restart}" ;;
esac
EOF
    chmod +x "$START_SCRIPT"
    ok "Init script installed: $START_SCRIPT"
    if [ "$_autostart_web" = "yes" ]; then
        ok "Dashboard auto-start on boot: enabled"
    fi
    info "Note: dispatcher will actually start after next reboot."
    info "To start now: $START_SCRIPT start"
else
    info "Skipping cron registration. You can enable it later:"
    info "  $INSTALL_BASE/install.sh --reconfigure"
fi

# =============================================================================
# Step 7: smoke test
# =============================================================================
step "Step 7/7: Smoke test"

# Test at-send
if [ -x "$INSTALL_BASE/bin/at-send" ] && [ -c "$AT_PORT" ]; then
    info "Testing AT command to modem..."
    # Capture output and normalise line endings (modem uses \r\n)
    AT_RAW=$("$INSTALL_BASE/bin/at-send" "ATI" 2 2>&1 || true)
    AT_OUT=$(printf '%s' "$AT_RAW" | tr -d '\r')

    if echo "$AT_OUT" | grep -q "^OK$\|^OK "; then
        MODEL=$(echo "$AT_OUT" | grep -E '^EM[0-9]+' | head -1)
        REV=$(echo "$AT_OUT" | grep -i "Revision:" | head -1 | sed 's/.*Revision: *//')
        [ -z "$MODEL" ] && MODEL="unknown"
        [ -z "$REV" ] && REV="unknown"
        ok "Modem responds: $MODEL (firmware: $REV)"
    else
        warn "AT command did not return OK. Raw output:"
        echo "$AT_RAW" | sed 's/^/    /'
    fi
fi

# Test DB
if /opt/bin/sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM meta;" >/dev/null 2>&1; then
    ok "Database read test passed"
else
    warn "Database read test failed"
fi

# Test collector (quick single run)
if [ -x "$INSTALL_BASE/bin/collector-lte.sh" ] && [ -c "$AT_PORT" ]; then
    info "Running a test LTE collection cycle..."
    if /bin/sh "$INSTALL_BASE/bin/collector-lte.sh" >/dev/null 2>&1; then
        LTE_COUNT=$(/opt/bin/sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM lte_samples;" 2>/dev/null)
        ok "LTE collector test passed (${LTE_COUNT} samples in DB)"
    else
        warn "LTE collector test failed (check logs for details)"
    fi
fi

# =============================================================================
# Done
# =============================================================================
cat <<EOF

${C_GREEN}${C_BOLD}Installation complete.${C_RST}

Installed to:    $INSTALL_BASE
Database:        $DB_PATH
Config:          $CONFIG_FILE
Logs:            $INSTALL_BASE/logs/

Next steps:

  1. Review and edit configuration (optional):
       nano $CONFIG_FILE

  2. Start the dispatcher (if not already running):
       /opt/etc/init.d/S99asus-lte-telemetry start

  3. Wait 60 seconds and check collected data:
       rmon status

  4. Start the web dashboard:
       rmon web start
       # then open http://$(ip addr show br0 2>/dev/null | grep -o 'inet [0-9.]*' | head -1 | sed 's/inet //'):8080/

  5. Tail the log:
       tail -f $INSTALL_BASE/logs/dispatcher.log

To uninstall:
       sh $INSTALL_BASE/uninstall.sh

Report issues:
       https://github.com/pajus1337/asus-lte-telemetry/issues

EOF
