# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
