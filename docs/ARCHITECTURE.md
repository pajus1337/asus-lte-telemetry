# Architecture

## Overview

```
              +----------------+
              |  cron / init   |   (every 60 seconds)
              +--------+-------+
                       |
                       v
              +--------+-------+
              |  dispatcher.sh |
              +--------+-------+
                       |
                       |  reads config.ini, checks last_run_ts per collector
                       |  and invokes whichever are due
                       |
    +------------------+------------------+------------------+
    |                  |                  |                  |
    v                  v                  v                  v
+----+----+      +-----+-----+      +-----+-----+      +-----+-----+
| lte.sh  |      | system.sh |      |  ping.sh  |      | vnstat.sh |
+----+----+      +-----+-----+      +-----+-----+      +-----+-----+
     |                 |                  |                  |
     |  at-send        |  /proc, df,      |  ping(1)          |  vnstat --json
     |                 |  ifconfig        |                   |
     v                 v                  v                   v
+----+-----------------+------------------+-------------------+----+
|                      SQLite (metrics.db)                         |
|   lte_samples, ca_samples, neighbour_cells, temp_samples,        |
|   system_samples, ping_samples, pdp_context, events, meta ...    |
+-------------------------------+----------------------------------+
                                |
                                v
                         +------+------+
                         |  web/api.sh |  (CGI, called by dashboard)
                         +------+------+
                                |
                                v
                          +-----+-----+
                          |  browser  |  LAN only
                          +-----------+
```

## Key design decisions

### Stock firmware constraints

On the ASUS 4G-AC86U stock firmware, the following do NOT work:

- `jffs2_scripts` nvram setting (doesn't persist)
- `/jffs/scripts/post-mount`
- `/jffs/scripts/services-start`
- `cron_jobs` nvram (saves but isn't loaded)
- `script_usbmount` / `script_usbhotplug` nvram

Instead, the project relies on:

- The `asusware.arm` mechanism (firmware auto-mounts the `asusware.arm`
  directory from the EXT4 partition as `/opt`)
- Entware's `/opt/etc/init.d/S*` scripts, which ARE executed at boot
- A persistent dispatcher process that wakes up every minute

### Single dispatcher, multiple collectors

Rather than registering each collector as a separate cron job, a single
dispatcher runs every minute and decides which collectors are due. Benefits:

- Only one cron-like entry to manage
- Dynamic sampling rates without rewriting cron
- Sub-minute intervals possible via in-dispatcher sleep loops
- Single place for locking and error handling

### SQLite over CSV/RRD

- Structured queries (events, aggregations, joins)
- Single file, easy to back up / transfer
- Low overhead on modern hardware (Entware's sqlite3 is ~1MB)
- WAL mode enables concurrent reads during writes

### EXT4 over NTFS for data

The persistent storage device is assumed to have two partitions:

- `System` (EXT4) — small, holds Entware, configs, database, logs
- `Data` (NTFS, large) — optional, Samba share, media

All `asus-lte-telemetry` files live on EXT4 because:

- `ntfs-3g` consumes CPU on every small write
- NTFS handling of many small transactions is poor
- EXT4 supports sqlite WAL reliably
- Backup procedures can target the System partition specifically

## Process lifecycle

### Boot sequence

1. Firmware mounts the USB stick
2. Firmware auto-mounts `asusware.arm` from EXT4 as `/opt`
3. Entware init scripts run: `/opt/etc/init.d/S*`
4. `S99asus-lte-telemetry` starts the dispatcher loop
5. Dispatcher begins polling collectors every minute

### Normal runtime

1. Dispatcher wakes every 60 seconds
2. Reads `config.ini`, determines active mode
3. Checks `collector_state` table for each collector's last run
4. Runs any collector whose interval has elapsed
5. Each collector writes to its own tables and updates `collector_state`
6. Dispatcher evaluates events (cell changes, SCC drops, etc.)
7. Retention cleanup runs once per day
8. VACUUM runs once per week

### Failure handling

- Lock files in `/tmp/asus-lte-telemetry/` prevent overlapping runs
- Collector errors are logged to `collector_state.last_error` and `events`
- Dispatcher never exits on collector failure — moves on to next collector
- On modem unavailability, LTE collector logs an event but does not crash
