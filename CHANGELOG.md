# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.4.8] - 2026-04-25

### Fixed

- **`web/cgi-bin/api.cgi`** — all `function` definitions were inside rule blocks `{ }`,
  which BusyBox awk rejects. Moved all `function n()` / `function s()` definitions to
  top-level scope (before any `BEGIN`/rule blocks). Fixes `awk: cmd. line:4: Unexpected
  token` errors that appeared on every dashboard refresh and caused empty/broken JSON.
- **`install.sh`** — `PRAGMA journal_mode = WAL` in schema.sql outputs `wal` to stdout
  when SQLite applies it. Added `>/dev/null` to all three `sqlite3 < schema.sql` calls
  so the word `wal` no longer leaks into the install output.
- **`install.sh`** — "Next steps" footer used `awk '/inet /{split($2,...)}` to print the
  dashboard URL; BusyBox awk rejects this with `Unexpected token`. Replaced with
  `grep -o 'inet [0-9.]*' | head -1 | sed 's/inet //'`.

## [0.4.7] - 2026-04-25

### Fixed

- **`rmon web start`** — lighttpd config was missing `index-file.names = ("index.html")`.
  Without this directive lighttpd returns 403 for `GET /` because directory listing is
  disabled by default. Adding it makes the root URL serve the dashboard immediately.

## [0.4.6] - 2026-04-25

### Fixed

- **AT port conflict** — `ttyUSB2` is permanently held by router processes (`quectel-CM` and
  LTE management daemons) on ASUS 4G-AC86U stock firmware, causing every AT command to return
  `ERROR`. Changed default AT port to `ttyUSB3` (free secondary AT port on Quectel EM12-G).
- **`lib/at.sh`** — now reads `at_port` from `config.ini` via `cfg_get` and exports it as
  `AT_PORT` before calling `at-send`, so the port is configurable without env-var hacks.
- **`config/config.ini.example`** — default `at_port` changed to `/dev/ttyUSB3`.
- **`bin/at-send`** — built-in default fallback changed to `/dev/ttyUSB3`.
- **`install.sh`** — port auto-detection now prefers `ttyUSB3` over `ttyUSB2`; if `ttyUSB2`
  is detected as held by another process and `ttyUSB3` exists, auto-switches to `ttyUSB3`.
  After writing `config.ini`, patches `at_port` to the detected port value.

## [0.4.5] - 2026-04-25

### Fixed

- **`rmon web start`** — lighttpd not found even when installed because Entware puts
  it in `/opt/sbin/lighttpd` which may not be in PATH. Now checks both `command -v`
  and the explicit path `/opt/sbin/lighttpd` as fallback.
- **`install.sh`** — same fix: lighttpd availability check now also tests `/opt/sbin/lighttpd`.

## [0.4.4] - 2026-04-24

### Fixed

- **`rmon web start`** — switch from `uhttpd` (not in Entware aarch64-k3.10) to
  `lighttpd` + `lighttpd-mod-cgi`. Generates a minimal `config/httpd.conf` on the
  fly (document-root, port, bind, mod_cgi, cgi.assign for `.cgi` files) and launches
  `lighttpd -f config -D` in foreground. Detection order: lighttpd → uhttpd → httpd
  → BusyBox multi-call.
- **`install.sh`** — optional HTTP server step now installs `lighttpd lighttpd-mod-cgi`
  instead of non-existent `uhttpd`. Checks for existing lighttpd/uhttpd/httpd before
  prompting.

## [0.4.3] - 2026-04-24

### Fixed

- **`install.sh`** — package check now verifies the actual binary exists, not just that
  the package name appears in `opkg list-installed`. A package can be listed as installed
  while its binary is missing (e.g. after USB remount or a failed previous install).
  Critical binaries checked: `sqlite3`, `sleep`, `mktemp`, `date`, `timeout` in `/opt/bin/`.
  If the binary is absent the package is added to MISSING and reinstalled.

## [0.4.2] - 2026-04-24

### Fixed

- **`rmon web start`** — switched HTTP server from BusyBox httpd to `uhttpd` (Entware).
  `busybox-httpd` does not exist in Entware aarch64 and stock ASUS firmware BusyBox 1.25.1
  does not have `httpd` compiled in. `uhttpd` is Entware's native OpenWrt HTTP server with
  CGI support built in; invoked as `uhttpd -f -p <port> -h <webroot> -x /cgi-bin`.
  BusyBox httpd and multi-call fallbacks are kept for other hardware.
