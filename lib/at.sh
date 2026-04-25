#!/bin/sh
# =============================================================================
# lib/at.sh — AT command response parsers
# =============================================================================
# Part of: asus-lte-telemetry
# https://github.com/pajus1337/asus-lte-telemetry
#
# Each parse_* function reads an AT response string and populates globals.
# Global names map directly to schema.sql column names where applicable.
#
# Requires: lib/common.sh sourced first.
# =============================================================================

AT_SEND="${AT_SEND:-${INSTALL_BASE}/bin/at-send}"
AT_TIMEOUT="${AT_TIMEOUT:-2}"
AT_TIMEOUT_TEMP="${AT_TIMEOUT_TEMP:-3}"  # QTEMP needs ≥2s per AT_COMMANDS.md

# Read AT_PORT from config if not already set in environment
if [ -z "${AT_PORT:-}" ]; then
    AT_PORT=$(cfg_get general at_port "/dev/ttyUSB3")
fi
export AT_PORT

# ---------------------------------------------------------------------------
# Core AT send wrapper
# ---------------------------------------------------------------------------

# at_cmd COMMAND [TIMEOUT] — send AT command, return response on stdout
at_cmd() {
    _cmd="$1"
    _timeout="${2:-$AT_TIMEOUT}"

    if [ ! -x "$AT_SEND" ]; then
        log_error "at" "at-send not found or not executable: ${AT_SEND}"
        return 1
    fi

    _response=$("$AT_SEND" "$_cmd" "$_timeout" 2>/dev/null)
    _rc=$?
    if [ $_rc -ne 0 ]; then
        log_warning "at" "AT command failed (rc=${_rc}): ${_cmd}"
        return 1
    fi

    # A command truly failed only if the response has ERROR with no OK.
    # If OK is present, the command succeeded — any ERROR after it is from
    # the router OS's own AT commands captured in the same serial read window.
    if echo "$_response" | grep -q "^ERROR" && ! echo "$_response" | grep -q "^OK"; then
        log_warning "at" "AT ERROR for: ${_cmd}"
        return 1
    fi

    echo "$_response"
    return 0
}

# ---------------------------------------------------------------------------
# +QENG="servingcell" parser
# ---------------------------------------------------------------------------
# Response example (from AT_COMMANDS.md):
# +QENG: "servingcell","CONNECT","LTE","FDD",262,03,63017XX,XXX,100,1,5,5,XXXX,-100,-10,-71,16,30,-
#
# Field mapping (0-indexed after removing +QENG: prefix):
# 0=state 1=rat 2=duplex 3=mcc 4=mnc 5=cell_id_hex 6=?? 7=earfcn
# 8=dl_bw_code 9=ul_bw_code 10=band 11=pci 12=rsrp 13=rsrq 14=rssi
# 15=sinr 16=cqi 17=tx_power
#
# Globals match schema.sql lte_samples columns:
AT_RRC_STATE="" AT_RAT="" AT_DUPLEX="" AT_MCC="" AT_MNC=""
AT_CELL_ID_HEX="" AT_PCI="" AT_EARFCN="" AT_BAND=""
AT_BW_DL_CODE="" AT_BW_UL_CODE="" AT_TAC_HEX=""
AT_RSRP="" AT_RSRQ="" AT_RSSI="" AT_SINR=""
AT_CQI="" AT_TX_POWER=""
AT_RAW_QENG=""

