# bin/ — executable scripts

- `at-send` — AT command helper for Quectel EM12-G (v0.1)
- `rmon` — user-facing CLI: status, tail, mode, events, db, export (v0.2)
- `dispatcher.sh` — cron orchestrator with dynamic sampling and auto-switch (v0.2)
- `collector-lte.sh` — LTE telemetry collector: servingcell, CA, neighbours, temps (v0.2)
- `collector-system.sh` — system metrics: load, RAM, SWAP, disk, wwan0, processes (v0.2)
- `collector-ping.sh` — multi-target ping: RTT, loss, gateway auto-detect (v0.2)
- `collector-vnstat.sh` — vnstat traffic snapshots (v0.2)

Planned for v0.3–v0.4:

- `rmon tail lte --follow` (live tail)
- `rmon plot` (ASCII charts)
- `web/api.sh` (CGI → JSON for dashboard)