- **`install.sh`** — optional HTTP server step now offers `uhttpd` instead of non-existent
  `busybox-httpd`; runs `opkg update` first to refresh the package list.

## [0.4.1] - 2026-04-24

### Fixed

- **`rmon web start`** — `httpd not found` on ASUS stock firmware where BusyBox has
  the httpd applet compiled in but no standalone `httpd` symlink in PATH. Now detects
  httpd via BusyBox multi-call binary (`busybox httpd`, `/opt/bin/busybox httpd`,
  `/bin/busybox httpd`) before giving up. Error message now includes the install hint.
- **`install.sh`** — missing web dashboard package step. Added optional `busybox-httpd`
  install prompt after required packages; non-fatal if not found in Entware (rmon
  falls back to BusyBox multi-call detection automatically).
- **`install.sh`** — "Next steps" footer now includes `rmon web start` and the dashboard
  URL; `rmon status` replaces the raw `sqlite3` command for readability.
- **`README.md`** — updated project status (was v0.2.0), fixed dashboard URL (removed
  non-existent `/asus-lte-telemetry/` path suffix), updated architecture diagram
  (cron → init loop, `web/api.sh` → `web/cgi-bin/api.cgi`), added `rmon web` commands
  to CLI section, added dashboard feature list.

## [0.4.0] - 2026-04-24

### Added — HTTP dashboard

#### `web/index.html`
- Single-page dark-theme monitoring dashboard served by BusyBox httpd
- Live signal panel: operator, band, RRC state, RSRP/RSRQ/SINR with quality badges
  (Excellent/Good/Fair/Poor/Very Poor, colour-coded green→red)
- RSRP sparkline chart (pure SVG, 40-sample trend, colour follows signal quality)
- Carrier Aggregation panel: CC count, per-carrier band/RSRP/SINR
- System panel: uptime, 1-min load, RAM/swap/disk progress bars, CPU temp
- Ping panel: per-target loss% and avg RTT
- Modem temperature panel (XO, modem case, PA thermistor)
- Collectors panel: last-run age and status for all four collectors
- Events panel: last 5 events with timestamp, type, severity and details
- Auto-refresh every 30 s with countdown indicator; dot turns red on API failure
- Responsive 2-column grid (CSS Grid), collapses to 1 column below 640 px
- Mode badge (normal/debug/night) colour-coded in header
- Zero external dependencies (no CDN, no npm)

#### `web/cgi-bin/api.cgi`
- BusyBox httpd CGI, outputs single JSON object with all current state:
  signal, ca, system, ping, temp, collectors, mode, events
- INSTALL_BASE derived from `$0` (no hard-coded paths)
- All nullable numeric fields serialised as JSON `null` on missing data
- Handles empty DB gracefully (sections return `null`/`[]`)

#### `web/cgi-bin/history.cgi`
- Returns `{metric, data:[{ts,v},...], min, max}` for sparkline rendering
- Query params: `metric=rsrp|sinr|rsrq|rssi`, `n=1..500` (default 60)
- Metric name validated against whitelist (no SQL injection)

#### `bin/rmon web`
- `rmon web start` — launch BusyBox httpd in background (`httpd -f`), write PID file
- `rmon web stop`  — kill httpd by PID file, clean up
- `rmon web status` (default) — show running/stopped, print LAN URL
- Port read from `[dashboard] port` in config.ini (default 8080)
- LAN URL derived from `br0` interface IP

### Fixed
- `lib/db.sh` `db_transaction`: was silencing SQLite errors with `2>/dev/null`;
  now captures and logs them the same way `db_exec` does

## [0.3.0] - 2026-04-24

### Added — CLI polish

#### `bin/rmon`
- **`rmon plot [metric] [N]`** — ASCII chart of last N samples (default: rsrp, 40)
  - Metrics: `rsrp` | `sinr` | `rsrq` | `rssi`
  - Scaled Y-axis with min/max annotation and time span footer
  - Implemented in awk, POSIX sh compatible
- **`rmon diag`** — quick diagnostic dump
  - Modem model, firmware, IMEI (from `device_info` table)
  - Latest signal: operator, band, RSRP/RSRQ/SINR with quality labels
  - CA component carrier count
  - Current sampling mode
  - Collector last-run times
  - Active errors and last 5 events
- **`rmon tail --follow [sec]`** — live tail for any metric
  - `-f` shorthand supported
  - Interval follows `--follow` directly (e.g. `--follow 10`)
  - Clears terminal via ANSI escape on each refresh
- **`rmon tail lte`** — added `quality` column (Excellent/Good/Fair/Poor/Very poor)
  based on RSRP thresholds

