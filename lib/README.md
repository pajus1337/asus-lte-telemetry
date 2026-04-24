# lib/ — shared shell libraries

Sourced by collectors and dispatcher. Never executed directly.

- `common.sh` — logging (levelled, to file + stderr), locking (atomic mkdir,
  stale-lock detection, trap cleanup), error handling (`die`, `check_dependency`)
- `config.sh` — INI parser (`cfg_get`, `cfg_get_int`, `cfg_get_bool`),
  atomic INI writer (`cfg_set`), sampling config loader
- `db.sh` — SQLite helpers (`db_exec`, `db_query`, `db_scalar`,
  `db_transaction`), collector state tracking, retention purge, VACUUM
- `at.sh` — AT command wrapper and response parsers for all Quectel EM12-G
  commands: QENG servingcell, COPS, QNWINFO, QRSRP, QCAINFO, neighbourcell,
  QTEMP, QGDCNT, CGCONTRDP
