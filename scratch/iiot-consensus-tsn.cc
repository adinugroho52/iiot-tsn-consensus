/*
 * iiot-consensus-tsn.cc -- PBFT-style consensus traffic sharing a TSN chain with a
 * periodic control loop (PLC -> n switches -> IO device), in ns-3.
 *
 * Every shaped egress port runs one of three disciplines (--shaper): the time-aware
 * shaper (ns3::TasQueueDisc from the DenKrysos TAS contrib module), strict priority,
 * or a single FIFO. Validators hang off the switches and run a PBFT message pattern
 * (fixed leader, no view change) as an application, so only message timing and size
 * are modelled. See README.md for the options, the experiments and what each showed.
 *
 * Place this file, control-loop-app.h and pcap-tap.h in ns-3's scratch/ directory.
 * The model is deterministic unless --offsetJitter, --randomRoundPhase or
 * --randomPlacement is set; --run then selects the random draw.
 *
 * ---------------------------------------------------------------------------
 * TWO ns-3 CONSTRAINTS THAT SHAPE THIS FILE
 *
 * 1. The "switches" are IP-forwarding routers, NOT BridgeNetDevices.
 *    BridgeNetDevice::ForwardUnicast calls outPort->SendFrom() directly and
 *    bypasses TrafficControlLayer, so a TAS queue disc on a bridge port never
 *    sees forwarded frames. Routers work because Ipv4Interface::Send() calls
 *    m_tc->Send(), which runs the queue disc.
 *
 * 2. Classification must be driven by IP ToS, not Socket::SetPriority().
 *    Ipv4L3Protocol::IpForward() removes the SocketPriorityTag and re-derives
 *    priority from the ToS field on every forwarded hop. A socket priority
 *    therefore survives only the first hop. Because Socket::IpTos2Priority()
 *    returns only 0, 2, 4 or 6, TAS classes 0, 3, 5 and 7 are unreachable
 *    end-to-end.
 * ---------------------------------------------------------------------------
 */

#include "ns3/core-module.h"
#include "ns3/network-module.h"
#include "ns3/csma-module.h"
#include "ns3/point-to-point-module.h"
#include "ns3/internet-module.h"
#include "ns3/applications-module.h"
#include "ns3/traffic-control-module.h"
#include "ns3/flow-monitor-module.h"
#include "ns3/ipv4-global-routing-helper.h"
#include "ns3/tsn-module.h"

#include "control-loop-app.h"
#include "adversary.h"
#include "pcap-tap.h"

#include <algorithm>
#include <cstring>
#include <cmath>
#include <fstream>
#include <map>
#include <set>
#include <sstream>
#include <utility>
#include <vector>

using namespace ns3;

NS_LOG_COMPONENT_DEFINE("IiotConsensusTsn");

// ---------------------------------------------------------------------------
// Traffic classes.
//
// TasQueueDisc uses m_prioMap = {1,0,2,3,4,5,6,7}, so priority -> class is:
//     prio 0 -> class 1     prio 4 -> class 4
//     prio 2 -> class 2     prio 6 -> class 6
//
// The GateStateMap passed to NetDeviceListConfig::Add() is indexed by
// TRAFFIC CLASS, not by socket priority. Getting this backwards silently
// gates the wrong queue.
//
// ToS constants (TOS_CONTROL / TOS_CONSENSUS / TOS_BE) live in
// control-loop-app.h.
// ---------------------------------------------------------------------------
static const uint32_t CLASS_CONTROL   = 6;   // from ToS 0x10 -> prio 6
static const uint32_t CLASS_CONSENSUS = 4;   // from ToS 0x18 -> prio 4
static const uint32_t CLASS_BE        = 1;   // from ToS 0x00 -> prio 0

// ---------------------------------------------------------------------------
// ConsensusApp: generates PBFT-shaped message bursts.
//
// Models message TIMING and VOLUME only -- no crypto, no chain. Signature
// verification is a CPU delay before a node reacts to a message.
//
// Classic PBFT round with n nodes, f = (n-1)/3:
//   PRE-PREPARE  primary -> backups        n-1 messages
//   PREPARE      backups -> all            (n-1)(n-1) messages
//   COMMIT       all -> all                n(n-1) messages
// For n = 4 that is 3 + 9 + 12 = 24 messages per round.
//
// Two models, chosen with --pbftModel:
//
//   v1    The normal-case pattern of release 1.x, reproduced exactly: validator
//         0 is the primary for the whole run, there is no view change, a node
//         sends its COMMIT after PREPAREs from 2f distinct senders whether or not
//         its PRE-PREPARE has arrived, and it commits on COMMITs from 2f+1 other
//         validators. With this model every run of release 1.x reproduces bit
//         for bit, captures included.
//
//   full  PBFT's normal case and view change (Castro and Liskov), as a traffic
//         model. Votes are counted per proposal (digest). A node prepares only
//         for a proposal it holds, and on accepting a PRE-PREPARE it re-checks
//         the PREPAREs and COMMITs that arrived before it. A node counts its own
//         COMMIT, as PBFT's committed-local predicate does: with f faulty nodes
//         only 2f correct peers remain, so 2f+1 COMMITs from others alone could
//         never be collected. The primary of view v is validator v mod n. Every
//         node keeps the round clock; a backup that has not committed a round
//         within the view timeout broadcasts VIEW-CHANGE (all to all), the new
//         primary collects 2f+1 and broadcasts NEW-VIEW and re-proposes every
//         uncommitted round, keeping each round's original start time. Timeouts
//         back off exponentially and reset on a commit. Messages of a view the
//         node has not entered yet are held and replayed when it enters it.
//         A node that sees messages of a higher view from f+1 distinct senders
//         (so from at least one correct node) moves to that view: this stands in
//         for state transfer, so a node that was crashed can rejoin.
//         Not modelled: certificates inside VIEW-CHANGE and NEW-VIEW (only their
//         size is charged, --viewChangeSize and --newViewSize), checkpoints,
//         and the f+1 rule for joining a view change early.
//
// Byzantine behaviours (adversary.h, full model only), active inside the
// attack window [attackStart, attackStop):
//   crash       sends nothing and drops everything it receives
//   withhold    takes part but never sends COMMIT, and never asks for a view change
//   equivocate  as primary, sends one digest to half the backups and another to
//               the rest; no quorum forms, so the backups time out
//   flood       sends floodFactor copies of every broadcast
//   delay       adds attackDelay to its processing of every message
//   mismark     sends its consensus messages at the CONTROL codepoint, so the
//               shaper releases them through the control gate
//
// Each phase is guarded by a per-round flag so a node broadcasts each phase
// at most once, and senders are deduplicated in sets.
//
// Wire header (32 bytes, little endian, the rest of the message is zeros):
//   0 type | 4 round | 8 sender | 16 round start (ns) | 24 view | 28 digest
// The first 24 bytes are release 1.x's layout, so tools/round_check.py and the
// dissector read both. view and digest are 0 in the v1 model and for an honest
// proposal, which leaves v1 messages byte-identical to release 1.x. A
// VIEW-CHANGE carries the view it asks for in the digest field.
// ---------------------------------------------------------------------------
class ConsensusApp : public Application
{
public:
  static TypeId GetTypeId()
  {
    static TypeId tid = TypeId("ConsensusApp")
      .SetParent<Application>()
      .AddConstructor<ConsensusApp>()
      .AddTraceSource("RoundCommitted",
                      "Fired when this node commits a round",
                      MakeTraceSourceAccessor(&ConsensusApp::m_commitTrace),
                      "ns3::Time::TracedCallback");
    return tid;
  }

  ConsensusApp() {}

  void Setup(std::vector<Ipv4Address> peers, uint32_t selfIdx, uint16_t port,
             Time roundInterval, uint32_t msgSize, Time verifyDelay, bool useBe = false)
  {
    m_peers = peers;
    m_self = selfIdx;
    m_port = port;
    m_roundInterval = roundInterval;
    m_msgSize = msgSize;
    m_verifyDelay = verifyDelay;
    m_useBe = useBe;
    m_n = peers.size();
    m_f = (m_n - 1) / 3;
  }

  /** Select the full model. Without this call the node runs the v1 model. */
  void SetFullModel(bool viewChange, Time viewTimeout, double backoff, uint32_t maxViews,
                    uint32_t viewChangeSize, uint32_t newViewSize)
  {
    m_full = true;
    m_vcEnabled = viewChange;
    m_baseViewTimeout = m_viewTimeout = viewTimeout;
    m_viewBackoff = backoff;
    m_maxViews = maxViews;
    m_vcSize = viewChangeSize;
    m_nvSize = newViewSize;
  }

  /**
   * How far back a new primary re-proposes (full model). On entering a view,
   * every node abandons the uncommitted rounds more than k round ticks old:
   * the new primary does not re-propose them and backups stop timing them.
   * This stands in for PBFT's log watermarks (the window between checkpoints);
   * real systems hand such requests back to the client. 0 = re-propose every
   * uncommitted round still held (the most recent 64), the behaviour before
   * this option existed.
   */
  void SetReproposeWindow(uint32_t k) { m_reproposeWindow = k; }
  uint32_t GetAbandoned() const { return m_abandoned; }

  /** Make this node Byzantine (full model). bits: AdvBit mask from adversary.h. */
  void SetAdversary(uint32_t bits, Time start, Time stop, uint32_t floodFactor, Time attackDelay)
  {
    m_adv = bits;
    m_attackStart = start;
    m_attackStop = stop;
    m_floodFactor = std::max<uint32_t>(floodFactor, 1);
    m_attackDelay = attackDelay;
  }
  void SetOracle(Ptr<ConsensusOracle> o) { m_oracle = o; }
  bool IsByzantine() const { return IsValidatorAttack(m_adv); }
  /**
   * Whether the oracle takes this node's word. A node whose only fault is a
   * crash never sends anything false (crash-recovery model), so its commits
   * count toward agreement and quorum once it is back; a node with any other
   * behaviour is excluded for the whole run.
   */
  bool Trusted() const { return !IsValidatorAttack(m_adv & ~ADV_CRASH); }
  uint32_t GetMismarked()     const { return m_mismarked; }
  uint32_t GetFloodExtra()    const { return m_floodExtra; }
  uint32_t GetEquivocations() const { return m_equivocations; }
  uint32_t GetCaughtUp()      const { return m_caughtUp; }

