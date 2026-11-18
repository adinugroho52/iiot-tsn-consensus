--
-- iiot-tsn-dissector.lua -- Wireshark dissectors for iiot-consensus-tsn
--
-- Install:  copy into your Wireshark plugins folder
--             Linux/macOS  ~/.local/lib/wireshark/plugins/
--             Windows      %APPDATA%\Wireshark\plugins\
--           then Analyze > Reload Lua Plugins (Ctrl+Shift+L).
--
-- WIRE FORMAT
--
-- Both applications memcpy a native C struct into the UDP payload, so the
-- layout is the host's: little-endian on x86-64 and aarch64, with the
-- compiler's alignment padding left in place. That is why the fields do not
-- sit at consecutive offsets.
--
--   ControlSourceApp, UDP dst 5000, struct CtrlPayload:
--     0  uint32  seq
--     4  ---     padding
--     8  int64   txNs        simulation time the frame was created
--     16 ...     zero padding out to --ctrlPayload bytes (64 by default)
--
--   ConsensusApp, UDP dst 7000, struct Hdr:
--     0  uint8   type        1 PRE-PREPARE, 2 PREPARE, 3 COMMIT
--     1  ---     padding
--     4  uint32  round
--     8  uint32  sender      validator index, not an address
--     12 ---     padding
--     16 int64   startNs     when the primary opened this round
--     24 ...     zero padding out to --consensusMsgSize bytes
--
-- If you ever replace the memcpy with a serialised ns3::Header, these offsets
-- change and this file must change with them.
--
-- ELAPSED TIME FIELDS
--
-- ns-3 writes pcap timestamps as nanoseconds since simulation t=0, so the
-- capture timestamp is directly comparable with the txNs and startNs values
-- carried in the payload. The generated "elapsed" fields are that difference:
--
--   iiotctrl.elapsed_us   age of this control frame at the captured port
--   iiotbft.elapsed_us    age of this consensus round at the captured port
--
-- On a capture taken at the IO device's ingress, iiotctrl.elapsed_us IS the
-- end-to-end control latency, so a deadline miss is a display filter:
--
--   iiotctrl.elapsed_us > 1000
--
-- Run the simulation with --pcapNanosec=true (the default) or these values
-- quantise to whole microseconds and stop being useful.
--

------------------------------------------------------------------------------
-- Control loop
------------------------------------------------------------------------------
local ctrl = Proto("iiotctrl", "IIoT TSN Control Loop")

local ctrl_seq     = ProtoField.uint32("iiotctrl.seq", "Sequence", base.DEC)
local ctrl_txns    = ProtoField.int64 ("iiotctrl.tx_ns", "Tx time (ns)", base.DEC)
local ctrl_elapsed = ProtoField.double("iiotctrl.elapsed_us", "Elapsed (us)")

ctrl.fields = { ctrl_seq, ctrl_txns, ctrl_elapsed }

function ctrl.dissector(tvb, pinfo, tree)
  if tvb:len() < 16 then return 0 end

  pinfo.cols.protocol = "IIOT-CTRL"

  local t = tree:add(ctrl, tvb(0, 16))
  local seq = tvb(0, 4):le_uint()
  local txns = tvb(8, 8):le_int64()

  t:add(ctrl_seq, tvb(0, 4), seq)
  t:add(ctrl_txns, tvb(8, 8), txns)

  local elapsed_us = (pinfo.abs_ts * 1e9 - txns:tonumber()) / 1000.0
  t:add(ctrl_elapsed, tvb(8, 8), elapsed_us):set_generated()

  t:append_text(string.format(": seq %d, %.3f us old", seq, elapsed_us))
  pinfo.cols.info = string.format("Control seq=%d elapsed=%.3f us",
                                  seq, elapsed_us)
  return tvb:len()
end

------------------------------------------------------------------------------
-- PBFT consensus
------------------------------------------------------------------------------
local bft = Proto("iiotbft", "IIoT TSN PBFT Consensus")

local PHASE = { [1] = "PRE-PREPARE", [2] = "PREPARE", [3] = "COMMIT" }

local bft_type    = ProtoField.uint8 ("iiotbft.type", "Phase", base.DEC, PHASE)
local bft_round   = ProtoField.uint32("iiotbft.round", "Round", base.DEC)
local bft_sender  = ProtoField.uint32("iiotbft.sender", "Sender", base.DEC)
local bft_startns = ProtoField.int64 ("iiotbft.start_ns", "Round start (ns)", base.DEC)
local bft_elapsed = ProtoField.double("iiotbft.elapsed_us", "Elapsed (us)")

bft.fields = { bft_type, bft_round, bft_sender, bft_startns, bft_elapsed }

function bft.dissector(tvb, pinfo, tree)
  if tvb:len() < 24 then return 0 end

  pinfo.cols.protocol = "IIOT-BFT"

  local t = tree:add(bft, tvb(0, 24))
  local ty     = tvb(0, 1):uint()
  local round  = tvb(4, 4):le_uint()
  local sender = tvb(8, 4):le_uint()
  local start  = tvb(16, 8):le_int64()

  t:add(bft_type,    tvb(0, 1),  ty)
  t:add(bft_round,   tvb(4, 4),  round)
  t:add(bft_sender,  tvb(8, 4),  sender)
  t:add(bft_startns, tvb(16, 8), start)

  local elapsed_us = (pinfo.abs_ts * 1e9 - start:tonumber()) / 1000.0
  t:add(bft_elapsed, tvb(16, 8), elapsed_us):set_generated()

  local name = PHASE[ty] or string.format("UNKNOWN(%d)", ty)
  t:append_text(string.format(": %s r%d from v%d", name, round, sender))
  pinfo.cols.info = string.format("%s round=%d sender=%d elapsed=%.3f us",
                                  name, round, sender, elapsed_us)
  return tvb:len()
end

------------------------------------------------------------------------------
-- Registration. Change these if you change the ports in the simulation.
------------------------------------------------------------------------------
local udp_port = DissectorTable.get("udp.port")
udp_port:add(5000, ctrl)
udp_port:add(7000, bft)
