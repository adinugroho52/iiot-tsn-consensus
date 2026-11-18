# Packet captures

Captures are off by default and change nothing about a run. They are written by `pcap-tap.h`
and read with Wireshark and `tools/iiot-tsn-dissector.lua`.

## Options

| Option | Meaning |
|---|---|
| `--pcapPoints=none\|control\|trunk\|path\|validators\|all` | comma separated; `path` = `control,trunk`, every port from PLC to IO |
| `--pcapPrefix=iiot` | file name stem |
| `--pcapMode=tx\|rx\|both` | `tx` (default) hooks `PhyTxBegin`; `rx` hooks `PhyRxEnd`; `both` hooks `PromiscSniffer` |
| `--pcapSnapLen=128` | bytes kept per frame: PPP, IP, UDP and the application header |
| `--pcapNanosec=true` | nanosecond timestamps (magic `0xa1b23c4d`) |
| `--pcapMaxMB=256` | byte budget shared by all taps; writing stops with a warning when it is spent |
| `--pcapStart`, `--pcapStop` | capture window; defaults to the warm-up end and `stopAt` minus the cool-down |

Files are named for the port: `iiot-plc-eg-tx.pcap`, `iiot-sw2-sw3-tx.pcap`, `iiot-val03-eg-tx.pcap`.
Two sidecars come with them: `<prefix>-manifest.csv` (file, role, packets, bytes, truncated, plus the run
configuration) and `<prefix>-gcl.csv` (the realised gate schedule per captured port, TAS runs only).

```bash
./ns3 run "iiot-consensus-tsn --ctrlPeriod=1000us --pcapPoints=path --pcapStart=0.5s --pcapStop=0.52s"
./ns3 run "iiot-consensus-tsn --pcapPoints=control --pcapMode=rx --pcapStart=0.5s --pcapStop=0.52s --pcapPrefix=e2e"
```

## Reading them correctly

**TX and RX timestamps are not symmetric.** A TX record is the instant serialisation starts, which for a
TAS port is the gate-release instant. An RX record is when the last bit arrives. Subtracting them across a
link overstates the delay by one frame time (7.52 µs for a 94 B frame at 100 Mbps, 228 µs for a 1 kB frame
at 10 Mbps). For end-to-end latency capture the IO device in `rx` mode.

**DSCP and the TAS class are inverted.** Classification uses the IP ToS byte; Wireshark shows DSCP = ToS >> 2.

| Traffic | ToS | DSCP in Wireshark | ns-3 priority | TAS queue |
|---|---|---|---|---|
| control | 0x10 | 4 | 6 | 6 |
| consensus | 0x18 | 6 | 4 | 4 |
| best effort | 0x00 | 0 | 0 | 1 |

`ip.dsfield.dscp == 4` selects control. The TAS module swaps queues 0 and 1, so priority 0 lands in queue 1.

**Microsecond timestamps hide the effect.** A per-hop offset of 852 ns quantises to zero at microsecond
resolution; keep nanosecond mode on.

**Payload padding is zeroed**, so a run produces byte-identical captures on any machine.

## Dissector

Copy `tools/iiot-tsn-dissector.lua` to the Wireshark plugin folder (`~/.local/lib/wireshark/plugins/`, or
`%APPDATA%\Wireshark\plugins\`) and reload Lua plugins. It decodes UDP port 5000 (control: `iiotctrl.seq`,
`iiotctrl.tx_ns`) and 7000 (consensus: `iiotbft.type`, `.round`, `.sender`, `.start_ns`). pcap timestamps are
nanoseconds since simulation start, so the generated fields `iiotctrl.elapsed_us` and `iiotbft.elapsed_us`
give the age of a frame at the captured port. On a receive capture at the IO device that is the end-to-end
latency, so deadline misses are the display filter `iiotctrl.elapsed_us > 1000`.

The dissector reads the C structs the applications copy into the payload (little endian, native alignment):
control `seq` at offset 0 and `txNs` at 8; consensus `type` at 0, `round` at 4, `sender` at 8, `startNs` at 16.
Change both together if you ever replace the `memcpy` with a serialised header.

## Checking the shaper from a capture

For a TX capture on a TAS port, `(timestamp_ns mod cycle_ns)` of every class-6 frame must lie inside an
`open_class=6` window of that port's rows in `<prefix>-gcl.csv`, shifted by `perHopOffset` times the hop index.
A frame outside its window means the gate is not doing what the configuration says. The hop-by-hop staircase
of 852 ns per hop (1 Gbps, 94 B frames) is the signature of a correctly aligned schedule.
