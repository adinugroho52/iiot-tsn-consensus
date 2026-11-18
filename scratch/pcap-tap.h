/*
 * pcap-tap.h -- windowed, budgeted, role-named packet capture for ns-3.
 *
 * Why this exists instead of PointToPointHelper::EnablePcap():
 *
 *   1. TIMESTAMP RESOLUTION. ns-3's pcap files default to MICROSECOND
 *      timestamps. A per-hop gate offset of ~600 ns, or the difference
 *      between a frame released at the start of its window and one released
 *      at the end, quantises to nothing at that resolution. This tap sets
 *      PcapFileWrapper::NanosecMode so timestamps carry the full ns-3
 *      nanosecond resolution.
 *
 *   2. CAPTURE WINDOW. EnablePcap() runs for the whole simulation. A stress
 *      run emitting ~170k consensus messages across a multi-hop path
 *      produces multi-gigabyte captures that no protocol analyser will open.
 *      Captures here are bounded in simulated time AND by a global byte
 *      budget shared across all taps.
 *
 *   3. SNAP LENGTH. Only the headers matter for schedule analysis. The
 *      default 128 B snaplen keeps PPP + IP + UDP + the application header
 *      while discarding the padding that dominates a 1 kB consensus message.
 *
 *   4. FILE NAMES. EnablePcap() names files <prefix>-<node>-<dev>.pcap,
 *      which forces you to reverse-engineer node indices months later. Taps
 *      here are named for their role in the topology: iiot-sw2-sw3.pcap.
 *
 * DIRECTIONALITY -- read this before interpreting timestamps.
 *
 *   TX taps hook PhyTxBegin, which PointToPointNetDevice fires in
 *   TransmitStart, i.e. the instant the frame left the queue disc and
 *   serialisation began. For a port carrying a TAS queue disc this is
 *   exactly the gate-release instant, and it is the observable you want.
 *
 *   RX taps hook PhyRxEnd, which fires when the last bit arrives
 *   (txTime + propagation after the peer's PhyTxBegin).
 *
 *   So a TX record and the matching RX record on the far end differ by
 *   serialisation + propagation, NOT propagation alone. Subtracting them and
 *   calling the result "link delay" overstates it by one frame time --
 *   228 us for a 1 kB frame at 10 Mbps, which is larger than most of the
 *   effects under study.
 *
 *   Mode "both" hooks PromiscSniffer instead, which fires on both paths and
 *   reproduces stock ns-3 behaviour: one file per device holding TX and RX
 *   interleaved.
 *
 * Drop this file in ns-3's scratch/ alongside iiot-consensus-tsn.cc.
 */

#ifndef PCAP_TAP_H
#define PCAP_TAP_H

#include "ns3/abort.h"
#include "ns3/boolean.h"
#include "ns3/callback.h"
#include "ns3/config.h"
#include "ns3/net-device.h"
#include "ns3/packet.h"
#include "ns3/pcap-file-wrapper.h"
#include "ns3/simulator.h"
#include "ns3/trace-helper.h"

#include <algorithm>
#include <fstream>
#include <iostream>
#include <memory>
#include <string>
#include <vector>

namespace ns3 {

/**
 * Link types are libpcap's, not ns-3's. The numeric values are fixed by
 * libpcap and stable forever; PcapHelper::DataLinkType carries the same
 * numbers but its enumerators are deprecated from ns-3.49 onward, so the
 * literals are used directly to keep this file version-neutral.
 */
static const uint16_t PCAP_LINKTYPE_ETHERNET = 1;
static const uint16_t PCAP_LINKTYPE_PPP      = 9;

/**
 * PcapHelper::CreateFile takes PcapHelper::DataLinkType up to ns-3.48 and a
 * plain uint16_t from ns-3.49 onward. Casting to the enum satisfies both: the
 * old signature wants exactly this type, and an unscoped enum converts
 * implicitly to uint16_t for the new one.
 *
 * The cast deliberately does not name DLT_PPP or DLT_EN10MB. Those
 * enumerators carry NS_DEPRECATED_3_49, so mentioning them would warn on
 * recent versions and fail to compile on a -Werror build. Casting a numeric
 * literal names nothing and warns nowhere. The numbers are libpcap's and are
 * fixed forever.
 */
static PcapHelper::DataLinkType
PcapLinkType(uint16_t v)
{
  return static_cast<PcapHelper::DataLinkType>(v);
}

/** Per-record overhead of the pcap record header, for budget accounting. */
static const uint32_t PCAP_RECORD_HEADER = 16;

// ---------------------------------------------------------------------------
// A single capture point: one file, one device, one direction.
// ---------------------------------------------------------------------------
class PcapTap
{
public:
  PcapTap(const std::string& filename, const std::string& role,
          uint16_t linkType, uint32_t snapLen,
          Time start, Time stop, uint64_t* budget)
    : m_filename(filename), m_role(role),
      m_snapLen(snapLen), m_start(start), m_stop(stop), m_budget(budget)
  {
    PcapHelper helper;
    m_file = helper.CreateFile(filename, std::ios::out, PcapLinkType(linkType),
                               snapLen);
  }

