# TROUBLESHOOTING

Common issues and how to fix them on ASUS 4G-AC86U (stock firmware + Entware).

---

## Quick diagnostics

```sh
# Overall status
rmon status

# Last 30 lines of main log
tail -30 /tmp/mnt/System/asus-lte-telemetry/logs/monitor.log

# Dispatcher loop running?
ps w | grep "[d]ispatcher"

# Dashboard running?
rmon web status
```

---

## Dispatcher not starting

**Symptom:** `rmon status` shows all collectors as `never` or very old timestamps.

**Check the dispatcher log:**
```sh
tail -30 /tmp/mnt/System/asus-lte-telemetry/logs/dispatcher.log
```

**Multiple loops stacked up** (each `S99 start` adds one loop):
```sh
pkill -f "while true"
pkill -f dispatcher.sh
sleep 2
/opt/etc/init.d/S99asus-lte-telemetry start
```

**sqlite3 not found at runtime:**
The dispatcher uses `/opt/bin/sqlite3`. If Entware is not mounted yet when the init script fires, sqlite3 won't be available. Fix: ensure `/opt` is mounted before S99 runs, or add a startup delay loop.

**Init script not installed:**
```sh
ls -la /opt/etc/init.d/S99asus-lte-telemetry
# If missing, re-run install.sh step 6:
sh /tmp/mnt/System/asus-lte-telemetry/install.sh
```

---

## LTE collector errors

**Symptom:** `lte [error]` in `rmon status`, or "AT collection failed" in monitor.log.

**Check which ttyUSB ports are busy:**
```sh
ls -la /proc/*/fd 2>/dev/null | grep ttyUSB
# or
lsof /dev/ttyUSB* 2>/dev/null
```

**ttyUSB2 is held by quectel-CM** — always. Do NOT use it. The correct port is `/dev/ttyUSB3`:
```sh
grep at_port /tmp/mnt/System/asus-lte-telemetry/config/config.ini
# Should show: at_port = /dev/ttyUSB3
```

**Router firmware polls ttyUSB3 occasionally** — this is normal. The collector handles it by draining the buffer before capture and filtering to post-echo responses.

**Test AT manually:**
```sh
/tmp/mnt/System/asus-lte-telemetry/bin/at-send "ATI" 2
```
Expected: lines ending with `OK`.

**False ERROR responses:** The router OS may fire AT commands on ttyUSB3 whose `ERROR` responses appear in our capture window. The collector ignores these if `OK` is also present. Only a response with `ERROR` and NO `OK` is treated as a failure.

---

## Dashboard not loading (403 or blank)

**Check if lighttpd is running:**
```sh
rmon web status
ps w | grep "[l]ighttpd"
```

**Start the dashboard:**
```sh
rmon web start
```

**403 Forbidden on root URL** — means `index-file.names` is missing from lighttpd config. Fix: `rmon web stop && rmon web start` (config is regenerated each time).

**lighttpd binary not found:**
```sh
[ -x /opt/sbin/lighttpd ] && echo "found" || echo "MISSING"
opkg install lighttpd lighttpd-mod-cgi
```

**Port already in use:**
```sh
rmon web stop
# wait a moment
rmon web start
```

**Check httpd error log:**
```sh
tail -20 /tmp/mnt/System/asus-lte-telemetry/logs/httpd-error.log
```

---

## CGI errors (500 Internal Server Error or empty JSON)

**Check CGI permissions:**
```sh
ls -la /tmp/mnt/System/asus-lte-telemetry/web/cgi-bin/
# All .cgi files must be executable (-rwxr-xr-x)
chmod +x /tmp/mnt/System/asus-lte-telemetry/web/cgi-bin/*.cgi
```

**Test CGI directly from shell:**
```sh
QUERY_STRING="" sh /tmp/mnt/System/asus-lte-telemetry/web/cgi-bin/api.cgi
```
Expected: a JSON object starting with `Content-Type:`.

**awk errors in CGI** — if you see `awk: cmd. line:N: Unexpected token`, it's a BusyBox awk incompatibility. Function definitions must be at the top level, not inside `{ }` rule blocks.

**Database unavailable:**
```sh
[ -f /tmp/mnt/System/asus-lte-telemetry/db/metrics.db ] && echo "DB exists" || echo "DB MISSING"
[ -x /opt/bin/sqlite3 ] && echo "sqlite3 ok" || echo "sqlite3 MISSING"
```

---

## Database issues

**Corrupt database:**
```sh
/opt/bin/sqlite3 /tmp/mnt/System/asus-lte-telemetry/db/metrics.db "PRAGMA integrity_check;"
```

**Rebuild database (loses all data):**
```sh
rm /tmp/mnt/System/asus-lte-telemetry/db/metrics.db
/opt/bin/sqlite3 /tmp/mnt/System/asus-lte-telemetry/db/metrics.db \
    < /tmp/mnt/System/asus-lte-telemetry/schema.sql
```

**WAL output on stdout during schema apply** — fixed in v0.4.7. If you see `wal` printed to terminal during install, add `>/dev/null` to the sqlite3 call.

**Storage full:**
```sh
df -h /tmp/mnt/System/
# Reduce retention:
# [retention] days = 30  in config.ini
```

---

## History chart shows no data

The chart queries `lte_samples` for the selected time window. If data is missing:

```sh
/opt/bin/sqlite3 /tmp/mnt/System/asus-lte-telemetry/db/metrics.db \
    "SELECT COUNT(*), MIN(ts), MAX(ts) FROM lte_samples;"
```

- `COUNT(*)` = 0 → LTE collector never ran successfully
- `MAX(ts)` is old → dispatcher stopped; restart with `S99 start`
- Data exists but chart is blank → check browser console for JS errors

---

## vnstat not collecting

**Symptom:** `vnstat [skipped]` in collector status.

vnstat is optional. To enable:
```sh
opkg install vnstat
vnstat --create -i wwan0
# Restart dispatcher so it picks up vnstat
/opt/etc/init.d/S99asus-lte-telemetry restart
```

---

## Checking logs

| Log file | Contents |
|----------|----------|
| `logs/monitor.log` | Collector and dispatcher output (via `log()`) |
| `logs/dispatcher.log` | Dispatcher loop stdout/stderr (nohup redirect) |
| `logs/httpd-error.log` | lighttpd errors |

```sh
# Live tail of monitor log
rmon tail

# Last 50 lines of dispatcher log
tail -50 /tmp/mnt/System/asus-lte-telemetry/logs/dispatcher.log
```