parse_qeng_serving() {
    _line=$(echo "$1" | grep '+QENG:.*"servingcell"' | head -1)
    if [ -z "$_line" ]; then
        log_warning "at" "No servingcell data in QENG response"
        return 1
    fi

    AT_RAW_QENG="$_line"

    # Remove +QENG: prefix and all quotes, trim CR
    _data=$(echo "$_line" | sed 's/+QENG:[[:space:]]*//' | tr -d '"' | tr -d '\r')

    # Field mapping (1-indexed for cut, from full comma-separated string):
    # f1=servingcell  f2=rrc_state  f3=rat  f4=duplex  f5=mcc  f6=mnc
    # f7=cell_id_hex  f8=pci  f9=earfcn  f10=band  f11=ul_bw  f12=dl_bw
    # f13=tac_hex  f14=rsrp  f15=rsrq  f16=rssi  f17=sinr  f18=cqi  f19=tx_power
    AT_RRC_STATE=$(echo "$_data" | cut -d',' -f2)
    AT_RAT=$(echo "$_data" | cut -d',' -f3)
    AT_DUPLEX=$(echo "$_data" | cut -d',' -f4)
    AT_MCC=$(echo "$_data" | cut -d',' -f5)
    AT_MNC=$(echo "$_data" | cut -d',' -f6)
    AT_CELL_ID_HEX=$(echo "$_data" | cut -d',' -f7)
    AT_PCI=$(echo "$_data" | cut -d',' -f8)
    AT_EARFCN=$(echo "$_data" | cut -d',' -f9)
    AT_BAND=$(echo "$_data" | cut -d',' -f10)
    AT_BW_UL_CODE=$(echo "$_data" | cut -d',' -f11)
    AT_BW_DL_CODE=$(echo "$_data" | cut -d',' -f12)
    AT_TAC_HEX=$(echo "$_data" | cut -d',' -f13)
    AT_RSRP=$(echo "$_data" | cut -d',' -f14)
    AT_RSRQ=$(echo "$_data" | cut -d',' -f15)
    AT_RSSI=$(echo "$_data" | cut -d',' -f16)
    AT_SINR=$(echo "$_data" | cut -d',' -f17)
    AT_CQI=$(echo "$_data" | cut -d',' -f18)
    AT_TX_POWER=$(echo "$_data" | cut -d',' -f19 | tr -d '\r')

    # Clean dash-as-null (modem returns "-" for unavailable fields)
    [ "$AT_CQI" = "-" ]      && AT_CQI=""
    [ "$AT_TX_POWER" = "-" ] && AT_TX_POWER=""

    log_debug "at" "QENG: state=${AT_RRC_STATE} RSRP=${AT_RSRP} SINR=${AT_SINR} band=${AT_BAND} cell=${AT_CELL_ID_HEX} pci=${AT_PCI}"
    return 0
}

# ---------------------------------------------------------------------------
# +COPS? parser (operator name)
# ---------------------------------------------------------------------------
# Response: +COPS: 0,0,"o2 - de",7
AT_OPERATOR=""

parse_cops() {
    _line=$(echo "$1" | grep '+COPS:' | head -1)
    if [ -z "$_line" ]; then
        return 1
    fi
    # Extract quoted operator name
    AT_OPERATOR=$(echo "$_line" | sed 's/.*"\(.*\)".*/\1/' | tr -d '\r')
    log_debug "at" "COPS: operator=${AT_OPERATOR}"
    return 0
}

# ---------------------------------------------------------------------------
# +QNWINFO parser (network type)
# ---------------------------------------------------------------------------
# Response: +QNWINFO: "FDD LTE","26203","LTE BAND 1",100
AT_NET_TYPE=""

parse_qnwinfo() {
    _line=$(echo "$1" | grep '+QNWINFO:' | head -1)
    if [ -z "$_line" ]; then
        return 1
    fi
    AT_NET_TYPE=$(echo "$_line" | sed 's/+QNWINFO:[[:space:]]*//' | cut -d',' -f1 | tr -d '"' | tr -d '\r')
    log_debug "at" "QNWINFO: net_type=${AT_NET_TYPE}"
    return 0
}

# ---------------------------------------------------------------------------
# +QRSRP parser (per-antenna RSRP)
# ---------------------------------------------------------------------------
# Response: +QRSRP: -99,-101,-140,-140
AT_RSRP_RX0="" AT_RSRP_RX1="" AT_RSRP_RX2="" AT_RSRP_RX3=""

parse_qrsrp() {
    _line=$(echo "$1" | grep '+QRSRP:' | head -1)
    if [ -z "$_line" ]; then
        log_warning "at" "No QRSRP data"
        return 1
    fi

    _data=$(echo "$_line" | sed 's/+QRSRP:[[:space:]]*//' | tr -d ' \r')
    AT_RSRP_RX0=$(echo "$_data" | cut -d',' -f1)
    AT_RSRP_RX1=$(echo "$_data" | cut -d',' -f2)
    AT_RSRP_RX2=$(echo "$_data" | cut -d',' -f3)
    AT_RSRP_RX3=$(echo "$_data" | cut -d',' -f4)

    log_debug "at" "QRSRP: RX0=${AT_RSRP_RX0} RX1=${AT_RSRP_RX1} RX2=${AT_RSRP_RX2} RX3=${AT_RSRP_RX3}"
    return 0
}