  /** Trace sink. Signature must match TracedCallback<Ptr<const Packet>>. */
  void Write(Ptr<const Packet> p)
  {
    Time now = Simulator::Now();
    if (now < m_start || now > m_stop) return;

    uint32_t onDisk =
        std::min<uint32_t>(p->GetSize(), m_snapLen) + PCAP_RECORD_HEADER;

    if (*m_budget < onDisk)
      {
        if (!m_truncated)
          {
            m_truncated = true;
            std::cerr << "pcap: byte budget exhausted at "
                      << now.GetSeconds() << " s; captures are TRUNCATED "
                      << "from here. Raise --pcapMaxMB, shorten "
                      << "[--pcapStart, --pcapStop], cut --pcapSnapLen, or "
                      << "capture fewer points.\n";
          }
        return;
      }

    *m_budget -= onDisk;
    m_file->Write(now, p);
    m_packets++;
    m_bytes += onDisk;
  }

  void Close() { if (m_file) m_file->Close(); }

  const std::string& Filename() const { return m_filename; }
  const std::string& Role()     const { return m_role; }
  uint64_t Packets()            const { return m_packets; }
  uint64_t Bytes()              const { return m_bytes; }
  bool     Truncated()          const { return m_truncated; }

private:
  Ptr<PcapFileWrapper> m_file;
  std::string m_filename, m_role;
  uint32_t m_snapLen;
  Time m_start, m_stop;
  uint64_t* m_budget;
  uint64_t m_packets{0}, m_bytes{0};
  bool m_truncated{false};
};

// ---------------------------------------------------------------------------
// Owns every tap and the shared byte budget.
// ---------------------------------------------------------------------------
class PcapTapSet
{
public:
  enum Mode { MODE_BOTH, MODE_TX, MODE_RX };

  /**
   * Must run BEFORE any tap is created: CreateFile() instantiates
   * PcapFileWrapper via CreateObject, so nanosecond mode has to be a
   * default already in place.
   */
  void Configure(Mode mode, uint32_t snapLen, bool nanosec,
                 Time start, Time stop, uint64_t budgetBytes)
  {
    m_mode = mode;
    m_snapLen = std::min<uint32_t>(std::max<uint32_t>(snapLen, 64), 65535);
    m_start = start;
    m_stop = stop;
    m_budget = budgetBytes;
    Config::SetDefault("ns3::PcapFileWrapper::NanosecMode",
                       BooleanValue(nanosec));
    m_nanosec = nanosec;
    m_configured = true;
  }

