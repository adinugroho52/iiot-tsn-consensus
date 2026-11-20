/*
 * control-loop-app.h -- periodic control loop for iiot-consensus-tsn: a source
 * (ControlSourceApp) that sends B frames per period and a sink (ControlSinkApp)
 * that records per-frame latency and deadline misses.
 *
 * Replaces OnOffHelper for the isochronous control loop.
 *
 * Two reasons this exists rather than OnOffHelper:
 *   1. ToS must be set so Ipv4L3Protocol::IpForward re-derives the right
 *      priority at every forwarded hop (it strips the socket's tag).
 *   2. Deadline-miss ratio and per-packet latency are the dependent
 *      variables; FlowMonitor's default histogram bins cannot resolve them.
 *
 * ToS -> priority -> TAS class (TasQueueDisc m_prioMap = {1,0,2,3,4,5,6,7}):
 *   0x10 -> 6 -> class 6   control
 *   0x18 -> 4 -> class 4   consensus
 *   0x00 -> 0 -> class 1   best effort
 *
 * Only priorities 0, 2, 4 and 6 are reachable through Socket::IpTos2Priority(),
 * so classes 3, 5, 7 and 0 cannot be targeted on a routed multi-hop path.
 */

#ifndef CONTROL_LOOP_APP_H
#define CONTROL_LOOP_APP_H

#include <cstring>
#include "ns3/application.h"
#include "ns3/socket.h"
#include "ns3/udp-socket-factory.h"
#include "ns3/inet-socket-address.h"
#include "ns3/simulator.h"
#include "ns3/uinteger.h"

#include <algorithm>
#include <cstdint>
#include <fstream>
#include <vector>

namespace ns3 {

static const uint8_t TOS_CONTROL   = 0x10;  // -> prio 6 -> class 6
static const uint8_t TOS_CONSENSUS = 0x18;  // -> prio 4 -> class 4
static const uint8_t TOS_BE        = 0x00;  // -> prio 0 -> class 1

/** Payload carried by every control frame. */
struct CtrlPayload
{
  uint32_t seq;
  int64_t  txNs;
};

// ---------------------------------------------------------------------------
// ControlSourceApp: strictly periodic sender, one frame per control cycle.
// ---------------------------------------------------------------------------
class ControlSourceApp : public Application
{
public:
  static TypeId GetTypeId()
  {
    static TypeId tid = TypeId("ControlSourceApp")
      .SetParent<Application>()
      .AddConstructor<ControlSourceApp>();
    return tid;
  }

  void Setup(Ipv4Address dst, uint16_t port, Time period,
             uint32_t payloadBytes, uint8_t tos = TOS_CONTROL,
             uint32_t burst = 1)
  {
    m_burst = std::max<uint32_t>(burst, 1);
    m_dst = dst;
    m_port = port;
    m_period = period;
    m_bytes = std::max<uint32_t>(payloadBytes, sizeof(CtrlPayload));
    m_tos = tos;
  }

  uint32_t GetSent() const { return m_seq; }

private:
  void StartApplication() override
  {
    m_sock = Socket::CreateSocket(GetNode(), UdpSocketFactory::GetTypeId());
    m_sock->Bind();
    // Order matters: bind, then SetIpTos, then Connect -- mirroring what
    // OnOffApplication does internally.
    m_sock->SetIpTos(m_tos);
    m_sock->Connect(InetSocketAddress(m_dst, m_port));
    m_next = Simulator::ScheduleNow(&ControlSourceApp::Tick, this);
  }

  void StopApplication() override
  {
    m_next.Cancel();
    if (m_sock) m_sock->Close();
  }

  void Tick()
  {
    // A burst models several control streams that share one period and phase
    // (for example a multi-axis controller). The frames leave back to back and
    // queue behind one another in the class-6 TAS queue.
    for (uint32_t i = 0; i < m_burst; ++i)
      {
        CtrlPayload p;
        std::memset(&p, 0, sizeof(p));   // deterministic padding bytes
        p.seq = m_seq++;
        p.txNs = Simulator::Now().GetNanoSeconds();
        // The whole payload is built in a zeroed buffer: Packet::AddPaddingAtEnd()
        // leaves the bytes it adds uninitialised, so padding added that way holds
        // whatever was in memory and differs from machine to machine.
        std::vector<uint8_t> buf(m_bytes, 0);
        std::memcpy(buf.data(), &p, sizeof(p));
        Ptr<Packet> pkt = Create<Packet>(buf.data(), m_bytes);
        m_sock->Send(pkt);
      }
    // Fixed-period rescheduling so the cadence never drifts.
    m_next = Simulator::Schedule(m_period, &ControlSourceApp::Tick, this);
  }

  Ptr<Socket> m_sock;
  Ipv4Address m_dst;
  uint16_t m_port{5000};
  Time m_period;
  uint32_t m_bytes{64};
  uint32_t m_burst{1};
  uint32_t m_seq{0};
  uint8_t m_tos{TOS_CONTROL};
  EventId m_next;
};

// ---------------------------------------------------------------------------
// ControlSinkApp: measures per-packet latency and deadline misses.
// ---------------------------------------------------------------------------
class ControlSinkApp : public Application
{
public:
  static TypeId GetTypeId()
  {
    static TypeId tid = TypeId("ControlSinkApp")
      .SetParent<Application>()
      .AddConstructor<ControlSinkApp>();
    return tid;
  }

