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
        Ptr<Packet> pkt = Create<Packet>(reinterpret_cast<const uint8_t*>(&p), sizeof(p));
        if (m_bytes > sizeof(p)) pkt->AddPaddingAtEnd(m_bytes - sizeof(p));
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

  double MissRatio() const
  {
    return m_stats.received ? double(m_stats.missed) / m_stats.received : 0.0;
  }

  double MeanUs() const
  {
    return m_stats.received ? double(m_stats.sumNs) / m_stats.received / 1000.0 : 0.0;
  }

  /** Latency at the given percentile, in microseconds. */
  double PercentileUs(double q) const
  {
    if (m_stats.samples.empty()) return 0.0;
    std::vector<int64_t> v = m_stats.samples;
    std::sort(v.begin(), v.end());
    size_t idx = static_cast<size_t>(q * (v.size() - 1));
    return v[idx] / 1000.0;
  }

  /** One latency sample per line, nanoseconds. Feed to your plotting script. */
  void DumpCsv(const std::string& path) const
  {
    std::ofstream f(path);
    f << "latency_ns\n";
    for (int64_t s : m_stats.samples) f << s << "\n";
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
        m_stats.received++;
        m_stats.sumNs += lat;
        m_stats.minNs = std::min(m_stats.minNs, lat);
        m_stats.maxNs = std::max(m_stats.maxNs, lat);
        m_stats.samples.push_back(lat);
        if (lat > m_deadline.GetNanoSeconds()) m_stats.missed++;
      }
  }

  Ptr<Socket> m_sock;
  uint16_t m_port{5000};
  Time m_deadline;
  Time m_warmup;
  Time m_measureEnd{Time::Max()};
  Stats m_stats;
};

NS_OBJECT_ENSURE_REGISTERED(ControlSourceApp);
NS_OBJECT_ENSURE_REGISTERED(ControlSinkApp);

} // namespace ns3
#endif // CONTROL_LOOP_APP_H