  /**
   * Attach a tap to one device. `role` becomes the file name stem and the
   * manifest key, so make it describe the port: "sw2-sw3", "plc-eg".
   */
  void Add(Ptr<NetDevice> dev, const std::string& prefix,
           const std::string& role)
  {
    NS_ABORT_MSG_IF(!m_configured, "PcapTapSet::Add before Configure");
    if (!dev) return;

    // PPP for point-to-point, Ethernet for anything else (CSMA, bridges).
    // Both device families hand the sniffer traces a fully encapsulated
    // frame, so the link type only has to match the encapsulation.
    const std::string devType = dev->GetInstanceTypeId().GetName();
    uint16_t linkType = (devType == "ns3::PointToPointNetDevice")
                            ? PCAP_LINKTYPE_PPP
                            : PCAP_LINKTYPE_ETHERNET;

    std::string suffix = (m_mode == MODE_TX) ? "-tx"
                       : (m_mode == MODE_RX) ? "-rx"
                                             : "";
    std::string filename = prefix + "-" + role + suffix + ".pcap";

    auto tap = std::make_shared<PcapTap>(filename, role, linkType,
                                         m_snapLen, m_start, m_stop,
                                         &m_budget);

    // PhyTxBegin  -> transmit start, i.e. gate release on a TAS port.
    // PhyRxEnd    -> last bit in.
    // PromiscSniffer -> both, stock ns-3 semantics.
    const char* traceName = (m_mode == MODE_TX) ? "PhyTxBegin"
                          : (m_mode == MODE_RX) ? "PhyRxEnd"
                                                : "PromiscSniffer";

    bool ok = dev->TraceConnectWithoutContext(
        traceName, MakeCallback(&PcapTap::Write, tap.get()));
    NS_ABORT_MSG_IF(!ok, "pcap: device type " << devType
                          << " has no trace source \"" << traceName
                          << "\". Use --pcapMode=both, which only needs "
                             "PromiscSniffer.");

    m_taps.push_back(tap);
  }

  /** True when the caller asked for no capture at all. */
  bool Empty() const { return m_taps.empty(); }

  void CloseAll() { for (auto& t : m_taps) t->Close(); }

  /**
   * A capture is only interpretable alongside the configuration that
   * produced it. This writes the map from file name to topology role, plus
   * every parameter needed to reproduce the run.
   */
  void WriteManifest(const std::string& path,
                     const std::vector<std::string>& configLines) const
  {
    std::ofstream f(path);
    if (!f) return;
    f << "# iiot-consensus-tsn capture manifest\n#\n";
    for (const auto& l : configLines) f << "# " << l << "\n";
    f << "#\n# timestamps: "
      << (m_nanosec ? "nanosecond" : "microsecond")
      << " resolution, measured from simulation t=0\n"
      << "# snaplen:    " << m_snapLen << " B\n"
      << "# window:     [" << m_start.GetSeconds() << " s, "
      << m_stop.GetSeconds() << " s]\n"
      << "# direction:  "
      << (m_mode == MODE_TX ? "PhyTxBegin (transmit start / gate release)"
        : m_mode == MODE_RX ? "PhyRxEnd (last bit received)"
                            : "PromiscSniffer (tx and rx interleaved)")
      << "\n#\nfile,role,packets,bytes_on_disk,truncated\n";
    for (const auto& t : m_taps)
      {
        f << t->Filename() << "," << t->Role() << "," << t->Packets() << ","
          << t->Bytes() << "," << (t->Truncated() ? "yes" : "no") << "\n";
      }
  }

  void Report(std::ostream& os) const
  {
    if (m_taps.empty()) return;
    uint64_t pkts = 0, bytes = 0;
    bool trunc = false;
    for (const auto& t : m_taps)
      {
        pkts += t->Packets();
        bytes += t->Bytes();
        trunc = trunc || t->Truncated();
      }
    os << "\n=== packet capture ===\n"
       << "  taps            " << m_taps.size() << "\n"
       << "  records         " << pkts << "\n"
       << "  bytes on disk   " << (bytes / 1024) << " KiB\n"
       << "  timestamps      "
       << (m_nanosec ? "nanosecond" : "microsecond") << " resolution\n"
       << "  window          [" << m_start.GetSeconds() << " s, "
       << m_stop.GetSeconds() << " s]\n"
       << "  snaplen         " << m_snapLen << " B\n"
       << "  truncated       " << (trunc ? "YES -- budget hit" : "no") << "\n";
  }

private:
  std::vector<std::shared_ptr<PcapTap>> m_taps;
  Mode m_mode{MODE_BOTH};
  uint32_t m_snapLen{128};
  bool m_nanosec{true}, m_configured{false};
  Time m_start, m_stop;
  uint64_t m_budget{0};
};

} // namespace ns3

#endif // PCAP_TAP_H