  // Instrumentation: broadcast counts by phase, and committed rounds.
  uint32_t GetSentPrePrepare() const { return m_sentPrePrepare; }
  uint32_t GetSentPrepare()    const { return m_sentPrepare; }
  uint32_t GetSentCommit()     const { return m_sentCommit; }
  uint32_t GetCommitted()      const { return m_committed; }
  uint32_t GetMsgsSent()       const { return m_msgsSent; }
  int64_t  GetLatSum()         const { return m_latSum; }
  int64_t  GetLatMax()         const { return m_latMax; }
  const std::vector<int64_t>& GetLatSamples() const { return m_latSamples; }
  // Rounds the round clock opened: the primary's PRE-PREPAREs in v1, every
  // node's clock ticks in full (all nodes tick together).
  uint32_t GetRoundsOpened()   const { return m_full ? m_expected : m_sentPrePrepare; }
  uint32_t GetSentViewChange() const { return m_sentViewChange; }
  uint32_t GetSentNewView()    const { return m_sentNewView; }
  uint32_t GetViewsEntered()   const { return m_viewsEntered; }
  uint32_t GetView()           const { return m_view; }
  /** Rounds in which PREPAREs from 2f senders arrived before the PRE-PREPARE. */
  uint32_t GetOvertaken()      const { return m_overtaken; }

private:
  enum MsgType : uint8_t { PRE_PREPARE = 1, PREPARE = 2, COMMIT = 3, VIEW_CHANGE = 4, NEW_VIEW = 5 };

  struct Hdr
  {
    uint8_t  type;
    uint32_t round;
    uint32_t sender;
    int64_t  startNs;   // when the round was first opened
    uint32_t view;      // full model; 0 in v1
    uint32_t digest;    // proposal identity (0 = honest), or a VIEW-CHANGE's target view
  };
  static_assert(sizeof(Hdr) == 32, "consensus header must stay 32 bytes");

  struct RoundState
  {
    // v1 model: senders, whatever they voted for.
    std::set<uint32_t> prepares;
    std::set<uint32_t> commits;
    bool gotPrePrepare{false};       // statistics only
    // full model: senders per digest.
    std::map<uint32_t, std::set<uint32_t>> preparesBy;
    std::map<uint32_t, std::set<uint32_t>> commitsBy;
    uint32_t proposed{0};
    bool haveProposal{false};
    bool timerArmed{false};
    bool abandoned{false};             // dropped at a view change (--reproposeWindow)
    EventId timer;
    // both
    int64_t startNs{-1};
    bool sentPrepare{false};
    bool sentCommit{false};
    bool committed{false};
  };

  void StartApplication() override
  {
    m_rxSocket = Socket::CreateSocket(GetNode(), UdpSocketFactory::GetTypeId());
    m_rxSocket->Bind(InetSocketAddress(Ipv4Address::GetAny(), m_port));
    m_rxSocket->SetRecvCallback(MakeCallback(&ConsensusApp::HandleRead, this));

    for (uint32_t i = 0; i < m_n; ++i)
      {
        if (i == m_self) continue;
        Ptr<Socket> s = Socket::CreateSocket(GetNode(), UdpSocketFactory::GetTypeId());
        s->Bind();
        // ToS, not SetPriority -- see the header comment on IpForward.
        s->SetIpTos(m_useBe ? TOS_BE : TOS_CONSENSUS);
        s->Connect(InetSocketAddress(m_peers[i], m_port));
        m_txSockets.push_back(s);
        if (m_adv & ADV_MISMARK)
          {
            // A second socket per peer at the CONTROL codepoint. Nothing in
            // 802.1Qbv checks a frame's claimed class.
            Ptr<Socket> m = Socket::CreateSocket(GetNode(), UdpSocketFactory::GetTypeId());
            m->Bind();
            m->SetIpTos(TOS_CONTROL);
            m->Connect(InetSocketAddress(m_peers[i], m_port));
            m_txMismark.push_back(m);
          }
      }

    if (m_full)
      {
        m_roundEvent = Simulator::Schedule(m_roundInterval, &ConsensusApp::RoundTick, this);
      }
    else if (IsPrimary())
      {
        m_roundEvent = Simulator::Schedule(m_roundInterval,
                                           &ConsensusApp::StartRound, this);
      }
  }

  void StopApplication() override
  {
    m_roundEvent.Cancel();
    for (auto& kv : m_rounds) kv.second.timer.Cancel();
    if (m_rxSocket) m_rxSocket->Close();
  }

  bool Attacking() const
  {
    Time now = Simulator::Now();
    return m_adv != ADV_NONE && now >= m_attackStart && now < m_attackStop;
  }
  bool Acts(uint32_t bit) const { return (m_adv & bit) && Attacking(); }

  uint32_t Primary() const { return m_full ? m_view % m_n : 0; }
  bool IsPrimary() const { return m_self == Primary(); }

  // ---- v1 model ----------------------------------------------------------------

  void StartRound()
  {
    m_round++;
    int64_t startNs = Simulator::Now().GetNanoSeconds();
    m_rounds[m_round].startNs = startNs;
    Broadcast(PRE_PREPARE, m_round, startNs);
    m_sentPrePrepare++;
    PruneOldRounds();
    m_roundEvent = Simulator::Schedule(m_roundInterval,
                                       &ConsensusApp::StartRound, this);
  }

  void ProcessV1(Hdr h)
  {
    RoundState& rs = m_rounds[h.round];
    if (rs.startNs < 0) rs.startNs = h.startNs;

    switch (h.type)
      {
      case PRE_PREPARE:
        rs.gotPrePrepare = true;
        // Backups answer a PRE-PREPARE with a PREPARE. The primary does not
        // send PREPARE; its PRE-PREPARE plays that role.
        if (!IsPrimary() && !rs.sentPrepare)
          {
            rs.sentPrepare = true;
            Broadcast(PREPARE, h.round, rs.startNs);
            m_sentPrepare++;
          }
        break;

      case PREPARE:
        rs.prepares.insert(h.sender);
        if (!rs.sentCommit && rs.prepares.size() >= 2 * m_f)
          {
            if (!IsPrimary() && !rs.gotPrePrepare) m_overtaken++;
            rs.sentCommit = true;
            Broadcast(COMMIT, h.round, rs.startNs);
            m_sentCommit++;
          }
        break;

      case COMMIT:
        rs.commits.insert(h.sender);
        if (!rs.committed && rs.commits.size() >= 2 * m_f + 1)
          {
            rs.committed = true;
            RecordCommit(h.round, rs);
          }
        break;
      }
  }

  /** Keep the round map bounded in long runs (v1: called by the primary only). */
  void PruneOldRounds()
  {
    const uint32_t keep = m_full ? std::max<uint32_t>(64, m_reproposeWindow) : 16;
    while (m_rounds.size() > keep)
      {
        m_rounds.begin()->second.timer.Cancel();
        m_rounds.erase(m_rounds.begin());
      }
  }

  // ---- full model ----------------------------------------------------------------

  void RoundTick()
  {
    m_expected++;
    RoundState& rs = m_rounds[m_expected];
    // Every node keeps the same round clock (synchronised, like the gates).
    if (rs.startNs < 0) rs.startNs = Simulator::Now().GetNanoSeconds();
    if (IsPrimary()) Propose(m_expected);
    else ArmViewTimer(m_expected);
    PruneOldRounds();
    m_roundEvent = Simulator::Schedule(m_roundInterval, &ConsensusApp::RoundTick, this);
  }

  void Propose(uint32_t round)
  {
    RoundState& rs = m_rounds[round];
    if (rs.startNs < 0) rs.startNs = Simulator::Now().GetNanoSeconds();
    if (rs.committed || rs.haveProposal || rs.abandoned) return;
    if (Acts(ADV_CRASH)) return;               // a crashed primary opens nothing
    if (m_oracle) m_oracle->NoteRoundOpened(round, rs.startNs);
    rs.proposed = HonestDigest(round);
    rs.haveProposal = true;
    if (Acts(ADV_EQUIVOCATE))
      {
        // Half the backups get the honest digest, the rest a forked one. The
        // primary holds the honest one. Neither half can collect 2f matching
        // PREPAREs, so the round stalls until the backups time out: the attack
        // costs no extra frames, only the view change it provokes.
        size_t half = m_txSockets.size() / 2;
        std::vector<uint8_t> a = MakeMsg(PRE_PREPARE, round, rs.startNs, m_view, rs.proposed, 0);
        std::vector<uint8_t> b = MakeMsg(PRE_PREPARE, round, rs.startNs, m_view, ForkedDigest(round), 0);
        for (size_t k = 0; k < m_txSockets.size(); ++k) SendTo(k, k < half ? a : b);
        m_equivocations++;
      }
    else
      {
        Broadcast(PRE_PREPARE, round, rs.startNs, m_view, rs.proposed);
      }
    m_sentPrePrepare++;
    CheckPrepared(round, rs);
  }

  /** The honest proposal's identity. Only equality within a round matters. */
  static uint32_t HonestDigest(uint32_t /*round*/) { return 0; }
  static uint32_t ForkedDigest(uint32_t round) { return 0xA5A50000u | (round & 0xFFFFu); }

  void ProcessFull(const Hdr& h)
  {
    if (h.type == VIEW_CHANGE) { OnViewChange(h); return; }
    if (h.type == NEW_VIEW)    { OnNewView(h); return; }
    if (h.view > m_view)
      {
        m_future.push_back(h);                // replayed on entering that view
        // f+1 distinct senders in a higher view include a correct node: catch up.
        auto& from = m_futureFrom[h.view];
        from.insert(h.sender);
        if (from.size() >= m_f + 1)
          {
            m_caughtUp++;
            EnterView(h.view);
          }
        return;
      }
    if (h.view < m_view) return;                                // from an abandoned view

    RoundState& rs = m_rounds[h.round];
    if (rs.startNs < 0) rs.startNs = h.startNs;
    if (rs.committed || rs.abandoned) return;

    switch (h.type)
      {
      case PRE_PREPARE:
        if (h.sender != Primary() || rs.haveProposal) break;
        if (rs.preparesBy[h.digest].size() >= 2 * m_f) m_overtaken++;
        rs.proposed = h.digest;
        rs.haveProposal = true;
        if (!rs.sentPrepare)
          {
            rs.sentPrepare = true;
            Broadcast(PREPARE, h.round, rs.startNs, m_view, rs.proposed);
            m_sentPrepare++;
            // A backup's own PREPARE is in its log and counts toward the 2f
            // (Castro-Liskov). Without it, one silent backup stops every round.
            rs.preparesBy[rs.proposed].insert(m_self);
          }
        // PREPAREs and COMMITs may have arrived before the PRE-PREPARE (it can
        // wait for a gate that the others pass): count them now.
        CheckPrepared(h.round, rs);
        break;

      case PREPARE:
        rs.preparesBy[h.digest].insert(h.sender);
        CheckPrepared(h.round, rs);
        break;

      case COMMIT:
        rs.commitsBy[h.digest].insert(h.sender);
        TryCommit(h.round, rs);
        break;
      }
  }

