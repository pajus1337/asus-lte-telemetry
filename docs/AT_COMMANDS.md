# AT Commands Reference

Reference of AT commands used by `asus-lte-telemetry`, with actual response formats
observed on the following hardware:

- **Router:** ASUS 4G-AC86U, stock firmware `3.0.0.4.382.41621`
- **Modem:** Quectel EM12-G
- **Modem firmware:** `EM12GPAR01A21M4G_02.001.02.001`
- **Test date:** 2026-04-22

Other firmware revisions may return slightly different formats. If you port
this project to another modem/firmware, please contribute your findings.

---

## Device identification

### `ATI`
Basic device info.

**Example response:**
```
Quectel
EM12
Revision: EM12GPAR01A21M4G
OK
```

### `AT+QGMR`
Full firmware revision.

**Example response:**
```
EM12GPAR01A21M4G_02.001.02.001
OK
```

---

## Network status

### `AT+COPS?`
Current operator.

**Example response:**
```
+COPS: 0,0,"freenet freenet",7
OK
```

Fields: `mode, format, operator, rat` (7 = E-UTRAN / LTE).

### `AT+QNWINFO`
Current network info.

**Example response:**
```
+QNWINFO: "FDD LTE","26203","LTE BAND 1",250
OK
```

Fields: `access_tech, mcc_mnc, operation_band, channel (EARFCN)`.

### `AT+CSQ`
Simple signal quality (legacy).

**Example response:**
```
+CSQ: 23,99
OK
```

Fields: `rssi_code, ber_code`. `rssi_dbm = -113 + 2 * rssi_code`.

---

## LTE serving cell

### `AT+QENG="servingcell"`
Detailed serving cell parameters.

**Example response:**
```
+QENG: "servingcell","NOCONN","LTE","FDD",262,03,F62927,277,250,1,3,3,8D40,-97,-10,-69,16,9,160,-
OK
```

Fields (for LTE):
1. `"servingcell"` — tag
2. `state` — `NOCONN` | `CONNECT` | `SEARCH` | `LIMSRV`
3. `rat` — `LTE`
4. `duplex` — `FDD` | `TDD`
5. `mcc`
6. `mnc`
7. `cell_id` (hex)
8. `pci`
9. `earfcn`
10. `band`
11. `bw_ul_code` — `0=1.4MHz, 1=3MHz, 2=5MHz, 3=10MHz, 4=15MHz, 5=20MHz`
12. `bw_dl_code` — same codes
13. `tac` (hex)
14. `rsrp` (dBm)
15. `rsrq` (dB)
16. `rssi` (dBm)
17. `sinr` (dB)
18. `cqi`
19. `tx_power`
20. `srxlev`

### `AT+QENG="neighbourcell"`
Neighbour cells.

**Example response:**
```
+QENG: "neighbourcell intra","LTE",250,277,-12,-97,-66,0,-,-,-,-,-
+QENG: "neighbourcell inter","LTE",1600,38,-12,-94,-62,0,-,-,-,-
+QENG: "neighbourcell inter","LTE",1600,37,-18,-103,-75,0,-,-,-,-
OK
```

Fields (for LTE intra/inter):
1. type (`neighbourcell intra` / `neighbourcell inter`)
2. `rat`
3. `earfcn`
4. `pci`
5. `rsrq`
6. `rsrp`
7. `rssi`
8. `sinr`
9. ...

### `AT+QCAINFO`
Carrier Aggregation info.

**Example response:**
```
+QCAINFO: "pcc",250,50,"LTE BAND 1",1,277,-97,-9,-71,15
+QCAINFO: "scc",1600,100,"LTE BAND 3",1,38,-96,-10,-76,11
DL
OK
```

Fields per CC:
1. `"pcc"` | `"scc"`
2. `earfcn`
3. `bandwidth` — `25=5MHz, 50=10MHz, 75=15MHz, 100=20MHz`
4. `band_name`
5. `pcc_idx`
6. `pci`
7. `rsrp`
8. `rsrq`
9. `rssi`
10. `sinr`

