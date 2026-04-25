# asus-lte-telemetry

Lightweight LTE modem and system monitoring for **ASUS 4G-AC86U** routers running
stock firmware with [Entware](https://github.com/Entware/Entware).

Collects signal quality, carrier aggregation, neighbour cells, temperature, system
and network metrics from a built-in Quectel EM12-G modem, stores them in SQLite,
and serves a local LAN dashboard. Designed to run within the constraints of stock
ASUS firmware (no Merlin, no custom kernel), cooperating with the original firmware
rather than replacing it.

## Features

- **LTE signal tracking** — RSRP, RSRQ, RSSI, SINR, CQI, TX power, per-antenna RSRP (4 RX paths)
- **Carrier aggregation monitoring** — PCC/SCC band, RSRP/RSRQ/SINR per carrier, SCC drop detection
- **Neighbour cell panel** — intra-freq, inter-freq, WCDMA, GSM neighbours with RSRP colouring
- **Band locking** — restrict modem to specific LTE bands via `rmon band lock`; adjustable from web UI
- **Temperature monitoring** — 8 modem thermal sensors (Quectel QTEMP)
- **System health** — uptime, load, RAM, SWAP, disk usage, process health
- **Network quality** — multi-target ping monitoring with configurable targets
- **Transfer stats** — via vnstat on `wwan0` (optional)
- **Event detection** — cell changes, SCC drops, SINR degradation, ping loss, reboots
- **Dynamic sampling** — normal / debug / night modes with configurable intervals
- **Auto-mode switching** — increases sampling rate on signal degradation or cell change
- **Web dashboard** — LAN-only tab SPA (Overview / Signal / Events / Config); 24h charts; no cloud, no external deps
- **Web command interface** — band lock/unlock, sampling mode switch directly from browser
- **Data retention** — 180 days by default; manual reset and purge supported
- **Firmware-cooperative** — uses the same AT port lock (`flock /tmp/at_cmd_lock`) as ASUS firmware; auto-detects active AT port from `nvram`

## Supported hardware

| Component | Model                              | Status   |
|-----------|------------------------------------|----------|
| Router    | ASUS 4G-AC86U                      | Tested   |
| CPU       | Broadcom BCM4906 (ARMv8 / aarch64) | Required |
| Modem     | Quectel EM12-G                     | Tested on `EM12GPAR01A21M4G` |
| Firmware  | ASUS stock `3.0.0.4.382.x`         | No Merlin required |

Other Quectel modems (EM06, EP06) and ASUS routers with Entware may work with minor adjustments.

## Requirements

- ASUS 4G-AC86U with stock firmware `3.0.0.4.382.x` or similar
- [Entware](https://github.com/Entware/Entware) installed and autostarted
- SSH access (router default: port 666)
- Persistent EXT4 mount point — recommended: USB stick labelled `System` at `/tmp/mnt/System`
- Entware packages (installed automatically by `install.sh`):
  `sqlite3-cli`, `lighttpd`, `lighttpd-mod-cgi`, `coreutils-sleep`, `coreutils-mktemp`,
  `coreutils-date`, `coreutils-stat`, `coreutils-timeout`, `psmisc`, `lsof`

## Quick start

```sh
# SSH into the router
ssh -p 666 admin@192.168.50.1
```

**Option A — clone from GitHub** (requires git on the router):

```sh
opkg install git git-http
cd /tmp/mnt/System
git clone https://github.com/pajus1337/asus-lte-telemetry.git
cd asus-lte-telemetry
sh install.sh
```

**Option B — scp from your workstation**:

```sh
# On your PC:
git clone https://github.com/pajus1337/asus-lte-telemetry.git
scp -P 666 -r asus-lte-telemetry admin@192.168.50.1:/tmp/mnt/System/

# On the router:
cd /tmp/mnt/System/asus-lte-telemetry
sh install.sh
```

The installer will:

1. Verify environment (Entware, architecture, modem port, binary availability)
2. Install required Entware packages
3. Ask whether to auto-start the dashboard on every boot
4. Create directory structure at `/tmp/mnt/System/asus-lte-telemetry/`
5. Initialise SQLite schema (WAL mode)
6. Register the dispatcher loop with Entware init (`/opt/etc/init.d/S99asus-lte-telemetry`)
7. Run a smoke test

After install:

```sh
# Start dispatcher (and dashboard, if auto-start was enabled during install)
/opt/etc/init.d/S99asus-lte-telemetry start

# Check collector status (after ~60 s)
rmon status
```

If you chose **auto-start dashboard** during installation, the dashboard is already
running after the `S99 start` command above. If not, start it manually:

```sh
rmon web start
# Open http://192.168.50.1:8080/ in any browser on your LAN
```

Removal:

```sh
sh /tmp/mnt/System/asus-lte-telemetry/uninstall.sh
```

## CLI

The `rmon` command is available after installation:

```sh
rmon status                       # collector state, DB size, last-run times
rmon tail lte 20                  # last 20 LTE samples
rmon tail lte --follow            # live tail, refreshes every 5 s
rmon plot rsrp 40                 # ASCII chart of last 40 RSRP samples
rmon diag                         # modem info, signal summary, CA status, recent errors
rmon mode debug                   # switch to high-frequency sampling
rmon mode normal                  # back to normal
rmon band                         # show active LTE bands (live AT query)
rmon band lock B1,B3,B20          # restrict modem to these bands (immediate)
rmon band lock B1,B3 --reboot     # restrict, takes effect after modem reboot
rmon band unlock                  # restore original full-band config
rmon web start                    # start dashboard (lighttpd on port 8080)
rmon web stop
rmon web status
rmon export --last 24h            # export recent data as CSV to stdout
rmon events 20                    # last 20 events
rmon db info                      # row counts, time range, file size
rmon db reset                     # wipe DB (creates backup, prompts confirmation)
rmon db purge --older-than 30d
rmon help
```

### Band locking

`rmon band lock` restricts the modem to the specified bands via `AT+QCFG="band"`.
The original full-band mask is saved automatically and can be restored with
`rmon band unlock`. The stock ASUS firmware does **not** reset the band configuration
automatically, so locked bands persist across router reboots.

Immediate effect (`--reboot` not set) causes a brief LTE reconnect (~10-30s).
`quectel-CM` handles the reconnect transparently. Use `--reboot` to defer the
change to the next modem power cycle with zero impact on the current connection.

```sh
# Lock to B1 + B3 (common European FDD aggregation pair)
rmon band lock B1,B3

# Check result
rmon band
```

## Dashboard

Start the dashboard and open the URL in any browser on your LAN:

```sh
rmon web start
# http://192.168.50.1:8080/
```

The dashboard auto-refreshes every 30 s. It is organised into four tabs:

| Tab | Contents |
|-----|----------|
| **Overview** | Signal summary (RSRP/RSRQ/RSSI/SINR, quality badges, CellMapper link), CA status, system metrics, ping, modem temperatures, collector health |
| **Signal** | Neighbour cells table (intra/inter-freq, WCDMA, GSM) with RSRP colouring; 24-hour chart with metric selector (RSRP/SINR/RSRQ/RSSI) and time range (6h/24h/3d/7d) |
| **Events** | Timeline of detected events (cell change, SCC drop, SINR alert, ping loss, reboot…) |
| **Config** | Read-only view of active config.ini settings; **Band Control** — checkbox grid for selecting active LTE bands, lock/unlock buttons, reboot-only option |

Port is configurable in `config.ini` under `[dashboard] port` (default 8080).

## Architecture

```
/opt/etc/init.d/S99asus-lte-telemetry
            │  (60 s loop)
            ▼
    bin/dispatcher.sh ──reads──▶ config.ini
            │
            ├──▶ collector-lte.sh    ──▶ AT commands ──▶ SQLite (6 tables)
            ├──▶ collector-system.sh ──▶ /proc        ──▶ SQLite (2 tables)
            ├──▶ collector-ping.sh   ──▶ ping         ──▶ SQLite (1 table)
            └──▶ collector-vnstat.sh ──▶ vnstat       ──▶ events table

lighttpd (Entware, rmon web start)
    ├──▶ web/index.html          (tab SPA: Overview/Signal/Events/Config)
    ├──▶ web/cgi-bin/api.cgi     (read-only JSON: signal, CA, neighbours, system…)
    ├──▶ web/cgi-bin/history.cgi (time-range chart data)
    └──▶ web/cgi-bin/cmd.cgi     (write commands: band lock/unlock, mode change)

bin/at-send
    ├── flock -x /tmp/at_cmd_lock  (same lock as ASUS firmware modem_at.sh)
    ├── port: nvram get usb_modem_act_int → fallback /dev/ttyUSB3
    ├── 0.2 s buffer drain
    └── echo-based response filtering
```

### Firmware coexistence

The ASUS stock firmware accesses the modem AT port (typically `/dev/ttyUSB3`) via
its own `modem_at.sh` script, serialised with `flock -x /tmp/at_cmd_lock`. This
project uses the **same lock**, so both never access the port simultaneously.

The firmware also reads the active AT port node from `nvram get usb_modem_act_int`
— `bin/at-send` does the same, so it follows any port reassignment automatically.

`AT+QCFG="band"` (band config) is written by `rmon band lock/unlock` and **is not
touched** by the firmware's automatic routines — only by an explicit mode change
in the router UI, which modifies `nwscanmode`, not the band bitmask.

## Data model

13 SQLite tables (all timestamps are unix epoch INTEGER):

| Table | Contents |
|-------|----------|
| `lte_samples` | Serving cell: RRC state, RAT, band, RSRP/RSRQ/RSSI/SINR, CQI, TX power, operator, per-antenna RSRP |
| `ca_samples` | Per-carrier CA data (FK → lte_samples) |
| `neighbour_cells` | Intra/inter-freq neighbours (FK → lte_samples) |
| `temp_samples` | 8 modem thermal sensors |
| `system_samples` | Uptime, load, RAM, SWAP, disk, CPU temp, wwan0 counters |
| `process_health` | quectel-CM, dnsmasq, httpd, smbd, crond alive flags |
| `ping_samples` | Per-target RTT and loss stats |
| `pdp_context` | APN, WAN IP, DNS (inserted on change only) |
| `modem_counters` | TX/RX byte counters from AT+QGDCNT |
| `events` | Detected events with type, severity, JSON details |
| `collector_state` | Per-collector last-run timestamp and status |
| `device_info` | Modem model, IMEI, firmware, band config (at install) |
| `meta` | Schema version, creation timestamp |

## Project status

**v0.5.0** — stable, tested on ASUS 4G-AC86U with firmware `3.0.0.4.382.x` and
modem firmware `EM12GPAR01A21M4G_02.001.02.001`.

All collectors, dispatcher, HTTP dashboard, and band locking are implemented and
confirmed working. Breaking changes may still occur before v1.0.

## License

MIT — see `LICENSE`.

## Credits

Created by [@pajus1337](https://github.com/pajus1337).

Companion repository: [asus-4g-ac86u-entware-stock-firmware](https://github.com/pajus1337/asus-4g-ac86u-entware-stock-firmware)
— documents the underlying Entware setup on ASUS 4G-AC86U stock firmware.

AT command documentation based on Quectel EM12-G specifications and empirical
testing on firmware `EM12GPAR01A21M4G_02.001.02.001`.