  /** Send COMMIT once PREPAREs from 2f senders match the proposal this node holds. */
  void CheckPrepared(uint32_t round, RoundState& rs)
  {
    if (rs.haveProposal && !rs.sentCommit && rs.preparesBy[rs.proposed].size() >= 2 * m_f &&
        !Acts(ADV_WITHHOLD))                    // withholding: prepare, then go quiet
      {
        rs.sentCommit = true;
        Broadcast(COMMIT, round, rs.startNs, m_view, rs.proposed);
        m_sentCommit++;
        rs.commitsBy[rs.proposed].insert(m_self);   // committed-local counts its own
      }
    TryCommit(round, rs);
  }

  /** Commit once prepared and holding 2f+1 matching COMMITs, its own included. */
  void TryCommit(uint32_t round, RoundState& rs)
  {
    if (rs.committed || !rs.haveProposal || !rs.sentCommit) return;
    if (rs.commitsBy[rs.proposed].size() < 2 * m_f + 1) return;
    rs.committed = true;
    rs.timer.Cancel();
    m_viewTimeout = m_baseViewTimeout;   // a commit ends any backoff
    RecordCommit(round, rs);
  }

  void ArmViewTimer(uint32_t round)
  {
    if (!m_vcEnabled) return;
    RoundState& rs = m_rounds[round];
    if (rs.committed || rs.timerArmed || rs.abandoned) return;
    rs.timerArmed = true;
    rs.timer = Simulator::Schedule(m_viewTimeout, &ConsensusApp::OnViewTimeout, this, round);
  }

  void OnViewTimeout(uint32_t round)
  {
    auto it = m_rounds.find(round);
    if (it == m_rounds.end() || it->second.committed) return;
    if (m_viewsEntered >= m_maxViews) return;
    // A crashed node cannot ask for a view change and a withholding one need
    // not: part of why recovery needs 2f+1 requests rather than f+1.
    if (Acts(ADV_CRASH) || Acts(ADV_WITHHOLD)) return;
    uint32_t target = m_view + 1;
    if (m_requestedView >= target) return;   // one request per view
    m_requestedView = target;
    // All to all: an O(n^2) burst on a network whose windows were sized for the
    // normal case.
    Broadcast(VIEW_CHANGE, round, it->second.startNs, m_view, target, m_vcSize);
    m_sentViewChange++;
    m_viewVotes[target].insert(m_self);
    MaybeEnterView(target);
  }

  void OnViewChange(const Hdr& h)
  {
    uint32_t target = h.digest;
    if (target <= m_view) return;
    m_viewVotes[target].insert(h.sender);
    MaybeJoin();
    MaybeEnterView(target);
  }

  /**
   * Castro-Liskov's liveness rule: VIEW-CHANGEs from f+1 other nodes for views
   * above this one include a correct node, so join the smallest of those views
   * without waiting for a timer. Without it a primary (which arms no timers) or
   * a node that recovered late never votes, and with f nodes silent the other
   * 2f cannot reach 2f+1 on their own.
   */
  void MaybeJoin()
  {
    if (!m_vcEnabled || Acts(ADV_CRASH) || Acts(ADV_WITHHOLD)) return;
    if (m_viewsEntered >= m_maxViews) return;
    std::set<uint32_t> senders;
    uint32_t smallest = 0;
    for (auto it = m_viewVotes.upper_bound(m_view); it != m_viewVotes.end(); ++it)
      for (uint32_t s : it->second)
        if (s != m_self)
          {
            senders.insert(s);
            if (!smallest) smallest = it->first;
          }
    if (senders.size() < m_f + 1 || m_requestedView >= smallest) return;
    m_requestedView = smallest;
    Broadcast(VIEW_CHANGE, m_expected, Simulator::Now().GetNanoSeconds(), m_view, smallest,
              m_vcSize);
    m_sentViewChange++;
    m_viewVotes[smallest].insert(m_self);
    MaybeEnterView(smallest);
  }

  void MaybeEnterView(uint32_t target)
  {
    if (m_viewVotes[target].size() < 2 * m_f + 1) return;
    // Votes keep arriving after the quorum; only the first entry acts.
    if (!EnterView(target)) return;
    if (IsPrimary())
      {
        Broadcast(NEW_VIEW, m_expected, Simulator::Now().GetNanoSeconds(), m_view, 0, m_nvSize);
        m_sentNewView++;
        std::vector<uint32_t> open;
        for (auto& kv : m_rounds)
          if (!kv.second.committed && !kv.second.abandoned) open.push_back(kv.first);
        for (uint32_t r : open) Propose(r);
      }
  }

  void OnNewView(const Hdr& h)
  {
    if (h.view <= m_view) return;
    EnterView(h.view);
  }

  bool EnterView(uint32_t v)
  {
    if (v <= m_view) return false;
    m_view = v;
    m_viewsEntered++;
    m_requestedView = 0;
    if (m_oracle && Trusted()) m_oracle->NoteViewChange(m_self, v);
    m_futureFrom.erase(m_futureFrom.begin(), m_futureFrom.upper_bound(v));
    // Exponential backoff (Castro-Liskov); reset by the next commit.
    m_viewTimeout = m_viewTimeout * m_viewBackoff;
    // Rounds at or below the cutoff fall outside the re-proposal window.
    const uint32_t cutoff = (m_reproposeWindow && m_expected > m_reproposeWindow)
                                ? m_expected - m_reproposeWindow : 0;
    // Votes are per view; round identity and start time carry over.
    for (auto& kv : m_rounds)
      {
        RoundState& rs = kv.second;
        if (rs.committed || rs.abandoned) continue;
        if (kv.first <= cutoff)
          {
            rs.abandoned = true;
            rs.timer.Cancel();
            rs.timerArmed = false;
            m_abandoned++;
            if (m_oracle && Trusted()) m_oracle->NoteAbandoned(kv.first);
            continue;
          }
        rs.preparesBy.clear();
        rs.commitsBy.clear();
        rs.sentPrepare = false;
        rs.sentCommit = false;
        rs.haveProposal = false;
        rs.timer.Cancel();
        rs.timerArmed = false;
        if (!IsPrimary()) ArmViewTimer(kv.first);
      }
    // Replay what arrived early for this view; keep what belongs to a later one.
    std::vector<Hdr> held;
    held.swap(m_future);
    for (const Hdr& h : held)
      {
        if (h.view == m_view) ProcessFull(h);
        else if (h.view > m_view) m_future.push_back(h);
      }
    return true;
  }

  // ---- both ----------------------------------------------------------------------

  void RecordCommit(uint32_t round, RoundState& rs)
  {
    m_committed++;
    // Only correct nodes file commits: safety is agreement among correct nodes.
    if (m_oracle && Trusted())
      m_oracle->NoteCommit(round, m_self, rs.proposed, Simulator::Now().GetNanoSeconds());
    // Time from the round first being opened (across view changes) to this
    // node committing it. This is the metric that moves under gate
    // quantisation; round and message counts do not until consensus fails.
    int64_t lat = Simulator::Now().GetNanoSeconds() - rs.startNs;
    m_latSum += lat;
    m_latMax = std::max(m_latMax, lat);
    m_latSamples.push_back(lat);
    m_commitTrace(Simulator::Now());
  }

  /** One message, header first, in a zeroed buffer of its full size. */
  std::vector<uint8_t> MakeMsg(MsgType t, uint32_t round, int64_t startNs, uint32_t view,
                               uint32_t digest, uint32_t size) const
  {
    // Zero first so the struct's alignment padding is deterministic, and build the whole
    // message in a zeroed buffer: Packet::AddPaddingAtEnd() leaves the bytes it adds
    // uninitialised. Captures are then byte-identical across machines.
    Hdr h;
    std::memset(&h, 0, sizeof(h));
    h.type = static_cast<uint8_t>(t);
    h.round = round;
    h.sender = m_self;
    h.startNs = startNs;
    h.view = view;
    h.digest = digest;
    uint32_t bytes = size ? size : m_msgSize;
    std::vector<uint8_t> buf(std::max<uint32_t>(bytes, sizeof(h)), 0);
    std::memcpy(buf.data(), &h, sizeof(h));
    return buf;
  }

  /** Send to peer slot k, at the control codepoint if this node mismarks. */
  void SendTo(size_t k, const std::vector<uint8_t>& buf)
  {
    bool mis = Acts(ADV_MISMARK) && k < m_txMismark.size();
    Ptr<Packet> p = Create<Packet>(buf.data(), buf.size());
    (mis ? m_txMismark[k] : m_txSockets[k])->Send(p);
    m_msgsSent++;
    if (mis) m_mismarked++;
  }

  void Broadcast(MsgType t, uint32_t round, int64_t startNs, uint32_t view = 0,
                 uint32_t digest = 0, uint32_t size = 0)
  {
    if (Acts(ADV_CRASH)) return;
    std::vector<uint8_t> buf = MakeMsg(t, round, startNs, view, digest, size);
    // Flooding: receivers deduplicate by sender, so the protocol outcome is
    // unchanged and only the bandwidth grows.
    uint32_t reps = Acts(ADV_FLOOD) ? m_floodFactor : 1;
    for (uint32_t r = 0; r < reps; ++r)
      {
        for (size_t k = 0; k < m_txSockets.size(); ++k) SendTo(k, buf);
        if (r > 0) m_floodExtra += static_cast<uint32_t>(m_txSockets.size());
      }
  }

  void HandleRead(Ptr<Socket> socket)
  {
    Ptr<Packet> p;
    Address from;
    while ((p = socket->RecvFrom(from)))
      {
        if (p->GetSize() < sizeof(Hdr)) continue;
        Hdr h;
        p->CopyData(reinterpret_cast<uint8_t*>(&h), sizeof(h));
        // A crashed node neither sends nor processes.
        if (Acts(ADV_CRASH)) continue;
        // Signature verification cost. Calibrate from your own testbed
        // rather than leaving it at the default. A delaying node adds to it; a
        // reaction that then misses its gate waits a whole cycle.
        Time d = m_verifyDelay;
        if (Acts(ADV_DELAY)) d += m_attackDelay;
        Simulator::Schedule(d, &ConsensusApp::Process, this, h);
      }
  }

  void Process(Hdr h)
  {
    if (m_full) ProcessFull(h);
    else ProcessV1(h);
  }

  std::vector<Ipv4Address> m_peers;
  std::vector<Ptr<Socket>> m_txSockets;
  Ptr<Socket> m_rxSocket;

  uint32_t m_self{0}, m_n{0}, m_f{0}, m_round{0};
  uint16_t m_port{7000};
  uint32_t m_msgSize{256};
  Time m_roundInterval, m_verifyDelay;
  EventId m_roundEvent;
  bool m_useBe{false};

  std::map<uint32_t, RoundState> m_rounds;

  // full model
  bool     m_full{false};
  bool     m_vcEnabled{false};
  uint32_t m_expected{0};
  uint32_t m_view{0}, m_requestedView{0}, m_viewsEntered{0}, m_maxViews{64};
  Time     m_viewTimeout, m_baseViewTimeout;
  double   m_viewBackoff{2.0};
  uint32_t m_vcSize{0}, m_nvSize{0};
  std::map<uint32_t, std::set<uint32_t>> m_viewVotes;
  std::vector<Hdr> m_future;
  std::map<uint32_t, std::set<uint32_t>> m_futureFrom;   // senders seen per higher view

