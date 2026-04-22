# lib/ — shared shell libraries

This directory contains shell functions sourced by the collectors and
dispatcher. Files will be added in v0.2:

- `common.sh` — logging, locking, error handling
- `config.sh` — INI parser
- `db.sh` — SQLite helpers
- `at.sh` — AT response parsers (QENG, QCAINFO, QRSRP, etc.)
