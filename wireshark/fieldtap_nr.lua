-- FieldTap: NR field decoders for "fieldtap-diag" records (0xB8xx / 0xB9xx log codes).
--
-- Each decoder mirrors the Python decoder of the same log code in fieldtap/decode/
-- (nr_cell.py, nr_state.py, nr_ml1.py, nr_mac.py); tests/test_wireshark_nr_diag.py
-- checks that both read the same fields from the same bytes. A decoder receives the
-- record body as a Tvb, adds fields under the record tree, and returns a short summary
-- for the Info column. Return nil (or raise) when the layout does not fit: the frame
-- keeps its raw bytes either way.
--
-- Every value is held to the same plausibility ranges as the Python side; an implausible
-- one is left out, the record is marked "partial" and fieldtap.nr.note names the field.
-- Layouts come from documentation (docs/research/qualcomm-measurement-log-layouts.md);
-- confirm on a hardware capture.
--
-- Load-order independent: works whether this file or fieldtap.lua loads first.
--
-- Wireshark (4.0.1 checked) runs every plugin file in its own environment: a bare
-- global written in one file is invisible to the others, while _G is shared and bare
-- reads fall through to it. So the shared table is published through _G, as every
-- file of the plugin does; whichever loads first creates it. Nothing from
-- FieldTap.helpers is captured at load time, since the core may not have run yet.

FieldTap = _G.FieldTap or { decoders = {}, names = {}, confidence = {}, helpers = {} }
_G.FieldTap = FieldTap
local D = FieldTap.decoders

local proto_nr = Proto("fieldtap-nr", "FieldTap NR fields")
local P = "fieldtap.nr."
local F = {}
local function def(name, kind, label, base_)
  local ctor = ProtoField[kind]
  F[name] = base_ and ctor(P .. name, label, base_) or ctor(P .. name, label)
end

def("version", "string", "Version (major.minor)")
def("decoded", "string", "Decoded")
def("note", "string", "Note")
def("layout", "string", "Layout")
def("layout_source", "string", "Layout source")
-- cell identity
def("pci", "uint16", "PCI")
def("arfcn", "uint32", "NR-ARFCN")
def("sfn", "uint16", "SFN")
def("scs_khz", "uint8", "Subcarrier spacing (kHz)")
def("dl_arfcn", "uint32", "DL NR-ARFCN")
def("ul_arfcn", "uint32", "UL NR-ARFCN")
def("dl_bw", "uint16", "DL bandwidth (raw)")
def("ul_bw", "uint16", "UL bandwidth (raw)")
def("dl_bw_mhz", "uint16", "DL bandwidth (MHz)")
def("ul_bw_mhz", "uint16", "UL bandwidth (MHz)")
def("cell_id", "uint64", "Cell ID (NCI)")
def("nr_cgi", "uint64", "NR-CGI")
def("mcc", "uint16", "MCC")
def("mnc", "uint16", "MNC")
def("plmn", "string", "PLMN")
def("allowed_access", "uint8", "Allowed access")
def("tac", "uint32", "TAC")
def("band", "uint16", "Band")
-- 5GMM state
def("state", "string", "MM5G state")
def("substate", "string", "Deregistered substate")
def("guti_plmn", "string", "GUTI PLMN")
def("amf_region_id", "uint8", "AMF region ID")
def("amf_set_id", "uint16", "AMF set ID")
def("amf_pointer", "uint8", "AMF pointer")
def("tmsi_5g", "uint32", "5G-TMSI", base.HEX)
def("update_status", "string", "Update status")
-- measurements
def("rsrp", "double", "SS-RSRP (dBm)")
def("rsrq", "double", "SS-RSRQ (dB)")
def("num_layers", "uint8", "Layers (carriers)")
def("num_cells", "uint16", "Cells")
def("num_beams", "uint16", "Beams")
def("ssb_periodicity", "uint8", "SSB periodicity (ms)")
def("serving_beam_ssb_index", "uint8", "Serving beam SSB index")
def("freq_offset", "uint32", "Frequency offset")
def("timing_offset", "uint32", "Timing offset")
def("time_offset", "uint32", "Time offset")
def("carrier.arfcn", "uint32", "Carrier NR-ARFCN")
def("carrier.cc_id", "uint8", "Carrier component id")
def("carrier.num_cells", "uint8", "Carrier cells")
def("carrier.serving_pci", "uint16", "Carrier serving PCI")
def("carrier.serving_ssb", "uint8", "Carrier serving SSB")
def("carrier.serving_rsrp_rx0", "double", "Serving SS-RSRP Rx0 (dBm)")
def("carrier.serving_rsrp_rx1", "double", "Serving SS-RSRP Rx1 (dBm)")
def("carrier.serving_rsrp_rx0_raw", "uint32", "Serving RSRP Rx0 (raw)")
def("carrier.serving_rsrp_rx1_raw", "uint32", "Serving RSRP Rx1 (raw)")
def("cell.pci", "uint16", "Cell PCI")
def("cell.sfn", "uint16", "Cell PBCH SFN")
def("cell.num_beams", "uint8", "Cell beams")
def("cell.rsrp", "double", "Cell SS-RSRP (dBm)")
def("cell.rsrq", "double", "Cell SS-RSRQ (dB)")
def("cell.rsrp_raw", "uint32", "Cell RSRP (raw)")
def("cell.rsrq_raw", "uint32", "Cell RSRQ (raw)")
def("beam.ssb_index", "uint16", "Beam SSB index")
def("beam.tx_beam_index", "uint16", "Tx beam index")
def("beam.rsrp", "double", "Beam SS-RSRP filtered (dBm)")
def("beam.rsrq", "double", "Beam SS-RSRQ filtered (dB)")
def("beam.rsrp_rx0", "double", "Beam SS-RSRP Rx0 (dBm)")
def("beam.rsrp_rx1", "double", "Beam SS-RSRP Rx1 (dBm)")
def("beam.rsrp_l3", "double", "Beam L3 filtered SS-RSRP (dBm)")
def("beam.rsrq_l3", "double", "Beam L3 filtered SS-RSRQ (dB)")
def("beam.l2_rsrp_l3", "double", "Beam L2-NR filtered SS-RSRP (dBm)")
def("beam.l2_rsrq_l3", "double", "Beam L2-NR filtered SS-RSRQ (dB)")
def("beam.rsrp_rx0_raw", "uint32", "Beam RSRP Rx0 (raw)")
def("beam.rsrp_rx1_raw", "uint32", "Beam RSRP Rx1 (raw)")
def("beam.rsrp_l3_raw", "uint32", "Beam L3 RSRP (raw)")
def("beam.rsrq_l3_raw", "uint32", "Beam L3 RSRQ (raw)")
-- MAC
def("num_records", "uint8", "Records")
def("sleep", "uint8", "Sleep")
def("beam_change", "uint8", "Beam change")
def("signal_change", "uint8", "Signal change")
def("dl_dyn_cfg_change", "uint8", "DL dynamic config change")
def("dl_config", "uint8", "DL config")
def("ul_config", "uint8", "UL config")
def("log_fields_change_bmask", "uint16", "Log fields change bitmask", base.HEX)
def("pdsch.carrier_id", "uint32", "Carrier id")
def("pdsch.slots", "uint32", "Slots elapsed")
def("pdsch.decodes", "uint32", "PDSCH decodes")
def("pdsch.crc_pass", "uint32", "CRC pass TBs")
def("pdsch.crc_fail", "uint32", "CRC fail TBs")
def("pdsch.retx", "uint32", "Retransmissions")
def("pdsch.ack_as_nack", "uint32", "ACK as NACK")
def("pdsch.harq_failure", "uint32", "HARQ failures")
def("pdsch.pass_bytes", "uint64", "CRC pass TB bytes")
def("pdsch.fail_bytes", "uint64", "CRC fail TB bytes")
def("pdsch.tb_bytes", "uint64", "TB bytes")
def("pdsch.padding_bytes", "uint64", "Padding bytes")
def("pdsch.retx_bytes", "uint64", "Retransmitted bytes")
def("pdsch.bler_pct", "double", "BLER (%)")
def("slot", "uint8", "Slot")
def("numerology", "uint8", "Numerology")
def("carrier_rnti_raw", "uint8", "Carrier id / RNTI type (raw)", base.HEX)
def("phychan_mask", "uint8", "Physical channel bitmask", base.HEX)
def("num_tti", "uint8", "TTIs")
def("type2_scell", "uint8", "Type-2 SCell")
def("type2_other_cell", "uint8", "Type-2 other cell")
def("num_tb", "uint16", "Transport blocks")
def("grant_bytes", "uint32", "Grant bytes")
def("bytes_built", "uint32", "Bytes built")
def("harq_id", "uint8", "HARQ id (first TB)")
def("tti.slot", "uint8", "TTI slot")
def("tti.sfn", "uint16", "TTI SFN")
def("tti.num_tb", "uint8", "TTI transport blocks")
def("tb.harq_id", "uint8", "HARQ id")
def("tb.numerology", "uint8", "TB numerology")
def("tb.carrier_id", "uint8", "TB carrier id")
def("tb.tb_type", "uint8", "TB type")
def("tb.rnti_type", "uint8", "RNTI type")
def("tb.grant_bytes", "uint32", "TB grant bytes")
def("tb.bytes_built", "uint32", "TB bytes built")
def("tb.mce_length", "uint8", "MAC-CE length")
def("tb.phr_reason", "uint8", "PHR reason")
def("tb.bsr_reason", "uint8", "BSR reason")