#### Helpers
- `fmt_bytes` — human-readable byte sizes (B / KB / MB / GB)
- `fmt_age` — relative timestamp age ("2m ago", "1h 5m ago", "never")
- `label_rsrp` / `label_sinr` — signal quality labels

### Changed
- `rmon status` — replaced raw epoch `1970-01-01 00:00:00` for never-run collectors
  with `never` (via `fmt_age` on `last_run_ts=0`)
- `rmon status` — DB size now shown human-readable (e.g. `1.4 MB`)
- `rmon status` — shows current sampling mode
- `rmon status` — collector last-run shown as relative age ("2m ago")
- `rmon db info` — DB size now human-readable
- `rmon tail system` — uptime shown as duration ("1d 3h", "45m") instead of raw seconds
- `rmon tail` / `rmon events` — consistent column-aligned output via awk
- VERSION bumped to 0.3.0

## [0.2.0] - 2026-04-24

### Added — Data collection layer

#### Libraries (`lib/`)
- **`lib/common.sh`** — shared utilities
  - Logging with levels (debug/info/warning/error), file + stderr output
  - Log rotation (configurable max size, keeps last 2 rotated files)
  - Locking via atomic `mkdir` (BusyBox-safe, no flock dependency)
  - Stale lock detection (PID liveness check + age timeout)
  - Trap helper for automatic lock cleanup on exit/signal
  - `die()`, `check_dependency()`, `now_epoch()`, `is_integer()`

- **`lib/config.sh`** — INI file parser
  - `cfg_get SECTION KEY [DEFAULT]` — read values with inline comment stripping
  - `cfg_get_int`, `cfg_get_bool` — typed getters with validation
  - `cfg_set SECTION KEY VALUE` — atomic write (awk → tmpfile → mv)
  - `load_sampling_config()` — populates all interval globals from current mode
  - Supports dotted section names (`[mode.normal]`), `=` in values

- **`lib/db.sh`** — SQLite helpers
  - `db_exec`, `db_query`, `db_scalar`, `db_query_csv` — query wrappers
  - `db_escape`, `db_quote` — SQL string escaping
  - `db_transaction` — BEGIN/COMMIT wrapper with rollback on failure
  - `db_update_collector_state` / `db_seconds_since_last_run` — scheduler support
  - `db_purge_old DAYS` — retention across all sample tables
  - `db_vacuum`, `db_check` — maintenance and health verification
  - `db_last_insert_rowid` — for FK references (ca_samples, neighbour_cells)

- **`lib/at.sh`** — AT command response parsers
  - `at_cmd COMMAND [TIMEOUT]` — wrapper around `at-send` with error detection
  - `parse_qeng_serving` — serving cell (rrc_state, rat, duplex, mcc, mnc,
    cell_id_hex, pci, earfcn, band, rsrp, rsrq, rssi, sinr, cqi, tx_power)
  - `parse_cops` — operator name
  - `parse_qnwinfo` — network type (FDD LTE, etc.)
  - `parse_qrsrp` — per-antenna RSRP (RX0–RX3)
  - `parse_qcainfo` — carrier aggregation (PCC + SCCs with per-CC metrics)
  - `parse_neighbours` — intra/inter-freq neighbour cells
  - `parse_qtemp` — 8 modem thermal sensors (mapped to schema column names)
  - `parse_qgdcnt` — modem byte counters (TX/RX)
  - `parse_cgcontrdp` — PDP context (CID, APN, WAN IP, DNS)
  - `collect_all_at()` — batch runner for all AT commands

#### Collectors (`bin/`)
- **`bin/collector-lte.sh`** — LTE telemetry collector
  - Runs all AT commands via `collect_all_at()`
  - Inserts into: `lte_samples` (with `raw_qeng` for forensics), `ca_samples`
    (FK to lte_samples), `neighbour_cells` (FK), `temp_samples`, `modem_counters`
  - Change-only insert for `pdp_context` (new row only when WAN IP changes)
  - Hex→decimal cell_id conversion

- **`bin/collector-system.sh`** — system metrics collector
  - `/proc/meminfo` parsing (free/used/total, swap)
  - `/proc/loadavg` (1/5/15 min), `/proc/uptime`
  - Disk usage for system and data partitions (percentage)
  - CPU temperature from `/sys/class/thermal` (if available)
  - wwan0 byte counters + error/drop counters from `/proc/net/dev`
  - Process health checks: quectel-CM, dnsmasq, httpd, smbd, crond
  - BusyBox-compatible `ps` grep (no `-C` flag)