  // adversary (full model)
  uint32_t m_adv{ADV_NONE};
  Time     m_attackStart{Time::Max()}, m_attackStop{Time::Max()};
  uint32_t m_floodFactor{1};
  Time     m_attackDelay;
  Ptr<ConsensusOracle> m_oracle;
  std::vector<Ptr<Socket>> m_txMismark;
  uint32_t m_mismarked{0}, m_floodExtra{0}, m_equivocations{0}, m_caughtUp{0};

  uint32_t m_sentPrePrepare{0}, m_sentPrepare{0}, m_sentCommit{0};
  uint32_t m_sentViewChange{0}, m_sentNewView{0}, m_overtaken{0};
  uint32_t m_reproposeWindow{0}, m_abandoned{0};
  uint32_t m_committed{0}, m_msgsSent{0};
  int64_t  m_latSum{0}, m_latMax{0};
  std::vector<int64_t> m_latSamples;

  TracedCallback<Time> m_commitTrace;
};

NS_OBJECT_ENSURE_REGISTERED(ConsensusApp);

// ---------------------------------------------------------------------------
static Time NowCallback() { return Simulator::Now(); }

/**
 * Cyclic GCL: control window, then consensus window, then best effort.
 *
 * `phase` rotates the whole sequence so that the schedule installed on a port
 * begins `phase` into the nominal cycle. Installing the SAME schedule with
 * ZERO phase on every port models a network where every gate opens
 * simultaneously; a frame then arrives at hop k after the window there has
 * already been open for k * (serialisation + propagation), and once that
 * exceeds the window width the frame waits a full cycle -- per hop. Real TSN
 * configuration (802.1Qcc CNC) computes per-hop offsets so each switch's
 * window opens as the frame arrives.
 *
 * Set --perHopOffset=0 to reproduce the naive simultaneous-gates behaviour.
 */
using GateWindow = std::pair<int64_t, NetDeviceListConfig::GateStateMap>;

static std::vector<GateWindow>
BuildSchedule(Time cycle, double ctrlFrac, double consFrac, Time phase = Time(0),
              uint32_t slices = 1)
{
  NS_ABORT_MSG_IF(ctrlFrac + consFrac > 1.0, "gate fractions exceed the cycle");

  NetDeviceListConfig::GateStateMap gCtrl{}, gCons{}, gBe{};
  gCtrl[CLASS_CONTROL]   = true;
  gCons[CLASS_CONSENSUS] = true;
  gBe[CLASS_BE]          = true;

  const int64_t C = cycle.GetNanoSeconds();

  // Nominal window sequence, in nanoseconds.
  std::vector<std::pair<int64_t, NetDeviceListConfig::GateStateMap>> seq;
  int64_t ctrlNs = static_cast<int64_t>(C * ctrlFrac);
  int64_t consNs = static_cast<int64_t>(C * consFrac);
  int64_t beNs   = C - ctrlNs - consNs;
  if (ctrlNs > 0) seq.push_back({ctrlNs, gCtrl});
  // Consensus and the best-effort time left over are cut into `slices` equal
  // parts and interleaved after the control window: [ctrl][cons][be][cons][be]...
  // The last slice takes the rounding remainder so the durations still sum to the
  // cycle. With slices == 1 this is exactly [ctrl][cons][be], as before.
  const uint32_t K = std::max<uint32_t>(slices, 1);
  for (uint32_t k = 0; k < K; ++k)
    {
      const bool last = (k + 1 == K);
      int64_t c = last ? consNs - (consNs / K) * (K - 1) : consNs / K;
      int64_t b = last ? beNs - (beNs / K) * (K - 1) : beNs / K;
      if (c > 0) seq.push_back({c, gCons});
      if (b > 0) seq.push_back({b, gBe});
    }
  NS_ABORT_MSG_IF(seq.empty(), "schedule has no open windows");

  // A POSITIVE phase DELAYS the schedule: the window that nominally opens at
  // 0 should now open at `phase`. Since the rotation below makes the gate
  // state at time t equal the nominal state at (t + ph), delaying by `phase`
  // requires rotating by its complement.
  int64_t ph = (-phase.GetNanoSeconds()) % C;
  if (ph < 0) ph += C;

  // Locate the window containing `ph`, and how far into it we start.
  size_t idx = 0;
  int64_t into = 0, acc = 0;
  for (size_t i = 0; i < seq.size(); ++i)
    {
      if (ph < acc + seq[i].first) { idx = i; into = ph - acc; break; }
      acc += seq[i].first;
    }

  // Emit: remainder of the straddled window, the rest in order, then the
  // leading fragment of the straddled window. Durations sum to exactly C.
  std::vector<std::pair<int64_t, NetDeviceListConfig::GateStateMap>> out;
  out.push_back({seq[idx].first - into, seq[idx].second});
  for (size_t k = 1; k < seq.size(); ++k)
    {
      size_t i = (idx + k) % seq.size();
      out.push_back({seq[i].first, seq[i].second});
    }
  if (into > 0) out.push_back({into, seq[idx].second});

  return out;
}

/**
 * Which traffic class a window opens, or -1 if the map is empty. Each window
 * built above opens exactly one class, so this is unambiguous here.
 */
static int
OpenClassOf(const NetDeviceListConfig::GateStateMap& g)
{
  // Despite the name, GateStateMap is std::array<bool,8> indexed by traffic
  // class -- not an associative container.
  for (size_t i = 0; i < g.size(); ++i) if (g[i]) return static_cast<int>(i);
  return -1;
}

/** Bytes on the wire for a UDP payload over PointToPointNetDevice (PPP). */
static const uint32_t FRAME_OVERHEAD = 30;   // 20 IP + 8 UDP + 2 PPP

/**
 * A frame that cannot be serialised inside its own gate window can never be
 * transmitted: it is enqueued and held forever. Catch that at setup rather
 * than discovering it as a mysteriously silent protocol.
 */
static void
CheckWindowFeasibility(const std::string& label, DataRate rate,
                       uint32_t payloadBytes, Time window)
{
  uint32_t bytes = payloadBytes + FRAME_OVERHEAD;
  Time tx = rate.CalculateBytesTxTime(bytes);
  NS_ABORT_MSG_IF(window <= Time(0),
                  label << ": gate window is zero -- this class can never "
                        << "transmit. Give it a window, or route the traffic "
                        << "to another class.");
  NS_ABORT_MSG_IF(tx > window,
                  label << ": a " << bytes << " B frame needs "
                        << tx.GetMicroSeconds() << " us at " << rate
                        << " but the window is only "
                        << window.GetMicroSeconds() << " us. Max payload here "
                        << "is about "
                        << (rate.GetBitRate() * window.GetNanoSeconds() / 8
                            / 1000000000 - FRAME_OVERHEAD)
                        << " B. Widen the window, raise the link rate, or "
                        << "shrink the frame.");
}