  /**
   * warmup:  samples arriving before this time are discarded (ARP, routing).
   * measureEnd: samples arriving after this time are discarded. Set it below
   *   the simulation stop time so control statistics only cover the interval
   *   in which the consensus load is definitely active; otherwise a quiet
   *   tail flatters the numbers.
   */
  void Setup(uint16_t port, Time deadline, Time warmup,
             Time measureEnd = Time::Max())
  {
    m_port = port;
    m_deadline = deadline;
    m_warmup = warmup;
    m_measureEnd = measureEnd;
  }

  struct Stats
  {
    uint32_t received{0};
    uint32_t missed{0};
    int64_t  minNs{INT64_MAX};
    int64_t  maxNs{0};
    int64_t  sumNs{0};
    std::vector<int64_t> samples;   // for percentiles / CDF plots
  };

  const Stats& GetStats() const { return m_stats; }

  /**
   * Split the samples at an attack window, by ARRIVAL time: a frame sent before
   * the attack but delayed past its deadline by it counts as a casualty of the
   * attack. A short attack inside a long run barely moves the aggregate
   * statistics; the split makes it visible, and the samples after the window
   * show whether the loop recovers. Without a window nothing changes.
   */
  void SetAttackWindow(Time start, Time stop)
  {
    m_attackStart = start;
    m_attackStop = stop;
    m_haveWindow = true;
  }
  bool HaveWindow() const { return m_haveWindow; }
  const Stats& GetDuring() const { return m_during; }
  const Stats& GetOutside() const { return m_outside; }

  static double MissRatioOf(const Stats& s)
  {
    return s.received ? double(s.missed) / s.received : 0.0;
  }
  static double MeanUsOf(const Stats& s)
  {
    return s.received ? double(s.sumNs) / s.received / 1000.0 : 0.0;
  }
  static double PercentileUsOf(const Stats& s, double q)
  {
    if (s.samples.empty()) return 0.0;
    std::vector<int64_t> v = s.samples;
    std::sort(v.begin(), v.end());
    size_t idx = static_cast<size_t>(q * (v.size() - 1));
    return v[idx] / 1000.0;
  }

  double MissRatio() const { return MissRatioOf(m_stats); }
  double MeanUs() const { return MeanUsOf(m_stats); }

  /** Latency at the given percentile, in microseconds. */
  double PercentileUs(double q) const { return PercentileUsOf(m_stats, q); }

  /**
   * One latency sample per line, nanoseconds. With an attack window the file
   * also has the arrival time and whether it fell in the window; scripts that
   * read only the first column are unaffected.
   */
  void DumpCsv(const std::string& path) const
  {
    std::ofstream f(path);
    if (!m_haveWindow)
      {
        f << "latency_ns\n";
        for (int64_t s : m_stats.samples) f << s << "\n";
        return;
      }
    f << "latency_ns,rx_ns,in_attack\n";
    for (size_t i = 0; i < m_stats.samples.size(); ++i)
      f << m_stats.samples[i] << "," << m_rxNs[i] << "," << (m_inAttack[i] ? 1 : 0) << "\n";
  }

private:
  void StartApplication() override
  {
    m_sock = Socket::CreateSocket(GetNode(), UdpSocketFactory::GetTypeId());
    m_sock->Bind(InetSocketAddress(Ipv4Address::GetAny(), m_port));
    m_sock->SetRecvCallback(MakeCallback(&ControlSinkApp::Rx, this));
  }

  void StopApplication() override
  {
    if (m_sock) m_sock->Close();
  }

  void Rx(Ptr<Socket> s)
  {
    Ptr<Packet> pkt;
    Address from;
    while ((pkt = s->RecvFrom(from)))
      {
        if (pkt->GetSize() < sizeof(CtrlPayload)) continue;

        CtrlPayload p;
        pkt->CopyData(reinterpret_cast<uint8_t*>(&p), sizeof(p));

        Time now = Simulator::Now();
        if (now < m_warmup) continue;        // discard warm-up transient
        if (now > m_measureEnd) continue;    // discard quiet tail

        int64_t lat = now.GetNanoSeconds() - p.txNs;
        bool miss = lat > m_deadline.GetNanoSeconds();
        Record(m_stats, lat, miss);
        if (m_haveWindow)
          {
            bool during = now >= m_attackStart && now < m_attackStop;
            Record(during ? m_during : m_outside, lat, miss);
            m_rxNs.push_back(now.GetNanoSeconds());
            m_inAttack.push_back(during);
          }
      }
  }

  static void Record(Stats& s, int64_t lat, bool miss)
  {
    s.received++;
    s.sumNs += lat;
    s.minNs = std::min(s.minNs, lat);
    s.maxNs = std::max(s.maxNs, lat);
    s.samples.push_back(lat);
    if (miss) s.missed++;
  }

  Ptr<Socket> m_sock;
  uint16_t m_port{5000};
  Time m_deadline;
  Time m_warmup;
  Time m_measureEnd{Time::Max()};
  Stats m_stats;
  // attack window (optional)
  bool m_haveWindow{false};
  Time m_attackStart{Time::Max()}, m_attackStop{Time::Max()};
  Stats m_during, m_outside;
  std::vector<int64_t> m_rxNs;
  std::vector<bool> m_inAttack;
};

NS_OBJECT_ENSURE_REGISTERED(ControlSourceApp);
NS_OBJECT_ENSURE_REGISTERED(ControlSinkApp);

} // namespace ns3
#endif // CONTROL_LOOP_APP_H
