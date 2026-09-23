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
-- confirm on a hardware capture.
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
})
local CELL_FIELDS = {
  {"cell", U16}, {"pci", U16}, {"serving_cell_index", U8}, {"is_serving_cell", U8}, {"sfn", U16}, {"subframe", U8},
  {"rsrp_rx0", FLT}, {"rsrp_rx1", FLT}, {"rsrp_rx2", FLT}, {"rsrp_rx3", FLT}, {"rsrp", FLT}, {"filtered_rsrp", FLT},
  {"rsrq_rx0", FLT}, {"rsrq_rx1", FLT}, {"rsrq_rx2", FLT}, {"rsrq_rx3", FLT}, {"rsrq", FLT}, {"filtered_rsrq", FLT},
  {"rssi_rx0", FLT}, {"rssi_rx1", FLT}, {"rssi_rx2", FLT}, {"rssi_rx3", FLT}, {"rssi", FLT},
  {"snr_rx0", FLT}, {"snr_rx1", FLT}, {"snr_rx2", FLT}, {"snr_rx3", FLT}, {"snr", FLT},
  {"projected_sir", FLT}, {"post_ic_rsrq", FLT}, {"cinr_rx0_raw", U32}, {"cinr_rx1_raw", U32}, {"cinr_rx2_raw", U32},
  {"cinr_rx3_raw", U32}, {"residual_freq_error", U16}, {"earfcn", U32}, {"num_cells", U16}, {"valid_rx", U16},
}
defs("cell", CELL_FIELDS)
defs("ncell", { {"pci", U16}, {"rsrp", FLT}, {"rsrq", FLT} })
defs("det", { {"pci", U32}, {"sss_corr", U32}, {"reference_time", U64} })
defs("sp", { {"subpacket_id", U8}, {"subpacket_version", U8}, {"subpacket_size", U16}, {"num_samples", U8} })
defs("sample", {
  {"sample", U16}, {"sub_id", U8}, {"cell_id", U8}, {"sfn", U16}, {"subframe", U8}, {"rnti_type", U8},
  {"rnti_type_name", STR}, {"harq_id", U8}, {"pmch_id", U16}, {"tbs_bytes", U16}, {"grant_bytes", U16}, {"rlc_pdus", U8},
  {"padding_bytes", U16}, {"bsr_event", U8}, {"bsr_event_name", STR}, {"bsr_trigger", U8}, {"bsr_trigger_name", STR},
  {"hdr_len", U8}, {"lcids", STR}, {"header_note", STR},
})
defs("subhdr", { {"sample", U16}, {"lcid", U8}, {"lcid_name", STR}, {"extension", U8}, {"length", U16} })
defs("record", {
  {"record", U8}, {"sfn", U16}, {"subframe", U8}, {"num_rbs", U8}, {"num_layers", U8}, {"num_tb", U8},
  {"serving_cell_index", U8}, {"hsic_enabled", U8}, {"pmch_id", U8}, {"area_id", U8},
})
defs("tb", {
  {"record", U8}, {"tb", U8}, {"harq_id", U8}, {"rv", U8}, {"ndi", U8}, {"crc_pass", U8}, {"rnti_type", U8},
  {"rnti_type_name", STR}, {"tb_index", U8}, {"discarded_retx_present", U8}, {"did_recombining", U8},
  {"tb_size", U16}, {"mcs", U8}, {"num_rbs", U8}, {"modulation_code", U8}, {"modulation", STR},
  {"qed2_interim_status", U8}, {"qed_iteration", U8},
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
})
proto_lte.fields = all_fields

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

-- apply the steps at off; add each field under `tree` (group prefix), fill `out`
local function run_steps(body, off, steps, tree, group, out, bad)
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

local HEADLINE_KEYS = { "pci", "serving_cell_index", "sfn", "subframe", "rsrp", "rsrq", "rssi", "snr",
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
    run_steps(body, at, cell_steps, ctree, "cell", row, bad)
    row.snr = best_snr(row)
    add(ctree, "cell.snr", body(at, 2), row.snr)
    cells[#cells + 1] = row
  end
  local serving = cells[1]
  for _, c in ipairs(cells) do
    if c.is_serving_cell == 1 then serving = c; break end
  end
  for k, v in pairs(header) do fields[k] = v end
  for _, key in ipairs(HEADLINE_KEYS) do fields[key] = serving[key] end
  fields.num_cells = num_cells
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
  local notes = { DOC_NOTE }
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

D[0xB179] = function(body, pinfo, tree, ctx)
  if body:len() < 8 then nofit() end
  local root = tree:add(proto_lte, body())
  local version = body(0, 1):uint()
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
local UL_LCID = { [0] = "CCCH", [25] = "Extended PHR", [26] = "PHR", [27] = "C-RNTI", [28] = "Truncated BSR",
                  [29] = "Short BSR", [30] = "Long BSR", [31] = "Padding" }

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
    if ext == 1 and lcid <= 10 then
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

local DL_SAMPLE = { [2] = 12, [4] = 14 }
local UL_SAMPLE = { [1] = 12, [2] = 14, [3] = 14, [5] = 14, [8] = 14 }

local function read_sample(body, p, downlink, sp_version)
  local s = {}
  local q = p
  if (downlink and sp_version == 4) or (not downlink and sp_version ~= 1) then
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
  local notes = { DOC_NOTE }
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
        add_all(stree, "sample", body(p, fixed), s)
        samples[#samples + 1] = s
        p = p + fixed + s.hdr_len
      end
      if p < stop then notes[#notes + 1] = string.format("%d bytes after the last sample", stop - p) end
      off = stop
    end
  end
  if nsp == 0 then notes[#notes + 1] = "no subpackets" end
  local decoded = "partial"
  if #samples > 0 then
    local first = samples[1]
    fields.num_samples = #samples
    local total = 0
    for _, s in ipairs(samples) do total = total + s[size_key] end
    fields[size_key] = total
    for _, key in ipairs({ "sfn", "subframe", "harq_id", "rnti_type", "rnti_type_name", "cell_id" }) do fields[key] = first[key] end
    fields.lcids = first.lcids
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

D[0xB063] = function(body, pinfo, tree, ctx) return decode_mac_tb(body, tree, true) end
D[0xB064] = function(body, pinfo, tree, ctx) return decode_mac_tb(body, tree, false) end

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

D[0xB173] = function(body, pinfo, tree, ctx)
  if body:len() < 4 then nofit() end
  local root = tree:add(proto_lte, body())
  local version, num_records = body(0, 1):uint(), body(1, 1):uint()
  local fields = { version = version, num_records = num_records }
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

D[0xB139] = function(body, pinfo, tree, ctx)
  if body:len() < 8 then nofit() end
  local root = tree:add(proto_lte, body())
  local version = body(0, 1):uint()
  local word = body(1, 2):le_uint()
  local fields = { version = version, serving_cell_id = bits(word, 0, 9), num_records = bits(word, 9, 5),
                   dispatch_sfn_sf_raw = body(4, 2):le_uint() }
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

for _, code in ipairs({ 0xB193, 0xB179, 0xB17F, 0xB180, 0xB0C1, 0xB0C2, 0xB063, 0xB064, 0xB173, 0xB139 }) do
  D[code] = guarded(D[code])
end