int main(int argc, char* argv[])
{
  uint32_t nSwitches = 4;
  uint32_t nValidators = 4;
  double   ctrlFrac = 0.20, consFrac = 0.30;
  Time     cycle = MicroSeconds(1000);
  Time     ctrlPeriod = MicroSeconds(1000);   // equals the default gate cycle
  Time     ctrlDeadline = MicroSeconds(1000);
  uint32_t ctrlPayload  = 64;   // UDP payload bytes per control frame
  uint32_t ctrlBurst    = 1;    // control frames sent back to back each period
  uint32_t ctrlTos      = 16;   // IP ToS of the control frames (decimal): 16 = class 6, 24 = class 4
  uint32_t consSlices   = 1;    // consensus window cut into this many slices per cycle
  Time     offsetJitter = NanoSeconds(0);  // sigma of independent per-port gate phase error
  bool     randomRoundPhase = false;       // random start phase of the consensus rounds
  bool     randomPlacement  = false;       // random switch for every validator
  Time     consensusInterval = MilliSeconds(10);
  Time     verifyDelay = MicroSeconds(200);
  Time     warmup = Seconds(0.5);
  Time     stopAt = Seconds(2.0);
  uint32_t consensusMsgSize = 256;
  std::string linkRate = "1Gbps";
  std::string latencyCsv = "";
  std::string consensusCsv = "";
  std::string pbftModel = "v1";
  bool     viewChange = true;
  Time     viewTimeout = Seconds(-1);   // negative: 4 x consensusInterval
  double   viewBackoff = 2.0;
  uint32_t maxViewChanges = 64;
  uint32_t reproposeWindow = 0;
  uint32_t viewChangeSize = 0;          // 0: consensusMsgSize
  uint32_t newViewSize = 0;             // 0: consensusMsgSize
  bool     pbftStats = false;
  std::string attackSpec = "none";
  uint32_t nByzantine = 0;
  std::string byzSelect = "primary";
  Time     attackStart = Seconds(-1);   // negative: --warmup
  Time     attackStop  = Seconds(-1);   // negative: stopAt - cooldown
  uint32_t floodFactor = 8;
  Time     attackDelay = MilliSeconds(0);
  uint32_t nInjectors = 0;
  std::string injectClass = "control";
  uint32_t injectFrame = 1024;
  uint32_t injectBurst = 4;
  Time     injectInterval = MicroSeconds(200);
  std::string adversaryCsv = "";
  bool consensusInBe = false;
  Time     perHopOffset = MicroSeconds(-1);   // negative => derive automatically
  Time     cooldown = MilliSeconds(100);
  uint32_t runId = 1;

  // --- Shaper ---------------------------------------------------------------
  std::string shaper = "tas";
  std::string qdiscSize = "800p";
  std::string devQueue  = "1p";    // point-to-point device transmit queue, below the qdisc

  // --- Capture -------------------------------------------------------------
  std::string pcapPoints = "none";
  std::string pcapPrefix = "iiot";
  std::string pcapMode   = "tx";
  uint32_t pcapSnapLen   = 128;
  bool     pcapNanosec   = true;
  uint32_t pcapMaxMB     = 256;
  Time     pcapStart     = Seconds(-1);   // negative => warmup
  Time     pcapStop      = Seconds(-1);   // negative => stopAt - cooldown

  CommandLine cmd;
  cmd.AddValue("nSwitches", "Number of switch (router) nodes", nSwitches);
  cmd.AddValue("nValidators", "Committee size n", nValidators);
  cmd.AddValue("ctrlFrac", "Fraction of cycle gated to control", ctrlFrac);
  cmd.AddValue("consFrac", "Fraction of cycle gated to consensus", consFrac);
  cmd.AddValue("cycle", "TAS cycle time", cycle);
  cmd.AddValue("ctrlPeriod",
               "Control loop send period. Keep it equal to --cycle: a shorter period puts more "
               "frames in a cycle than the single control window can pass, which queues "
               "half of them for most of a cycle", ctrlPeriod);
  cmd.AddValue("ctrlDeadline", "Control loop end-to-end deadline", ctrlDeadline);
  cmd.AddValue("ctrlPayload",
               "UDP payload bytes per control frame (minimum 16). The aligned "
               "per-hop offset follows this value", ctrlPayload);
  cmd.AddValue("ctrlBurst",
               "Control frames sent back to back each period, modelling several "
               "streams with one period and phase. 1 reproduces the original "
               "single-frame behaviour", ctrlBurst);
  cmd.AddValue("ctrlTos",
               "IP ToS byte of the control frames, in DECIMAL: 16 (default) puts them in "
               "the control class, 24 in the consensus class. A diagnostic option for "
               "comparing how two classes' gates admit the same traffic", ctrlTos);
  cmd.AddValue("consSlices",
               "Cut the consensus window into this many equal slices spread across "
               "the cycle, interleaved with best-effort slices: [ctrl][cons][be]"
               "[cons][be]... Total consensus and best-effort time are unchanged, "
               "so each PBFT phase waits less for the next window, but every slice "
               "strands up to one frame. 1 reproduces the original schedule",
               consSlices);
  cmd.AddValue("offsetJitter",
               "Standard deviation of an independent Gaussian error added to the "
               "gate phase of every shaped port, truncated at 4 sigma. Models clock "
               "synchronisation error between devices. Drawn from --run, so each run "
               "is a different, repeatable draw. 0 (default) draws nothing",
               offsetJitter);
  cmd.AddValue("randomRoundPhase",
               "Start the consensus rounds at a uniformly random point of the cycle "
               "instead of at a cycle boundary. Drawn from --run", randomRoundPhase);
  cmd.AddValue("randomPlacement",
               "Attach each validator to a uniformly random switch instead of round "
               "robin. Drawn from --run", randomPlacement);
  cmd.AddValue("consensusInterval", "Consensus round period", consensusInterval);
  cmd.AddValue("verifyDelay", "Per-message signature verification delay", verifyDelay);
  cmd.AddValue("consensusMsgSize", "Consensus message size in bytes", consensusMsgSize);
  cmd.AddValue("warmup", "Discard control samples before this time", warmup);
  cmd.AddValue("stopAt", "Simulation stop time", stopAt);
  cmd.AddValue("latencyCsv", "If set, dump per-packet control latency here", latencyCsv);
  cmd.AddValue("consensusInBe", "Send consensus at best effort (class 1)", consensusInBe);
  cmd.AddValue("linkRate", "Link data rate", linkRate);
  cmd.AddValue("perHopOffset",
               "Per-hop gate phase offset along the control path. "
               "0 = every gate opens simultaneously (naive). "
               "Negative = derive automatically from link rate.", perHopOffset);
  cmd.AddValue("cooldown",
               "Ignore control samples in the final interval before stopAt, "
               "so statistics cover only the loaded period", cooldown);
  cmd.AddValue("run", "RNG run number, for repeat trials", runId);
  cmd.AddValue("consensusCsv",
               "If set, dump per-commit consensus latency here", consensusCsv);

  cmd.AddValue("shaper",
               "Egress queue discipline on every port. tas = time-aware "
               "shaper, the system under study. prio = strict priority, no "
               "gates: control preempts consensus preempts best effort. "
               "fifo = single FIFO, no differentiation at all. The two "
               "baselines make --cycle, --ctrlFrac, --consFrac and "
               "--perHopOffset inactive", shaper);
  cmd.AddValue("qdiscSize",
               "Queue depth per class for --shaper=prio, or total for "
               "--shaper=fifo. Default 800p matches the TAS module's "
               "per-class default so drop behaviour is comparable",
               qdiscSize);

  cmd.AddValue("devQueue",
               "Transmit queue of every point-to-point device, below the queue "
               "discipline (default 1p). A frame the qdisc has already handed to this "
               "queue cannot be overtaken, so a larger value lets lower-priority "
               "frames block control for longer", devQueue);

  cmd.AddValue("pcapPoints",
               "Comma-separated capture points: none | control (PLC and IO "
               "access links) | trunk (switch-to-switch) | path (control + "
               "trunk, the whole PLC->IO path) | validators | injectors | all",
               pcapPoints);
  cmd.AddValue("pcapPrefix", "File name stem for captures", pcapPrefix);
  cmd.AddValue("pcapMode",
               "tx = PhyTxBegin, one file per egress port, timestamp is the "
               "gate-release instant (default); rx = PhyRxEnd; both = "
               "PromiscSniffer, tx and rx interleaved as in stock ns-3",
               pcapMode);
  cmd.AddValue("pcapSnapLen",
               "Bytes retained per frame. 128 keeps PPP+IP+UDP and the "
               "application header while dropping consensus padding",
               pcapSnapLen);
  cmd.AddValue("pcapNanosec",
               "Nanosecond pcap timestamps. Disable only for tools that "
               "cannot read the nanosecond magic number", pcapNanosec);
  cmd.AddValue("pcapMaxMB",
               "Total budget across all captures. Writing stops and a warning "
               "is printed once it is exhausted", pcapMaxMB);
  cmd.AddValue("pcapStart",
               "Start capturing at this time. Negative = at --warmup",
               pcapStart);
  cmd.AddValue("pcapStop",
               "Stop capturing at this time. Negative = at stopAt - cooldown",
               pcapStop);
  cmd.AddValue("pbftModel",
               "v1 = release 1.x normal case, reproduced exactly (static primary, no view "
               "change); full = per-digest quorums, own COMMIT counted, view change",
               pbftModel);
  cmd.AddValue("viewChange", "full model: enable the view change", viewChange);
  cmd.AddValue("viewTimeout",
               "full model: time from a round's start until a backup that has not committed "
               "it asks for a view change. Negative = 4 x --consensusInterval", viewTimeout);
  cmd.AddValue("viewBackoff", "full model: timeout multiplier per view entered, reset by a commit",
               viewBackoff);
  cmd.AddValue("maxViewChanges", "full model: views a node may enter in one run", maxViewChanges);
  cmd.AddValue("reproposeWindow",
               "full model: on a view change, re-propose only uncommitted rounds opened in "
               "the last N round ticks and abandon older ones (PBFT's log watermarks). "
               "0 = every uncommitted round still held (the most recent 64)",
               reproposeWindow);
  cmd.AddValue("viewChangeSize", "full model: VIEW-CHANGE size in bytes (0 = consensusMsgSize)",
               viewChangeSize);
  cmd.AddValue("newViewSize", "full model: NEW-VIEW size in bytes (0 = consensusMsgSize)",
               newViewSize);
  cmd.AddValue("pbftStats", "print the pbft model section in the v1 model too", pbftStats);
  cmd.AddValue("attack",
               "Comma-separated behaviours: none | crash | withhold | equivocate | flood | "
               "delay | mismark | inject. Validator behaviours need --pbftModel=full. "
               "Naming a validator behaviour with --nByzantine=0 makes it 1; naming inject "
               "with --nInjectors=0 makes it 1", attackSpec);
  cmd.AddValue("nByzantine", "Number of Byzantine validators", nByzantine);
  cmd.AddValue("byzSelect",
               "Which validators are Byzantine: primary (0, 1, ..., so the first primary "
               "is faulty) | spread (evenly spaced, on different switches) | last "
               "(n-1, n-2, ..., so the primary stays honest)", byzSelect);
  cmd.AddValue("attackStart", "Start of the attack window. Negative = --warmup", attackStart);
  cmd.AddValue("attackStop",
               "End of the attack window, leaving a recovery period. Negative = stopAt - "
               "cooldown", attackStop);
  cmd.AddValue("floodFactor", "Copies of every broadcast under --attack=flood", floodFactor);
  cmd.AddValue("attackDelay", "Extra processing delay under --attack=delay", attackDelay);
  cmd.AddValue("nInjectors",
               "Compromised end stations at switch 0 sending to the IO device (no consensus "
               "role); used only with --attack=inject", nInjectors);
  cmd.AddValue("injectClass", "Class the injectors claim: control | consensus | be", injectClass);
  cmd.AddValue("injectFrame", "Injected UDP payload size in bytes", injectFrame);
  cmd.AddValue("injectBurst", "Frames per injector burst", injectBurst);
  cmd.AddValue("injectInterval", "Interval between injector bursts", injectInterval);
  cmd.AddValue("adversaryCsv", "If set, write per-round safety and liveness detail here",
               adversaryCsv);
  cmd.Parse(argc, argv);

  NS_ABORT_MSG_IF(shaper != "tas" && shaper != "prio" && shaper != "fifo",
                  "--shaper must be tas, prio or fifo");
  const bool gated = (shaper == "tas");

  // --- Resolve capture parameters -----------------------------------------
  std::set<std::string> pcapSel;
  {
    std::stringstream ss(pcapPoints);
    std::string tok;
    while (std::getline(ss, tok, ','))
      {
        tok.erase(0, tok.find_first_not_of(" \t"));
        tok.erase(tok.find_last_not_of(" \t") + 1);
        if (!tok.empty() && tok != "none") pcapSel.insert(tok);
      }
    for (const auto& s : pcapSel)
      {
        NS_ABORT_MSG_IF(s != "control" && s != "trunk" && s != "path" &&
                        s != "validators" && s != "injectors" && s != "all",
                        "unknown --pcapPoints value \"" << s << "\"");
      }
    if (pcapSel.count("all"))
      { pcapSel = {"control", "trunk", "validators", "injectors"}; }
    if (pcapSel.count("path"))
      { pcapSel.erase("path"); pcapSel.insert("control"); pcapSel.insert("trunk"); }
  }

  if (pcapStart < Time(0)) pcapStart = warmup;
  if (pcapStop  < Time(0)) pcapStop  = stopAt - cooldown;
  NS_ABORT_MSG_IF(!pcapSel.empty() && pcapStop <= pcapStart,
                  "empty capture window: --pcapStop must exceed --pcapStart");

  PcapTapSet::Mode tapMode =
      (pcapMode == "tx")   ? PcapTapSet::MODE_TX :
      (pcapMode == "rx")   ? PcapTapSet::MODE_RX :
      (pcapMode == "both") ? PcapTapSet::MODE_BOTH :
                             PcapTapSet::MODE_TX;
  NS_ABORT_MSG_IF(pcapMode != "tx" && pcapMode != "rx" && pcapMode != "both",
                  "--pcapMode must be tx, rx or both");

  // The attack is parsed before the network is built: --attack=inject decides
  // how many injector nodes exist.
  uint32_t advBits = ADV_NONE;
  {
    std::string bad;
    NS_ABORT_MSG_IF(!ParseAttack(attackSpec, advBits, bad),
                    "unknown --attack behaviour \"" << bad << "\"");
  }
  if (IsValidatorAttack(advBits) && nByzantine == 0) nByzantine = 1;
  if ((advBits & ADV_INJECT) && nInjectors == 0) nInjectors = 1;
  if (!(advBits & ADV_INJECT)) nInjectors = 0;

  RngSeedManager::SetSeed(1);
  RngSeedManager::SetRun(runId);

  Time::SetResolution(Time::NS);

  // FlowMonitor's default 1 ms histogram bins are far too coarse for
  // gate-scale effects.
  Config::SetDefault("ns3::FlowMonitor::DelayBinWidth", DoubleValue(0.00001));   // 10 us
  Config::SetDefault("ns3::FlowMonitor::JitterBinWidth", DoubleValue(0.00001));

  // --- Switch backbone (linear; swap for ring / star per IEC 61918) -------
  NodeContainer switches;
  switches.Create(nSwitches);

  //CsmaHelper csma;
  //csma.SetChannelAttribute("DataRate", StringValue(linkRate));
  //csma.SetChannelAttribute("Delay", TimeValue(NanoSeconds(100)));

  PointToPointHelper p2p;
  p2p.SetDeviceAttribute("DataRate", StringValue(linkRate));
  p2p.SetChannelAttribute("Delay", TimeValue(NanoSeconds(100)));
  // A deep device queue below the shaper defeats gating: packets released by
  // an open gate would just buffer here. Keep it minimal.
  p2p.SetQueue("ns3::DropTailQueue<Packet>", "MaxSize", StringValue(devQueue));

  InternetStackHelper stack;
  stack.Install(switches);

  std::vector<NetDeviceContainer> trunkDevs;
  for (uint32_t i = 0; i + 1 < nSwitches; ++i)
    {
      NodeContainer pair(switches.Get(i), switches.Get(i + 1));
      trunkDevs.push_back(p2p.Install(pair));
    }

  // --- End stations: PLC, IO device, validators ---------------------------
  NodeContainer plc, io, validators;
  plc.Create(1);
  io.Create(1);
  validators.Create(nValidators);
  stack.Install(plc);
  stack.Install(io);
  stack.Install(validators);

  NetDeviceContainer plcDev =
      p2p.Install(NodeContainer(plc.Get(0), switches.Get(0)));
  NetDeviceContainer ioDev =
      p2p.Install(NodeContainer(io.Get(0), switches.Get(nSwitches - 1)));

  // Switch each validator attaches to. Default is round robin. The generator is
  // created only when asked for, so default runs draw no random numbers at all.
  std::vector<uint32_t> placement(nValidators);
  {
    Ptr<UniformRandomVariable> pick;
    if (randomPlacement)
      {
        pick = CreateObject<UniformRandomVariable>();
        pick->SetStream(1001);
      }
    for (uint32_t i = 0; i < nValidators; ++i)
      placement[i] = randomPlacement ? pick->GetInteger(0, nSwitches - 1) : i % nSwitches;
  }

  std::vector<NetDeviceContainer> valDevs;
  for (uint32_t i = 0; i < nValidators; ++i)
    {
      // Validator placement is itself a variable worth sweeping.
      uint32_t sw = placement[i];
      valDevs.push_back(p2p.Install(NodeContainer(validators.Get(i), switches.Get(sw))));
    }

  // Injectors (compromised end stations) attach to switch 0 and send to the IO
  // device, so their traffic crosses the whole control path. Created after
  // everything else, so a run without them builds exactly the same network.
  NodeContainer injectors;
  std::vector<NetDeviceContainer> injDevs;
  if (nInjectors > 0)
    {
      injectors.Create(nInjectors);
      stack.Install(injectors);
      for (uint32_t i = 0; i < nInjectors; ++i)
        injDevs.push_back(p2p.Install(NodeContainer(injectors.Get(i), switches.Get(0))));
    }

  // --- Feasibility: can each class serialise its largest frame in-window? --
  DataRate rate(linkRate);
  Time ctrlWindow = cycle * ctrlFrac;
  Time consWindow = cycle * consFrac;
  Time beWindow   = cycle - ctrlWindow - consWindow;

  NS_ABORT_MSG_IF(ctrlPayload < 16 || ctrlBurst < 1,
                  "--ctrlPayload must be at least 16 and --ctrlBurst at least 1");
  NS_ABORT_MSG_IF(consSlices < 1, "--consSlices must be at least 1");
  // Each slice must hold a whole frame on its own, so check the slice width.
  Time consSlice = NanoSeconds(consWindow.GetNanoSeconds() / consSlices);
  Time beSlice   = NanoSeconds(beWindow.GetNanoSeconds() / consSlices);
  CheckWindowFeasibility("control (class 6)", rate, ctrlPayload, ctrlWindow);
  NS_ABORT_MSG_IF(pbftModel != "v1" && pbftModel != "full", "--pbftModel must be v1 or full");
  const bool fullModel = (pbftModel == "full");
  if (viewTimeout < Time(0)) viewTimeout = consensusInterval * 4;
  NS_ABORT_MSG_IF(viewBackoff < 1.0, "--viewBackoff must be at least 1.0");
  NS_ABORT_MSG_IF((viewChangeSize && viewChangeSize < 32) || (newViewSize && newViewSize < 32),
                  "--viewChangeSize and --newViewSize must be 0 or at least 32 B");
  NS_ABORT_MSG_IF(IsValidatorAttack(advBits) && !fullModel,
                  "validator behaviours need --pbftModel=full");
  NS_ABORT_MSG_IF(nByzantine > nValidators, "--nByzantine exceeds --nValidators");
  NS_ABORT_MSG_IF(byzSelect != "primary" && byzSelect != "spread" && byzSelect != "last",
                  "--byzSelect must be primary, spread or last");
  uint8_t injectTos = TOS_CONTROL;
  if (injectClass == "consensus") injectTos = TOS_CONSENSUS;
  else if (injectClass == "be") injectTos = TOS_BE;
  else NS_ABORT_MSG_IF(injectClass != "control", "--injectClass must be control, consensus or be");
  if (attackStart < Time(0)) attackStart = warmup;
  if (attackStop < Time(0)) attackStop = stopAt - cooldown;
  NS_ABORT_MSG_IF(advBits != ADV_NONE && attackStop <= attackStart,
                  "the attack window is empty: --attackStop must be after --attackStart");
  NS_ABORT_MSG_IF(nValidators > 0 && consensusMsgSize < 32,
                  "consensusMsgSize must be at least 32 B: the consensus "
                  "header (type, round, sender, startNs, view, digest) is "
                  "32 B and would be truncated.");
  if (nValidators > 0)
    {
      CheckWindowFeasibility(consensusInBe ? "consensus (in best effort)"
                                           : "consensus (class 4)",
                             rate, consensusMsgSize,
                             consensusInBe ? beSlice : consSlice);
    }

  // --- Per-hop gate phase offset ------------------------------------------
  // A control frame needs (serialisation + propagation) to reach the next hop.
  // Opening each successive gate that much later lets the frame travel without
  // waiting. Pass --perHopOffset=0 to model naive simultaneous gates.
  Time linkDelay = NanoSeconds(100);
  if (perHopOffset < Time(0))
    {
      perHopOffset = rate.CalculateBytesTxTime(ctrlPayload + FRAME_OVERHEAD) + linkDelay;
    }

  // --- Install TAS on every egress port -----------------------------------
  CallbackValue timeSource = MakeCallback(&NowCallback);

  // A named table of every shaped egress port. TAS installation, capture
  // point selection and the manifest all read from this one list, so a port
  // cannot be shaped under one identity and captured under another.
  //
  // role     goes in the pcap file name -- describes the port, not the node index
  // category selects it via --pcapPoints
  // hop      0 = PLC egress, k = switch k-1 egress toward switch k,
  //          nSwitches = last switch egress toward the IO device
  struct Port
  {
    Ptr<NetDevice> dev;
    std::string role;
    std::string category;
    uint32_t hop;
  };
  std::vector<Port> ports;

  // Only the forward PLC -> IO control path is phase aligned. Reverse-direction
  // ports mirror their peer's offset; consensus traffic is not aligned, which
  // is itself worth studying.
  ports.push_back({plcDev.Get(0), "plc-eg", "control", 0});
  ports.push_back({plcDev.Get(1), "sw0-plc", "control", 0});
  for (uint32_t i = 0; i < trunkDevs.size(); ++i)
    {
      std::ostringstream fwd, rev;
      fwd << "sw" << i << "-sw" << (i + 1);
      rev << "sw" << (i + 1) << "-sw" << i;
      ports.push_back({trunkDevs[i].Get(0), fwd.str(), "trunk", i + 1});
      ports.push_back({trunkDevs[i].Get(1), rev.str(), "trunk", i + 1});
    }
  {
    std::ostringstream last;
    last << "sw" << (nSwitches - 1) << "-io";
    ports.push_back({ioDev.Get(1), last.str(), "control", nSwitches});
    ports.push_back({ioDev.Get(0), "io-eg", "control", nSwitches});
  }
  for (uint32_t i = 0; i < valDevs.size(); ++i)
    {
      uint32_t sw = placement[i];
      std::ostringstream up, down;
      up   << "val" << i << "-eg";
      down << "sw" << sw << "-val" << i;
      ports.push_back({valDevs[i].Get(0), up.str(),   "validators", sw + 1});
      ports.push_back({valDevs[i].Get(1), down.str(), "validators", sw + 1});
    }
  for (uint32_t i = 0; i < injDevs.size(); ++i)
    {
      std::ostringstream up, down;
      up   << "inj" << i << "-eg";
      down << "sw0-inj" << i;
      ports.push_back({injDevs[i].Get(0), up.str(),   "injectors", 1});
      ports.push_back({injDevs[i].Get(1), down.str(), "injectors", 1});
    }

  // --- Install the shaper on every port ------------------------------------
  //
  // All three disciplines classify on the SocketPriorityTag, which
  // Ipv4L3Protocol re-derives from the IP ToS byte at every forwarded hop, so
  // classification is identical across the three and only the service policy
  // differs. Socket::IpTos2Priority yields 6 for control (ToS 0x10), 4 for
  // consensus (ToS 0x18) and 0 for best effort (ToS 0x00).
  //
  // A note on the TAS priority map, because it looks wrong and is not:
  // TasQueueDisc with 8 classes uses m_prioMap = {1,0,2,3,4,5,6,7}, which
  // swaps priorities 0 and 1. Priority 0 therefore lands in queue 1, which is
  // why CLASS_BE is 1 rather than 0. The two baselines below index bands by
  // socket priority directly, with no such swap, so their maps differ from
  // the CLASS_* constants by design.
  std::vector<std::pair<std::string, std::vector<GateWindow>>> gcl;

  // Gate phase of a port: the aligned offset times its hop index, plus an optional
  // independent Gaussian error (truncated at 4 sigma) modelling clock
  // synchronisation error. One draw per shaped port, in port-table order.
  Ptr<NormalRandomVariable> phaseErr;
  if (offsetJitter.GetNanoSeconds() > 0)
    {
      phaseErr = CreateObject<NormalRandomVariable>();
      phaseErr->SetStream(1002);
    }
  auto portPhase = [&](uint32_t hop) {
    int64_t ph = (perHopOffset * hop).GetNanoSeconds();
    if (phaseErr)
      {
        const double sd = static_cast<double>(offsetJitter.GetNanoSeconds());
        ph += static_cast<int64_t>(std::llround(phaseErr->GetValue(0.0, sd * sd, 4.0 * sd)));
      }
    const int64_t C = cycle.GetNanoSeconds();
    ph %= C;
    if (ph < 0) ph += C;
    return NanoSeconds(ph);
  };

  // Priority -> band for --shaper=prio. Index is the socket priority, value is
  // the band, band 0 served first. Priorities other than 6, 4 and 0 are
  // unreachable end-to-end (IpTos2Priority only returns 0, 2, 4, 6) and are
  // parked in the lowest band.
  const std::string prioMap = "2 2 2 2 1 2 0 2 2 2 2 2 2 2 2 2";
  //                           0 1 2 3 4 5 6 7  <- socket priority
  //                                   |   |
  //                                   |   +-- control  -> band 0
  //                                   +------ consensus-> band 1
  //                           +-------------- best eff -> band 2

  for (const auto& p : ports)
    {
      if (shaper == "tas")
        {
          std::vector<GateWindow> windows =
              BuildSchedule(cycle, ctrlFrac, consFrac, portPhase(p.hop), consSlices);

          NetDeviceListConfig plan;
          for (const auto& w : windows)
            if (w.first > 0) plan.Add(NanoSeconds(w.first), w.second);

          TsnHelper tsn;
          tsn.SetRootQueueDisc("ns3::TasQueueDisc",
                               "NetDeviceListConfig", NetDeviceListConfigValue(plan),
                               "TimeSource", timeSource,
                               "DataRate", StringValue(linkRate),
                               "TrustQostag", BooleanValue(true));
          tsn.Install(p.dev);

          gcl.push_back({p.role, windows});
        }
      else if (shaper == "prio")
        {
          // Strict priority with three bands and no time gating. This is what
          // an industrial Ethernet switch does without 802.1Qbv, and it is the
          // baseline the TAS result has to beat: control still gets absolute
          // precedence, but a consensus frame already in transmission cannot
          // be preempted, so control inherits up to one frame time of blocking
          // per hop.
          TrafficControlHelper tch;
          uint16_t h = tch.SetRootQueueDisc("ns3::PrioQueueDisc",
                                            "Priomap", StringValue(prioMap));
          TrafficControlHelper::ClassIdList cls =
              tch.AddQueueDiscClasses(h, 3, "ns3::QueueDiscClass");
          tch.AddChildQueueDiscs(h, cls, "ns3::FifoQueueDisc",
                                 "MaxSize", StringValue(qdiscSize));
          tch.Install(p.dev);

          gcl.push_back({p.role, {}});
        }
      else // fifo
        {
          // No differentiation whatsoever. Control queues behind whatever
          // consensus happens to have sent first.
          TrafficControlHelper tch;
          tch.SetRootQueueDisc("ns3::FifoQueueDisc",
                               "MaxSize", StringValue(qdiscSize));
          tch.Install(p.dev);

          gcl.push_back({p.role, {}});
        }
    }

  // --- Addressing ---------------------------------------------------------
  Ipv4AddressHelper address;
  uint32_t subnet = 1;
  auto assign = [&](NetDeviceContainer& d) {
    std::ostringstream base;
    base << "10.1." << subnet++ << ".0";
    address.SetBase(base.str().c_str(), "255.255.255.0");
    return address.Assign(d);
  };

  for (auto& dc : trunkDevs) assign(dc);
  Ipv4InterfaceContainer plcIf = assign(plcDev);
  Ipv4InterfaceContainer ioIf  = assign(ioDev);

  std::vector<Ipv4Address> valAddrs;
  for (auto& dc : valDevs) valAddrs.push_back(assign(dc).GetAddress(0));
  for (auto& dc : injDevs) assign(dc);

  Ipv4GlobalRoutingHelper::PopulateRoutingTables();

  // --- Packet capture ------------------------------------------------------
  PcapTapSet taps;
  if (!pcapSel.empty())
    {
      taps.Configure(tapMode, pcapSnapLen, pcapNanosec, pcapStart, pcapStop,
                     uint64_t(pcapMaxMB) * 1024 * 1024);
      for (const auto& p : ports)
        if (pcapSel.count(p.category)) taps.Add(p.dev, pcapPrefix, p.role);

      NS_ABORT_MSG_IF(taps.Empty(),
                      "--pcapPoints selected no ports; check the spelling");

      // The gate schedule is what the capture is evidence about, so it ships
      // with it. Times are offsets within one cycle on that port. The two
      // ungated baselines have no schedule, so the file would be empty and is
      // skipped rather than written as a misleading zero-row CSV.
      if (gated)
      {
      // gcl is parallel to ports: one entry per shaped egress port, same order.
      std::ofstream g(pcapPrefix + "-gcl.csv");
      g << "port,hop,window_index,open_class,start_ns,end_ns,duration_ns\n";
      for (size_t i = 0; i < ports.size(); ++i)
        {
          if (!pcapSel.count(ports[i].category)) continue;
          int64_t t = 0;
          uint32_t k = 0;
          for (const auto& w : gcl[i].second)
            {
              if (w.first <= 0) continue;
              g << ports[i].role << "," << ports[i].hop << "," << k++ << ","
                << OpenClassOf(w.second) << "," << t << "," << (t + w.first)
                << "," << w.first << "\n";
              t += w.first;
            }
        }
      }
    }

  // --- Control loop: PLC -> IO, isochronous, class 6 ----------------------
  uint16_t ctrlPort = 5000;

  Ptr<ControlSinkApp> sinkApp = CreateObject<ControlSinkApp>();
  sinkApp->Setup(ctrlPort, ctrlDeadline, warmup, stopAt - cooldown);
  if (advBits != ADV_NONE) sinkApp->SetAttackWindow(attackStart, attackStop);
  io.Get(0)->AddApplication(sinkApp);
  sinkApp->SetStartTime(Seconds(0));
  sinkApp->SetStopTime(stopAt);

  Ptr<ControlSourceApp> srcApp = CreateObject<ControlSourceApp>();
  srcApp->Setup(ioIf.GetAddress(0), ctrlPort, ctrlPeriod, ctrlPayload,
                static_cast<uint8_t>(ctrlTos), ctrlBurst);
  plc.Get(0)->AddApplication(srcApp);
  srcApp->SetStartTime(Seconds(0.1));
  srcApp->SetStopTime(stopAt);

  // --- Consensus committee, class 4 ---------------------------------------
  // Random start phase of the consensus rounds, relative to the gate cycle.
  Time roundPhase = Time(0);
  if (randomRoundPhase)
    {
      Ptr<UniformRandomVariable> ph = CreateObject<UniformRandomVariable>();
      ph->SetStream(1003);
      roundPhase = NanoSeconds(ph->GetInteger(0, cycle.GetNanoSeconds() - 1));
    }
  std::vector<Ptr<ConsensusApp>> consensusApps;
  // The oracle observes commits and views from outside; it sends nothing.
  Ptr<ConsensusOracle> oracle = fullModel ? Create<ConsensusOracle>() : nullptr;
  std::set<uint32_t> byzantine =
      IsValidatorAttack(advBits) ? SelectByzantine(byzSelect, nValidators, nByzantine)
                                 : std::set<uint32_t>();
  for (uint32_t i = 0; i < nValidators; ++i)
    {
      Ptr<ConsensusApp> app = CreateObject<ConsensusApp>();
      app->Setup(valAddrs, i, 7000, consensusInterval, consensusMsgSize, verifyDelay, consensusInBe);
      if (fullModel)
        {
          app->SetFullModel(viewChange, viewTimeout, viewBackoff, maxViewChanges,
                            viewChangeSize, newViewSize);
          app->SetReproposeWindow(reproposeWindow);
          app->SetOracle(oracle);
          if (byzantine.count(i))
            app->SetAdversary(advBits & ~ADV_INJECT, attackStart, attackStop, floodFactor,
                              attackDelay);
        }
      validators.Get(i)->AddApplication(app);
      app->SetStartTime(Seconds(0.2) + roundPhase);
      app->SetStopTime(stopAt);
      consensusApps.push_back(app);
    }

  // --- Injectors: compromised end stations, no consensus role -------------
  std::vector<Ptr<InjectorApp>> injApps;
  Ptr<CountingSinkApp> injSink;
  if (nInjectors > 0)
    {
      const uint16_t injPort = 5001;
      injSink = CreateObject<CountingSinkApp>();
      injSink->Setup(injPort);
      io.Get(0)->AddApplication(injSink);
      injSink->SetStartTime(Seconds(0));
      injSink->SetStopTime(stopAt);
      for (uint32_t i = 0; i < nInjectors; ++i)
        {
          Ptr<InjectorApp> a = CreateObject<InjectorApp>();
          a->Setup(ioIf.GetAddress(0), injPort, injectTos, injectFrame, injectBurst,
                   injectInterval, attackStart, attackStop);
          injectors.Get(i)->AddApplication(a);
          a->SetStartTime(Seconds(0.1));
          a->SetStopTime(stopAt);
          injApps.push_back(a);
        }
    }

  // --- Measurement --------------------------------------------------------
  FlowMonitorHelper fmh;
  Ptr<FlowMonitor> monitor = fmh.InstallAll();

  Simulator::Stop(stopAt);
  Simulator::Run();

  monitor->CheckForLostPackets();
  monitor->SerializeToXmlFile("iiot-consensus-tsn.flowmon", true, true);

  if (!taps.Empty())
    {
      taps.CloseAll();

      std::ostringstream l1, l2, l3, l4;
      l1 << "link " << linkRate << ", cycle " << cycle.GetMicroSeconds()
         << " us, ctrlFrac " << ctrlFrac << ", consFrac " << consFrac
         << ", consSlices " << consSlices;
      l2 << "nSwitches " << nSwitches << ", nValidators " << nValidators
         << ", consensusMsgSize " << consensusMsgSize << " B"
         << ", consensusInterval " << consensusInterval.GetMicroSeconds() << " us";
      l3 << "shaper " << shaper << ", perHopOffset "
         << perHopOffset.GetNanoSeconds() << " ns, run " << runId;
      l4 << "ctrl UDP port " << ctrlPort << " (ToS 0x10, class " << CLASS_CONTROL
         << "); consensus UDP port 7000 (ToS "
         << (consensusInBe ? "0x00" : "0x18") << ", class "
         << (consensusInBe ? CLASS_BE : CLASS_CONSENSUS) << ")";

      taps.WriteManifest(pcapPrefix + "-manifest.csv",
                         {l1.str(), l2.str(), l3.str(), l4.str()});
    }

  // --- Report -------------------------------------------------------------
  const auto& st = sinkApp->GetStats();

  std::cout << "\n=== configuration ===\n"
            << "  link            " << linkRate << "\n"
            << "  cycle           " << cycle.GetMicroSeconds() << " us\n"
            << "  windows         ctrl " << ctrlWindow.GetMicroSeconds()
            << " us | cons " << consWindow.GetMicroSeconds()
            << " us | be " << beWindow.GetMicroSeconds() << " us\n"
            << "  ctrl frame      "
            << rate.CalculateBytesTxTime(ctrlPayload + FRAME_OVERHEAD).GetNanoSeconds()
            << " ns on the wire\n"
            << "  ctrl load       " << ctrlBurst << " frame(s) per period; window holds "
            << (ctrlWindow.GetNanoSeconds() /
                rate.CalculateBytesTxTime(ctrlPayload + FRAME_OVERHEAD).GetNanoSeconds())
            << " per cycle (strict fit; a backlogged source port gains one frame per "
               "device-queue slot)\n"
            << "  cons frame      "
            << rate.CalculateBytesTxTime(consensusMsgSize + FRAME_OVERHEAD)
                   .GetNanoSeconds()
            << " ns on the wire\n"
            << "  cons slices     " << consSlices << " per cycle\n"
            << "  cons frames/slice  "
            << (consSlice.GetNanoSeconds()
                / std::max<int64_t>(1, rate.CalculateBytesTxTime(
                      consensusMsgSize + FRAME_OVERHEAD).GetNanoSeconds()))
            << "  (whole frames only)\n"
            << "  shaper          " << shaper
            << (gated ? "  (time-aware gates)"
                      : shaper == "prio"
                          ? "  (strict priority, NO gates -- cycle/frac/"
                            "perHopOffset inactive)"
                          : "  (single FIFO, NO classes -- cycle/frac/"
                            "perHopOffset inactive)")
            << "\n"
            << "  perHopOffset    " << perHopOffset.GetNanoSeconds()
            << " ns  (" << (perHopOffset == Time(0)
                            ? "naive: all gates simultaneous"
                            : "phase aligned along control path") << ")\n"
            << "  hops PLC->IO    " << (nSwitches + 1) << "\n"
            << "  measured over   [" << warmup.GetSeconds() << " s, "
            << (stopAt - cooldown).GetSeconds() << " s]\n"
            << "  rng run         " << runId << "\n"
            << "  randomness      offsetJitter " << offsetJitter.GetNanoSeconds()
            << " ns, round phase " << (randomRoundPhase ? "random" : "fixed")
            << ", validator placement " << (randomPlacement ? "random" : "round robin")
            << "\n";

  std::cout << "\n=== control loop (class " << CLASS_CONTROL << ") ===\n"
            << "  sent      " << srcApp->GetSent() << "\n"
            << "  received  " << st.received << "  (post-warmup)\n"
            << "  deadline  " << ctrlDeadline.GetMicroSeconds() << " us\n"
            << "  missed    " << st.missed
            << "  ratio " << sinkApp->MissRatio() << "\n"
            << "  min       " << (st.received ? st.minNs / 1000.0 : 0) << " us\n"
            << "  mean      " << sinkApp->MeanUs() << " us\n"
            << "  p99       " << sinkApp->PercentileUs(0.99) << " us\n"
            << "  max       " << st.maxNs / 1000.0 << " us\n";

  uint32_t pp = 0, pr = 0, cm = 0, done = 0, msgs = 0;
  int64_t latSum = 0, latMax = 0;
  std::vector<int64_t> allLat;
  for (auto& a : consensusApps)
    {
      pp   += a->GetSentPrePrepare();
      pr   += a->GetSentPrepare();
      cm   += a->GetSentCommit();
      done += a->GetCommitted();
      msgs += a->GetMsgsSent();
      latSum += a->GetLatSum();
      latMax  = std::max(latMax, a->GetLatMax());
      for (int64_t v : a->GetLatSamples()) allLat.push_back(v);
    }
  std::sort(allLat.begin(), allLat.end());
  auto latPct = [&](double q) -> double {
    if (allLat.empty()) return 0.0;
    return allLat[static_cast<size_t>(q * (allLat.size() - 1))] / 1000.0;
  };

  uint32_t rounds = consensusApps.empty() ? 0 : consensusApps[0]->GetRoundsOpened();
  uint32_t n = nValidators;
  uint32_t expectedPerRound = (n - 1) + (n - 1) * (n - 1) + n * (n - 1);

  std::cout << "\n=== consensus (class " << CLASS_CONSENSUS << ", n=" << n << ") ===\n"
            << "  rounds started      " << rounds << "\n"
            << "  broadcasts  pre-prepare " << pp
            << "  prepare " << pr << "  commit " << cm << "\n"
            << "  messages sent       " << msgs << "\n"
            << "  msgs/round actual   "
            << (rounds ? double(msgs) / rounds : 0) << "\n"
            << "  msgs/round expected " << expectedPerRound << "\n"
            << "  rounds committed    " << done
            << "  (expect ~" << rounds * n << " node-rounds)\n"
            << "  commit latency mean "
            << (allLat.empty() ? 0.0 : double(latSum) / allLat.size() / 1000.0)
            << " us\n"
            << "  commit latency p50  " << latPct(0.50) << " us\n"
            << "  commit latency p99  " << latPct(0.99) << " us\n"
            << "  commit latency max  " << latMax / 1000.0 << " us\n";

  if (fullModel || pbftStats)
    {
      uint32_t vcs = 0, nvs = 0, over = 0, entered = 0, viewMax = 0, aband = 0;
      for (auto& a : consensusApps)
        {
          vcs += a->GetSentViewChange();
          nvs += a->GetSentNewView();
          over += a->GetOvertaken();
          aband += a->GetAbandoned();
          entered += a->GetViewsEntered();
          viewMax = std::max(viewMax, a->GetView());
        }
      std::cout << "\n=== pbft model ===\n"
                << "  model               " << pbftModel;
      if (fullModel)
        std::cout << "  (view change " << (viewChange ? "on" : "off")
                  << ", timeout " << viewTimeout.GetMicroSeconds() << " us, backoff "
                  << viewBackoff << ", VIEW-CHANGE "
                  << (viewChangeSize ? viewChangeSize : consensusMsgSize) << " B, NEW-VIEW "
                  << (newViewSize ? newViewSize : consensusMsgSize) << " B)";
      std::cout << "\n"
                << "  broadcasts  view-change " << vcs << "  new-view " << nvs << "\n"
                << "  views entered       " << entered << "  (highest view " << viewMax << ")\n"
                << "  prepares before pre-prepare  " << over
                << "  node-rounds with PREPAREs from 2f senders before the PRE-PREPARE\n";
      // Printed only when set, so default full-model logs are unchanged.
      if (fullModel && reproposeWindow > 0)
        std::cout << "  re-propose window   " << reproposeWindow << " rounds  ("
                  << aband << " node-rounds abandoned at view changes)\n";
    }

  if (advBits != ADV_NONE)
    {
      uint32_t mis = 0, fl = 0, eq = 0, cu = 0;
      for (auto& a : consensusApps)
        {
          mis += a->GetMismarked();
          fl += a->GetFloodExtra();
          eq += a->GetEquivocations();
          cu += a->GetCaughtUp();
        }
      std::ostringstream who;
      for (uint32_t b : byzantine) who << (who.tellp() ? "," : "") << b;
      std::cout << "\n=== adversary ===\n"
                << "  attack              " << AttackName(advBits) << "\n"
                << "  byzantine           " << byzantine.size() << " of " << n << " (f = "
                << (n ? (n - 1) / 3 : 0) << ")  select " << byzSelect << "  ids "
                << (byzantine.empty() ? "-" : who.str()) << "\n"
                << "  window              [" << attackStart.GetSeconds() << " s, "
                << attackStop.GetSeconds() << " s)\n"
                << "  mismarked frames    " << mis << "\n"
                << "  flood extra frames  " << fl << "  (factor " << floodFactor << ")\n"
                << "  equivocations       " << eq << "\n"
                << "  caught up to a view " << cu << "\n";
      if (nInjectors > 0)
        {
          uint64_t sent = 0;
          for (auto& a : injApps) sent += a->GetFramesSent();
          std::cout << "  injectors           " << nInjectors << "  class " << injectClass
                    << "  " << injectFrame << " B x " << injectBurst << " every "
                    << injectInterval.GetMicroSeconds() << " us\n"
                    << "  injected frames     sent " << sent << "  arrived "
                    << injSink->GetFrames() << "\n";
        }
      if (oracle)
        {
          uint32_t q = 2 * ((n - 1) / 3) + 1;
          std::cout << "  rounds opened       " << oracle->RoundsOpened() << "\n"
                    << "  rounds with commit  " << oracle->RoundsWithAnyCommit()
                    << "  (any trusted node)\n"
                    << "  rounds quorum-done  " << oracle->QuorumComplete(q)
                    << "  (2f+1 trusted nodes, same digest; crash-only nodes are trusted)\n"
                    << "  safety violations   " << oracle->SafetyViolations() << "\n"
                    << (reproposeWindow > 0
                            ? "  rounds abandoned    " + std::to_string(oracle->RoundsAbandoned(q)) +
                                  "  (outside the re-propose window, never quorum-done)\n"
                            : std::string())
                    << "  longest stall       "
                    << oracle->MaxStallNs((stopAt - cooldown).GetNanoSeconds()) / 1000.0
                    << " us\n";
          if (!adversaryCsv.empty())
            {
              std::ofstream f(adversaryCsv);
              oracle->DumpCsv(f, q);
            }
        }
      const auto& d = sinkApp->GetDuring();
      const auto& o = sinkApp->GetOutside();
      std::cout << "  control during      received " << d.received << "  missed " << d.missed
                << "  p99 " << ControlSinkApp::PercentileUsOf(d, 0.99) << " us  max "
                << d.maxNs / 1000.0 << " us\n"
                << "  control outside     received " << o.received << "  missed " << o.missed
                << "  p99 " << ControlSinkApp::PercentileUsOf(o, 0.99) << " us  max "
                << o.maxNs / 1000.0 << " us\n";
    }

  taps.Report(std::cout);
  if (!taps.Empty())
    {
      std::cout << "  manifest        " << pcapPrefix << "-manifest.csv\n"
                << "  gate schedule   " << pcapPrefix << "-gcl.csv\n";
    }

  if (!consensusCsv.empty() && !allLat.empty())
    {
      std::ofstream f(consensusCsv);
      f << "commit_latency_ns\n";
      for (int64_t v : allLat) f << v << "\n";
    }

  if (!latencyCsv.empty()) sinkApp->DumpCsv(latencyCsv);

  Simulator::Destroy();
  return 0;
}