# ---------------------------------------------------------------------------
# +QCAINFO parser (carrier aggregation)
# ---------------------------------------------------------------------------
# Response lines:
# +QCAINFO: "pcc",100,50,"LTE BAND 1",1,422,-99,-10,-71,16
# +QCAINFO: "scc",1300,50,"LTE BAND 3",1,422,-105,-12,-75,10
#
# Outputs lines to /tmp/_qcainfo_parsed.tmp:
# cc_type|cc_index|earfcn|bandwidth|band|pci|rsrp|rsrq|rssi|sinr|scc_state

QCAINFO_COUNT=0

parse_qcainfo() {
    QCAINFO_COUNT=0
    rm -f /tmp/_qcainfo_parsed.tmp

    _input="$1"
    if ! echo "$_input" | grep -q '+QCAINFO:'; then
        log_debug "at" "No QCAINFO data (CA may be inactive)"
        return 0
    fi

    _pcc_idx=0
    _scc_idx=1

    echo "$_input" | grep '+QCAINFO:' | while IFS= read -r _line; do
        _data=$(echo "$_line" | sed 's/+QCAINFO:[[:space:]]*//' | tr -d '\r')
        _type=$(echo "$_data" | cut -d',' -f1 | tr -d '"')
        _earfcn=$(echo "$_data" | cut -d',' -f2)
        _bw=$(echo "$_data" | cut -d',' -f3)
        _band_str=$(echo "$_data" | cut -d',' -f4 | tr -d '"')
        _band=$(echo "$_band_str" | sed 's/.*BAND[[:space:]]*//')
        # field 5 often = dl_state or something firmware-specific
        _pci=$(echo "$_data" | cut -d',' -f6)
        _rsrp=$(echo "$_data" | cut -d',' -f7)
        _rsrq=$(echo "$_data" | cut -d',' -f8)
        _rssi=$(echo "$_data" | cut -d',' -f9)
        _sinr=$(echo "$_data" | cut -d',' -f10 | tr -d '\r')

        if [ "$_type" = "pcc" ]; then
            _idx=1
        else
            _scc_idx=$(( _scc_idx + 1 ))
            _idx=$_scc_idx
        fi

        echo "${_type}|${_idx}|${_earfcn}|${_bw}|${_band}|${_pci}|${_rsrp}|${_rsrq}|${_rssi}|${_sinr}"
    done > /tmp/_qcainfo_parsed.tmp

    if [ -f /tmp/_qcainfo_parsed.tmp ]; then
        QCAINFO_COUNT=$(grep -c '.' /tmp/_qcainfo_parsed.tmp 2>/dev/null || echo 0)
    fi

    log_debug "at" "QCAINFO: ${QCAINFO_COUNT} carriers parsed"
    return 0
}

# ---------------------------------------------------------------------------
# +QENG="neighbourcell" parser
# ---------------------------------------------------------------------------
# Response lines:
# +QENG: "neighbourcell intra","LTE",100,422,-99,-10,-71,0
# +QENG: "neighbourcell inter","LTE",1300,422,-105,-12,-75,0
#
# Output to /tmp/_neighbours_parsed.tmp:
# neighbour_type|rat|earfcn|pci|rsrp|rsrq|rssi|sinr

NEIGHBOUR_COUNT=0

