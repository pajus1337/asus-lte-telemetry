# asus-lte-telemetry

Lightweight LTE modem and system monitoring for **ASUS 4G-AC86U** routers running
stock firmware with [Entware](https://github.com/Entware/Entware).

Collects signal quality, carrier aggregation, temperature, system and network
metrics from a built-in Quectel EM12-G modem, stores them in SQLite, and serves
a local LAN dashboard. Designed to run within the constraints of the stock ASUS
firmware (no Merlin, no custom kernel) with minimal RAM footprint.

## Features

- **LTE signal tracking** — RSRP, RSRQ, RSSI, SINR, CQI, TX power, per-antenna RSRP
- **Carrier aggregation monitoring** — PCC/SCC, band lock, SCC drop detection
- **Neighbour cell visibility** — intra-freq and inter-freq neighbours
- **Temperature monitoring** — 8 modem thermal sensors
- **System health** — uptime, load, RAM, SWAP, disk usage, process health
- **Network quality** — multi-target ping monitoring (configurable)
- **Transfer stats** — via vnstat on `wwan0`
- **Event detection** — cell changes, SCC drops, SINR degradation, reboots
- **Dynamic sampling** — configurable per-mode intervals (normal / debug / night / custom)
- **Auto-switch mode** — increases sampling rate on signal degradation
- **Local dashboard** — LAN-only HTML/CSS/JS SPA, no cloud, no telemetry, no external deps
- **Data retention** — 180 days by default, manual reset and purge supported

## Supported hardware

| Component | Model                              | Status   |
|-----------|------------------------------------|----------|
| Router    | ASUS 4G-AC86U                      | Primary  |
| CPU       | Broadcom BCM4906 (ARMv8 / aarch64) | Required |
| Modem     | Quectel EM12-G                     | Tested on firmware `EM12GPAR01A21M4G` |

Other Quectel modems (EM06, EP06, RM500Q) and other ASUS routers with Entware
may work with minor adjustments — see `docs/PORTING.md`.

## Requirements

- ASUS 4G-AC86U running stock firmware `3.0.0.4.382.x` or similar
- [Entware](https://github.com/Entware/Entware) installed and autostarted
  (see parent repo for installation guide)
- SSH access to the router as `admin`
- A persistent mount point on an EXT4 partition (recommended: USB stick labelled
  `System`, mounted at `/tmp/mnt/System` — this is the same partition used
  by Entware)
- Serial port `/dev/ttyUSB2` available for AT commands (not exclusively held
  by another process)

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

# Then on the router:
cd /tmp/mnt/System/asus-lte-telemetry
sh install.sh
```

The installer will:

1. Verify environment (Entware, architecture, modem presence, port accessibility)
2. Install required Entware packages (`sqlite3-cli`, `vnstat`, `coreutils-*`, etc.)
3. Optionally install `busybox-httpd` for the web dashboard
4. Create directory structure at `/tmp/mnt/System/asus-lte-telemetry/`
5. Initialise SQLite schema
6. Register the dispatcher with Entware init (`/opt/etc/init.d/S99asus-lte-telemetry`)
7. Run a smoke test

After install:

```sh
# Start the dispatcher background loop
/opt/etc/init.d/S99asus-lte-telemetry start

# Check collector status (after ~60 s)
rmon status

# Start the web dashboard
rmon web start
```

Removal:

```sh
sh /tmp/mnt/System/asus-lte-telemetry/uninstall.sh
```

## CLI

After installation, the `rmon` command becomes available:

```sh
rmon status                     # current collection state and DB size
rmon tail lte 20                # last 20 LTE samples
rmon tail lte --follow          # live tail (refreshes every 5 s)
rmon plot rsrp 40               # ASCII chart of last 40 RSRP samples
rmon diag                       # modem info, signal summary, recent errors
rmon mode debug                 # switch to high-frequency sampling
rmon mode normal                # back to normal
rmon web start                  # start HTTP dashboard (BusyBox httpd)
rmon web stop                   # stop the dashboard
rmon web status                 # show dashboard URL and running state
rmon export --last 24h          # export recent data as CSV
rmon events 20                  # last 20 events
rmon db info                    # row counts, time range, file size
rmon db reset                   # wipe DB (creates backup, prompts confirmation)
rmon db purge --older-than 30d
rmon help
```

## Dashboard

Once the dispatcher has run for a few minutes, start the dashboard and open the
URL in any browser on your LAN:

```sh
rmon web start
# Dashboard: http://192.168.50.1:8080/
```

The dashboard auto-refreshes every 30 s and shows:

- Signal quality (RSRP/RSRQ/SINR) with quality badges and RSRP sparkline
- Carrier aggregation (PCC + SCCs, per-carrier band/RSRP/SINR)
- System metrics (RAM, load, uptime, disk, CPU temp)
- Ping targets (loss%, RTT)
- Modem temperature sensors
- Collector health (last-run age and status for all four collectors)
- Last 5 events

Port is configurable in `config.ini` under `[dashboard] port` (default 8080).

## Data retention

- Raw samples: 180 days (configurable)
- Events: retained indefinitely (they are sparse)
- Automatic cleanup runs once per day
- Manual commands: `rmon db purge`, `rmon db reset`

## Architecture

```
      /opt/etc/init.d/S99asus-lte-telemetry
                 │  (60 s loop)
                 ▼
         bin/dispatcher.sh ──reads──▶ config.ini
                 │
                 ├──▶ collector-lte.sh    ──▶ AT commands  ──▶ SQLite
                 ├──▶ collector-system.sh ──▶ /proc        ──▶ SQLite
                 ├──▶ collector-ping.sh   ──▶ ping         ──▶ SQLite
                 └──▶ collector-vnstat.sh ──▶ vnstat       ──▶ SQLite
                                                  │
                                                  ▼
                                   BusyBox httpd (rmon web start)
                                        │
                                        ├──▶ web/index.html       (SPA dashboard)
                                        ├──▶ web/cgi-bin/api.cgi  (current state JSON)
                                        └──▶ web/cgi-bin/history.cgi (sparkline data)
```

## Project status

**v0.4.5** — stable, tested on ASUS 4G-AC86U with firmware `3.0.0.4.382.x` and
modem firmware `EM12GPAR01A21M4G`.

All collectors, the dispatcher, and the HTTP dashboard are implemented and
confirmed working. Breaking changes may still occur before v1.0.

## License

MIT — see `LICENSE`.

## Credits

Created by [@pajus1337](https://github.com/pajus1337).

Companion to [asus-4g-ac86u-entware-stock-firmware](https://github.com/pajus1337/asus-4g-ac86u-entware-stock-firmware)
which documents the underlying Entware setup on ASUS 4G-AC86U stock firmware.

AT command documentation based on Quectel EM12-G specifications and empirical
testing on firmware `EM12GPAR01A21M4G`.
