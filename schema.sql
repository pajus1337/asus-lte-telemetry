-- =============================================================================
-- asus-lte-telemetry: SQLite schema
-- =============================================================================
-- Stores LTE modem telemetry, system metrics, ping quality, transfer stats,
-- and detected events. Designed for SQLite 3.x (tested on 3.51.2).
--
-- All timestamps are unix epoch seconds (INTEGER).
-- Retention is enforced by the dispatcher via scheduled DELETE + VACUUM.
-- =============================================================================

PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;

-- -----------------------------------------------------------------------------
-- Metadata: schema version and device info
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS meta (
    key         TEXT PRIMARY KEY,
    value       TEXT,
    updated_at  INTEGER
);

INSERT OR IGNORE INTO meta (key, value, updated_at) VALUES
    ('schema_version', '1',       strftime('%s','now')),
    ('created_at',     strftime('%s','now'), strftime('%s','now'));

-- -----------------------------------------------------------------------------
-- Device info: populated once on install, updated on firmware/IMEI changes
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS device_info (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    ts               INTEGER NOT NULL,
    modem_model      TEXT,        -- e.g. EM12
    modem_revision   TEXT,        -- AT+QGMR full firmware string
    modem_imei       TEXT,
    router_firmware  TEXT,
    nwscanseq        TEXT,        -- AT+QCFG="nwscanseq" value
    band_config      TEXT,        -- AT+QCFG="band" raw value
    notes            TEXT
);

-- -----------------------------------------------------------------------------
-- LTE serving cell samples (from AT+QENG="servingcell")
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS lte_samples (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    ts           INTEGER NOT NULL,

    -- From +QENG: "servingcell"
    rrc_state    TEXT,         -- NOCONN | CONNECT | SEARCH | LIMSRV
    rat          TEXT,         -- LTE | NR5G | WCDMA | GSM
    duplex       TEXT,         -- FDD | TDD
    mcc          INTEGER,
    mnc          INTEGER,
    cell_id_hex  TEXT,
    cell_id_dec  INTEGER,
    pci          INTEGER,
    earfcn       INTEGER,
    band         INTEGER,
    bw_ul_code   INTEGER,      -- 0=1.4MHz, 1=3MHz, 2=5MHz, 3=10MHz, 4=15MHz, 5=20MHz
    bw_dl_code   INTEGER,
    tac_hex      TEXT,
    rsrp         INTEGER,
    rsrq         INTEGER,
    rssi         INTEGER,
    sinr         INTEGER,
    cqi          INTEGER,      -- may be NULL if modem returns "-"
    tx_power     INTEGER,

    -- From +COPS
    operator     TEXT,

    -- From +QNWINFO
    net_type     TEXT,         -- e.g. "FDD LTE"

    -- Per-antenna RSRP from +QRSRP (4 RX paths)
    rsrp_rx0     INTEGER,
    rsrp_rx1     INTEGER,
    rsrp_rx2     INTEGER,
    rsrp_rx3     INTEGER,

    -- Raw QENG line for debugging / forensics
    raw_qeng     TEXT
);

CREATE INDEX IF NOT EXISTS idx_lte_ts       ON lte_samples(ts);
CREATE INDEX IF NOT EXISTS idx_lte_cell     ON lte_samples(cell_id_hex);
CREATE INDEX IF NOT EXISTS idx_lte_band     ON lte_samples(band);