parse_neighbours() {
    NEIGHBOUR_COUNT=0
    rm -f /tmp/_neighbours_parsed.tmp

    _input="$1"
    if ! echo "$_input" | grep -q 'neighbourcell'; then
        log_debug "at" "No neighbour cell data"
        return 0
    fi

    echo "$_input" | grep 'neighbourcell' | while IFS= read -r _line; do
        _data=$(echo "$_line" | sed 's/+QENG:[[:space:]]*//' | tr -d '"' | tr -d '\r')
        _ntype=$(echo "$_data" | cut -d',' -f1 | sed 's/neighbourcell //')
        _rat=$(echo "$_data" | cut -d',' -f2)
        _earfcn=$(echo "$_data" | cut -d',' -f3)
        _pci=$(echo "$_data" | cut -d',' -f4)
        _rsrp=$(echo "$_data" | cut -d',' -f5)
        _rsrq=$(echo "$_data" | cut -d',' -f6)
        _rssi=$(echo "$_data" | cut -d',' -f7)
        _sinr=$(echo "$_data" | cut -d',' -f8 | tr -d '\r')

        echo "${_ntype}|${_rat}|${_earfcn}|${_pci}|${_rsrp}|${_rsrq}|${_rssi}|${_sinr}"
    done > /tmp/_neighbours_parsed.tmp

    if [ -f /tmp/_neighbours_parsed.tmp ]; then
        NEIGHBOUR_COUNT=$(grep -c '.' /tmp/_neighbours_parsed.tmp 2>/dev/null || echo 0)
    fi

    log_debug "at" "Neighbours: ${NEIGHBOUR_COUNT} cells parsed"
    return 0
}

# ---------------------------------------------------------------------------
# +QTEMP parser (modem thermal sensors)
# ---------------------------------------------------------------------------
# Response (8 lines):
# +QTEMP: "xo-therm-buf",35
# +QTEMP: "mdm-case-therm",36
# +QTEMP: "pa-therm1",39
# +QTEMP: "tsens_tz_sensor0",42
# ... etc.
#
# Globals match schema.sql temp_samples columns:
AT_TEMP_XO_THERM_BUF=""
AT_TEMP_MDM_CASE_THERM=""
AT_TEMP_PA_THERM1=""
AT_TEMP_TSENS0="" AT_TEMP_TSENS1="" AT_TEMP_TSENS2=""
AT_TEMP_TSENS3="" AT_TEMP_TSENS4=""

parse_qtemp() {
    _input="$1"
    if ! echo "$_input" | grep -q '+QTEMP:'; then
        log_warning "at" "No QTEMP data"
        return 1
    fi

    # Reset
    AT_TEMP_XO_THERM_BUF="" ; AT_TEMP_MDM_CASE_THERM="" ; AT_TEMP_PA_THERM1=""
    AT_TEMP_TSENS0="" ; AT_TEMP_TSENS1="" ; AT_TEMP_TSENS2=""
    AT_TEMP_TSENS3="" ; AT_TEMP_TSENS4=""

    # Parse each line; sensor names may use hyphens or underscores
    echo "$_input" | grep '+QTEMP:' | while IFS= read -r _line; do
        _data=$(echo "$_line" | sed 's/+QTEMP:[[:space:]]*//' | tr -d '"' | tr -d '\r')
        _sensor=$(echo "$_data" | cut -d',' -f1 | tr -d ' ')
        _temp=$(echo "$_data" | cut -d',' -f2 | tr -d ' ')

        # Normalize hyphens to underscores for matching
        _sensor_norm=$(echo "$_sensor" | tr '-' '_')
        case "$_sensor_norm" in
            xo_therm_buf|xo_therm)     echo "AT_TEMP_XO_THERM_BUF=$_temp" ;;
            mdm_case_therm|mdm_core)   echo "AT_TEMP_MDM_CASE_THERM=$_temp" ;;
            pa_therm1|pa0)             echo "AT_TEMP_PA_THERM1=$_temp" ;;
            tsens_tz_sensor0)          echo "AT_TEMP_TSENS0=$_temp" ;;
            tsens_tz_sensor1)          echo "AT_TEMP_TSENS1=$_temp" ;;
            tsens_tz_sensor2)          echo "AT_TEMP_TSENS2=$_temp" ;;
            tsens_tz_sensor3)          echo "AT_TEMP_TSENS3=$_temp" ;;
            tsens_tz_sensor4)          echo "AT_TEMP_TSENS4=$_temp" ;;
        esac
    done > /tmp/_qtemp_parsed.tmp

    if [ -f /tmp/_qtemp_parsed.tmp ]; then
        . /tmp/_qtemp_parsed.tmp
        rm -f /tmp/_qtemp_parsed.tmp
    fi

    log_debug "at" "QTEMP: xo=${AT_TEMP_XO_THERM_BUF} mdm=${AT_TEMP_MDM_CASE_THERM} pa=${AT_TEMP_PA_THERM1}"
    return 0
}

