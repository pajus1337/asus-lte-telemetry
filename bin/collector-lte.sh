#!/bin/sh
# =============================================================================
# bin/collector-lte.sh — LTE telemetry collector
# =============================================================================
# Part of: asus-lte-telemetry
# https://github.com/pajus1337/asus-lte-telemetry
#
# Collects: servingcell, COPS, QNWINFO, QRSRP, QCAINFO, neighbours,
#           QTEMP, QGDCNT, CGCONTRDP
#
# Inserts into (schema.sql):
#   lte_samples, ca_samples, neighbour_cells, temp_samples,
#   modem_counters, pdp_context
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "${SCRIPT_DIR}/lib/common.sh"
. "${SCRIPT_DIR}/lib/config.sh"
. "${SCRIPT_DIR}/lib/db.sh"
. "${SCRIPT_DIR}/lib/at.sh"

COMPONENT="lte"

# ---------------------------------------------------------------------------
# Main collection logic
# ---------------------------------------------------------------------------
collect_lte() {
    log_info "$COMPONENT" "Starting LTE collection"

    if ! collect_all_at; then
        log_error "$COMPONENT" "AT collection failed"
        db_update_collector_state "$COMPONENT" "error" "AT collection failed"
        return 1
    fi

    _ts=$(now_epoch)

    # -----------------------------------------------------------------------
    # 1. lte_samples — insert main row, then get its rowid for FK references
    # -----------------------------------------------------------------------
    # cell_id_dec: convert hex to decimal if available
    _cell_id_dec=""
    if [ -n "$AT_CELL_ID_HEX" ]; then
        _cell_id_dec=$(printf '%d' "0x${AT_CELL_ID_HEX}" 2>/dev/null || echo "")
    fi

    _lte_sql="INSERT INTO lte_samples (
        ts, rrc_state, rat, duplex, mcc, mnc,
        cell_id_hex, cell_id_dec, pci, earfcn, band,
        bw_dl_code, bw_ul_code,
        rsrp, rsrq, rssi, sinr, cqi, tx_power,
        operator, net_type,
        rsrp_rx0, rsrp_rx1, rsrp_rx2, rsrp_rx3,
        raw_qeng
    ) VALUES (
        ${_ts},
        $(db_quote "$AT_RRC_STATE"), $(db_quote "$AT_RAT"), $(db_quote "$AT_DUPLEX"),
        ${AT_MCC:-NULL}, ${AT_MNC:-NULL},
        $(db_quote "$AT_CELL_ID_HEX"), ${_cell_id_dec:-NULL},
        ${AT_PCI:-NULL}, ${AT_EARFCN:-NULL}, ${AT_BAND:-NULL},
        ${AT_BW_DL_CODE:-NULL}, ${AT_BW_UL_CODE:-NULL},
        ${AT_RSRP:-NULL}, ${AT_RSRQ:-NULL}, ${AT_RSSI:-NULL},
        ${AT_SINR:-NULL}, ${AT_CQI:-NULL}, ${AT_TX_POWER:-NULL},
        $(db_quote "$AT_OPERATOR"), $(db_quote "$AT_NET_TYPE"),
        ${AT_RSRP_RX0:-NULL}, ${AT_RSRP_RX1:-NULL},
        ${AT_RSRP_RX2:-NULL}, ${AT_RSRP_RX3:-NULL},
        $(db_quote "$AT_RAW_QENG")
    );"

    db_exec "$_lte_sql"
    if [ $? -ne 0 ]; then
        log_error "$COMPONENT" "Failed to insert lte_samples"
        db_update_collector_state "$COMPONENT" "error" "lte_samples insert failed"
        return 1
    fi

    _sample_id=$(db_last_insert_rowid)
    log_debug "$COMPONENT" "lte_samples inserted, id=${_sample_id}"

    # -----------------------------------------------------------------------
    # 2. ca_samples — one row per carrier (FK: sample_id)
    # -----------------------------------------------------------------------
    if [ -f /tmp/_qcainfo_parsed.tmp ] && [ "$QCAINFO_COUNT" -gt 0 ]; then
        while IFS='|' read -r _type _idx _earfcn _bw _band _pci _rsrp _rsrq _rssi _sinr; do
            db_exec "INSERT INTO ca_samples (
                sample_id, ts, cc_type, cc_index,
                earfcn, bandwidth, band, pci,
                rsrp, rsrq, rssi, sinr
            ) VALUES (
                ${_sample_id}, ${_ts},
                $(db_quote "$_type"), ${_idx:-NULL},
                ${_earfcn:-NULL}, ${_bw:-NULL}, ${_band:-NULL}, ${_pci:-NULL},
                ${_rsrp:-NULL}, ${_rsrq:-NULL}, ${_rssi:-NULL}, ${_sinr:-NULL}
            );"
        done < /tmp/_qcainfo_parsed.tmp
        rm -f /tmp/_qcainfo_parsed.tmp
    fi

    # -----------------------------------------------------------------------
    # 3. neighbour_cells — variable rows (FK: sample_id)
    # -----------------------------------------------------------------------
    if [ -f /tmp/_neighbours_parsed.tmp ] && [ "$NEIGHBOUR_COUNT" -gt 0 ]; then
        while IFS='|' read -r _ntype _rat _earfcn _pci _rsrp _rsrq _rssi _sinr; do
            db_exec "INSERT INTO neighbour_cells (
                sample_id, ts, neighbour_type, rat,
                earfcn, pci, rsrp, rsrq, rssi, sinr
            ) VALUES (
                ${_sample_id}, ${_ts},
                $(db_quote "$_ntype"), $(db_quote "$_rat"),
                ${_earfcn:-NULL}, ${_pci:-NULL},
                ${_rsrp:-NULL}, ${_rsrq:-NULL}, ${_rssi:-NULL}, ${_sinr:-NULL}
            );"
        done < /tmp/_neighbours_parsed.tmp
        rm -f /tmp/_neighbours_parsed.tmp
    fi

    # -----------------------------------------------------------------------
    # 4. temp_samples — one row, 8 pivoted columns
    # -----------------------------------------------------------------------
    if [ -n "$AT_TEMP_XO_THERM_BUF" ] || [ -n "$AT_TEMP_MDM_CASE_THERM" ]; then
        db_exec "INSERT INTO temp_samples (
            ts, xo_therm_buf, mdm_case_therm, pa_therm1,
            tsens_tz_sensor0, tsens_tz_sensor1, tsens_tz_sensor2,
            tsens_tz_sensor3, tsens_tz_sensor4
        ) VALUES (
            ${_ts},
            ${AT_TEMP_XO_THERM_BUF:-NULL}, ${AT_TEMP_MDM_CASE_THERM:-NULL},
            ${AT_TEMP_PA_THERM1:-NULL},
            ${AT_TEMP_TSENS0:-NULL}, ${AT_TEMP_TSENS1:-NULL},
            ${AT_TEMP_TSENS2:-NULL}, ${AT_TEMP_TSENS3:-NULL},
            ${AT_TEMP_TSENS4:-NULL}
        );"
    fi

    # -----------------------------------------------------------------------
    # 5. modem_counters
    # -----------------------------------------------------------------------
    if [ -n "$AT_MODEM_TX" ] && [ -n "$AT_MODEM_RX" ]; then
        db_exec "INSERT INTO modem_counters (ts, tx_bytes, rx_bytes) VALUES (${_ts}, ${AT_MODEM_TX}, ${AT_MODEM_RX});"
    fi

    # -----------------------------------------------------------------------
    # 6. pdp_context — insert only on change
    # -----------------------------------------------------------------------
    if [ -n "$AT_PDP_APN" ]; then
        _last_ip=$(db_scalar "SELECT wan_ip FROM pdp_context ORDER BY ts DESC LIMIT 1;")
        if [ "$_last_ip" != "$AT_PDP_WAN_IP" ] || [ -z "$_last_ip" ]; then
            db_exec "INSERT INTO pdp_context (
                ts, cid, apn, wan_ip, dns_primary, dns_secondary
            ) VALUES (
                ${_ts}, ${AT_PDP_CID:-NULL},
                $(db_quote "$AT_PDP_APN"), $(db_quote "$AT_PDP_WAN_IP"),
                $(db_quote "$AT_PDP_DNS1"), $(db_quote "$AT_PDP_DNS2")
            );"
            log_info "$COMPONENT" "PDP context changed: IP=${AT_PDP_WAN_IP}"
        fi
    fi

    db_update_collector_state "$COMPONENT" "ok"
    log_info "$COMPONENT" "LTE data collected (RSRP=${AT_RSRP} SINR=${AT_SINR} band=${AT_BAND} cell=${AT_CELL_ID_HEX})"
    return 0
}

# ---------------------------------------------------------------------------
# Entry point (when executed directly for testing)
# ---------------------------------------------------------------------------
if [ "$(basename "$0")" = "collector-lte.sh" ]; then
    setup_trap "$COMPONENT"
    if ! acquire_lock "$COMPONENT"; then
        die "Another instance of ${COMPONENT} is running"
    fi
    collect_lte
    release_lock "$COMPONENT"
fi
