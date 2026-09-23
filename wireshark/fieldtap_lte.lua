-- FieldTap: LTE field decoders for "fieldtap-diag" records (0xB0xx / 0xB1xx log codes).
--
-- Each decoder mirrors the Python decoder of the same log code in fieldtap/decode/
-- (cellinfo.py, lte_ml1.py, lte_mac.py, lte_phy.py); tests/test_wireshark_lte_diag.py
-- checks through tshark that both read the same fields, notes and summary from the
-- same bytes. A decoder receives the record body as a Tvb, adds fields under the
-- record tree, and returns a short summary for the Info column. It raises when the
-- layout does not fit: the frame keeps its raw bytes either way.
--
-- Layouts: MobileInsight log_packet.h and friends (Apache-2.0), restated in
-- docs/research/qualcomm-measurement-log-layouts.md. Layout from documentation;
-- confirm on a hardware capture. The iPhone 17 (M25) versions (0xB193 v66, 0xB179 v56,
-- 0xB173 v50, 0xB139 v162, 0xB063 v50, 0xB064 v7, 0xB062, 0xB14E/0xB14D v164, 0xB126,
-- 0xB12A, 0xB16C, 0x184C, 0x1D0B) mirror fieldtap/decode/lte_ml1.py, lte_phy.py,
-- lte_mac.py, lte_ll1.py and rf.py, whose layouts are web/engine/src/phy/decoders/*.ts.
--
-- Load-order independent: works whether this file or fieldtap.lua loads first, so
-- nothing from FieldTap.helpers is captured at load time. tshark 4.0.1 runs each
-- -X lua_script file in its own environment (reads fall back to _G, plain global
-- writes do not reach it), so the shared table is published into _G by hand: a
-- file that loads later then finds this one's table instead of creating its own.

FieldTap = FieldTap or { decoders = {}, names = {}, confidence = {}, helpers = {} }
rawset(_G, "FieldTap", FieldTap)
local D = FieldTap.decoders

local proto_lte = Proto("fieldtap-lte", "FieldTap LTE fields")

local DOC_NOTE = "layout from documentation; confirm on a hardware capture"
local SINGLE_SOURCE = "single-sourced layout: header fields only"

-- ---------------------------------------------------------------------------------
-- fields: fieldtap.lte.<name> for the headline, fieldtap.lte.<group>.<name> for rows

local U8, U16, U32, I32, U64, FLT, STR, BYT = "uint8", "uint16", "uint32", "int32", "uint64", "float", "string", "bytes"
local F = {}
local all_fields = {}

local function def(group, name, kind)
  local key = group and (group .. "." .. name) or name
  local f = ProtoField[kind]("fieldtap.lte." .. key, key)
  F[key] = f
  all_fields[#all_fields + 1] = f
end

local function defs(group, list)
  for _, spec in ipairs(list) do def(group, spec[1], spec[2]) end
end

defs(nil, {
  {"version", U8}, {"num_subpackets", U8}, {"subpacket_id", U8}, {"subpacket_version", U8}, {"subpacket_size", U16},
  {"earfcn", U32}, {"num_cells", U16}, {"valid_rx", U16}, {"pci", U16}, {"serving_cell_index", U8},
  {"sfn", U16}, {"subframe", U8}, {"rsrp", FLT}, {"rsrq", FLT}, {"rssi", FLT}, {"snr", FLT},
  {"filtered_rsrp", FLT}, {"filtered_rsrq", FLT}, {"projected_sir", FLT}, {"post_ic_rsrq", FLT},
  {"num_neighbours", U8}, {"num_detected", U8}, {"subframe_number", U16},
  {"rrc_release", U8}, {"serving_layer_priority", U8}, {"rsrp_avg", FLT}, {"rsrq_avg", FLT},
  {"direction", STR}, {"num_samples", U16}, {"tbs_bytes", U32}, {"grant_bytes", U32}, {"harq_id", U8},
  {"rnti_type", U8}, {"rnti_type_name", STR}, {"cell_id", U32}, {"lcids", STR},
  {"num_records", U8}, {"num_tb", U16}, {"mcs", U8}, {"modulation", STR}, {"crc_pass", U16}, {"crc_fail", U16},
  {"num_rbs", U8}, {"serving_cell_id", U16}, {"dispatch_sfn_sf_raw", U16}, {"tx_power_dbm", I32}, {"mod_order", U8},
  {"coding_rate", FLT},
  {"num_tx_antennas", U8}, {"dl_bw", U8}, {"dl_bw_mhz", FLT}, {"dl_bw_reading", STR}, {"sib1_br_sch_info", U8},
  {"sfn_msb4", U8}, {"hsfn_lsb2", U8}, {"sib1_sch_info", U8}, {"sys_info_value_tag", U8},
  {"access_barring_enabled", U8}, {"op_mode_type", U8}, {"op_mode", STR}, {"raster_offset", U16},
  {"raster_offset_khz", STR}, {"dl_earfcn", U32}, {"ul_earfcn", U32}, {"ul_bw", U8}, {"ul_bw_mhz", FLT},
  {"tac", U16}, {"band", U32}, {"mcc", U16}, {"mnc_digits", U8}, {"mnc", U16}, {"allowed_access", U8},
  {"plmn", STR}, {"enb_id", U32}, {"sector", U8}, {"plausible", STR}, {"layout", STR}, {"note", STR},
  -- iPhone 17 layouts
  {"rx_map", U32}, {"num_rx", U8}, {"tti", U16}, {"unidentified_word", U32}, {"required_power_dbm", FLT},
  {"num_transport_blocks", U32}, {"num_found", U32}, {"walk_exact", U8}, {"resynced", U32}, {"padding_bytes", U32},
  {"power_headroom_db", I32}, {"num_attempts", U8}, {"result", U8}, {"contention", U8}, {"msg_mask", U8},
  {"preamble", U8}, {"preamble_target_dbm", I32}, {"ta_rar", U16}, {"num_rach_attempts", U8},
  {"carrier", U8}, {"ri", U8}, {"cqi_cw0", U8}, {"cqi_cw1", U8}, {"wideband_pmi", U8}, {"tx_mode", U8},
  {"report_type", U8}, {"num_subframes", U8}, {"tx_antennas", U8}, {"rx_antennas", U8}, {"rank", U8}, {"num_prb", U8},
  {"num_decoded", U8}, {"cfi1", U8}, {"cfi2", U8}, {"cfi3", U8}, {"num_consistent", U8}, {"num_declared", U8},
  {"num_ul_grants", U16}, {"num_dl_assignments", U16}, {"start_rb", U8},
})
local CELL_FIELDS = {
  {"cell", U16}, {"pci", U16}, {"serving_cell_index", U8}, {"is_serving_cell", U8}, {"sfn", U16}, {"subframe", U8},
  {"rsrp_rx0", FLT}, {"rsrp_rx1", FLT}, {"rsrp_rx2", FLT}, {"rsrp_rx3", FLT}, {"rsrp", FLT}, {"filtered_rsrp", FLT},
  {"rsrq_rx0", FLT}, {"rsrq_rx1", FLT}, {"rsrq_rx2", FLT}, {"rsrq_rx3", FLT}, {"rsrq", FLT}, {"filtered_rsrq", FLT},
  {"rssi_rx0", FLT}, {"rssi_rx1", FLT}, {"rssi_rx2", FLT}, {"rssi_rx3", FLT}, {"rssi", FLT},
  {"snr_rx0", FLT}, {"snr_rx1", FLT}, {"snr_rx2", FLT}, {"snr_rx3", FLT}, {"snr", FLT},
  {"projected_sir", FLT}, {"post_ic_rsrq", FLT}, {"cinr_rx0_raw", U32}, {"cinr_rx1_raw", U32}, {"cinr_rx2_raw", U32},
  {"cinr_rx3_raw", U32}, {"residual_freq_error", U16}, {"earfcn", U32}, {"num_cells", U16}, {"valid_rx", U16},
  {"rx_map", U32}, {"num_rx", U8},
}
defs("cell", CELL_FIELDS)
defs("ncell", { {"pci", U16}, {"rsrp", FLT}, {"rsrq", FLT} })
defs("det", { {"pci", U32}, {"sss_corr", U32}, {"reference_time", U64} })
defs("sp", { {"subpacket_id", U8}, {"subpacket_version", U8}, {"subpacket_size", U16}, {"num_samples", U8} })
defs("sample", {
  {"sample", U16}, {"sub_id", U8}, {"cell_id", U8}, {"sfn", U16}, {"subframe", U8}, {"rnti_type", U8},
  {"rnti_type_name", STR}, {"harq_id", U8}, {"pmch_id", U16}, {"tbs_bytes", U16}, {"grant_bytes", U16}, {"rlc_pdus", U8},
  {"padding_bytes", U16}, {"bsr_event", U8}, {"bsr_event_name", STR}, {"bsr_trigger", U8}, {"bsr_trigger_name", STR},
  {"hdr_len", U8}, {"lcids", STR}, {"header_note", STR}, {"power_headroom_db", I32}, {"header_consistent", U8},
})
defs("subhdr", { {"sample", U16}, {"lcid", U8}, {"lcid_name", STR}, {"extension", U8}, {"length", U16} })
defs("sdu", { {"tb", U16}, {"control", U8}, {"lcid", U8}, {"lcid_name", STR}, {"length_bytes", U16} })
defs("record", {
  {"record", U8}, {"sfn", U16}, {"subframe", U8}, {"num_rbs", U8}, {"num_layers", U8}, {"num_tb", U8},
  {"serving_cell_index", U8}, {"hsic_enabled", U8}, {"pmch_id", U8}, {"area_id", U8},
})
defs("tb", {
  {"record", U8}, {"tb", U8}, {"harq_id", U8}, {"rv", U8}, {"ndi", U8}, {"crc_pass", U8}, {"rnti_type", U8},
  {"rnti_type_name", STR}, {"tb_index", U8}, {"discarded_retx_present", U8}, {"did_recombining", U8},
  {"tb_size", U16}, {"mcs", U8}, {"num_rbs", U8}, {"modulation_code", U8}, {"modulation", STR},
  {"qed2_interim_status", U8}, {"qed_iteration", U8}, {"qm", U8},
  -- 0xB063 v50 transport blocks
  {"size_bytes", U32}, {"padding_bytes", U32}, {"carrier", U8}, {"header_length", U16}, {"num_sdus", U8}, {"lcids", STR},
})
defs("grant", {
  {"grant", U8}, {"sfn", U16}, {"subframe", U8}, {"coding_rate", FLT}, {"ack", U8}, {"cqi", U8}, {"ri", U8},
  {"frequency_hopping", U8}, {"rv", U8}, {"mirror_hopping", U8}, {"dmrs_cyclic_shift_slot0", U8},
  {"dmrs_cyclic_shift_slot1", U8}, {"dmrs_root_slot0", U16}, {"ue_srs", U8}, {"dmrs_root_slot1", U16},
  {"start_rb_slot0", U8}, {"start_rb_slot1", U8}, {"num_rbs", U8}, {"tb_size", U16}, {"num_ack_bits", U8},
  {"ack_payload", U8}, {"rate_matched_ack_bits", U16}, {"num_ri_bits", U8}, {"ri_payload", U8},
  {"rate_matched_ri_bits", U16}, {"mod_order", U8}, {"modulation", STR}, {"digital_gain_db", U8},
  {"srs_occasion", U8}, {"retx_index", U8}, {"tx_power_dbm", I32}, {"num_cqi_bits", U8},
  {"rate_matched_cqi_bits", U16}, {"cqi_payload", BYT}, {"tx_resampler", U32}, {"num_repetition", U16},
  {"rb_nb_start_index", U8},
  -- 0xB139 v162
  {"tti", U16}, {"carrier", U8}, {"start_rb", U8}, {"modulation_code", U8}, {"power_raw", U8}, {"required_power_dbm", FLT},
})
defs("rach", {
  {"attempt", U8}, {"cell_id", U8}, {"num_attempts", U8}, {"result", U8}, {"contention", U8}, {"msg_mask", U8},
  {"preamble", U8}, {"preamble_target_dbm", I32}, {"ta_rar", U16}, {"ul_earfcn", U32},
})
defs("dmp", {
  {"index", U8}, {"sfn", U16}, {"subframe", U8}, {"tx_antennas", U8}, {"rx_antennas", U8}, {"rank", U8},
  {"prb_mask_lo", U32}, {"prb_mask_hi", U32}, {"num_prb", U8},
})
defs("cfi", { {"index", U16}, {"subframe", U8}, {"decoded_flag", U8}, {"cfi", U8}, {"consistent", U8} })
defs("dci", { {"index", U8}, {"sfn", U16}, {"subframe", U8}, {"tti", U16}, {"num_ul_grants", U8}, {"num_dl_assignments", U8} })
defs("ulg", { {"subframe_index", U8}, {"start_rb", U8}, {"num_rbs", U8}, {"modulation_code", U8}, {"modulation", STR} })
proto_lte.fields = all_fields

-- fieldtap.rf.<name>: the modem front-end and clock records (fieldtap/decode/rf.py)
local proto_rf = Proto("fieldtap-rf", "FieldTap modem RF fields")
local RF = {}
local rf_fields = {}
local function def_rf(group, name, kind)
  local key = group and (group .. "." .. name) or name
  local f = ProtoField[kind]("fieldtap.rf." .. key, key)
  RF[key] = f
  rf_fields[#rf_fields + 1] = f
end
local function defs_rf(group, list)
  for _, spec in ipairs(list) do def_rf(group, spec[1], spec[2]) end
end
defs_rf(nil, {
  {"version", U32}, {"num_blocks_declared", U8}, {"num_blocks", U8}, {"walk_exact", U8}, {"subframes_in_range", U8},
  {"num_chain_samples", U8}, {"chain", U8}, {"gain_state", U8}, {"tx_power_dbm", FLT}, {"tx_power2_dbm", FLT},
  {"limit_dbm", FLT}, {"max_tx_power_dbm", FLT}, {"num_live", U8},
  {"ticks_1024hz", U32}, {"ticks_19m2", U32}, {"sequence", U32}, {"note", STR},
})
defs_rf("blk", { {"block", U8}, {"subframe_counter", U16}, {"frame", U16}, {"subframe", U8} })
defs_rf("chain", {
  {"block", U8}, {"subframe_counter", U16}, {"chain", U8}, {"gain_state", U8}, {"tx_power_dbm", FLT},
  {"tx_power2_dbm", FLT}, {"limit0_dbm", FLT}, {"limit1_dbm", FLT}, {"limit2_dbm", FLT}, {"live", U8},
})
proto_rf.fields = rf_fields

local function add(tree, key, range, value)
  if value == nil then return end
  local f = F[key]
  if f == nil then error("no field " .. key) end
  tree:add(f, range, value)
end

local function add_all(tree, group, range, values)
  for key, value in pairs(values) do
    local fkey = group and (group .. "." .. key) or key
    if F[fkey] ~= nil then add(tree, fkey, range, value) end
  end
end

local function add_rf(tree, key, range, value)
  if value == nil then return end
  local f = RF[key]
  if f == nil then error("no rf field " .. key) end
  tree:add(f, range, value)
end

local function add_all_rf(tree, group, range, values)
  for key, value in pairs(values) do
    local fkey = group and (group .. "." .. key) or key
    if RF[fkey] ~= nil then add_rf(tree, fkey, range, value) end
  end
end

local HW_NOTE = "layout validated on the iPhone 17 (M25) captures of 2026-09-21/22"

local function popcount(x)
  local n = 0
  while x > 0 do
    n = n + (x % 2)
    x = math.floor(x / 2)
  end
  return n
end

local function join(list, sep)
  return table.concat(list, sep)
end

local function na(v)
  if v == nil then return "n/a" end
  return tostring(v)
end

-- A layout that does not fit ends the decoder here; the wrapper below turns it into
-- an Info note rather than an expert error, so the frame is not flagged malformed
-- (the record is complete and its bytes are kept; only FieldTap's reading stops).
local NOFIT = "layout did not fit; raw bytes kept"
local function nofit()
  error(NOFIT, 0)
end

local function guarded(fn)
  return function(body, pinfo, tree, ctx)
    local ok, result = pcall(fn, body, pinfo, tree, ctx)
    if ok then return result end
    if tostring(result):find(NOFIT, 1, true) then return "(" .. NOFIT .. ")" end
    error(result, 0)
  end
end

-- ---------------------------------------------------------------------------------
-- scaling, plausibility, bit fields (the same constants as fieldtap/decode/lte_ml1.py)

local function bits(word, shift, width)
  return math.floor(word / 2 ^ shift) % (2 ^ width)
end

local function s16(x) if x >= 32768 then return x - 65536 end return x end
local function s32(x) if x >= 2147483648 then return x - 4294967296 end return x end

local KIND = {
  u = { conv = function(x) return x end },
  pci = { conv = function(x) return x end, lo = 0, hi = 503, int = true },
  sfn = { conv = function(x) return x end, lo = 0, hi = 1023, int = true },
  subframe = { conv = function(x) return x end, lo = 0, hi = 9, int = true },
  rsrp = { conv = function(x) return x * 0.0625 - 180 end, lo = -140, hi = -44 },
  rsrp640 = { conv = function(x) return (x + 640) * 0.0625 - 180 end, lo = -140, hi = -44 },
  rsrq = { conv = function(x) return x * 0.0625 - 30 end, lo = -34, hi = 3 },
  rssi = { conv = function(x) return x * 0.0625 - 110 end, lo = -110, hi = 0 },
  snr = { conv = function(x) return x * 0.1 - 20 end, lo = -20, hi = 30 },
  sir = { conv = function(x) return s32(x) / 16 end, lo = -40, hi = 60 },
  cinr = { conv = function(x) return x end },
}
KIND.u.int = true

local function plausible(kind, value)
  local k = KIND[kind]
  if k.lo == nil or value == nil then return true end
  return value >= k.lo and value <= k.hi
end

local function per_antenna(name)
  return name:match("_rx%d") ~= nil
end

-- 0xB193 step tables, the same shape as lte_ml1.SCMR_LAYOUTS: {"skip", n} or
-- {"w", nbytes, {{name, shift, width, kind}, ...}}.
local function SKIP(n) return { "skip", n } end
local function U(name, nbytes, kind) return { "w", nbytes, { { name, 0, 8 * nbytes, kind or "u" } } } end
local function W(...) return { "w", 4, { ... } } end

local PCI16 = { "w", 2, { { "pci", 0, 9, "pci" }, { "serving_cell_index", 9, 3, "u" } } }
local PCI16_SERVING = { "w", 2, { { "pci", 0, 9, "pci" }, { "serving_cell_index", 9, 3, "u" }, { "is_serving_cell", 12, 1, "u" } } }
local SFN16 = { "w", 2, { { "sfn", 0, 10, "sfn" }, { "subframe", 10, 4, "subframe" } } }
local RSRP_RX0 = W({ "rsrp_rx0", 10, 12, "rsrp" })
local RSRP_RX1 = W({ "rsrp_rx1", 12, 12, "rsrp" })
local RSRP_RX2 = W({ "rsrp_rx2", 12, 12, "rsrp" })
local RSRP_12 = W({ "rsrp", 12, 12, "rsrp" })
local RSRQ_RX0_12 = W({ "rsrq_rx0", 12, 10, "rsrq" })
local RSRQ_RX1_AND_RSRQ = W({ "rsrq_rx1", 0, 10, "rsrq" }, { "rsrq", 20, 10, "rsrq" })
local RSSI_RX0_RX1 = W({ "rssi_rx0", 10, 11, "rssi" }, { "rssi_rx1", 21, 11, "rssi" })
local RSSI_LOW = W({ "rssi", 0, 11, "rssi" })
local SNR_RX0_RX1 = W({ "snr_rx0", 0, 9, "snr" }, { "snr_rx1", 9, 9, "snr" })
local SNR_RX2_RX3 = W({ "snr_rx2", 0, 9, "snr" }, { "snr_rx3", 9, 9, "snr" })
local SIR = U("projected_sir", 4, "sir")
local POST_IC_RSRQ = U("post_ic_rsrq", 4, "rsrq")
local CINR = { U("cinr_rx0_raw", 4, "cinr"), U("cinr_rx1_raw", 4, "cinr"), U("cinr_rx2_raw", 4, "cinr"), U("cinr_rx3_raw", 4, "cinr") }
local FOUR_RX = {
  W({ "rsrp_rx3", 0, 12, "rsrp" }, { "rsrp", 12, 12, "rsrp640" }),
  W({ "filtered_rsrp", 12, 12, "rsrp" }),
  W({ "rsrq_rx0", 0, 10, "rsrq" }, { "rsrq_rx1", 20, 10, "rsrq" }),
  W({ "rsrq_rx2", 10, 10, "rsrq" }, { "rsrq_rx3", 20, 10, "rsrq" }),
  W({ "rsrq", 0, 10, "rsrq" }, { "filtered_rsrq", 20, 12, "rsrq" }),
  W({ "rssi_rx0", 0, 11, "rssi" }, { "rssi_rx1", 11, 11, "rssi" }),
  W({ "rssi_rx2", 0, 11, "rssi" }, { "rssi_rx3", 11, 11, "rssi" }),
  RSSI_LOW,
}

local function cat(...)
  local out = {}
  for _, list in ipairs({ ... }) do
    for _, item in ipairs(list) do out[#out + 1] = item end
  end
  return out
end

local HEADER_EARFCN16 = { U("earfcn", 2) }
local HEADER_EARFCN32 = { U("earfcn", 4) }
local HEADER_CELLS = { U("earfcn", 4), U("num_cells", 2), SKIP(2) }
local HEADER_CELLS_VALID_RX = { U("earfcn", 4), U("num_cells", 2), U("valid_rx", 2) }
local CELL_V4_TAIL = { RSRP_RX0, RSRP_RX1, RSRP_12, RSRQ_RX0_12, RSRQ_RX1_AND_RSRQ, RSSI_RX0_RX1, RSSI_LOW,
                       SKIP(20), SNR_RX0_RX1, SKIP(12) }

local SCMR_LAYOUTS = {
  [4] = { HEADER_EARFCN16, cat({ PCI16, SFN16, SKIP(2), SKIP(4) }, CELL_V4_TAIL), false },
  [7] = { HEADER_EARFCN32, cat({ PCI16, SKIP(2), SFN16, SKIP(2), SKIP(4) }, CELL_V4_TAIL), false },
  [18] = { HEADER_EARFCN32, { PCI16, SKIP(2), SFN16, SKIP(11), RSRP_RX0, RSRP_RX1, RSRP_12, RSRQ_RX0_12, RSRQ_RX1_AND_RSRQ,
                              W({ "rssi_rx0", 10, 11, "rssi" }, { "rssi_rx1", 21, 11, "rssi" }, { "rssi", 0, 11, "rssi" }),
                              SKIP(23), SNR_RX0_RX1, SKIP(20) }, false },
  [19] = { HEADER_CELLS, { PCI16_SERVING, SKIP(2), SFN16, SKIP(2), SKIP(4), SKIP(4),
                           RSRP_RX0, RSRP_RX1, RSRP_12, RSRQ_RX0_12, RSRQ_RX1_AND_RSRQ, RSSI_RX0_RX1, RSSI_LOW,
                           SKIP(20), SNR_RX0_RX1, SKIP(12), SIR, POST_IC_RSRQ }, true },
  [22] = { HEADER_CELLS, { PCI16_SERVING, SKIP(2), SFN16, SKIP(2), SKIP(4), SKIP(4),
                           RSRP_RX0, RSRP_RX1, SKIP(4), RSRP_12, RSRQ_RX0_12,
                           W({ "rsrq_rx1", 0, 10, "rsrq" }), W({ "rsrq", 10, 10, "rsrq" }),
                           RSSI_RX0_RX1, SKIP(4), RSSI_LOW, SKIP(20), SNR_RX0_RX1, SKIP(16),
                           SIR, POST_IC_RSRQ, CINR[1], CINR[2] }, true },
  [24] = { HEADER_CELLS, { PCI16_SERVING, SKIP(2), SFN16, SKIP(2), SKIP(4), SKIP(4), SKIP(1),
                           W({ "rsrp_rx0", 1, 12, "rsrp" }), W({ "rsrp_rx1", 4, 12, "rsrp" }), W({ "rsrp", 4, 12, "rsrp" }),
                           { "w", 2, { { "rsrq_rx0", 4, 10, "rsrq" } } }, SKIP(1),
                           { "w", 2, { { "rsrq_rx1", 0, 10, "rsrq" } } }, { "w", 2, { { "rsrq", 4, 10, "rsrq" } } },
                           RSSI_RX0_RX1, RSSI_LOW, SKIP(20), SNR_RX0_RX1, SKIP(16), SKIP(8) }, true },
  [35] = { HEADER_CELLS, cat({ PCI16_SERVING, SKIP(2), SFN16, SKIP(2), SKIP(4), SKIP(4), RSRP_RX0, RSRP_RX1, RSRP_RX2 },
                             FOUR_RX, { SKIP(20), SNR_RX0_RX1, SNR_RX2_RX3, SKIP(12), SIR, POST_IC_RSRQ }, CINR), true },
  [36] = { HEADER_CELLS, { PCI16_SERVING, SKIP(2), SFN16, SKIP(2), SKIP(4), SKIP(4),
                           RSRP_RX0, RSRP_RX1, SKIP(4), SKIP(4), W({ "rsrp", 0, 12, "rsrp" }),
                           W({ "rsrq_rx0", 0, 10, "rsrq" }, { "rsrq_rx1", 20, 10, "rsrq" }), SKIP(4),
                           W({ "rsrq", 0, 10, "rsrq" }) }, true },
  [40] = { HEADER_CELLS_VALID_RX, cat({ PCI16_SERVING, SKIP(2), SFN16, SKIP(2), SKIP(4), SKIP(4),
                                        RSRP_RX0, RSRP_RX1, RSRP_RX2, SKIP(4) }, FOUR_RX,
                                      { SKIP(10), U("residual_freq_error", 2), SKIP(8), SNR_RX0_RX1, SNR_RX2_RX3,
                                        SKIP(12), SKIP(4), SIR, POST_IC_RSRQ }, CINR), true },
}
-- Subpacket 0x19 v66 (iPhone 17): lte_ml1._CELL_V66, from web/engine/src/phy/decoders/b193.ts
local PCI16_V66 = { "w", 2, { { "pci", 0, 9, "pci" }, { "serving_cell_index", 9, 3, "u" }, { "is_serving_cell", 15, 1, "u" } } }
local CELL_V66 = {
  U("rx_map", 4), SKIP(4), PCI16_V66, SKIP(14), RSRP_RX0, RSRP_RX1, RSRP_RX2, SKIP(4),
  W({ "rsrp_rx3", 0, 12, "rsrp" }, { "rsrp", 12, 12, "rsrp640" }),
  W({ "filtered_rsrp", 12, 12, "rsrp" }),
  W({ "rsrq_rx0", 0, 10, "rsrq" }, { "rsrq_rx1", 20, 10, "rsrq" }),
  W({ "rsrq_rx2", 10, 10, "rsrq" }, { "rsrq_rx3", 20, 10, "rsrq" }),
  W({ "rsrq", 0, 10, "rsrq" }, { "filtered_rsrq", 20, 10, "rsrq" }),
  W({ "rssi_rx0", 0, 11, "rssi" }, { "rssi_rx1", 11, 11, "rssi" }),
  W({ "rssi_rx2", 0, 11, "rssi" }, { "rssi_rx3", 11, 11, "rssi" }),
  RSSI_LOW, SKIP(72),
}
SCMR_LAYOUTS[66] = { HEADER_CELLS_VALID_RX, CELL_V66, true }
local HW_VALIDATED_SCMR = { [66] = true }
local RX_MAPPED = { [66] = true }
local OPEN_ENDED = { [36] = true }

local function steps_length(steps)
  local n = 0
  for _, step in ipairs(steps) do n = n + step[2] end
  return n
end

local function fmt_bad(name, kind, value)
  if KIND[kind].int then return string.format("%s=%d", name, value) end
  return string.format("%s=%.1f", name, value)
end

-- apply the steps at off; add each field under `tree` (group prefix), fill `out`.
-- With rx_mapped, a per-antenna field of an antenna the cell's rx_map (read earlier in
-- the same steps) does not cover is not a measurement and is not added.
local function run_steps(body, off, steps, tree, group, out, bad, rx_mapped)
  for _, step in ipairs(steps) do
    if step[1] == "skip" then
      off = off + step[2]
    else
      local nbytes, fields = step[2], step[3]
      local range = body(off, nbytes)
      local word = range:le_uint()
      off = off + nbytes
      for _, fld in ipairs(fields) do
        local name, shift, width, kind = fld[1], fld[2], fld[3], fld[4]
        local raw = bits(word, shift, width)
        if raw == 0 and per_antenna(name) then
          out[name] = nil
        elseif rx_mapped and per_antenna(name) and bits(out.rx_map or 0, tonumber(name:match("_rx(%d)")), 1) == 0 then
          out[name] = nil
        else
          local value = KIND[kind].conv(raw)
          if not plausible(kind, value) then
            bad[#bad + 1] = fmt_bad(name, kind, value)
            out[name] = nil
          else
            out[name] = value
            add(tree, group and (group .. "." .. name) or name, range, value)
          end
        end
      end
    end
  end
  return off
end

local function best_snr(row)
  local best = nil
  for i = 0, 3 do
    local v = row["snr_rx" .. i]
    if v ~= nil and (best == nil or v > best) then best = v end
  end
  return best
end

local function meas_line(fields)
  local parts = {}
  local spec = { { "rsrp", "RSRP", "dBm" }, { "rsrq", "RSRQ", "dB" }, { "rssi", "RSSI", "dBm" }, { "snr", "SNR", "dB" } }
  for _, s in ipairs(spec) do
    if fields[s[1]] ~= nil then parts[#parts + 1] = string.format("%s %.1f %s", s[2], fields[s[1]], s[3]) end
  end
  return join(parts, " ")
end

-- ---------------------------------------------------------------------------------
-- 0xB193 LTE ML1 Serving Cell Measurement Result

local HEADLINE_KEYS = { "pci", "serving_cell_index", "sfn", "subframe", "rx_map", "num_rx", "rsrp", "rsrq", "rssi", "snr",
                        "filtered_rsrp", "filtered_rsrq", "projected_sir", "post_ic_rsrq" }

local function decode_scmr(body, start, stop, sp_version, fields, cells, notes, tree, root)
  local layout = SCMR_LAYOUTS[sp_version]
  if layout == nil then
    notes[#notes + 1] = string.format("subpacket version %d not implemented", sp_version)
    return nil
  end
  local header_steps, cell_steps, multi = layout[1], layout[2], layout[3]
  local bad = {}
  local header = {}
  if start + steps_length(header_steps) > stop then
    notes[#notes + 1] = "subpacket shorter than its header"
    return nil
  end
  local off = run_steps(body, start, header_steps, tree, "cell", header, bad)
  local num_cells = 1
  if multi then num_cells = header.num_cells end
  local remaining = stop - off
  local cell_len = steps_length(cell_steps)
  if multi and num_cells == 0 then
    notes[#notes + 1] = "no cells in the subpacket"
    for k, v in pairs(header) do fields[k] = v end
    return "partial"
  end
  local stride
  if OPEN_ENDED[sp_version] then
    stride = math.floor(remaining / num_cells)
    if stride < cell_len then
      notes[#notes + 1] = string.format("cell stride %d shorter than the documented %d bytes", stride, cell_len)
      return nil
    end
    notes[#notes + 1] = string.format("v%d: %d of %d bytes per cell documented", sp_version, cell_len, stride)
  else
    stride = cell_len
    if remaining < num_cells * cell_len then
      notes[#notes + 1] = string.format("%d cells of %d bytes do not fit in %d", num_cells, cell_len, remaining)
      return nil
    end
  end
  for i = 0, num_cells - 1 do
    local at = off + i * stride
    local ctree = tree:add(body(at, math.min(stride, stop - at)), string.format("Cell %d", i))
    local row = { cell = i }
    add(ctree, "cell.cell", body(at, 2), i)
    run_steps(body, at, cell_steps, ctree, "cell", row, bad, RX_MAPPED[sp_version])
    if RX_MAPPED[sp_version] then
      row.num_rx = popcount(bits(row.rx_map or 0, 0, 4))
      add(ctree, "cell.num_rx", body(at, 4), row.num_rx)
    end
    row.snr = best_snr(row)
    add(ctree, "cell.snr", body(at, 2), row.snr)
    cells[#cells + 1] = row
  end
  -- the headline is the PCell (a serving cell on carrier 0), else any serving cell, else the first
  local serving = nil
  for _, c in ipairs(cells) do
    if c.is_serving_cell == 1 and c.serving_cell_index == 0 then serving = c; break end
  end
  if serving == nil then
    for _, c in ipairs(cells) do
      if c.is_serving_cell == 1 then serving = c; break end
    end
  end
  if serving == nil then serving = cells[1] end
  for k, v in pairs(header) do fields[k] = v end
  for _, key in ipairs(HEADLINE_KEYS) do fields[key] = serving[key] end
  fields.num_cells = num_cells
  if HW_VALIDATED_SCMR[sp_version] then
    notes[#notes + 1] = string.format("v%d: no SNR field (the older versions' projected-SIR slot is not SIR here)", sp_version)
  end
  if #bad > 0 then
    notes[#notes + 1] = "implausible: " .. join(bad, ", ")
    return "partial"
  end
  return "fields"
end

local function scell_meas_summary(fields)
  if fields.pci == nil then
    return string.format("v%d, subpacket v%s (partial)", fields.version or 0, na(fields.subpacket_version))
  end
  local line = string.format("PCI %d EARFCN %d", fields.pci, fields.earfcn)
  local meas = meas_line(fields)
  if meas ~= "" then line = line .. " " .. meas end
  return line
end

D[0xB193] = function(body, pinfo, tree, ctx)
  if body:len() < 4 then nofit() end
  local root = tree:add(proto_lte, body())
  local version, nsub = body(0, 1):uint(), body(1, 1):uint()
  local fields = { version = version, num_subpackets = nsub }
  add(root, "version", body(0, 1), version)
  add(root, "num_subpackets", body(1, 1), nsub)
  local notes = {}
  local subpackets, cells = {}, {}
  local decoded = "partial"
  local off = 4
  for _ = 1, nsub do
    if off + 4 > body:len() then
      if #subpackets == 0 then nofit() end
      notes[#notes + 1] = "subpacket header beyond the body"
      break
    end
    local sp_id, sp_version, sp_size = body(off, 1):uint(), body(off + 1, 1):uint(), body(off + 2, 2):le_uint()
    if sp_size < 4 or off + sp_size > body:len() then
      if #subpackets == 0 then nofit() end
      notes[#notes + 1] = string.format("subpacket %d size %d does not fit", sp_id, sp_size)
      break
    end
    local sp_tree = root:add(body(off, sp_size), string.format("Subpacket %d v%d, %d bytes", sp_id, sp_version, sp_size))
    add(sp_tree, "sp.subpacket_id", body(off, 1), sp_id)
    add(sp_tree, "sp.subpacket_version", body(off + 1, 1), sp_version)
    add(sp_tree, "sp.subpacket_size", body(off + 2, 2), sp_size)
    subpackets[#subpackets + 1] = sp_id
    if sp_id == 25 and fields.subpacket_version == nil then
      fields.subpacket_id, fields.subpacket_version, fields.subpacket_size = sp_id, sp_version, sp_size
      add(root, "subpacket_id", body(off, 1), sp_id)
      add(root, "subpacket_version", body(off + 1, 1), sp_version)
      add(root, "subpacket_size", body(off + 2, 2), sp_size)
      local result = decode_scmr(body, off + 4, off + sp_size, sp_version, fields, cells, notes, sp_tree, root)
      if result ~= nil then decoded = result end
    end
    off = off + sp_size
  end
  if #subpackets == 0 then notes[#notes + 1] = "no subpackets" end
  table.insert(notes, 1, HW_VALIDATED_SCMR[fields.subpacket_version] and HW_NOTE or DOC_NOTE)
  local head = {}
  for _, key in ipairs({ "earfcn", "num_cells", "valid_rx" }) do head[key] = fields[key] end
  for _, key in ipairs(HEADLINE_KEYS) do head[key] = fields[key] end
  add_all(root, nil, body(0, 4), head)
  add(root, "note", body(0, 4), join(notes, "; "))
  root:append_text(" (" .. decoded .. ")")
  return scell_meas_summary(fields)
end

-- ---------------------------------------------------------------------------------
-- 0xB179 LTE ML1 Connected Mode Intra-Freq Meas Results

-- v56 (iPhone 17): lte_ml1._decode_intra_meas_v56, from web/engine/src/phy/decoders/b179.ts
local function decode_intra_v56(body, tree)
  if body:len() < 28 then nofit() end
  local n = body(24, 4):le_uint()
  if body:len() ~= 28 + 12 * n then nofit() end
  local root = tree:add(proto_lte, body())
  local tti = body(14, 2):le_uint()
  local fields = { version = 56, unidentified_word = body(4, 4):le_uint(), earfcn = body(8, 4):le_uint(), tti = tti,
                   sfn = math.floor(tti / 10), subframe = tti % 10 }
  local notes = { HW_NOTE, "no DIAG timestamp on this version; the TTI is the record's clock" }
  local bad = {}
  local function meas(prefix, raw_rsrp, raw_rsrq, out)
    local v = KIND.rsrp.conv(raw_rsrp)
    if plausible("rsrp", v) then out.rsrp = v else out.rsrp = nil; bad[#bad + 1] = string.format("%srsrp=%.1f", prefix, v) end
    v = KIND.rsrq.conv(raw_rsrq)
    if plausible("rsrq", v) then out.rsrq = v else out.rsrq = nil; bad[#bad + 1] = string.format("%srsrq=%.1f", prefix, v) end
  end
  local pci = body(12, 2):le_uint()
  if plausible("pci", pci) then fields.pci = pci else bad[#bad + 1] = string.format("pci=%d", pci) end
  meas("", body(16, 2):le_uint(), body(20, 2):le_uint(), fields)
  if fields.sfn > 1023 then bad[#bad + 1] = string.format("tti=%d", tti); fields.sfn = nil; fields.subframe = nil end
  fields.num_neighbours = n
  add_all(root, nil, body(0, 28), fields)
  for i = 0, n - 1 do
    local range = body(28 + 12 * i, 12)
    local ntree = root:add(range, string.format("Neighbour %d", i))
    local row = {}
    local npci = range(0, 2):le_uint()
    if plausible("pci", npci) then row.pci = npci else bad[#bad + 1] = string.format("neighbour%d.pci=%d", i, npci) end
    meas(string.format("neighbour%d.", i), range(2, 2):le_uint(), range(6, 2):le_uint(), row)
    add_all(ntree, "ncell", range, row)
  end
  if #bad > 0 then notes[#notes + 1] = "implausible: " .. join(bad, ", ") end
  add(root, "note", body(0, 28), join(notes, "; "))
  local parts = { string.format("PCI %s EARFCN %d", na(fields.pci), fields.earfcn) }
  if fields.rsrp ~= nil then parts[#parts + 1] = string.format("RSRP %.1f dBm", fields.rsrp) end
  if fields.rsrq ~= nil then parts[#parts + 1] = string.format("RSRQ %.1f dB", fields.rsrq) end
  parts[#parts + 1] = string.format("%d neighbours", n)
  return join(parts, " ")
end

D[0xB179] = function(body, pinfo, tree, ctx)
  if body:len() < 8 then nofit() end
  local version = body(0, 1):uint()
  if version == 56 then return decode_intra_v56(body, tree) end
  local root = tree:add(proto_lte, body())
  local fields = { version = version, serving_cell_index = bits(body(4, 1):uint(), 0, 3) }
  local notes = { DOC_NOTE }
  if version ~= 3 and version ~= 4 then
    notes[#notes + 1] = string.format("version %d not implemented", version)
    add_all(root, nil, body(0, 8), fields)
    add(root, "note", body(0, 8), join(notes, "; "))
    return string.format("v%d (partial)", version)
  end
  local off = 8
  local header_len = (version == 3) and 16 or 20
  if body:len() < off + header_len then nofit() end
  local earfcn_len = (version == 3) and 2 or 4
  fields.earfcn = body(off, earfcn_len):le_uint()
  local p = off + earfcn_len
  local pci = body(p, 2):le_uint()
  fields.subframe_number = body(p + 2, 2):le_uint()
  local rsrp_raw = s16(body(p + 4, 2):le_uint())
  local rsrq_raw = s16(body(p + 8, 2):le_uint())
  local n_nb, n_det = body(p + 12, 1):uint(), body(p + 13, 1):uint()
  off = off + header_len
  local det_size = 16
  local nb_size = 12
  if off + n_nb * nb_size + n_det * det_size > body:len() then
    nb_size = 10
    if off + n_nb * nb_size + n_det * det_size == body:len() then
      notes[#notes + 1] = "10-byte neighbour records (the 12-byte layout did not fit)"
    else
      nofit()
    end
  end
  local bad = {}
  local function meas(prefix, raw_rsrp, raw_rsrq, out)
    local v = KIND.rsrp.conv(raw_rsrp)
    if plausible("rsrp", v) then out.rsrp = v else out.rsrp = nil; bad[#bad + 1] = string.format("%srsrp=%.1f", prefix, v) end
    v = KIND.rsrq.conv(raw_rsrq)
    if plausible("rsrq", v) then out.rsrq = v else out.rsrq = nil; bad[#bad + 1] = string.format("%srsrq=%.1f", prefix, v) end
  end
  fields.pci = pci
  meas("", rsrp_raw, rsrq_raw, fields)
  if not plausible("pci", pci) then bad[#bad + 1] = string.format("pci=%d", pci); fields.pci = nil end
  fields.num_neighbours, fields.num_detected = n_nb, n_det
  add_all(root, nil, body(0, 8 + header_len), fields)
  for i = 0, n_nb - 1 do
    local range = body(off, nb_size)
    local ntree = root:add(range, string.format("Neighbour %d", i))
    local npci = range(0, 2):le_uint()
    local row = {}
    if plausible("pci", npci) then row.pci = npci else bad[#bad + 1] = string.format("neighbour%d.pci=%d", i, npci) end
    meas(string.format("neighbour%d.", i), s16(range(2, 2):le_uint()), s16(range(6, 2):le_uint()), row)
    add_all(ntree, "ncell", range, row)
    off = off + nb_size
  end
  for i = 0, n_det - 1 do
    local range = body(off, det_size)
    local dtree = root:add(range, string.format("Detected cell %d", i))
    if version == 3 then
      add(dtree, "det.pci", range(0, 4), range(0, 4):le_uint())
    else
      add(dtree, "det.pci", range(0, 2), range(0, 2):le_uint())
    end
    add(dtree, "det.sss_corr", range(4, 4), range(4, 4):le_uint())
    dtree:add_le(F["det.reference_time"], range(8, 8))
    off = off + det_size
  end
  if #bad > 0 then notes[#notes + 1] = "implausible: " .. join(bad, ", ") end
  add(root, "note", body(0, 8), join(notes, "; "))
  local parts = { string.format("PCI %s EARFCN %d", na(fields.pci), fields.earfcn) }
  if fields.rsrp ~= nil then parts[#parts + 1] = string.format("RSRP %.1f dBm", fields.rsrp) end
  if fields.rsrq ~= nil then parts[#parts + 1] = string.format("RSRQ %.1f dB", fields.rsrq) end
  parts[#parts + 1] = string.format("%d neighbours", n_nb)
  return join(parts, " ")
end

-- ---------------------------------------------------------------------------------
-- 0xB17F LTE ML1 Serving Cell Meas and Eval (header only)

local EVAL_LAYOUT = { [4] = { 2, 2, 4, 8, 32 }, [5] = { 4, 4, 8, 12, 36 } }   -- earfcn len, earfcn off, pci off, meas off, length

D[0xB17F] = function(body, pinfo, tree, ctx)
  if body:len() < 2 then nofit() end
  local root = tree:add(proto_lte, body())
  local version = body(0, 1):uint()
  local fields = { version = version, rrc_release = body(1, 1):uint() }
  local notes = { DOC_NOTE, SINGLE_SOURCE }
  local layout = EVAL_LAYOUT[version]
  local summary = string.format("v%d", version)
  if layout == nil then
    notes[#notes + 1] = string.format("version %d not documented", version)
  else
    if body:len() < layout[5] then nofit() end
    fields.earfcn = body(layout[2], layout[1]):le_uint()
    local pci_word = body(layout[3], 2):le_uint()
    local pci = bits(pci_word, 0, 9)
    fields.serving_layer_priority = bits(pci_word, 9, 7)
    local m = layout[4]
    local w0, w1, w2, w3 = body(m, 4):le_uint(), body(m + 4, 4):le_uint(), body(m + 8, 4):le_uint(), body(m + 12, 4):le_uint()
    local cand = {
      { "rsrp", KIND.rsrp.conv(bits(w0, 0, 12)), "rsrp" }, { "rsrp_avg", KIND.rsrp.conv(bits(w1, 0, 12)), "rsrp" },
      { "rsrq", KIND.rsrq.conv(bits(w2, 0, 10)), "rsrq" }, { "rsrq_avg", KIND.rsrq.conv(bits(w2, 20, 10)), "rsrq" },
      { "rssi", KIND.rssi.conv(bits(w3, 10, 11)), "rssi" },
    }
    local bad = {}
    for _, c in ipairs(cand) do
      if not plausible(c[3], c[2]) then bad[#bad + 1] = c[1] end
    end
    if #bad > 0 then
      notes[#notes + 1] = string.format("measurement words implausible (%s); not reported", join(bad, ", "))
    else
      for _, c in ipairs(cand) do fields[c[1]] = c[2] end
    end
    if plausible("pci", pci) then fields.pci = pci else notes[#notes + 1] = string.format("implausible: pci=%d", pci) end
    summary = summary .. string.format(" PCI %s EARFCN %d", na(fields.pci), fields.earfcn)
    if fields.rsrp ~= nil then summary = summary .. string.format(" RSRP %.1f dBm", fields.rsrp) end
  end
  add_all(root, nil, body(0, 2), fields)
  add(root, "note", body(0, 2), join(notes, "; "))
  return summary .. " (partial)"
end

-- ---------------------------------------------------------------------------------
-- 0xB180 LTE ML1 Idle Neighbor Meas Results (header only)

local NCELL_LAYOUT = { [4] = { 2, 2, 2, 6, 8 }, [5] = { 4, 4, 4, 8, 12 } }   -- earfcn len/off, packed len/off, header len

D[0xB180] = function(body, pinfo, tree, ctx)
  if body:len() < 2 then nofit() end
  local root = tree:add(proto_lte, body())
  local version = body(0, 1):uint()
  local fields = { version = version, rrc_release = body(1, 1):uint() }
  local notes = { DOC_NOTE, SINGLE_SOURCE }
  local layout = NCELL_LAYOUT[version]
  local summary = string.format("v%d", version)
  if layout == nil then
    notes[#notes + 1] = string.format("version %d not documented", version)
  else
    if body:len() < layout[5] then nofit() end
    fields.earfcn = body(layout[2], layout[1]):le_uint()
    local packed = body(layout[4], layout[3]):le_uint()
    local remaining = body:len() - layout[5]
    local fits = {}
    for _, r in ipairs({ { "low 10 bits", bits(packed, 0, 10) }, { "bits 6..15", bits(packed, 6, 10) } }) do
      if r[2] > 0 and (remaining == r[2] * 32 or remaining == r[2] * 36) then fits[#fits + 1] = r end
    end
    local counts = {}
    for _, r in ipairs(fits) do counts[r[2]] = r end
    local n = 0
    local only
    for _, r in pairs(counts) do n = n + 1; only = r end
    if n == 1 then
      fields.num_cells = only[2]
      notes[#notes + 1] = string.format("cell count from the %s of the packed word (%d bytes per cell fit)", only[1],
                                        math.floor(remaining / only[2]))
    else
      notes[#notes + 1] = "cell count not determined"
    end
    summary = summary .. string.format(" EARFCN %d", fields.earfcn)
    if fields.num_cells ~= nil then summary = summary .. string.format(" %d cells", fields.num_cells) end
  end
  add_all(root, nil, body(0, 2), fields)
  add(root, "note", body(0, 2), join(notes, "; "))
  return summary .. " (partial)"
end

-- ---------------------------------------------------------------------------------
-- 0xB0C1 LTE RRC MIB, 0xB0C2 LTE RRC Serving Cell Info (fieldtap/decode/cellinfo.py)

local BW_CODE = { [0] = 1.4, [1] = 3, [2] = 5, [3] = 10, [4] = 15, [5] = 20 }
local BW_PRB = { [6] = 1.4, [15] = 3, [25] = 5, [50] = 10, [75] = 15, [100] = 20 }
local OP_MODE = { [0] = "inband-DifferentPCI", [1] = "inband-SamePCI", [2] = "guardband", [3] = "standalone" }
local RASTER = { [0] = "-7.5 kHz", [1] = "-2.5 kHz", [2] = "+2.5 kHz", [3] = "+7.5 kHz" }

local function bandwidth(fields, key, code)
  fields[key] = code
  if BW_CODE[code] ~= nil then
    fields[key .. "_mhz"] = BW_CODE[code]; fields[key .. "_reading"] = "code"
  elseif BW_PRB[code] ~= nil then
    fields[key .. "_mhz"] = BW_PRB[code]; fields[key .. "_reading"] = "prb"
  else
    fields[key .. "_reading"] = "unknown"
  end
end

D[0xB0C1] = function(body, pinfo, tree, ctx)
  if body:len() < 1 then nofit() end
  local version = body(0, 1):uint()
  local fields = { version = version }
  local earfcn_len = (version == 1) and 2 or 4
  local need = 1 + 2 + earfcn_len + 2
  if version == 17 then need = need + 9 elseif version == 3 then need = need + 3 else need = need + 2 end
  if body:len() < need then nofit() end
  if version ~= 1 and version ~= 2 and version ~= 3 and version ~= 17 then fields.layout = "assumed v2" end
  local root = tree:add(proto_lte, body())
  fields.pci = body(1, 2):le_uint()
  fields.earfcn = body(3, earfcn_len):le_uint()
  local p = 3 + earfcn_len
  fields.sfn = body(p, 2):le_uint()
  if version == 17 then
    fields.sfn_msb4, fields.hsfn_lsb2, fields.sib1_sch_info = body(p + 2, 1):uint(), body(p + 3, 1):uint(), body(p + 4, 1):uint()
    fields.sys_info_value_tag, fields.access_barring_enabled = body(p + 5, 1):uint(), body(p + 6, 1):uint()
    fields.op_mode_type, fields.raster_offset = body(p + 7, 1):uint(), body(p + 8, 2):le_uint()
    fields.num_tx_antennas = body(p + 10, 1):uint()
    fields.op_mode = OP_MODE[fields.op_mode_type] or "unknown"
    fields.raster_offset_khz = RASTER[fields.raster_offset] or "unknown"
  else
    fields.num_tx_antennas = body(p + 2, 1):uint()
    bandwidth(fields, "dl_bw", body(p + 3, 1):uint())
    if version == 3 then fields.sib1_br_sch_info = body(p + 4, 1):uint() end
  end
  fields.plausible = tostring(fields.pci <= 503 and fields.sfn < 1024)
  add_all(root, nil, body(), fields)
  local bw = fields.dl_bw_mhz and string.format(" BW %g MHz", fields.dl_bw_mhz) or ""
  return string.format("PCI %d EARFCN %d SFN %d%s", fields.pci, fields.earfcn, fields.sfn, bw)
end

D[0xB0C2] = function(body, pinfo, tree, ctx)
  if body:len() < 1 then nofit() end
  local version = body(0, 1):uint()
  local earfcn_len = (version == 2) and 2 or 4
  if body:len() < 1 + 2 + 2 * earfcn_len + 2 + 4 + 2 + 4 + 2 + 1 + 2 + 1 then nofit() end
  local root = tree:add(proto_lte, body())
  local fields = { version = version }
  fields.pci = body(1, 2):le_uint()
  fields.dl_earfcn = body(3, earfcn_len):le_uint()
  fields.ul_earfcn = body(3 + earfcn_len, earfcn_len):le_uint()
  local p = 3 + 2 * earfcn_len
  bandwidth(fields, "dl_bw", body(p, 1):uint())
  bandwidth(fields, "ul_bw", body(p + 1, 1):uint())
  fields.cell_id = body(p + 2, 4):le_uint()
  fields.tac = body(p + 6, 2):le_uint()
  fields.band = body(p + 8, 4):le_uint()
  fields.mcc = body(p + 12, 2):le_uint()
  fields.mnc_digits = body(p + 14, 1):uint()
  fields.mnc = body(p + 15, 2):le_uint()
  fields.allowed_access = body(p + 17, 1):uint()
  fields.plmn = string.format("%03d", fields.mcc) .. string.format(fields.mnc_digits == 3 and "%03d" or "%02d", fields.mnc)
  fields.enb_id = math.floor(fields.cell_id / 256)
  fields.sector = fields.cell_id % 256
  fields.dl_bw_reading, fields.ul_bw_reading = nil, nil
  add_all(root, nil, body(), fields)
  return string.format("PLMN %s PCI %d EARFCN %d band %d TAC %d cell 0x%X", fields.plmn, fields.pci, fields.dl_earfcn,
                       fields.band, fields.tac, fields.cell_id)
end

-- ---------------------------------------------------------------------------------
-- 0xB063 / 0xB064 LTE MAC DL / UL Transport Block (fieldtap/decode/lte_mac.py)

local RNTI_NAMES = { [0] = "C-RNTI", [1] = "SPS C-RNTI", [2] = "P-RNTI", [3] = "RA-RNTI", [4] = "Temp C-RNTI", [5] = "SI-RNTI" }
local BSR_EVENT = { [0] = "none", [1] = "periodic", [2] = "high data arrival" }
local BSR_TRIGGER = { [0] = "no BSR", [3] = "S-BSR", [4] = "Pad L-BSR" }
local DL_LCID = { [0] = "CCCH", [24] = "Activation/Deactivation (4 octet)", [26] = "Long DRX Command",
                  [27] = "Activation/Deactivation (1 octet)", [28] = "UE Contention Resolution Identity",
                  [29] = "Timing Advance Command", [30] = "DRX Command", [31] = "Padding" }
local UL_LCID = { [0] = "CCCH", [24] = "Dual Connectivity PHR", [25] = "Extended PHR", [26] = "PHR", [27] = "C-RNTI",
                  [28] = "Truncated BSR", [29] = "Short BSR", [30] = "Long BSR", [31] = "Padding" }
-- fixed-size UL control elements by LCID (TS 36.321 6.1.3); 24 and 25 carry an L field instead
local UL_CE_SIZE = { [26] = 1, [27] = 2, [28] = 1, [29] = 1, [30] = 3 }

local function lcid_name(lcid, downlink)
  local t = downlink and DL_LCID or UL_LCID
  if t[lcid] ~= nil then return t[lcid] end
  if lcid >= 1 and lcid <= 10 then return string.format("DTCH/DCCH %d", lcid) end
  return string.format("reserved %d", lcid)
end

-- returns rows {lcid, lcid_name, extension, length, from, len}, note
local function parse_subheaders(hdr, downlink)
  local rows, i, note = {}, 0, ""
  local n = hdr:len()
  while i < n do
    local octet = hdr(i, 1):uint()
    local from = i
    i = i + 1
    local ext, lcid = bits(octet, 5, 1), bits(octet, 0, 5)
    local row = { lcid = lcid, lcid_name = lcid_name(lcid, downlink), extension = ext, from = from }
    local has_length = lcid <= 10 or (not downlink and (lcid == 24 or lcid == 25))
    if ext == 1 and has_length then
      if i >= n then
        note = "sub-header truncated"; row.len = i - from; rows[#rows + 1] = row; break
      end
      local b = hdr(i, 1):uint()
      if b >= 128 then
        if i + 1 >= n then
          note = "sub-header truncated"; row.len = i - from; rows[#rows + 1] = row; break
        end
        row.length = (b - 128) * 256 + hdr(i + 1, 1):uint()
        i = i + 2
      else
        row.length = b
        i = i + 1
      end
    end
    row.len = i - from
    rows[#rows + 1] = row
    if ext == 0 then break end
  end
  if note == "" and i < n then note = string.format("%d control-element bytes after the sub-headers", n - i) end
  return rows, note
end

-- the uplink control elements after the sub-headers, in sub-header order (lte_mac.ul_control_elements,
-- the port of lteMac.ts controlElements): returns the PHR CE's power headroom (or nil) and the header
-- bytes used in all
local function ul_control_elements(hdr)
  local n = hdr:len()
  local subheaders = {}
  local i = 0
  while i < n do
    local octet = hdr(i, 1):uint()
    local ext, lcid = bits(octet, 5, 1), bits(octet, 0, 5)
    i = i + 1
    local length = nil
    if ext == 1 and (lcid <= 10 or lcid == 24 or lcid == 25) then
      if i >= n then break end
      local b = hdr(i, 1):uint()
      if b >= 128 then
        if i + 1 >= n then break end
        length = (b - 128) * 256 + hdr(i + 1, 1):uint()
        i = i + 2
      else
        length = b
        i = i + 1
      end
    end
    subheaders[#subheaders + 1] = { lcid = lcid, length = length }
    if ext == 0 then break end
  end
  local phr = nil
  for _, sh in ipairs(subheaders) do
    local size = UL_CE_SIZE[sh.lcid]
    if size == nil and (sh.lcid == 24 or sh.lcid == 25) then size = sh.length end
    if size ~= nil then
      if sh.lcid == 26 and phr == nil and i < n and size > 0 then phr = bits(hdr(i, 1):uint(), 0, 6) - 23 end
      i = i + size
    end
  end
  return phr, i
end

local DL_SAMPLE = { [2] = 12, [4] = 14 }
local UL_SAMPLE = { [1] = 12, [2] = 14, [3] = 14, [5] = 14, [7] = 13, [8] = 14 }
local HW_SAMPLE_VERSIONS = { dl = {}, ul = { [7] = true } }

local function read_sample(body, p, downlink, sp_version)
  local s = {}
  local q = p
  if not downlink and sp_version == 7 then
    s.cell_id = body(q, 1):uint()
    q = q + 1
  elseif (downlink and sp_version == 4) or (not downlink and sp_version ~= 1) then
    s.sub_id, s.cell_id = body(q, 1):uint(), body(q + 1, 1):uint()
    q = q + 2
  end
  local subfn
  if downlink then
    subfn = body(q, 2):le_uint()
    s.rnti_type, s.harq_id = body(q + 2, 1):uint(), body(q + 3, 1):uint()
    s.pmch_id, s.tbs_bytes = body(q + 4, 2):le_uint(), body(q + 6, 2):le_uint()
    s.rlc_pdus, s.padding_bytes, s.hdr_len = body(q + 8, 1):uint(), body(q + 9, 2):le_uint(), body(q + 11, 1):uint()
  else
    s.harq_id, s.rnti_type = body(q, 1):uint(), body(q + 1, 1):uint()
    subfn = body(q + 2, 2):le_uint()
    s.grant_bytes, s.rlc_pdus, s.padding_bytes = body(q + 4, 2):le_uint(), body(q + 6, 1):uint(), body(q + 7, 2):le_uint()
    s.bsr_event, s.bsr_trigger, s.hdr_len = body(q + 9, 1):uint(), body(q + 10, 1):uint(), body(q + 11, 1):uint()
  end
  s.subframe, s.sfn = bits(subfn, 0, 4), bits(subfn, 4, 12)
  return s
end

local function decode_mac_tb(body, tree, downlink)
  if body:len() < 4 then nofit() end
  local root = tree:add(proto_lte, body())
  local version, nsub = body(0, 1):uint(), body(1, 1):uint()
  local layouts = downlink and DL_SAMPLE or UL_SAMPLE
  local size_key = downlink and "tbs_bytes" or "grant_bytes"
  local fields = { version = version, num_subpackets = nsub, direction = downlink and "dl" or "ul" }
  local notes = {}
  local hw_versions = HW_SAMPLE_VERSIONS[downlink and "dl" or "ul"]
  local source_note = DOC_NOTE
  local bad = {}
  local samples = {}
  local nsp = 0
  local off = 4
  for _ = 1, nsub do
    if off + 5 > body:len() then
      if nsp == 0 then nofit() end
      notes[#notes + 1] = "subpacket header beyond the body"
      break
    end
    local sp_id, sp_version, sp_size, num_samples = body(off, 1):uint(), body(off + 1, 1):uint(), body(off + 2, 2):le_uint(), body(off + 4, 1):uint()
    local stop = off + sp_size
    if sp_size < 5 or stop > body:len() then
      if nsp == 0 then nofit() end
      notes[#notes + 1] = string.format("subpacket %d size %d does not fit", sp_id, sp_size)
      break
    end
    nsp = nsp + 1
    local sp_tree = root:add(body(off, sp_size), string.format("Subpacket %d v%d, %d samples", sp_id, sp_version, num_samples))
    add(sp_tree, "sp.subpacket_id", body(off, 1), sp_id)
    add(sp_tree, "sp.subpacket_version", body(off + 1, 1), sp_version)
    add(sp_tree, "sp.subpacket_size", body(off + 2, 2), sp_size)
    add(sp_tree, "sp.num_samples", body(off + 4, 1), num_samples)
    local fixed = layouts[sp_version]
    if fixed == nil then
      notes[#notes + 1] = string.format("subpacket version %d not documented", sp_version)
      off = stop
    else
      if hw_versions[sp_version] then source_note = HW_NOTE end
      local p = off + 5
      for k = 0, num_samples - 1 do
        if p + fixed > stop then
          notes[#notes + 1] = string.format("sample %d does not fit the subpacket", k)
          break
        end
        local s = read_sample(body, p, downlink, sp_version)
        if p + fixed + s.hdr_len > stop then
          notes[#notes + 1] = string.format("sample %d: %d header bytes beyond the subpacket", k, s.hdr_len)
          break
        end
        local stree = sp_tree:add(body(p, fixed + s.hdr_len), string.format("Sample %d", #samples))
        s.sample = #samples
        if s.subframe > 9 then bad[#bad + 1] = string.format("sample%d.subframe=%d", k, s.subframe); s.subframe = nil end
        if s.sfn > 1023 then bad[#bad + 1] = string.format("sample%d.sfn=%d", k, s.sfn); s.sfn = nil end
        if RNTI_NAMES[s.rnti_type] == nil then bad[#bad + 1] = string.format("sample%d.rnti_type=%d", k, s.rnti_type) end
        s.rnti_type_name = RNTI_NAMES[s.rnti_type] or "unknown"
        if not downlink then
          s.bsr_event_name = BSR_EVENT[s.bsr_event] or "unknown"
          s.bsr_trigger_name = BSR_TRIGGER[s.bsr_trigger] or "unknown"
        end
        local hdr = body(p + fixed, s.hdr_len)
        local rows, hdr_note = parse_subheaders(hdr, downlink)
        local lcids = {}
        for _, row in ipairs(rows) do
          lcids[#lcids + 1] = tostring(row.lcid)
          local htree = stree:add(hdr(row.from, row.len), string.format("Sub-header LCID %d (%s)", row.lcid, row.lcid_name))
          add(htree, "subhdr.sample", hdr(row.from, 1), s.sample)
          add(htree, "subhdr.lcid", hdr(row.from, 1), row.lcid)
          add(htree, "subhdr.lcid_name", hdr(row.from, 1), row.lcid_name)
          add(htree, "subhdr.extension", hdr(row.from, 1), row.extension)
          add(htree, "subhdr.length", hdr(row.from, row.len), row.length)
        end
        s.lcids = join(lcids, ",")
        if hdr_note ~= "" then s.header_note = hdr_note end
        if not downlink then
          local phr, used = ul_control_elements(hdr)
          s.header_consistent = (used == s.hdr_len) and 1 or 0
          s.power_headroom_db = phr
        end
        add_all(stree, "sample", body(p, fixed), s)
        samples[#samples + 1] = s
        p = p + fixed + s.hdr_len
      end
      -- (v7 pads its subpacket to a multiple of 4 bytes; 1-3 trailing bytes are that padding)
      if p < stop and not (hw_versions[sp_version] and stop - p < 4) then
        notes[#notes + 1] = string.format("%d bytes after the last sample", stop - p)
      end
      off = stop
    end
  end
  if nsp == 0 then notes[#notes + 1] = "no subpackets" end
  table.insert(notes, 1, source_note)
  local decoded = "partial"
  if #samples > 0 then
    local first = samples[1]
    fields.num_samples = #samples
    local total = 0
    for _, s in ipairs(samples) do total = total + s[size_key] end
    fields[size_key] = total
    for _, key in ipairs({ "sfn", "subframe", "harq_id", "rnti_type", "rnti_type_name", "cell_id" }) do fields[key] = first[key] end
    fields.lcids = first.lcids
    if not downlink then
      for _, s in ipairs(samples) do
        if s.power_headroom_db ~= nil then fields.power_headroom_db = s.power_headroom_db; break end
      end
    end
    if #notes == 1 and #bad == 0 then decoded = "fields" end
  end
  if #bad > 0 then notes[#notes + 1] = "implausible: " .. join(bad, ", ") end
  add_all(root, nil, body(0, 4), fields)
  add(root, "note", body(0, 4), join(notes, "; "))
  root:append_text(" (" .. decoded .. ")")
  if fields.num_samples == nil then return string.format("v%d (partial)", version) end
  return string.format("%d samples %s %d bytes %s LCID %s", fields.num_samples, downlink and "TBS" or "grant",
                       fields[size_key], fields.rnti_type_name, fields.lcids)
end

-- 0xB063 v50 (0x32): lte_mac._decode_dl_tb_v50, from web/engine/src/phy/decoders/lteMac.ts decodeB063
local TB_HEADER_BYTES, SDU_DESCRIPTOR_BYTES, MAX_TB_BYTES = 16, 12, 9422

local function tb_header_v50(body, o)
  if o < 0 or o + TB_HEADER_BYTES > body:len() then return nil end
  local size, padding, word = body(o, 4):le_uint(), body(o + 4, 4):le_uint(), body(o + 8, 4):le_uint()
  local carrier_harq, n_sdu, header_length = body(o + 12, 1):uint(), body(o + 13, 1):uint(), body(o + 14, 2):le_uint()
  if n_sdu < 1 or n_sdu > 8 then return nil end
  if header_length > 4 * n_sdu + 4 then return nil end
  if size == 0 or size > MAX_TB_BYTES or padding > size then return nil end
  return { size_bytes = size, padding_bytes = padding, sfn = bits(word, 0, 10), subframe = bits(word, 10, 4),
           carrier = bits(carrier_harq, 0, 4), harq_id = bits(carrier_harq, 4, 4), header_length = header_length,
           num_sdus = n_sdu }
end

local function decode_dl_tb_v50(body, tree)
  if body:len() < 8 then nofit() end
  local root = tree:add(proto_lte, body())
  local declared = body(4, 4):le_uint()
  local fields = { version = 0x32, direction = "dl", num_transport_blocks = declared }
  local notes = { HW_NOTE }
  local blocks = {}
  local pos, resynced = 8, 0
  local n = body:len()
  while #blocks < declared do
    local tb = tb_header_v50(body, pos)
    if tb == nil then
      local last = blocks[#blocks]
      local nxt = -1
      local q = pos
      while q + TB_HEADER_BYTES <= n do
        local cand = tb_header_v50(body, q)
        if cand ~= nil and (last == nil or (cand.sfn - last.sfn + 1024) % 1024 <= 2) then nxt = q; break end
        q = q + 4
      end
      if nxt < 0 then break end
      resynced = resynced + 1
      pos = nxt
    else
      local start = pos + TB_HEADER_BYTES
      tb.tb = #blocks
      local tail = 0
      local lcids = {}
      local sdu_rows = {}
      for i = 0, tb.num_sdus - 1 do
        local p = start + SDU_DESCRIPTOR_BYTES * i
        if p + 3 > n then break end
        local word = body(p, 1):uint() + body(p + 1, 1):uint() * 256 + body(p + 2, 1):uint() * 65536
        local lcid = bits(word, 1, 6)
        sdu_rows[#sdu_rows + 1] = { at = p, tb = tb.tb, control = bits(word, 0, 1), lcid = lcid, lcid_name = lcid_name(lcid, true),
                                    length_bytes = bits(word, 7, 16) }
        lcids[#lcids + 1] = tostring(lcid)
        if p + SDU_DESCRIPTOR_BYTES <= n then tail = tail + 8 * body(p + 9, 1):uint() end
      end
      tb.lcids = join(lcids, ",")
      local stop = math.min(start + SDU_DESCRIPTOR_BYTES * tb.num_sdus + tail, n)
      local ttree = root:add(body(pos, stop - pos), string.format("Transport block %d", tb.tb))
      add_all(ttree, "tb", body(pos, TB_HEADER_BYTES), tb)
      for _, sdu in ipairs(sdu_rows) do
        local stree = ttree:add(body(sdu.at, math.min(SDU_DESCRIPTOR_BYTES, n - sdu.at)), string.format("SDU LCID %d (%s)", sdu.lcid, sdu.lcid_name))
        add_all(stree, "sdu", body(sdu.at, 3), sdu)
      end
      blocks[#blocks + 1] = tb
      pos = start + SDU_DESCRIPTOR_BYTES * tb.num_sdus + tail
    end
  end
  local exact = (pos == n) and (#blocks == declared)
  fields.num_found, fields.walk_exact, fields.resynced = #blocks, exact and 1 or 0, resynced
  if #blocks > 0 then
    local first = blocks[1]
    local total, padding = 0, 0
    for _, b in ipairs(blocks) do total = total + b.size_bytes; padding = padding + b.padding_bytes end
    fields.tbs_bytes, fields.padding_bytes = total, padding
    fields.sfn, fields.subframe, fields.harq_id, fields.cell_id, fields.lcids = first.sfn, first.subframe, first.harq_id, first.carrier, first.lcids
  end
  if not exact then
    if #blocks == declared then
      notes[#notes + 1] = string.format("walk found all %d transport blocks but ended %d bytes before the end of the body (%d resyncs)",
                                        declared, n - pos, resynced)
    else
      notes[#notes + 1] = string.format("walk found %d of %d declared transport blocks (%d resyncs); the rest is not read",
                                        #blocks, declared, resynced)
    end
  end
  notes[#notes + 1] = "no MAC PDU bytes in this version"
  add_all(root, nil, body(0, 8), fields)
  add(root, "note", body(0, 8), join(notes, "; "))
  root:append_text(" (" .. (#blocks > 0 and "fields" or "partial") .. ")")
  if fields.tbs_bytes == nil then
    return string.format("v%d, %d TB declared, none found (partial)", fields.version, declared)
  end
  return string.format("%d of %d TB TBS %d bytes LCID %s", fields.num_found, declared, fields.tbs_bytes, fields.lcids)
end

D[0xB063] = function(body, pinfo, tree, ctx)
  if body:len() >= 1 and body(0, 1):uint() == 0x32 then return decode_dl_tb_v50(body, tree) end
  return decode_mac_tb(body, tree, true)
end
D[0xB064] = function(body, pinfo, tree, ctx) return decode_mac_tb(body, tree, false) end

-- ---------------------------------------------------------------------------------
-- 0xB062 LTE MAC RACH Attempt (fieldtap/decode/lte_mac.py decode_rach_attempt)

D[0xB062] = function(body, pinfo, tree, ctx)
  if body:len() < 4 then nofit() end
  local root = tree:add(proto_lte, body())
  local version, nsub = body(0, 1):uint(), body(1, 1):uint()
  local fields = { version = version, num_subpackets = nsub }
  local notes = { HW_NOTE }
  local attempts = {}
  local nsp = 0
  local off = 4
  for _ = 1, nsub do
    if off + 4 > body:len() then
      if nsp == 0 then nofit() end
      notes[#notes + 1] = "subpacket header beyond the body"
      break
    end
    local sp_id, sp_version, sp_size = body(off, 1):uint(), body(off + 1, 1):uint(), body(off + 2, 2):le_uint()
    local start = off + 4
    off = start + sp_size
    nsp = nsp + 1
    local sp_tree = root:add(body(start - 4, math.min(4 + sp_size, body:len() - start + 4)),
                             string.format("Subpacket %d v%d, %d bytes", sp_id, sp_version, sp_size))
    add(sp_tree, "sp.subpacket_id", body(start - 4, 1), sp_id)
    add(sp_tree, "sp.subpacket_version", body(start - 3, 1), sp_version)
    add(sp_tree, "sp.subpacket_size", body(start - 2, 2), sp_size)
    if sp_id == 6 then
      if sp_version ~= 50 then
        notes[#notes + 1] = string.format("subpacket version %d not implemented", sp_version)
      elseif sp_size < 41 or start + 41 > body:len() then
        if #attempts == 0 then nofit() end
        notes[#notes + 1] = "subpacket shorter than 41 bytes"
        break
      else
        local mask = body(start + 5, 1):uint()
        local row = { attempt = #attempts, cell_id = body(start + 1, 1):uint(), num_attempts = body(start + 2, 1):uint(),
                      result = body(start + 3, 1):uint(), contention = body(start + 4, 1):uint(), msg_mask = mask,
                      preamble = body(start + 6, 1):uint(), preamble_target_dbm = s16(body(start + 8, 2):le_uint()),
                      ul_earfcn = body(start + 37, 4):le_uint() }
        if mask % 4 >= 2 then row.ta_rar = body(start + 18, 2):le_uint() end
        add_all(sp_tree, "rach", body(start, 41), row)
        attempts[#attempts + 1] = row
      end
    end
  end
  if nsp == 0 then notes[#notes + 1] = "no subpackets" end
  if #attempts > 0 then
    for k, v in pairs(attempts[1]) do
      if k ~= "attempt" then fields[k] = v end
    end
    fields.num_rach_attempts = #attempts
  end
  add_all(root, nil, body(0, 4), fields)
  add(root, "note", body(0, 4), join(notes, "; "))
  root:append_text(" (" .. (#attempts > 0 and "fields" or "partial") .. ")")
  if fields.preamble == nil then return string.format("v%d (partial)", version) end
  return string.format("cell %d attempt %d result %d preamble %d target %d dBm TA %s UL EARFCN %d", fields.cell_id,
                       fields.num_attempts, fields.result, fields.preamble, fields.preamble_target_dbm, na(fields.ta_rar),
                       fields.ul_earfcn)
end

-- ---------------------------------------------------------------------------------
-- 0xB173 LTE PDSCH Stat Indication (fieldtap/decode/lte_phy.py)

local PDSCH_LAYOUT = {   -- P1 len, TB len, P2 len, modulation byte, HSIC bits, QED byte
  [5] = { 6, 6, 2, false, false, false }, [16] = { 6, 6, 2, false, true, false },
  [24] = { 6, 8, 2, true, true, false }, [32] = { 6, 8, 2, true, true, false }, [36] = { 12, 12, 4, true, true, true },
}
local MODULATION_V24 = { [2] = "QPSK", [4] = "16QAM", [6] = "64QAM", [8] = "256QAM" }

local function pdsch_tb(body, p, version, has_mod, has_qed)
  local harq, rnti = body(p, 1):uint(), body(p + 1, 1):uint()
  local q = p + 2
  if version == 36 then q = q + 2 end
  local tb = {
    harq_id = bits(harq, 0, 4), rv = bits(harq, 4, 2), ndi = bits(harq, 6, 1), crc_pass = bits(harq, 7, 1),
    rnti_type = bits(rnti, 0, 4), tb_index = bits(rnti, 4, 1), discarded_retx_present = bits(rnti, 5, 1),
    did_recombining = bits(rnti, 6, 1), tb_size = body(q, 2):le_uint(), mcs = body(q + 2, 1):uint(),
    num_rbs = body(q + 3, 1):uint(),
  }
  tb.rnti_type_name = RNTI_NAMES[tb.rnti_type] or "unknown"
  if has_mod then
    tb.modulation_code = body(q + 4, 1):uint()
    tb.modulation = MODULATION_V24[tb.modulation_code] or "unknown"
  elseif version == 5 then
    if tb.mcs >= 17 then tb.modulation = "64QAM" elseif tb.mcs >= 10 then tb.modulation = "16QAM" else tb.modulation = "QPSK" end
  end
  if has_qed then
    local qed = body(q + 5, 1):uint()
    tb.qed2_interim_status, tb.qed_iteration = bits(qed, 0, 2), bits(qed, 2, 6)
  end
  return tb
end

-- v50 (iPhone 17): lte_phy._decode_pdsch_stat_v50, from web/engine/src/phy/decoders/b173.ts
local function decode_pdsch_v50(body, tree, fields)
  local num_records = fields.num_records
  if body:len() < 4 + num_records * 40 then nofit() end
  local root = tree:add(proto_lte, body())
  local notes = { HW_NOTE }
  local bad, tbs, first_rec = {}, {}, nil
  for i = 0, num_records - 1 do
    local r = 4 + 40 * i
    local rtree = root:add(body(r, 40), string.format("Record %d", i))
    local sf_word = body(r, 2):le_uint()
    local num_tb = body(r + 3, 1):uint()
    local row = { record = i, subframe = bits(sf_word, 0, 4), sfn = bits(sf_word, 4, 12), num_layers = body(r + 2, 1):uint(),
                  num_tb = num_tb, serving_cell_index = bits(body(r + 4, 1):uint(), 0, 3) }
    for _, lim in ipairs({ { "subframe", 9 }, { "sfn", 1023 } }) do
      if row[lim[1]] > lim[2] then bad[#bad + 1] = string.format("record%d.%s=%d", i, lim[1], row[lim[1]]); row[lim[1]] = nil end
    end
    if num_tb > 2 then bad[#bad + 1] = string.format("record%d.num_tb=%d", i, num_tb); num_tb = 2 end
    for t = 0, num_tb - 1 do
      local p = r + 12 + 12 * t
      local harq, rnti = body(p, 1):uint(), body(p + 1, 2):le_uint()
      local qm = body(p + 8, 1):uint()
      local tb = { record = i, tb = t, harq_id = bits(harq, 0, 4), rv = bits(harq, 4, 2), ndi = bits(harq, 6, 1),
                   crc_pass = bits(harq, 7, 1), rnti_type = bits(rnti, 0, 4), tb_index = bits(rnti, 4, 1),
                   tb_size = body(p + 4, 2):le_uint(), mcs = body(p + 6, 1):uint(), num_rbs = body(p + 7, 1):uint(),
                   qm = qm, modulation = MODULATION_V24[qm] }
      tb.rnti_type_name = RNTI_NAMES[tb.rnti_type] or "unknown"
      for _, lim in ipairs({ { "mcs", 31 }, { "num_rbs", 110 } }) do
        if tb[lim[1]] > lim[2] then bad[#bad + 1] = string.format("record%d.tb%d.%s=%d", i, t, lim[1], tb[lim[1]]); tb[lim[1]] = nil end
      end
      if RNTI_NAMES[tb.rnti_type] == nil then bad[#bad + 1] = string.format("record%d.tb%d.rnti_type=%d", i, t, tb.rnti_type) end
      if MODULATION_V24[qm] == nil and qm ~= 0 then bad[#bad + 1] = string.format("record%d.tb%d.qm=%d", i, t, qm) end
      local ttree = rtree:add(body(p, 12), string.format("Transport block %d", t))
      add_all(ttree, "tb", body(p, 12), tb)
      tbs[#tbs + 1] = tb
    end
    add_all(rtree, "record", body(r, 12), row)
    if first_rec == nil then first_rec = row end
  end
  if #tbs > 0 then
    local first = tbs[1]
    local total, pass, fail = 0, 0, 0
    for _, t in ipairs(tbs) do
      total = total + t.tb_size
      if t.crc_pass == 1 then pass = pass + 1 else fail = fail + 1 end
    end
    fields.sfn, fields.subframe, fields.tbs_bytes, fields.num_tb = first_rec.sfn, first_rec.subframe, total, #tbs
    fields.harq_id, fields.rnti_type, fields.rnti_type_name = first.harq_id, first.rnti_type, first.rnti_type_name
    fields.mcs, fields.modulation, fields.num_rbs = first.mcs, first.modulation, first.num_rbs
    fields.crc_pass, fields.crc_fail = pass, fail
  end
  if #bad > 0 then notes[#notes + 1] = "implausible: " .. join(bad, ", ") end
  add_all(root, nil, body(0, 4), fields)
  add(root, "note", body(0, 4), join(notes, "; "))
  if fields.tbs_bytes == nil then return string.format("v%d, %d records (partial)", fields.version, num_records) end
  return string.format("%d TB %d bytes MCS %s %s CRC %d/%d", fields.num_tb, fields.tbs_bytes, na(fields.mcs),
                       na(fields.modulation), fields.crc_pass, fields.crc_pass + fields.crc_fail)
end

D[0xB173] = function(body, pinfo, tree, ctx)
  if body:len() < 4 then nofit() end
  local version, num_records = body(0, 1):uint(), body(1, 1):uint()
  local fields = { version = version, num_records = num_records }
  if version == 50 then return decode_pdsch_v50(body, tree, fields) end
  local root = tree:add(proto_lte, body())
  local notes = { DOC_NOTE }
  local layout = PDSCH_LAYOUT[version]
  if layout == nil then
    notes[#notes + 1] = string.format("version %d not documented", version)
    add_all(root, nil, body(0, 4), fields)
    add(root, "note", body(0, 4), join(notes, "; "))
    return string.format("v%d, %d records (partial)", version, num_records)
  end
  local p1_len, tb_len, p2_len, has_mod, has_hsic, has_qed = layout[1], layout[2], layout[3], layout[4], layout[5], layout[6]
  local rec_len = p1_len + 2 * tb_len + p2_len
  if body:len() < 4 + num_records * rec_len then nofit() end
  local bad, tbs, first_rec = {}, {}, nil
  local off = 4
  for i = 0, num_records - 1 do
    local rtree = root:add(body(off, rec_len), string.format("Record %d", i))
    local sf_word = body(off, 2):le_uint()
    local cell_byte = body(off + 5, 1):uint()
    local row = { record = i, subframe = bits(sf_word, 0, 4), sfn = bits(sf_word, 4, 12), num_rbs = body(off + 2, 1):uint(),
                  num_layers = body(off + 3, 1):uint(), num_tb = body(off + 4, 1):uint(), serving_cell_index = bits(cell_byte, 0, 3) }
    if has_hsic then row.hsic_enabled = bits(cell_byte, 3, 4) end
    for _, lim in ipairs({ { "subframe", 9 }, { "sfn", 1023 }, { "num_rbs", 110 } }) do
      if row[lim[1]] > lim[2] then bad[#bad + 1] = string.format("record%d.%s=%d", i, lim[1], row[lim[1]]); row[lim[1]] = nil end
    end
    local num_tb = row.num_tb
    if num_tb ~= 1 and num_tb ~= 2 then bad[#bad + 1] = string.format("record%d.num_tb=%d", i, num_tb); num_tb = 0 end
    local p = off + p1_len
    for t = 0, num_tb - 1 do
      local tb = pdsch_tb(body, p, version, has_mod, has_qed)
      tb.record, tb.tb = i, t
      for _, lim in ipairs({ { "mcs", 31 }, { "num_rbs", 110 } }) do
        if tb[lim[1]] > lim[2] then bad[#bad + 1] = string.format("record%d.tb%d.%s=%d", i, t, lim[1], tb[lim[1]]); tb[lim[1]] = nil end
      end
      if RNTI_NAMES[tb.rnti_type] == nil then bad[#bad + 1] = string.format("record%d.tb%d.rnti_type=%d", i, t, tb.rnti_type) end
      local ttree = rtree:add(body(p, tb_len), string.format("Transport block %d", t))
      add_all(ttree, "tb", body(p, tb_len), tb)
      tbs[#tbs + 1] = tb
      p = p + tb_len
    end
    p = off + p1_len + 2 * tb_len
    row.pmch_id, row.area_id = body(p, 1):uint(), body(p + 1, 1):uint()
    add_all(rtree, "record", body(off, p1_len), row)
    if first_rec == nil then first_rec = row end
    off = off + rec_len
  end
  if #tbs > 0 then
    local first = tbs[1]
    local total, pass, fail = 0, 0, 0
    for _, t in ipairs(tbs) do
      total = total + t.tb_size
      if t.crc_pass == 1 then pass = pass + 1 else fail = fail + 1 end
    end
    fields.sfn, fields.subframe, fields.tbs_bytes, fields.num_tb = first_rec.sfn, first_rec.subframe, total, #tbs
    fields.harq_id, fields.rnti_type, fields.rnti_type_name = first.harq_id, first.rnti_type, first.rnti_type_name
    fields.mcs, fields.modulation, fields.num_rbs = first.mcs, first.modulation, first_rec.num_rbs
    fields.crc_pass, fields.crc_fail = pass, fail
  end
  if #bad > 0 then notes[#notes + 1] = "implausible: " .. join(bad, ", ") end
  add_all(root, nil, body(0, 4), fields)
  add(root, "note", body(0, 4), join(notes, "; "))
  if fields.tbs_bytes == nil then return string.format("v%d, %d records (partial)", version, num_records) end
  return string.format("%d TB %d bytes MCS %s %s CRC %d/%d", fields.num_tb, fields.tbs_bytes, na(fields.mcs),
                       na(fields.modulation), fields.crc_pass, fields.crc_pass + fields.crc_fail)
end

-- ---------------------------------------------------------------------------------
-- 0xB139 LTE PHY PUSCH Tx Report (fieldtap/decode/lte_phy.py)

local PUSCH_RECORD_LEN = { [23] = 48, [24] = 48, [26] = 52 }
local PUSCH_MOD = { [0] = "BPSK", [1] = "QPSK", [2] = "16QAM", [3] = "64QAM" }

-- v162 (iPhone 17): lte_phy._decode_pusch_tx_v162, from web/engine/src/phy/decoders/b139.ts
local PUSCH_MOD_V162 = { [1] = "QPSK", [2] = "16QAM", [3] = "64QAM", [4] = "256QAM" }
local PUSCH_QM_V162 = { [1] = 2, [2] = 4, [3] = 6, [4] = 8 }

local function decode_pusch_v162(body, tree, fields)
  if body:len() < 8 + fields.num_records * 100 then nofit() end
  local root = tree:add(proto_lte, body())
  local notes = { HW_NOTE }
  local bad, grants = {}, {}
  for i = 0, fields.num_records - 1 do
    local r = body(8 + 100 * i, 100)
    local gtree = root:add(r, string.format("Grant %d", i))
    local w0, w1 = r(0, 4):le_uint(), r(4, 4):le_uint()
    local flags = bits(w0, 16, 16)
    local tti = bits(w0, 0, 16)
    local code = bits(r(36, 1):uint(), 2, 3)
    local power_raw = r(46, 1):uint()
    local g = { grant = i, tti = tti, sfn = math.floor(tti / 10), subframe = tti % 10, carrier = bits(flags, 0, 2),
                retx_index = bits(flags, 7, 5), start_rb = bits(w1, 1, 7), num_rbs = bits(w1, 15, 7),
                tb_size = r(8, 2):le_uint(), coding_rate = r(10, 2):le_uint() / 1024, modulation_code = code,
                modulation = PUSCH_MOD_V162[code], mod_order = PUSCH_QM_V162[code], power_raw = power_raw,
                required_power_dbm = power_raw / 4 - 1.5 }
    for _, lim in ipairs({ { "sfn", 0, 1023 }, { "num_rbs", 0, 110 }, { "coding_rate", 0, 2 } }) do
      local v = g[lim[1]]
      if v < lim[2] or v > lim[3] then
        bad[#bad + 1] = string.format("grant%d.%s=%s", i, lim[1], tostring(v))
        g[lim[1]] = nil
      end
    end
    if g.sfn == nil then g.subframe = nil end
    add_all(gtree, "grant", r, g)
    grants[#grants + 1] = g
  end
  if #grants > 0 then
    local first = grants[1]
    local total = 0
    for _, g in ipairs(grants) do total = total + g.tb_size end
    fields.tti, fields.sfn, fields.subframe, fields.tbs_bytes = first.tti, first.sfn, first.subframe, total
    fields.required_power_dbm, fields.modulation, fields.mod_order = first.required_power_dbm, first.modulation, first.mod_order
    fields.coding_rate, fields.num_rbs = first.coding_rate, first.num_rbs
  end
  if #bad > 0 then notes[#notes + 1] = "implausible: " .. join(bad, ", ") end
  add_all(root, nil, body(0, 8), fields)
  add(root, "note", body(0, 8), join(notes, "; "))
  if fields.tbs_bytes == nil then return string.format("v%d, %d records (partial)", fields.version, fields.num_records) end
  return string.format("%d grants %d bytes %s Tx %.2f dBm", fields.num_records, fields.tbs_bytes, na(fields.modulation),
                       fields.required_power_dbm)
end

D[0xB139] = function(body, pinfo, tree, ctx)
  if body:len() < 8 then nofit() end
  local version = body(0, 1):uint()
  local word = body(1, 2):le_uint()
  local fields = { version = version, serving_cell_id = bits(word, 0, 9), num_records = bits(word, 9, 5),
                   dispatch_sfn_sf_raw = body(4, 2):le_uint() }
  if version == 162 then return decode_pusch_v162(body, tree, fields) end
  local root = tree:add(proto_lte, body())
  local notes = { DOC_NOTE }
  local rec_len = PUSCH_RECORD_LEN[version]
  if rec_len == nil then
    notes[#notes + 1] = string.format("version %d not documented", version)
    add_all(root, nil, body(0, 8), fields)
    add(root, "note", body(0, 8), join(notes, "; "))
    return string.format("v%d, %d records (partial)", version, fields.num_records)
  end
  if body:len() < 8 + fields.num_records * rec_len then nofit() end
  local bad, grants = {}, {}
  local off = 8
  for i = 0, fields.num_records - 1 do
    local r = body(off, rec_len)
    local gtree = root:add(r, string.format("Grant %d", i))
    local sfn_sf, coding_raw = r(0, 2):le_uint(), r(2, 2):le_uint()
    local a, b, c, d = r(4, 4):le_uint(), r(8, 4):le_uint(), r(16, 4):le_uint(), r(24, 4):le_uint()
    local ack_word, srs_byte = r(14, 2):le_uint(), r(21, 1):uint()
    local g = {
      grant = i, sfn = bits(sfn_sf, 4, 12), subframe = bits(sfn_sf, 0, 4), coding_rate = coding_raw / 1024,
      ack = bits(a, 0, 1), cqi = bits(a, 1, 1), ri = bits(a, 2, 1), frequency_hopping = bits(a, 3, 2), rv = bits(a, 5, 2),
      mirror_hopping = bits(a, 7, 2), dmrs_cyclic_shift_slot0 = bits(a, 9, 4), dmrs_cyclic_shift_slot1 = bits(a, 13, 4),
      dmrs_root_slot0 = bits(a, 17, 11), ue_srs = bits(a, 28, 1),
      dmrs_root_slot1 = bits(b, 0, 11), start_rb_slot0 = bits(b, 11, 7), start_rb_slot1 = bits(b, 18, 7), num_rbs = bits(b, 25, 7),
      tb_size = r(12, 2):le_uint(), num_ack_bits = bits(ack_word, 0, 3), ack_payload = bits(ack_word, 3, 4),
      rate_matched_ack_bits = bits(c, 0, 11), num_ri_bits = bits(c, 11, 2), ri_payload = bits(c, 13, 2),
      rate_matched_ri_bits = bits(c, 15, 11), mod_order = bits(c, 26, 2),
      digital_gain_db = r(20, 1):uint(), srs_occasion = bits(srs_byte, 0, 1), retx_index = bits(srs_byte, 1, 5),
      tx_power_dbm = bits(d, 0, 10), num_cqi_bits = bits(d, 10, 8), rate_matched_cqi_bits = bits(d, 18, 14),
      tx_resampler = r(44, 4):le_uint(),
    }
    if g.tx_power_dbm >= 512 then g.tx_power_dbm = g.tx_power_dbm - 1024 end
    g.modulation = PUSCH_MOD[g.mod_order]
    if version == 26 then
      local e = r(48, 4):le_uint()
      g.num_repetition, g.rb_nb_start_index = bits(e, 0, 12), bits(e, 12, 8)
    end
    for _, lim in ipairs({ { "subframe", 0, 9 }, { "sfn", 0, 1023 }, { "num_rbs", 0, 110 }, { "coding_rate", 0, 2 },
                           { "tx_power_dbm", -60, 33 } }) do
      local v = g[lim[1]]
      if v < lim[2] or v > lim[3] then
        bad[#bad + 1] = string.format("grant%d.%s=%s", i, lim[1], tostring(v))
        g[lim[1]] = nil
      end
    end
    add_all(gtree, "grant", r, g)
    gtree:add(F["grant.cqi_payload"], r(28, 16))
    grants[#grants + 1] = g
    off = off + rec_len
  end
  if #grants > 0 then
    local first = grants[1]
    local total = 0
    for _, g in ipairs(grants) do total = total + g.tb_size end
    fields.sfn, fields.subframe, fields.tbs_bytes, fields.tx_power_dbm = first.sfn, first.subframe, total, first.tx_power_dbm
    fields.modulation, fields.mod_order, fields.coding_rate, fields.num_rbs = first.modulation, first.mod_order, first.coding_rate, first.num_rbs
  end
  if #bad > 0 then notes[#notes + 1] = "implausible: " .. join(bad, ", ") end
  add_all(root, nil, body(0, 8), fields)
  add(root, "note", body(0, 8), join(notes, "; "))
  if fields.tbs_bytes == nil then return string.format("v%d, %d records (partial)", version, fields.num_records) end
  local power = "n/a"
  if fields.tx_power_dbm ~= nil then power = string.format("%d dBm", fields.tx_power_dbm) end
  return string.format("%d grants %d bytes %s Tx %s", fields.num_records, fields.tbs_bytes, fields.modulation, power)
end

-- ---------------------------------------------------------------------------------
-- LL1/ML1 per-subframe reports of the iPhone 17 (fieldtap/decode/lte_ll1.py)

local function wrong_version(body, tree, version, wanted)
  local root = tree:add(proto_lte, body())
  add(root, "version", body(0, 1), version)
  add(root, "note", body(0, 1), HW_NOTE .. string.format("; version %d not implemented (only v%d)", version, wanted))
  root:append_text(" (partial)")
  return string.format("v%d (partial)", version)
end

-- 0xB14E LTE LL1 PUSCH CSF v164 (csf.ts decodeB14E)
D[0xB14E] = function(body, pinfo, tree, ctx)
  if body:len() < 1 then nofit() end
  local version = body(0, 1):uint()
  if version ~= 164 then return wrong_version(body, tree, version, 164) end
  if body:len() < 10 then nofit() end
  local root = tree:add(proto_lte, body())
  local a, c = body(1, 4):le_uint(), body(5, 4):le_uint()
  local fields = { version = version, sfn = bits(a, 4, 10), subframe = bits(a, 0, 4), carrier = bits(a, 14, 4),
                   ri = bits(a, 28, 2) + 1, cqi_cw0 = bits(c, 7, 4), cqi_cw1 = bits(c, 11, 4), wideband_pmi = bits(c, 24, 4),
                   tx_mode = bits(body(9, 1):uint(), 0, 4) }
  local notes = { HW_NOTE }
  if fields.subframe > 9 then
    notes[#notes + 1] = string.format("implausible: subframe=%d", fields.subframe)
    fields.subframe = nil
  end
  add_all(root, nil, body(0, 10), fields)
  add(root, "note", body(0, 10), join(notes, "; "))
  return string.format("SFN %d.%s CQI %d/%d RI %d PMI %d TM %d", fields.sfn, na(fields.subframe), fields.cqi_cw0,
                       fields.cqi_cw1, fields.ri, fields.wideband_pmi, fields.tx_mode)
end

-- 0xB14D LTE LL1 PUCCH CSF v164 (csf.ts decodeB14D)
D[0xB14D] = function(body, pinfo, tree, ctx)
  if body:len() < 1 then nofit() end
  local version = body(0, 1):uint()
  if version ~= 164 then return wrong_version(body, tree, version, 164) end
  if body:len() < 14 then nofit() end
  local root = tree:add(proto_lte, body())
  local a = body(1, 4):le_uint()
  local q, mode_word, r = body(6, 2):le_uint(), body(8, 2):le_uint(), body(10, 2):le_uint()
  local report_type = bits(a, 26, 4)
  local fields = { version = version, sfn = bits(a, 4, 10), subframe = bits(a, 0, 4), carrier = bits(a, 14, 4),
                   report_type = report_type, tx_mode = bits(mode_word, 0, 4) }
  if report_type == 3 then
    fields.ri = bits(r, 8, 2) + 1
  elseif report_type == 2 or report_type == 4 then
    fields.cqi_cw0, fields.cqi_cw1, fields.wideband_pmi = bits(q, 4, 4), bits(q, 8, 4), bits(q, 12, 4)
  end
  local notes = { HW_NOTE }
  if fields.subframe > 9 then
    notes[#notes + 1] = string.format("implausible: subframe=%d", fields.subframe)
    fields.subframe = nil
  end
  add_all(root, nil, body(0, 14), fields)
  add(root, "note", body(0, 14), join(notes, "; "))
  local line = string.format("SFN %d.%s type %d", fields.sfn, na(fields.subframe), report_type)
  if fields.ri ~= nil then line = line .. string.format(" RI %d", fields.ri) end
  if fields.cqi_cw0 ~= nil then line = line .. string.format(" CQI %d/%d PMI %d", fields.cqi_cw0, fields.cqi_cw1, fields.wideband_pmi) end
  return line .. string.format(" TM %d", fields.tx_mode)
end

-- 0xB126 LTE LL1 PDSCH Demapper Configuration v163 (b126.ts)
local RX_ANTENNAS = { [0] = 1, [1] = 2, [2] = 3, [3] = 4 }

D[0xB126] = function(body, pinfo, tree, ctx)
  if body:len() < 1 then nofit() end
  local version = body(0, 1):uint()
  if version ~= 163 then return wrong_version(body, tree, version, 163) end
  if body:len() ~= 968 then nofit() end
  local root = tree:add(proto_lte, body())
  local bad = {}
  local now = nil
  for k = 0, 19 do
    local o = 8 + 48 * k
    local word, antennas = body(o, 2):le_uint(), body(o + 2, 1):uint()
    local lo = body(o + 8, 4):le_uint()
    local hi = body(o + 12, 1):uint() + body(o + 13, 1):uint() * 256 + body(o + 14, 1):uint() * 65536
    local row = { index = k, sfn = bits(word, 4, 10), subframe = bits(word, 0, 4), tx_antennas = bits(antennas, 1, 3),
                  rx_antennas = RX_ANTENNAS[bits(antennas, 4, 2)], rank = bits(body(o + 4, 1):uint(), 0, 2) + 1,
                  prb_mask_lo = lo, prb_mask_hi = hi, num_prb = popcount(lo) + popcount(hi) }
    if row.subframe > 9 then bad[#bad + 1] = string.format("subframe%d.subframe=%d", k, row.subframe); row.subframe = nil end
    local stree = root:add(body(o, 48), string.format("Subframe %d", k))
    add_all(stree, "dmp", body(o, 48), row)
    now = row
  end
  local fields = { version = version, num_subframes = 20, sfn = now.sfn, subframe = now.subframe, tx_antennas = now.tx_antennas,
                   rx_antennas = now.rx_antennas, rank = now.rank, num_prb = now.num_prb }
  local notes = { HW_NOTE, "headline = the last (newest) subframe" }
  if #bad > 0 then notes[#notes + 1] = "implausible: " .. join(bad, ", ") end
  add_all(root, nil, body(0, 8), fields)
  add(root, "note", body(0, 8), join(notes, "; "))
  return string.format("SFN %d.%s Tx ant %d Rx ant %d rank %d %d PRB", fields.sfn, na(fields.subframe), fields.tx_antennas,
                       fields.rx_antennas, fields.rank, fields.num_prb)
end

-- 0xB12A LTE LL1 PCFICH Decoding Results v161 (b12a.ts)
D[0xB12A] = function(body, pinfo, tree, ctx)
  if body:len() < 1 then nofit() end
  local version = body(0, 1):uint()
  if version ~= 161 then return wrong_version(body, tree, version, 161) end
  if body:len() ~= 176 then nofit() end
  local root = tree:add(proto_lte, body())
  local counts = { [1] = 0, [2] = 0, [3] = 0 }
  local consistent, decoded_n = 0, 0
  for k = 0, 19 do
    local o = 16 + 8 * k
    local flag, raw = body(o + 2, 1):uint(), body(o + 3, 1):uint()
    local decoded_flag = (flag == 1) and 1 or 0
    local legal = raw == 4 or raw == 8 or raw == 12
    local ok
    if raw == 0 then ok = decoded_flag == 0 else ok = legal and decoded_flag == 1 end
    local row = { index = body(o, 2):le_uint(), subframe = bits(body(o + 4, 2):le_uint(), 8, 4), decoded_flag = decoded_flag,
                  consistent = ok and 1 or 0 }
    if legal then row.cfi = math.floor(raw / 4); counts[row.cfi] = counts[row.cfi] + 1 end
    if ok then consistent = consistent + 1 end
    decoded_n = decoded_n + decoded_flag
    local stree = root:add(body(o, 8), string.format("Subframe %d", k))
    add_all(stree, "cfi", body(o, 8), row)
  end
  local fields = { version = version, sfn = bits(body(4, 2):le_uint(), 0, 10), num_subframes = 20, num_decoded = decoded_n,
                   cfi1 = counts[1], cfi2 = counts[2], cfi3 = counts[3], num_consistent = consistent }
  local notes = { HW_NOTE }
  if consistent < 20 then notes[#notes + 1] = string.format("%d elements break the CFI/decode-flag identity", 20 - consistent) end
  add_all(root, nil, body(0, 16), fields)
  add(root, "note", body(0, 16), join(notes, "; "))
  return string.format("SFN %d CFI 1/2/3 x%d/%d/%d decoded %d/%d", fields.sfn, counts[1], counts[2], counts[3], decoded_n, 20)
end

-- 0xB16C LTE ML1 DCI Information Report v50 (b16c.ts)
local DCI_MODULATION = { [1] = "QPSK", [2] = "16QAM", [3] = "64QAM", [4] = "256QAM" }

D[0xB16C] = function(body, pinfo, tree, ctx)
  if body:len() < 1 then nofit() end
  local version = body(0, 1):uint()
  if version ~= 50 then return wrong_version(body, tree, version, 50) end
  if body:len() < 4 then nofit() end
  local root = tree:add(proto_lte, body())
  local n = body:len()
  local declared = bits(body(1, 1):uint(), 6, 2) + bits(body(2, 1):uint(), 0, 4) * 4
  local subframes, grants = {}, {}
  local pos = 4
  local exact = false
  local total_dl = 0
  while true do
    if #subframes >= declared or pos + 4 > n then
      exact = (pos == n) and (#subframes == declared)
      break
    end
    local word = body(pos, 4):le_uint()
    local n_grants, n_assign = bits(word, 14, 2), bits(word, 17, 3)
    local p = pos + 4
    local rows = {}
    for i = 0, n_grants - 1 do
      local g = p + 16 * i
      if g + 16 > n then break end
      local code = bits(body(g + 4, 1):uint(), 0, 3)
      rows[#rows + 1] = { at = g, subframe_index = #subframes, start_rb = bits(body(g + 5, 4):le_uint(), 3, 7),
                          num_rbs = bits(body(g + 6, 4):le_uint(), 2, 7), modulation_code = code, modulation = DCI_MODULATION[code] }
    end
    if #rows < n_grants then break end
    p = p + 16 * n_grants + 8 * n_assign
    if p > n then break end
    local sfn, subframe = bits(word, 0, 10), bits(word, 10, 4)
    local row = { index = #subframes, sfn = sfn, subframe = subframe, tti = sfn * 10 + subframe, num_ul_grants = n_grants,
                  num_dl_assignments = n_assign }
    local stree = root:add(body(pos, p - pos), string.format("Subframe %d", row.index))
    add_all(stree, "dci", body(pos, 4), row)
    for _, g in ipairs(rows) do
      local gtree = stree:add(body(g.at, 16), "Uplink grant")
      add_all(gtree, "ulg", body(g.at, 16), g)
      grants[#grants + 1] = g
    end
    subframes[#subframes + 1] = row
    total_dl = total_dl + n_assign
    pos = p
  end
  local fields = { version = version, num_declared = declared, num_subframes = #subframes, num_ul_grants = #grants,
                   num_dl_assignments = total_dl, walk_exact = exact and 1 or 0 }
  if #subframes > 0 then fields.sfn, fields.subframe = subframes[1].sfn, subframes[1].subframe end
  if #grants > 0 then fields.start_rb, fields.num_rbs, fields.modulation = grants[1].start_rb, grants[1].num_rbs, grants[1].modulation end
  local notes = { HW_NOTE, "downlink assignments counted, contents not read" }
  if not exact then
    notes[#notes + 1] = string.format("element chain did not consume the body (%d of %d elements)", #subframes, declared)
  end
  add_all(root, nil, body(0, 4), fields)
  add(root, "note", body(0, 4), join(notes, "; "))
  root:append_text(" (" .. (#subframes > 0 and "fields" or "partial") .. ")")
  if #subframes == 0 then return string.format("v%d (partial)", version) end
  return string.format("%d subframes %d UL grants %d DL assignments", #subframes, #grants, total_dl)
end

-- ---------------------------------------------------------------------------------
-- 0x184C LTE RF FED Tx AGC and 0x1D0B modem 100 Hz sampler (fieldtap/decode/rf.py)

local function is_block_header(body, p)
  if p + 16 > body:len() then return false end
  if body(p, 1):uint() ~= 0x11 then return false end
  for k = 2, 6 do
    if body(p + k, 1):uint() ~= 0 then return false end
  end
  return true
end

D[0x184C] = function(body, pinfo, tree, ctx)
  if body:len() < 2 then nofit() end
  local root = tree:add(proto_rf, body())
  local version = body(0, 1):uint()
  local fields = { version = version, num_blocks_declared = body(1, 1):uint() }
  local notes = { HW_NOTE }
  if version ~= 0x11 then
    notes[#notes + 1] = string.format("version %d not implemented (only v%d)", version, 0x11)
    add_all_rf(root, nil, body(0, 2), fields)
    add_rf(root, "note", body(0, 2), join(notes, "; "))
    root:append_text(" (partial)")
    return string.format("v%d (partial)", version)
  end
  local n = body:len()
  local blocks, chains = {}, {}
  local in_range = 0
  local pos = 0
  local closed = true
  while pos + 16 <= n do
    if not is_block_header(body, pos) then closed = false; break end
    local word = body(pos + 7, 2):le_uint()
    local frame, subframe = bits(word, 8, 10), bits(word, 4, 4)
    if subframe <= 9 then in_range = in_range + 1 end
    local counter = frame * 10 + subframe
    local index = #blocks
    local block = { block = index, subframe_counter = counter, frame = frame, subframe = subframe }
    local btree = root:add(body(pos, 16), string.format("Block %d", index))
    add_all_rf(btree, "blk", body(pos, 16), block)
    blocks[#blocks + 1] = block
    pos = pos + 16
    while pos + 120 <= n and not is_block_header(body, pos) do
      local power, power2 = s16(body(pos + 4, 2):le_uint()) / 10, s16(body(pos + 6, 2):le_uint()) / 10
      local chain = { block = index, subframe_counter = counter, chain = body(pos, 1):uint(), gain_state = body(pos + 1, 1):uint(),
                      tx_power_dbm = power, tx_power2_dbm = power2, limit0_dbm = body(pos + 66, 2):le_uint() / 10,
                      limit1_dbm = body(pos + 68, 2):le_uint() / 10, limit2_dbm = body(pos + 70, 2):le_uint() / 10,
                      live = (power > -70) and 1 or 0 }
      chain.at = pos
      chains[#chains + 1] = chain
      pos = pos + 120
    end
  end
  local exact = closed and pos == n
  fields.num_blocks, fields.walk_exact, fields.subframes_in_range = #blocks, exact and 1 or 0, in_range
  if not exact then
    notes[#notes + 1] = "block walk did not consume the body; no chain samples read"
    add_all_rf(root, nil, body(0, 2), fields)
    add_rf(root, "note", body(0, 2), join(notes, "; "))
    root:append_text(" (partial)")
    return string.format("v%d (partial)", version)
  end
  fields.num_chain_samples = #chains
  local live_n, first = 0, nil
  for _, c in ipairs(chains) do
    local ctree = root:add(body(c.at, 120), string.format("Chain 0x%02X (block %d)", c.chain, c.block))
    add_all_rf(ctree, "chain", body(c.at, 120), c)
    if c.live == 1 then
      live_n = live_n + 1
      if first == nil then first = c end
      if fields.max_tx_power_dbm == nil or c.tx_power_dbm > fields.max_tx_power_dbm then fields.max_tx_power_dbm = c.tx_power_dbm end
    end
  end
  fields.num_live = live_n
  if first ~= nil then
    fields.chain, fields.gain_state, fields.tx_power_dbm, fields.tx_power2_dbm = first.chain, first.gain_state, first.tx_power_dbm, first.tx_power2_dbm
    fields.limit_dbm = math.min(first.limit0_dbm, first.limit1_dbm, first.limit2_dbm)
  end
  if in_range < #blocks then notes[#notes + 1] = string.format("%d block counters outside subframes 0..9", #blocks - in_range) end
  notes[#notes + 1] = "front-end Tx power, not the PUSCH target; the block counter is not the cell's SFN"
  add_all_rf(root, nil, body(0, 2), fields)
  add_rf(root, "note", body(0, 2), join(notes, "; "))
  root:append_text(" (fields)")
  local head = string.format("%d blocks %d chain samples", #blocks, #chains)
  if live_n > 0 then
    return head .. string.format(" Tx %.1f dBm chain 0x%02X gain state 0x%02X limit %.1f dBm", fields.tx_power_dbm, fields.chain,
                                 fields.gain_state, fields.limit_dbm)
  end
  return head .. " no chain transmitting"
end

D[0x1D0B] = function(body, pinfo, tree, ctx)
  if body:len() < 4 then nofit() end
  local root = tree:add(proto_rf, body())
  local version = body(0, 4):le_uint()
  local fields = { version = version }
  local notes = { HW_NOTE }
  if version ~= 7 then
    notes[#notes + 1] = string.format("version %d not implemented (only v%d)", version, 7)
    add_all_rf(root, nil, body(0, 4), fields)
    add_rf(root, "note", body(0, 4), join(notes, "; "))
    root:append_text(" (partial)")
    return string.format("v%d (partial)", version)
  end
  if body:len() < 88 then nofit() end
  fields.ticks_1024hz = body(4, 4):le_uint()
  fields.ticks_19m2 = bits(body(8, 4):le_uint(), 0, 24)
  fields.sequence = body(84, 4):le_uint()
  notes[#notes + 1] = "only the clocks and the sequence number are read; the five 2 ms entries are not identified"
  add_all_rf(root, nil, body(0, 88), fields)
  add_rf(root, "note", body(0, 4), join(notes, "; "))
  return string.format("seq %d sleep clock %d (1024 Hz) TCXO %d (19.2 MHz)", fields.sequence, fields.ticks_1024hz, fields.ticks_19m2)
end

for _, code in ipairs({ 0xB193, 0xB179, 0xB17F, 0xB180, 0xB0C1, 0xB0C2, 0xB063, 0xB064, 0xB062, 0xB173, 0xB139,
                        0xB14E, 0xB14D, 0xB126, 0xB12A, 0xB16C, 0x184C, 0x1D0B }) do
  D[code] = guarded(D[code])
end