-- -----------------------------------------------------------------------------
-- Carrier Aggregation component carriers (from AT+QCAINFO)
-- One row per CC (PCC + SCC...) per sample.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ca_samples (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    sample_id    INTEGER NOT NULL,
    ts           INTEGER NOT NULL,
    cc_type      TEXT NOT NULL,    -- "pcc" | "scc"
    cc_index     INTEGER,          -- 1 for PCC, 2+ for SCCs
    earfcn       INTEGER,
    bandwidth    INTEGER,          -- 25=5MHz, 50=10MHz, 75=15MHz, 100=20MHz
    band         INTEGER,
    pci          INTEGER,
    rsrp         INTEGER,
    rsrq         INTEGER,
    rssi         INTEGER,
    sinr         INTEGER,
    scc_state    TEXT,             -- "DL" | "DL+UL" | NULL for PCC
    FOREIGN KEY (sample_id) REFERENCES lte_samples(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_ca_ts        ON ca_samples(ts);
CREATE INDEX IF NOT EXISTS idx_ca_sample    ON ca_samples(sample_id);
CREATE INDEX IF NOT EXISTS idx_ca_type      ON ca_samples(cc_type);

-- -----------------------------------------------------------------------------
-- Neighbour cells (from AT+QENG="neighbourcell")
-- Variable number of rows per sample.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS neighbour_cells (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    sample_id     INTEGER NOT NULL,
    ts            INTEGER NOT NULL,
    neighbour_type TEXT,           -- "intra" | "inter" | "wcdma" | "gsm"
    rat           TEXT,            -- LTE | WCDMA | GSM
    earfcn        INTEGER,
    pci           INTEGER,
    rsrq          INTEGER,
    rsrp          INTEGER,
    rssi          INTEGER,
    sinr          INTEGER,
    FOREIGN KEY (sample_id) REFERENCES lte_samples(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_neigh_ts     ON neighbour_cells(ts);
CREATE INDEX IF NOT EXISTS idx_neigh_sample ON neighbour_cells(sample_id);
CREATE INDEX IF NOT EXISTS idx_neigh_pci    ON neighbour_cells(pci);

-- -----------------------------------------------------------------------------
-- Modem temperatures (from AT+QTEMP)
-- Pivoted for fast queries.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS temp_samples (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    ts                INTEGER NOT NULL,
    xo_therm_buf      INTEGER,
    mdm_case_therm    INTEGER,
    pa_therm1         INTEGER,
    tsens_tz_sensor0  INTEGER,
    tsens_tz_sensor1  INTEGER,
    tsens_tz_sensor2  INTEGER,
    tsens_tz_sensor3  INTEGER,
    tsens_tz_sensor4  INTEGER
);

CREATE INDEX IF NOT EXISTS idx_temp_ts ON temp_samples(ts);

-- -----------------------------------------------------------------------------
-- System metrics
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS system_samples (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    ts            INTEGER NOT NULL,
    uptime_sec    INTEGER,
    load_1min     REAL,
    load_5min     REAL,
    load_15min    REAL,
    mem_free_kb   INTEGER,
    mem_used_kb   INTEGER,
    mem_total_kb  INTEGER,
    swap_used_kb  INTEGER,
    swap_total_kb INTEGER,
    disk_system_used_pct  INTEGER,
    disk_data_used_pct    INTEGER,
    cpu_temp      INTEGER,          -- from /sys/class/thermal if available
    wwan0_rx_bytes INTEGER,
    wwan0_tx_bytes INTEGER,
    wwan0_rx_errors INTEGER,
    wwan0_tx_errors INTEGER,
    wwan0_rx_dropped INTEGER,
    wwan0_tx_dropped INTEGER
);

CREATE INDEX IF NOT EXISTS idx_sys_ts ON system_samples(ts);

-- -----------------------------------------------------------------------------
-- Process health
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS process_health (
    id                 INTEGER PRIMARY KEY AUTOINCREMENT,
    ts                 INTEGER NOT NULL,
    quectel_cm_alive   INTEGER,      -- 0|1
    dnsmasq_alive      INTEGER,
    httpd_alive        INTEGER,
    smbd_alive         INTEGER,
    crond_alive        INTEGER
);

CREATE INDEX IF NOT EXISTS idx_proc_ts ON process_health(ts);

-- -----------------------------------------------------------------------------
-- Ping monitoring (multiple targets per run)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ping_samples (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    ts            INTEGER NOT NULL,
    target        TEXT NOT NULL,      -- "1.1.1.1", "8.8.8.8", "gateway", etc.
    target_label  TEXT,                -- human-friendly label
    sent          INTEGER,
    received      INTEGER,
    loss_pct      REAL,
    rtt_min_ms    REAL,
    rtt_avg_ms    REAL,
    rtt_max_ms    REAL,
    rtt_mdev_ms   REAL
);

CREATE INDEX IF NOT EXISTS idx_ping_ts      ON ping_samples(ts);
CREATE INDEX IF NOT EXISTS idx_ping_target  ON ping_samples(target);

-- -----------------------------------------------------------------------------
-- PDP context changes (from AT+CGCONTRDP=1)
-- Only inserts when something changes (rare).
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pdp_context (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    ts            INTEGER NOT NULL,
    cid           INTEGER,
    apn           TEXT,
    wan_ip        TEXT,
    dns_primary   TEXT,
    dns_secondary TEXT
);

CREATE INDEX IF NOT EXISTS idx_pdp_ts ON pdp_context(ts);
CREATE INDEX IF NOT EXISTS idx_pdp_ip ON pdp_context(wan_ip);

-- -----------------------------------------------------------------------------
-- Modem data counters (from AT+QGDCNT?, optional)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS modem_counters (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    ts            INTEGER NOT NULL,
    tx_bytes      INTEGER,
    rx_bytes      INTEGER
);

CREATE INDEX IF NOT EXISTS idx_qgdcnt_ts ON modem_counters(ts);

-- -----------------------------------------------------------------------------
-- Events: detected changes and anomalies
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS events (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    ts          INTEGER NOT NULL,
    event_type  TEXT NOT NULL,
    severity    TEXT,                 -- info | warning | critical
    details     TEXT,                 -- JSON blob with event-specific data
    sample_id   INTEGER                -- optional reference to related lte_sample
);

CREATE INDEX IF NOT EXISTS idx_events_ts       ON events(ts);
CREATE INDEX IF NOT EXISTS idx_events_type     ON events(event_type);
CREATE INDEX IF NOT EXISTS idx_events_severity ON events(severity);

-- Event types enumeration (documented here for reference):
--   cell_change      -- serving cell ID changed
--   scc_drop         -- SCC disappeared between samples
--   scc_up           -- SCC reappeared
--   sinr_low         -- SINR < threshold for N consecutive samples
--   rrc_disconnect   -- RRC stuck in NOCONN with active wwan0
--   ping_loss        -- ping loss > threshold
--   reboot           -- detected via uptime reset
--   collector_error  -- a collector failed to run

-- -----------------------------------------------------------------------------
-- Collector state: last run timestamps for dispatcher scheduling
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS collector_state (
    collector_name TEXT PRIMARY KEY,
    last_run_ts    INTEGER,
    last_status    TEXT,         -- ok | error | skipped
    last_error     TEXT
);

-- -----------------------------------------------------------------------------
-- Initial state for all known collectors
-- -----------------------------------------------------------------------------
INSERT OR IGNORE INTO collector_state (collector_name, last_run_ts, last_status) VALUES
    ('lte',     0, 'never'),
    ('system',  0, 'never'),
    ('ping',    0, 'never'),
    ('vnstat',  0, 'never');