local fields = {}
for _, f in pairs(F) do fields[#fields + 1] = f end
proto_nr.fields = fields

-- ---------------------------------------------------------------------------------------------
-- shared machinery (mirrors fieldtap/decode/nr_common.py)

local DOC_NOTE = "layout from documentation; confirm on a hardware capture"
local RANGES = {
  rsrp = { -156, -31 }, rsrq = { -43, 20 }, sinr = { -23, 40 }, pci = { 0, 1007 }, arfcn = { 0, 3279165 },
  tac = { 0, 0xFFFFFF }, sfn = { 0, 1023 }, band = { 1, 1024 }, numerology = { 0, 4 }, slot = { 0, 159 },
  ssb_index = { 0, 63 }, harq_id = { 0, 15 }, tb_bytes = { 0, 2 ^ 20 },
}
local NR_BW_MHZ = { [5] = 1, [10] = 1, [15] = 1, [20] = 1, [25] = 1, [30] = 1, [35] = 1, [40] = 1, [45] = 1,
                    [50] = 1, [60] = 1, [70] = 1, [80] = 1, [90] = 1, [100] = 1, [200] = 1, [400] = 1 }
local SCS_KHZ = { [0] = 15, [1] = 30, [2] = 60, [3] = 120 }

local function q7(raw) return FieldTap.helpers.nr_q7(raw) end
local function u8(b, off) return b(off, 1):uint() end
local function u16(b, off) return b(off, 2):le_uint() end
local function u32(b, off) return b(off, 4):le_uint() end
local function fmt(v, unit) return FieldTap.helpers.fmt(v, unit, 1) end

-- One decode's bookkeeping: what failed plausibility, the notes, the outcome.
local function state()
  return { bad = {}, notes = {}, decoded = "fields" }
end
local function plausible(S, kind, value, label)
  if value == nil then return nil end
  local r = RANGES[kind]
  if value >= r[1] and value <= r[2] then return value end
  S.bad[#S.bad + 1] = label
  return nil
end
local function add(t, name, range, value)
  if value ~= nil then t:add(F[name], range, value) end
end
local function add64(t, name, range) t:add_le(F[name], range) end
local function finish(S, t, body, ctx, extra_notes)
  if #S.bad > 0 then
    S.decoded = "partial"
    table.insert(S.notes, 1, "implausible: " .. table.concat(S.bad, ", "))
  end
  for _, n in ipairs(extra_notes or {}) do S.notes[#S.notes + 1] = n end
  S.notes[#S.notes + 1] = DOC_NOTE
  t:add(F.decoded, body(0, 0), S.decoded)
  t:add(F.note, body(0, 0), table.concat(S.notes, "; "))
  if S.decoded == "partial" then t:append_text(" (partial)") end
end
local function version_pair(body)
  if body:len() < 4 then return nil end
  return u16(body, 2), u16(body, 0)          -- major, minor
end
local function header(t, body, ctx, major, minor)
  t:add_le(ctx.version_field, body(0, 4))
  local label = string.format("%d.%d", major, minor)
  t:add(F.version, body(0, 4), label)
  t:add(ctx.layout_field, body(0, 4), label)
  return label
end
-- The layout whose size fits the body after the 4-byte version word (nr_cell._fit).
local function fit(payload, preferred, order, sizes)
  if preferred and sizes[preferred] == payload then return preferred, "table", 0 end
  for _, key in ipairs(order) do
    if key ~= preferred and sizes[key] == payload then return key, "probed", 0 end
  end
  if preferred and sizes[preferred] < payload then return preferred, "table", payload - sizes[preferred] end
  return nil
end
local function decode_plmn(b, off)
  local o0, o1, o2 = u8(b, off), u8(b, off + 1), u8(b, off + 2)
  local d = { o0 % 16, math.floor(o0 / 16), o1 % 16, math.floor(o1 / 16), o2 % 16, math.floor(o2 / 16) }
  local mnc = string.format("%d%d", d[5], d[6])
  if d[4] ~= 0xF then mnc = mnc .. string.format("%d", d[4]) end
  return string.format("%d%d%d", d[1], d[2], d[3]) .. mnc
end

-- ---------------------------------------------------------------------------------------------
-- 0xB822 NR RRC MIB Info (nr_cell.decode_mib)

local MIB_SIZES = { bits4 = 10, bits5 = 11 }
local MIB_ORDER = { "bits4", "bits5" }

D[0xB822] = function(body, pinfo, tree, ctx)
  local major, minor = version_pair(body)
  if major == nil then return nil end
  local preferred
  if major == 0 and minor == 3 then preferred = "bits4" elseif major == 2 and minor == 0 then preferred = "bits5" end
  local layout, source, trailing = fit(body:len() - 4, preferred, MIB_ORDER, MIB_SIZES)
  if layout == nil then return nil end
  local t = tree:add(proto_nr, body())
  local S = state()
  header(t, body, ctx, major, minor)
  t:add(F.layout, body(0, 4), layout)
  t:add(F.layout_source, body(0, 4), source)
  local pci = plausible(S, "pci", u16(body, 4), "pci")
  local arfcn = plausible(S, "arfcn", u32(body, 6), "earfcn")
  local nbits = layout == "bits4" and 4 or 5
  local bits = body(10, nbits)
  local sfn = plausible(S, "sfn", u8(bits, 0) * 4 + math.floor(u8(bits, 1) / 64), "sfn")
  local scs
  if layout == "bits4" then scs = u8(bits, 3) % 4 else scs = (u8(bits, 3) % 2) * 2 + math.floor(u8(bits, 4) / 128) end
  add(t, "pci", body(4, 2), pci)
  add(t, "arfcn", body(6, 4), arfcn)
  add(t, "sfn", bits, sfn)
  t:add(F.scs_khz, bits, SCS_KHZ[scs])
  local notes = {}
  if trailing > 0 then notes[#notes + 1] = string.format("%d trailing bytes not decoded", trailing) end
  finish(S, t, body, ctx, notes)
  return string.format("MIB PCI %s NR-ARFCN %s SFN %s SCS %d kHz", tostring(pci), tostring(arfcn), tostring(sfn),
                       SCS_KHZ[scs])
end

-- ---------------------------------------------------------------------------------------------
-- 0xB823 NR RRC Serving Cell Info (nr_cell.decode_serving_cell)

local SCELL_SIZES = { v0 = 34, v3 = 42, v3p = 45 }
local SCELL_ORDER = { "v0", "v3", "v3p" }

D[0xB823] = function(body, pinfo, tree, ctx)
  local major, minor = version_pair(body)
  if major == nil then return nil end
  local preferred
  if major == 0 and minor == 4 then preferred = "v0"
  elseif major == 3 and minor == 0 then preferred = "v3"
  elseif major == 3 and (minor == 2 or minor == 3) then preferred = "v3p" end
  local layout, source, trailing = fit(body:len() - 4, preferred, SCELL_ORDER, SCELL_SIZES)
  if layout == nil then return nil end
  local t = tree:add(proto_nr, body())
  local S = state()
  header(t, body, ctx, major, minor)
  t:add(F.layout, body(0, 4), layout)
  t:add(F.layout_source, body(0, 4), source)
  local off = 4
  if layout == "v3p" then off = off + 3 end
  local pci = plausible(S, "pci", u16(body, off), "pci")
  add(t, "pci", body(off, 2), pci)
  off = off + 2
  if layout ~= "v0" then add64(t, "nr_cgi", body(off, 8)); off = off + 8 end
  local dl = plausible(S, "arfcn", u32(body, off), "dl_earfcn")
  local ul = plausible(S, "arfcn", u32(body, off + 4), "ul_earfcn")
  add(t, "dl_arfcn", body(off, 4), dl)
  add(t, "ul_arfcn", body(off + 4, 4), ul)
  local dl_bw, ul_bw = u16(body, off + 8), u16(body, off + 10)
  t:add(F.dl_bw, body(off + 8, 2), dl_bw)
  t:add(F.ul_bw, body(off + 10, 2), ul_bw)
  if NR_BW_MHZ[dl_bw] then t:add(F.dl_bw_mhz, body(off + 8, 2), dl_bw) end
  if NR_BW_MHZ[ul_bw] then t:add(F.ul_bw_mhz, body(off + 10, 2), ul_bw) end
  local cell_id = body(off + 12, 8):le_uint64()
  local cell_ok = cell_id < UInt64(0, 16)          -- 2^36
  if cell_ok then add64(t, "cell_id", body(off + 12, 8)) else S.bad[#S.bad + 1] = "cell_id" end
  local mcc, digits, mnc = u16(body, off + 20), u8(body, off + 22), u16(body, off + 23)
  local mcc_ok = (mcc >= 200 and mcc <= 999) or mcc == 1
  local mnc_ok = (digits == 2 or digits == 3) and mnc <= 999
  if not mcc_ok then S.bad[#S.bad + 1] = "mcc" end
  if not mnc_ok then S.bad[#S.bad + 1] = "mnc" end
  local plmn
  if mcc_ok and mnc_ok then
    plmn = string.format("%03d%0" .. (digits == 3 and 3 or 2) .. "d", mcc, mnc)
    t:add(F.mcc, body(off + 20, 2), mcc)
    t:add(F.mnc, body(off + 23, 2), mnc)
    t:add(F.plmn, body(off + 20, 5), plmn)
  end
  t:add(F.allowed_access, body(off + 25, 1), u8(body, off + 25))
  local tac = plausible(S, "tac", u32(body, off + 26), "tac")
  local band = plausible(S, "band", u16(body, off + 30), "band")
  add(t, "tac", body(off + 26, 4), tac)
  add(t, "band", body(off + 30, 2), band)
  table.sort(S.bad)
  local notes = {}
  if trailing > 0 then notes[#notes + 1] = string.format("%d trailing bytes not decoded", trailing) end
  finish(S, t, body, ctx, notes)
  return string.format("PLMN %s TAC %s PCI %s NR-ARFCN %s band n%s", tostring(plmn), tostring(tac), tostring(pci),
                       tostring(dl), tostring(band))
end

-- ---------------------------------------------------------------------------------------------
-- 0xB80C NR NAS MM5G State (nr_state.decode_mm5g_state; the NAS fallback is Python-only)

local MM5G_STATE = { [1] = "deregistered", [2] = "registered_initiated", [3] = "registered",
                     [4] = "service_request_initiated" }
local DEREG_SUBSTATE = { [0] = "normal_service", [1] = "plmn_search", [2] = "no_cell_available", [5] = "limited_service" }
local UPDATE_STATUS = { [0] = "updated", [1] = "not_updated" }

D[0xB80C] = function(body, pinfo, tree, ctx)
  if body:len() < 26 then return nil end
  local version = u32(body, 0)
  local st = u8(body, 4)
  if version ~= 1 or MM5G_STATE[st] == nil then return nil end
  local t = tree:add(proto_nr, body())
  local S = state()
  t:add_le(ctx.version_field, body(0, 4))
  t:add(F.version, body(0, 4), "1")
  local sub = u16(body, 5)
  t:add(F.state, body(4, 1), MM5G_STATE[st])
  t:add(F.substate, body(5, 2), DEREG_SUBSTATE[sub] or string.format("substate_%d", sub))
  local plmn = decode_plmn(body, 7)
  t:add(F.plmn, body(7, 3), plmn)
  t:add(F.guti_plmn, body(11, 3), decode_plmn(body, 11))
  t:add(F.amf_region_id, body(14, 1), u8(body, 14))
  t:add(F.amf_set_id, body(15, 2), body(15, 2):uint())
  t:add(F.amf_pointer, body(17, 1), u8(body, 17))
  t:add(F.tmsi_5g, body(18, 4), body(18, 4):uint())
  local upd = u8(body, 22)
  t:add(F.update_status, body(22, 1), UPDATE_STATUS[upd] or string.format("status_%d", upd))
  local tac = body(23, 3):uint()
  t:add(F.tac, body(23, 3), tac)
  finish(S, t, body, ctx)
  return string.format("%s PLMN %s TAC %d", MM5G_STATE[st], plmn, tac)
end

-- ---------------------------------------------------------------------------------------------
-- 0xB975 NR ML1 Serving Cell Beam Management (nr_ml1.decode_beam_mgmt)

D[0xB975] = function(body, pinfo, tree, ctx)
  local major, minor = version_pair(body)
  if major == nil or body:len() < 40 then return nil end
  local num_beams = u8(body, 36)
  local beam_len
  for _, cand in ipairs({ 12, 16 }) do
    if 40 + num_beams * cand == body:len() then beam_len = cand; break end
  end
  if beam_len == nil then return nil end
  local t = tree:add(proto_nr, body())
  local S = state()
  local label = header(t, body, ctx, major, minor)
  local pci = plausible(S, "pci", u16(body, 4), "pci")
  add(t, "pci", body(4, 2), pci)
  t:add(F.ssb_periodicity, body(8, 1), u8(body, 8))
  t:add(F.serving_beam_ssb_index, body(9, 1), u8(body, 9))
  local rsrp = plausible(S, "rsrp", q7(u32(body, 12)), "rsrp")
  local rsrq = plausible(S, "rsrq", q7(u32(body, 16)), "rsrq")
  add(t, "rsrp", body(12, 4), rsrp)
  add(t, "rsrq", body(16, 4), rsrq)
  t:add(F.freq_offset, body(28, 4), u32(body, 28))
  t:add(F.time_offset, body(32, 4), u32(body, 32))
  t:add(F.num_beams, body(36, 1), num_beams)
  local off = 40
  for i = 0, num_beams - 1 do
    local bt = t:add(body(off, beam_len), string.format("Beam %d", i))
    bt:add(F["beam.tx_beam_index"], body(off, 2), u16(body, off))
    local br = plausible(S, "rsrp", q7(u32(body, off + 4)), string.format("beam[%d].rsrp", i))
    local bq = plausible(S, "rsrq", q7(u32(body, off + 8)), string.format("beam[%d].rsrq", i))
    add(bt, "beam.rsrp", body(off + 4, 4), br)
    add(bt, "beam.rsrq", body(off + 8, 4), bq)
    bt:append_text(string.format(": Tx beam %d, %s, %s", u16(body, off), fmt(br, "dBm"), fmt(bq, "dB")))
    off = off + beam_len
  end
  local notes = {}
  if not (major == 2 and minor == 1) then
    S.decoded = "partial"
    notes[#notes + 1] = "version " .. label .. " not in the table; read with the 2.1 layout, which fits by size"
  end
  if beam_len ~= 12 then notes[#notes + 1] = string.format("%d-byte beam records", beam_len) end
  finish(S, t, body, ctx, notes)
  return string.format("PCI %s SS-RSRP %s SS-RSRQ %s %d beams", tostring(pci), fmt(rsrp, "dBm"), fmt(rsrq, "dB"),
                       num_beams)
end

-- ---------------------------------------------------------------------------------------------
-- 0xB97F NR ML1 Searcher Measurement Database Update Ext (nr_ml1.decode_search_meas)

local function cand(hdr, count_off, carrier, beam, scale, shape, full)
  return { header = hdr, count_off = count_off, carrier = carrier, beam = beam, scale = scale,
           shape = shape or "v2", full = full ~= false }
end
local C26 = cand(8, 4, 32, 44, "raw")
local C27 = cand(16, 4, 32, 44, "q7")
local C27_NOFMT = cand(8, 4, 32, 44, "q7")
local C29 = cand(16, 4, 32, 84, "q7", "v2", false)
local C29_NOFMT = cand(8, 4, 32, 84, "q7", "v2", false)
local C30 = cand(20, 8, 40, 84, "q7", "v3", false)
local SEARCH_CANDIDATES = {
  ["2.6"] = { C26 }, ["2.7"] = { C27, C27_NOFMT },
  ["2.9"] = { C29, C29_NOFMT, C27, C27_NOFMT }, ["2.10"] = { C29, C29_NOFMT, C27, C27_NOFMT },
  ["3.0"] = { C30 },
}
local SEARCH_PROBE = { C30, C27, C29, C27_NOFMT, C29_NOFMT }

-- Walk the container under one candidate: returns the parsed tables, or nil unless the
-- walk consumes the body exactly.
local function search_walk(body, c)
  local n = body:len()
  if n < c.header then return nil end
  local num_layers = u8(body, c.count_off)
  local carriers, cells, beams = {}, {}, {}
  local off = c.header
  for layer = 0, num_layers - 1 do
    if n < off + c.carrier then return nil end
    local car = { off = off, layer = layer, arfcn = u32(body, off) }
    local num_cells
    if c.shape == "v3" then
      car.cc_id, num_cells = u8(body, off + 4), u8(body, off + 5)
      car.serving_pci = u16(body, off + 6)
      local serving_index = u8(body, off + 8)
      if num_cells == 0 or num_cells == 0xFF then
        num_cells = (serving_index > 0 and serving_index < 0xFF) and serving_index or 0
      end
    else
      num_cells = u8(body, off + 4)
      car.serving_pci, car.serving_ssb = u16(body, off + 6), u8(body, off + 8)
      car.rx0, car.rx1 = u32(body, off + 12), u32(body, off + 16)
    end
    if car.serving_pci == 0xFFFF then car.serving_pci = nil end
    car.num_cells = num_cells
    carriers[#carriers + 1] = car
    off = off + c.carrier
    for ci = 0, num_cells - 1 do
      if n < off + 16 then return nil end
      local num_beams = u8(body, off + 4)
      local cell = { off = off, layer = layer, cell = ci, pci = u16(body, off), sfn = u16(body, off + 2),
                     num_beams = num_beams, rsrp = u32(body, off + 8), rsrq = u32(body, off + 12) }
      cells[#cells + 1] = cell
      off = off + 16
      for bi = 0, num_beams - 1 do
        if n < off + c.beam then return nil end
        local beam = { off = off, layer = layer, cell = ci, beam = bi, ssb_index = u16(body, off) }
        if c.full then
          beam.rx0, beam.rx1 = u32(body, off + 20), u32(body, off + 24)
          beam.l3_rsrp, beam.l3_rsrq = u32(body, off + 28), u32(body, off + 32)
          beam.l2_rsrp, beam.l2_rsrq = u32(body, off + 36), u32(body, off + 40)
        end
        beams[#beams + 1] = beam
        off = off + c.beam
      end
    end
  end
  if off ~= n then return nil end
  return { num_layers = num_layers, carriers = carriers, cells = cells, beams = beams }
end

D[0xB97F] = function(body, pinfo, tree, ctx)
  local major, minor = version_pair(body)
  if major == nil then return nil end
  local label = string.format("%d.%d", major, minor)
  local known = SEARCH_CANDIDATES[label] ~= nil
  local walked, c
  for _, candidate in ipairs(SEARCH_CANDIDATES[label] or SEARCH_PROBE) do
    c = candidate
    walked = search_walk(body, c)
    if walked ~= nil then break end
  end
  if walked == nil then return nil end
  local t = tree:add(proto_nr, body())
  local S = state()
  header(t, body, ctx, major, minor)
  t:add(F.num_layers, body(c.count_off, 1), walked.num_layers)
  if c.shape == "v2" then t:add(F.ssb_periodicity, body(5, 1), u8(body, 5)) end
  if c.header == 16 then
    t:add(F.freq_offset, body(8, 4), u32(body, 8))
    t:add(F.timing_offset, body(12, 4), u32(body, 12))
  end
  t:add(F.num_cells, body(0, 0), #walked.cells)
  t:add(F.num_beams, body(0, 0), #walked.beams)
  local raw = c.scale == "raw"
  local scale = raw and function(v) return v end or q7
  -- record-level headline: the first layer's carrier and its serving cell
  local head_pci, head_arfcn, head_rsrp, head_rsrq
  if #walked.carriers > 0 then
    local car = walked.carriers[1]
    head_arfcn = plausible(S, "arfcn", car.arfcn, "arfcn")
    head_pci = plausible(S, "pci", car.serving_pci, "pci")
    add(t, "arfcn", body(car.off, 4), head_arfcn)
    add(t, "pci", body(car.off + 6, 2), head_pci)
    if not raw then
      for _, cell in ipairs(walked.cells) do
        if cell.layer == 0 and cell.pci == head_pci then
          head_rsrp = plausible(S, "rsrp", q7(cell.rsrp), "rsrp")
          head_rsrq = plausible(S, "rsrq", q7(cell.rsrq), "rsrq")
          add(t, "rsrp", body(cell.off + 8, 4), head_rsrp)
          add(t, "rsrq", body(cell.off + 12, 4), head_rsrq)
          break
        end
      end
    end
  end
  for i, car in ipairs(walked.carriers) do
    local ct = t:add(body(car.off, c.carrier), string.format("Carrier %d", i - 1))
    local arfcn = plausible(S, "arfcn", car.arfcn, string.format("carrier[%d].arfcn", i - 1))
    local spci = plausible(S, "pci", car.serving_pci, string.format("carrier[%d].serving_pci", i - 1))
    add(ct, "carrier.arfcn", body(car.off, 4), arfcn)
    if car.cc_id ~= nil then ct:add(F["carrier.cc_id"], body(car.off + 4, 1), car.cc_id) end
    ct:add(F["carrier.num_cells"], body(car.off + (c.shape == "v3" and 5 or 4), 1), car.num_cells)
    add(ct, "carrier.serving_pci", body(car.off + 6, 2), spci)
    if car.serving_ssb ~= nil then ct:add(F["carrier.serving_ssb"], body(car.off + 8, 1), car.serving_ssb) end
    if car.rx0 ~= nil then
      if raw then
        ct:add(F["carrier.serving_rsrp_rx0_raw"], body(car.off + 12, 4), car.rx0)
        ct:add(F["carrier.serving_rsrp_rx1_raw"], body(car.off + 16, 4), car.rx1)
      else
        add(ct, "carrier.serving_rsrp_rx0", body(car.off + 12, 4),
            plausible(S, "rsrp", q7(car.rx0), string.format("carrier[%d].serving_rsrp_rx0", i - 1)))
        add(ct, "carrier.serving_rsrp_rx1", body(car.off + 16, 4),
            plausible(S, "rsrp", q7(car.rx1), string.format("carrier[%d].serving_rsrp_rx1", i - 1)))
      end
    end
    ct:append_text(string.format(": NR-ARFCN %s, serving PCI %s, %d cells", tostring(arfcn), tostring(spci),
                                 car.num_cells))
  end
  for i, cell in ipairs(walked.cells) do
    local lt = t:add(body(cell.off, 16), string.format("Cell %d", i - 1))
    local pci = plausible(S, "pci", cell.pci, string.format("cell[%d].pci", i - 1))
    local sfn = plausible(S, "sfn", cell.sfn, string.format("cell[%d].pbch_sfn", i - 1))
    add(lt, "cell.pci", body(cell.off, 2), pci)
    add(lt, "cell.sfn", body(cell.off + 2, 2), sfn)
    lt:add(F["cell.num_beams"], body(cell.off + 4, 1), cell.num_beams)
    local rsrp, rsrq
    if raw then
      lt:add(F["cell.rsrp_raw"], body(cell.off + 8, 4), cell.rsrp)
      lt:add(F["cell.rsrq_raw"], body(cell.off + 12, 4), cell.rsrq)
    else
      rsrp = plausible(S, "rsrp", q7(cell.rsrp), string.format("cell[%d].rsrp", i - 1))
      rsrq = plausible(S, "rsrq", q7(cell.rsrq), string.format("cell[%d].rsrq", i - 1))
      add(lt, "cell.rsrp", body(cell.off + 8, 4), rsrp)
      add(lt, "cell.rsrq", body(cell.off + 12, 4), rsrq)
    end
    lt:append_text(string.format(": PCI %s, %s, %s, %d beams", tostring(pci), fmt(rsrp, "dBm"), fmt(rsrq, "dB"),
                                 cell.num_beams))
  end
  for i, beam in ipairs(walked.beams) do
    local bt = t:add(body(beam.off, c.beam), string.format("Beam %d", i - 1))
    local ssb = plausible(S, "ssb_index", beam.ssb_index, string.format("beam[%d].ssb_index", i - 1))
    add(bt, "beam.ssb_index", body(beam.off, 2), ssb)
    if beam.rx0 ~= nil then
      if raw then
        bt:add(F["beam.rsrp_rx0_raw"], body(beam.off + 20, 4), beam.rx0)
        bt:add(F["beam.rsrp_rx1_raw"], body(beam.off + 24, 4), beam.rx1)
        bt:add(F["beam.rsrp_l3_raw"], body(beam.off + 28, 4), beam.l3_rsrp)
        bt:add(F["beam.rsrq_l3_raw"], body(beam.off + 32, 4), beam.l3_rsrq)
      else
        local l = string.format("beam[%d].", i - 1)
        add(bt, "beam.rsrp_rx0", body(beam.off + 20, 4), plausible(S, "rsrp", q7(beam.rx0), l .. "rsrp_rx0"))
        add(bt, "beam.rsrp_rx1", body(beam.off + 24, 4), plausible(S, "rsrp", q7(beam.rx1), l .. "rsrp_rx1"))
        add(bt, "beam.rsrp_l3", body(beam.off + 28, 4), plausible(S, "rsrp", q7(beam.l3_rsrp), l .. "nr2nr_rsrp_l3"))
        add(bt, "beam.rsrq_l3", body(beam.off + 32, 4), plausible(S, "rsrq", q7(beam.l3_rsrq), l .. "nr2nr_rsrq_l3"))
        add(bt, "beam.l2_rsrp_l3", body(beam.off + 36, 4), plausible(S, "rsrp", q7(beam.l2_rsrp), l .. "l2_rsrp_l3"))
        add(bt, "beam.l2_rsrq_l3", body(beam.off + 40, 4), plausible(S, "rsrq", q7(beam.l2_rsrq), l .. "l2_rsrq_l3"))
      end
    end
    bt:append_text(string.format(": SSB %s", tostring(ssb)))
  end
  local notes = {}
  if raw then notes[#notes + 1] = "2.6 RSRP/RSRQ scaling is unverified: raw values kept" end
  if not c.full then
    S.decoded = "partial"
    notes[#notes + 1] = string.format("%d-byte beam records skipped by size", c.beam)
  end
  if not known then
    S.decoded = "partial"
    notes[#notes + 1] = "version " .. label .. " not in the table; layout probed by size"
  end
  finish(S, t, body, ctx, notes)
  local summary = string.format("PCI %s NR-ARFCN %s", tostring(head_pci), tostring(head_arfcn))
  if head_rsrp ~= nil then summary = summary .. string.format(" SS-RSRP %s SS-RSRQ %s", fmt(head_rsrp, "dBm"), fmt(head_rsrq, "dB")) end
  return summary .. string.format(" %d cells %d beams", #walked.cells, #walked.beams)
end

-- ---------------------------------------------------------------------------------------------
-- the MAC container header shared by 0xB888 and 0xB883 (nr_mac._mac_header)

local function mac_header(t, body)
  local names = { "sleep", "beam_change", "signal_change", "dl_dyn_cfg_change", "dl_config", "ul_config" }
  for i, name in ipairs(names) do t:add(F[name], body(3 + i, 1), u8(body, 3 + i)) end
  t:add(F.log_fields_change_bmask, body(12, 2), u16(body, 12))
  t:add(F.num_records, body(15, 1), u8(body, 15))
end

-- ---------------------------------------------------------------------------------------------
-- 0xB888 NR MAC PDSCH Stats (nr_mac.decode_pdsch_stats)

local PDSCH_22, PDSCH_22_SHORT, PDSCH_31 = { 28, 72, 0 }, { 16, 72, 0 }, { 16, 76, 1 }
local PDSCH_CANDIDATES = { ["2.2"] = { PDSCH_22, PDSCH_22_SHORT }, ["3.1"] = { PDSCH_31 } }
local PDSCH_PROBE = { PDSCH_31, PDSCH_22_SHORT, PDSCH_22 }
local PDSCH_U32 = { "slots", "decodes", "crc_pass", "crc_fail", "retx", "ack_as_nack", "harq_failure" }
local PDSCH_U64 = { "pass_bytes", "fail_bytes", "tb_bytes", "padding_bytes", "retx_bytes" }

D[0xB888] = function(body, pinfo, tree, ctx)
  local major, minor = version_pair(body)
  if major == nil or body:len() < 16 then return nil end
  local label = string.format("%d.%d", major, minor)
  local known = PDSCH_CANDIDATES[label] ~= nil
  local num_records = u8(body, 15)
  local fits = {}
  for _, c in ipairs(PDSCH_CANDIDATES[label] or PDSCH_PROBE) do
    if body:len() == c[1] + num_records * c[2] then fits[#fits + 1] = c end
  end
  if #fits == 0 then return nil end
  local t = tree:add(proto_nr, body())
  local S = state()
  header(t, body, ctx, major, minor)
  mac_header(t, body)
  local notes = {}
  local summary = string.format("%d records", num_records)
  if not known and #fits > 1 then
    S.decoded = "partial"
    notes[#notes + 1] = "version " .. label .. " not in the table and more than one record layout fits; header only"
  else
    local c = fits[1]
    local off = c[1]
    local rows = {}
    for i = 0, num_records - 1 do
      local row = { off = off, carrier_id = u32(body, off) }
      local pos = off + 4 + 4 * c[3]
      for k, name in ipairs(PDSCH_U32) do row[name] = u32(body, pos + 4 * (k - 1)) end
      for k, name in ipairs(PDSCH_U64) do row[name] = body(pos + 28 + 8 * (k - 1), 8):le_uint64() end
      row.pos = pos
      rows[#rows + 1] = row
      -- plausibility: a CRC verdict count cannot exceed the decode count, nor a byte share the total
      for _, name in ipairs({ "crc_pass", "crc_fail" }) do
        if row[name] > row.decodes then S.bad[#S.bad + 1] = string.format("record[%d].num_%s_tb", i, name) end
      end
      for _, name in ipairs({ "pass_bytes", "fail_bytes" }) do
        if row[name] > row.tb_bytes then
          S.bad[#S.bad + 1] = string.format("record[%d].crc_%s", i, (name:gsub("_bytes", "_tb_bytes")))
        end
      end
      off = off + c[2]
    end
    for i, row in ipairs(rows) do
      local rt = t:add(body(row.off, c[2]), string.format("Record %d", i - 1))
      rt:add(F["pdsch.carrier_id"], body(row.off, 4), row.carrier_id)
      if #S.bad == 0 then
        for k, name in ipairs(PDSCH_U32) do rt:add(F["pdsch." .. name], body(row.pos + 4 * (k - 1), 4), row[name]) end
        for k, name in ipairs(PDSCH_U64) do rt:add_le(F["pdsch." .. name], body(row.pos + 28 + 8 * (k - 1), 8)) end
        local total = row.crc_pass + row.crc_fail
        local bler
        if total > 0 then
          bler = 100.0 * row.crc_fail / total
          rt:add(F["pdsch.bler_pct"], body(row.pos + 8, 8), bler)
        end
        rt:append_text(string.format(": %d decodes, BLER %s, %s TB bytes", row.decodes, fmt(bler, "%"),
                                     tostring(row.tb_bytes)))
        if i == 1 then
          summary = string.format("%d decodes BLER %s TB bytes %s", row.decodes, fmt(bler, "%"), tostring(row.tb_bytes))
        end
      end
    end
    if not known then
      S.decoded = "partial"
      notes[#notes + 1] = "version " .. label .. " not in the table; record layout probed by size"
    end
  end
  finish(S, t, body, ctx, notes)
  return summary
end

-- ---------------------------------------------------------------------------------------------
-- 0xB883 NR MAC UL Physical Channel Schedule Report (nr_mac.decode_ul_sched): header and
-- the first slot; the rest is bit-packed and its carrier count undocumented.

D[0xB883] = function(body, pinfo, tree, ctx)
  local major, minor = version_pair(body)
  if major == nil or body:len() < 16 then return nil end
  local t = tree:add(proto_nr, body())
  local S = state()
  header(t, body, ctx, major, minor)
  mac_header(t, body)
  local num_records = u8(body, 15)
  local summary = string.format("%d records", num_records)
  if num_records > 0 and body:len() >= 20 then
    local slot = plausible(S, "slot", u8(body, 16), "slot")
    local numerology = plausible(S, "numerology", u8(body, 17), "numerology")
    local sfn = plausible(S, "sfn", u16(body, 18), "sfn")
    add(t, "slot", body(16, 1), slot)
    add(t, "numerology", body(17, 1), numerology)
    add(t, "sfn", body(18, 2), sfn)
    if body:len() >= 24 then
      t:add(F.carrier_rnti_raw, body(20, 1), u8(body, 20))
      t:add(F.phychan_mask, body(21, 1), u8(body, 21))
    end
    summary = summary .. string.format(" SFN %s slot %s", tostring(sfn), tostring(slot))
  end
  S.decoded = "partial"
  finish(S, t, body, ctx, { "header and first slot only: the per-carrier records are bit-packed and their count is not documented" })
  return summary
end

-- ---------------------------------------------------------------------------------------------
-- 0xB872 NR L2 UL Transport Block (nr_mac.decode_ul_tb)

local function ul_tb_walk(body)
  local n = body:len()
  local num_tti = u8(body, 4) % 16
  local ttis, tbs = {}, {}
  local off = 8
  for ti = 0, num_tti - 1 do
    if n < off + 8 then return nil end
    ttis[#ttis + 1] = { off = off, tti = ti, slot = u8(body, off), sfn = u16(body, off + 2) % 1024,
                        num_tb = u8(body, off + 4) % 16 }
    local num_tb = ttis[#ttis].num_tb
    off = off + 8
    for bi = 0, num_tb - 1 do
      if n < off + 18 then return nil end
      local b0, b1 = u8(body, off), u8(body, off + 1)
      local row = { off = off, tti = ti, tb = bi, numerology = b0 % 8, harq_id = math.floor(b0 / 8) % 16,
                    carrier_id = math.floor(b0 / 128) + (b1 % 2) * 2, tb_type = math.floor(b1 / 2) % 16,
                    rnti_type = math.floor(b1 / 32), grant = u32(body, off + 4), built = u32(body, off + 8),
                    build_mask = u8(body, off + 13) }
      local pos = off + 14
      if row.build_mask % 2 == 1 then row.phr_reason, row.phr_off = u8(body, pos), pos; pos = pos + 1 end
      if math.floor(row.build_mask / 2) % 2 == 1 then row.bsr_reason, row.bsr_off = u8(body, pos), pos; pos = pos + 1 end
      if n < pos + 4 then return nil end
      row.mce_length, row.mce_off = u8(body, pos), pos
      pos = pos + 4
      if n < pos + row.mce_length then return nil end
      pos = pos + row.mce_length
      row.len = pos - off
      tbs[#tbs + 1] = row
      off = pos
    end
  end
  if off ~= n then return nil end
  return ttis, tbs
end

D[0xB872] = function(body, pinfo, tree, ctx)
  if body:len() < 8 then return nil end
  local version = u32(body, 0)
  local ttis, tbs = ul_tb_walk(body)
  if ttis == nil and version ~= 4 then return nil end
  local t = tree:add(proto_nr, body())
  local S = state()
  t:add_le(ctx.version_field, body(0, 4))
  t:add(F.version, body(0, 4), tostring(version))
  local count = u8(body, 4)
  t:add(F.num_tti, body(4, 1), count % 16)
  t:add(F.type2_scell, body(4, 1), math.floor(count / 16) % 2)
  t:add(F.type2_other_cell, body(4, 1), math.floor(count / 32) % 2)
  if ttis == nil then
    S.decoded = "partial"
    finish(S, t, body, ctx, { "TTI/TB records did not fit the documented layout; header only" })
    return string.format("%d TTIs (records did not fit)", count % 16)
  end
  t:add(F.num_tb, body(0, 0), #tbs)
  local grant_sum, built_sum = 0, 0
  for _, tb in ipairs(tbs) do grant_sum = grant_sum + tb.grant; built_sum = built_sum + tb.built end
  local head_sfn, head_slot
  for i, tti in ipairs(ttis) do
    local tt = t:add(body(tti.off, 8), string.format("TTI %d", i - 1))
    local slot = plausible(S, "slot", tti.slot, string.format("tti[%d].slot", i - 1))
    local sfn = plausible(S, "sfn", tti.sfn, string.format("tti[%d].sfn", i - 1))
    add(tt, "tti.slot", body(tti.off, 1), slot)
    add(tt, "tti.sfn", body(tti.off + 2, 2), sfn)
    tt:add(F["tti.num_tb"], body(tti.off + 4, 1), tti.num_tb)
    tt:append_text(string.format(": SFN %s slot %s, %d TBs", tostring(sfn), tostring(slot), tti.num_tb))
    if i == 1 then head_sfn, head_slot = sfn, slot end
  end
  for i, tb in ipairs(tbs) do
    local bt = t:add(body(tb.off, tb.len), string.format("TB %d", i - 1))
    local l = string.format("tb[%d].", i - 1)
    add(bt, "tb.numerology", body(tb.off, 1), plausible(S, "numerology", tb.numerology, l .. "numerology"))
    add(bt, "tb.harq_id", body(tb.off, 1), plausible(S, "harq_id", tb.harq_id, l .. "harq_id"))
    bt:add(F["tb.carrier_id"], body(tb.off, 2), tb.carrier_id)
    bt:add(F["tb.tb_type"], body(tb.off + 1, 1), tb.tb_type)
    bt:add(F["tb.rnti_type"], body(tb.off + 1, 1), tb.rnti_type)
    local grant = plausible(S, "tb_bytes", tb.grant, l .. "grant_bytes")
    local built = plausible(S, "tb_bytes", tb.built, l .. "bytes_built")
    if grant ~= nil and built ~= nil and built > grant then
      built = nil
      S.bad[#S.bad + 1] = l .. "bytes_built"
    end
    add(bt, "tb.grant_bytes", body(tb.off + 4, 4), grant)
    add(bt, "tb.bytes_built", body(tb.off + 8, 4), built)
    if tb.phr_reason ~= nil then bt:add(F["tb.phr_reason"], body(tb.phr_off, 1), tb.phr_reason) end
    if tb.bsr_reason ~= nil then bt:add(F["tb.bsr_reason"], body(tb.bsr_off, 1), tb.bsr_reason) end
    bt:add(F["tb.mce_length"], body(tb.mce_off, 1), tb.mce_length)
    bt:append_text(string.format(": HARQ %d, grant %s, built %s", tb.harq_id, tostring(grant), tostring(built)))
  end
  local notes = {}
  if #S.bad == 0 then
    add(t, "sfn", body(0, 0), head_sfn)
    add(t, "slot", body(0, 0), head_slot)
    if #tbs > 0 then
      t:add(F.grant_bytes, body(0, 0), grant_sum)
      t:add(F.bytes_built, body(0, 0), built_sum)
      t:add(F.harq_id, body(tbs[1].off, 1), tbs[1].harq_id)
    end
  end
  if version ~= 4 then
    S.decoded = "partial"
    notes[#notes + 1] = string.format("version %d not in the table; read with the version-4 layout, which fits by size", version)
  end
  finish(S, t, body, ctx, notes)
  return string.format("%d TTIs %d TBs grant %d built %d", #ttis, #tbs, grant_sum, built_sum)
end