# ---------------------------------------------------------------------------
# +QGDCNT? parser (modem byte counters)
# ---------------------------------------------------------------------------
# Response: +QGDCNT: 123456789,987654321
AT_MODEM_TX="" AT_MODEM_RX=""

parse_qgdcnt() {
    _line=$(echo "$1" | grep '+QGDCNT:' | head -1)
    if [ -z "$_line" ]; then
        log_warning "at" "No QGDCNT data"
        return 1
    fi

    _data=$(echo "$_line" | sed 's/+QGDCNT:[[:space:]]*//' | tr -d ' \r')
    AT_MODEM_TX=$(echo "$_data" | cut -d',' -f1)
    AT_MODEM_RX=$(echo "$_data" | cut -d',' -f2)

    log_debug "at" "QGDCNT: TX=${AT_MODEM_TX} RX=${AT_MODEM_RX}"
    return 0
}

# ---------------------------------------------------------------------------
# AT+CGCONTRDP=1 parser (PDP context)
# ---------------------------------------------------------------------------
# Response: +CGCONTRDP: 1,5,"internet","10.x.x.x","10.x.x.x","dns1","dns2"
AT_PDP_CID="" AT_PDP_APN="" AT_PDP_WAN_IP="" AT_PDP_DNS1="" AT_PDP_DNS2=""

parse_cgcontrdp() {
    _line=$(echo "$1" | grep '+CGCONTRDP:' | head -1)
    if [ -z "$_line" ]; then
        log_warning "at" "No CGCONTRDP data"
        return 1
    fi

    _data=$(echo "$_line" | sed 's/+CGCONTRDP:[[:space:]]*//' | tr -d '"' | tr -d '\r')
    AT_PDP_CID=$(echo "$_data" | cut -d',' -f1)
    # field 2 = bearer_id
    AT_PDP_APN=$(echo "$_data" | cut -d',' -f3)
    AT_PDP_WAN_IP=$(echo "$_data" | cut -d',' -f4)
    # field 5 = subnet_mask or gateway
    AT_PDP_DNS1=$(echo "$_data" | cut -d',' -f6)
    AT_PDP_DNS2=$(echo "$_data" | cut -d',' -f7)

    log_debug "at" "PDP: APN=${AT_PDP_APN} IP=${AT_PDP_WAN_IP} DNS=${AT_PDP_DNS1},${AT_PDP_DNS2}"
    return 0
}

# ---------------------------------------------------------------------------
# Batch AT command collection — runs all, sets all globals
# ---------------------------------------------------------------------------
# Returns 0 if at least servingcell succeeded
collect_all_at() {
    _ok=0

    _resp=$(at_cmd 'AT+QENG="servingcell"')
    if [ $? -eq 0 ]; then
        parse_qeng_serving "$_resp"
        _ok=1
    fi

    _resp=$(at_cmd 'AT+COPS?')
    [ $? -eq 0 ] && parse_cops "$_resp"

    _resp=$(at_cmd 'AT+QNWINFO')
    [ $? -eq 0 ] && parse_qnwinfo "$_resp"

    _resp=$(at_cmd 'AT+QRSRP')
    [ $? -eq 0 ] && parse_qrsrp "$_resp"

    _resp=$(at_cmd 'AT+QCAINFO')
    [ $? -eq 0 ] && parse_qcainfo "$_resp"

    _resp=$(at_cmd 'AT+QENG="neighbourcell"')
    [ $? -eq 0 ] && parse_neighbours "$_resp"

    _resp=$(at_cmd 'AT+QTEMP' "$AT_TIMEOUT_TEMP")
    [ $? -eq 0 ] && parse_qtemp "$_resp"

    _resp=$(at_cmd 'AT+QGDCNT?')
    [ $? -eq 0 ] && parse_qgdcnt "$_resp"

    _resp=$(at_cmd 'AT+CGCONTRDP=1')
    [ $? -eq 0 ] && parse_cgcontrdp "$_resp"

    if [ $_ok -eq 0 ]; then
        log_error "at" "Failed to collect servingcell data"
        return 1
    fi

    return 0
}
