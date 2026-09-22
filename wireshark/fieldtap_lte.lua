-- FieldTap: LTE field decoders for "fieldtap-diag" records (0xB0xx / 0xB1xx log codes).
--
-- Each decoder mirrors the Python decoder of the same log code in fieldtap/decode/;
-- a tshark test checks that both read the same fields from the same bytes. A decoder
-- receives the record body as a Tvb, adds fields under the record tree, and returns a
-- short summary for the Info column. Return nil (or raise) when the layout does not
-- fit: the frame keeps its raw bytes either way.
--
-- Load-order independent: works whether this file or fieldtap.lua loads first.

FieldTap = FieldTap or { decoders = {}, names = {}, confidence = {}, helpers = {} }
local D = FieldTap.decoders

-- Decoders for 0xB0C1, 0xB0C2, 0xB063, 0xB064, 0xB179, 0xB193 ... are added here.
