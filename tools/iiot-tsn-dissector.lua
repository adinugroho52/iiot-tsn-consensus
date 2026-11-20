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
--     0  uint8   type        1 PRE-PREPARE, 2 PREPARE, 3 COMMIT,
--                            4 VIEW-CHANGE, 5 NEW-VIEW (--pbftModel=full)
--     1  ---     padding
--     4  uint32  round
--     8  uint32  sender      validator index, not an address
--     12 ---     padding
--     16 int64   startNs     when the round was first opened
--     24 uint32  view        0 in the v1 model
--     28 uint32  digest      proposal identity, 0 = honest; a VIEW-CHANGE
--                            carries the view it asks for here
--     32 ...     zero padding out to --consensusMsgSize bytes
-- Release 1.x had zero padding from byte 24, so its captures decode the same.
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

local PHASE = { [1] = "PRE-PREPARE", [2] = "PREPARE", [3] = "COMMIT",
                [4] = "VIEW-CHANGE", [5] = "NEW-VIEW" }

local bft_type    = ProtoField.uint8 ("iiotbft.type", "Phase", base.DEC, PHASE)
local bft_round   = ProtoField.uint32("iiotbft.round", "Round", base.DEC)
local bft_sender  = ProtoField.uint32("iiotbft.sender", "Sender", base.DEC)
local bft_startns = ProtoField.int64 ("iiotbft.start_ns", "Round start (ns)", base.DEC)
local bft_elapsed = ProtoField.double("iiotbft.elapsed_us", "Elapsed (us)")
-- Since the second paper's code: bytes 24-31. Both are 0 in the v1 model and
-- for an honest proposal, so v1 captures decode the same either way.
local bft_view    = ProtoField.uint32("iiotbft.view", "View", base.DEC)
local bft_digest  = ProtoField.uint32("iiotbft.digest", "Digest", base.HEX)
local bft_target  = ProtoField.uint32("iiotbft.target_view", "Requested view", base.DEC)
-- A consensus message sent at the control codepoint (ToS 0x10), which 802.1Qbv
-- releases through the control gate: --attack=mismark. Filter: iiotbft.mismarked == 1
local bft_mismark = ProtoField.uint8 ("iiotbft.mismarked", "Mismarked (control ToS)", base.DEC)
local ip_dsfield  = Field.new("ip.dsfield")

bft.fields = { bft_type, bft_round, bft_sender, bft_startns, bft_elapsed,
               bft_view, bft_digest, bft_target, bft_mismark }

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
  local extra = ""
  if tvb:len() >= 32 then
    local view   = tvb(24, 4):le_uint()
    local digest = tvb(28, 4):le_uint()
    t:add(bft_view, tvb(24, 4), view)
    if ty == 4 then
      t:add(bft_target, tvb(28, 4), digest)
      extra = string.format(" view=%d target=%d", view, digest)
    else
      t:add(bft_digest, tvb(28, 4), digest)
      if view ~= 0 or digest ~= 0 then
        extra = string.format(" view=%d digest=0x%08x", view, digest)
      end
    end
  end
  local dsf = ip_dsfield()
  local mis = (dsf ~= nil and dsf.value == 0x10) and 1 or 0
  t:add(bft_mismark, mis):set_generated()
  if mis == 1 then extra = extra .. " MISMARKED" end
  t:append_text(string.format(": %s r%d from v%d%s", name, round, sender, extra))
  pinfo.cols.info = string.format("%s round=%d sender=%d%s elapsed=%.3f us",
                                  name, round, sender, extra, elapsed_us)
  return tvb:len()
end

------------------------------------------------------------------------------
-- Registration. Change these if you change the ports in the simulation.
------------------------------------------------------------------------------
local udp_port = DissectorTable.get("udp.port")
udp_port:add(5000, ctrl)
udp_port:add(7000, bft)