For SCC, an additional line `"DL"` or `"DL+UL"` follows indicating direction.

### `AT+QRSRP`
Per-antenna RSRP (4 RX paths).

**Example response:**
```
+QRSRP: -98,-97,-140,-140
OK
```

Fields: `rsrp_rx0, rsrp_rx1, rsrp_rx2, rsrp_rx3` (dBm). A value of `-140` means
the antenna is below the measurement floor (essentially "no signal on that RX").

On ASUS 4G-AC86U, RX2/RX3 typically return `-140` because only 2 antennas are
connected to the modem (2x2 MIMO).

---

## Modem configuration

### `AT+QCFG="nwscanseq"`
Network scan sequence (technology priority).

**Example response:**
```
+QCFG: "nwscanseq",0403010502
OK
```

Each 2-digit code is a technology:
- `00` — Automatic
- `01` — GSM
- `02` — TD-SCDMA
- `03` — LTE
- `04` — NR5G
- `05` — WCDMA

### `AT+QCFG="band"`
Allowed bands (bitmask).

**Example response:**
```
+QCFG: "band",0x5af0,0x2000001e0bb1f39df,0x0
OK
```

Fields: `gsm_wcdma_mask, lte_mask, nr5g_mask`.

---

## Temperatures

### `AT+QTEMP`
All thermal sensors.

**Example response:**
```
+QTEMP: "xo_therm_buf","47"
+QTEMP: "mdm_case_therm","47"
+QTEMP: "pa_therm1","44"
+QTEMP: "tsens_tz_sensor0","52"
+QTEMP: "tsens_tz_sensor1","52"
+QTEMP: "tsens_tz_sensor2","52"
+QTEMP: "tsens_tz_sensor3","52"
+QTEMP: "tsens_tz_sensor4","53"
OK
```

Values are in degrees Celsius. The most practical sensors:
- `mdm_case_therm` — modem case temperature
- `pa_therm1` — power amplifier (rises during heavy TX)

---

## PDP context / IP info

### `AT+CGCONTRDP=1`
Current bearer details for context ID 1.

**Example response:**
```
+CGCONTRDP: 1,5,internet,10.191.91.211,,62.109.121.17,62.109.121.18
OK
```

Fields: `cid, bearer_id, apn, wan_ip, gateway, dns_primary, dns_secondary`.

Note: On CGNAT, `wan_ip` is in private space (10.x, 100.64.0.0/10, etc.).

---

## Traffic counters

### `AT+QGDCNT?`
Modem-internal byte counters for the PDP context.

**Confirmed working** on `EM12GPAR01A21M4G_02.001.02.001`.

**Example response:**
```
+QGDCNT: 237505722,614994307
OK
```

Fields: `tx_bytes, rx_bytes` — counters since last modem reset. The values reset
when the modem reboots (e.g. full router reboot) but NOT on transient
disconnects like SCC drop or temporary signal loss.

**Use case:** Compare against `/proc/net/dev` on `wwan0` — the delta between
modem counters and kernel counters indicates overhead (retransmissions,
protocol headers, AT channel traffic).

**Note:** On some firmware revisions the command returns an empty response.
If so, fall back to `/proc/net/dev` on `wwan0`.

---

## Notes and gotchas

1. **Command echo:** The modem echoes commands back before responding. Parsers
   must strip the first line if it equals the sent command.
2. **Baudrate is irrelevant** for USB CDC ACM — `stty` complaints about
   `raw` or specific baudrates can be ignored.
3. **Port is shared:** Other processes (panel www, `quectel-CM`) may also
   read/write `/dev/ttyUSB2`. Use the reader-before-writer pattern in
   `bin/at-send` to avoid losing responses.
4. **Timeouts:** Multi-line responses (`AT+QTEMP`, `AT+QENG="neighbourcell"`)
   need ≥2s. Single-line responses work fine with 1.5s.
5. **ERROR responses:** Some firmware revisions return `+CME ERROR: <code>`
   instead of plain `ERROR`. Parsers should handle both.