- **`bin/collector-ping.sh`** — multi-target ping collector
  - Parses config `[ping] targets` multi-line format (label|address|count)
  - Gateway keyword auto-resolves to current default gateway
  - BusyBox ping compatible parsing (sent, received, loss_pct, RTT min/avg/max/mdev)

- **`bin/collector-vnstat.sh`** — vnstat traffic snapshot
  - `--oneline` parsing (day/month/total rx/tx)
  - Stores as event with severity=info for schema flexibility

#### Dispatcher (`bin/dispatcher.sh`)
- Mode-based scheduling (reads `[mode.*]` intervals from config)
- Per-collector interval tracking via `collector_state` table
- **Auto-switch logic:**
  - Night mode: automatic during configured `night_hours_start`/`night_hours_end`
  - Debug mode: on SINR drop below threshold for N consecutive samples
  - Debug mode: on cell change (`cell_id_hex` change) with configurable linger
  - Auto-recovery: back to normal after `debug_linger_sec` timeout
- **Event detection (7 types):**
  - `cell_change` — serving cell ID changed
  - `scc_drop` / `scc_up` — SCC disappeared/reappeared
  - `sinr_low` — sustained low SINR
  - `ping_loss` — average packet loss above threshold
  - `rrc_disconnect` — NOCONN state with active wwan0 interface
  - `reboot` — uptime reset detected
- **Retention:** daily purge (configurable days), VACUUM on configurable interval
- **Log rotation:** automatic on configurable max file size
- State tracking files in `state/` directory (persistent across reboots)

### Changed
- `bin/rmon` version bumped to 0.2.0, header updated
- `lib/README.md` updated with actual library descriptions
- `bin/README.md` updated with all v0.2 scripts

### Technical notes
- All code POSIX sh compatible (`#!/bin/sh`), tested against BusyBox 1.25.1
- All timestamps stored as unix epoch INTEGER (matching schema.sql)
- All column names match schema.sql exactly (verified against v0.1 schema)
- Foreign keys used: ca_samples.sample_id → lte_samples.id,
  neighbour_cells.sample_id → lte_samples.id
- collector_state updated with status (ok/error/skipped) and error messages
- Temporary files cleaned via trap handlers
- No bash/dash/zsh dependencies, integer-only sleep

## [0.1.1] - 2026-04-22

### Fixed
- Installer user detection no longer fails when `id` and `whoami` are missing
  from BusyBox (fallback chain: id → whoami → $USER → /proc/self/status)
- Smoke test no longer garbles modem output; CR/LF from AT responses is
  now normalised before parsing
- Modem identification in smoke test now correctly extracts model and firmware

### Added
- `.gitattributes` with LF line endings for shell scripts, configs, SQL, docs
- `.gitignore` excluding runtime directories and user config from git

## [0.1.0] - 2026-04-22

### Added
- Initial project skeleton
- `install.sh` with interactive environment checks
- `uninstall.sh` with backup option
- `schema.sql` with full data model (LTE, CA, neighbours, temperatures,
  system, ping, PDP context, modem counters, events, collector state)
- `bin/at-send` production AT command helper for Quectel EM12-G
- `bin/rmon` CLI skeleton (status, tail, mode, events, db info/reset/purge/vacuum, export)
- `config/config.ini.example` with normal/debug/night modes and auto-switch
- `README.md` with features, quick start, and architecture overview
- `docs/AT_COMMANDS.md` — tested command reference for Quectel EM12-G
- `docs/ARCHITECTURE.md` — design rationale and failure handling
- MIT License

### Confirmed working (EM12GPAR01A21M4G firmware)
- ATI, AT+QGMR, AT+COPS?, AT+QNWINFO, AT+CSQ
- AT+QENG="servingcell", AT+QENG="neighbourcell"
- AT+QCAINFO, AT+QRSRP
- AT+QCFG="nwscanseq", AT+QCFG="band"
- AT+QTEMP (needs ≥2s timeout)
- AT+QGDCNT? (modem byte counters)
- AT+CGCONTRDP=1 (PDP context details)

### Pending (next releases)
- `lib/common.sh`, `lib/config.sh`, `lib/db.sh`, `lib/at.sh`
- `bin/dispatcher.sh` — cron orchestrator with dynamic sampling
- `bin/collector-lte.sh`, `collector-system.sh`, `collector-ping.sh`, `collector-vnstat.sh`
- `web/index.html` — LAN dashboard
- Event detection logic
- Documentation: `TROUBLESHOOTING.md`, `PORTING.md`
