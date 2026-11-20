/*
 * adversary.h -- threat model for iiot-consensus-tsn.
 *
 * Two adversaries live here, and they are deliberately different kinds of
 * thing:
 *
 *   1. THE PROTOCOL ADVERSARY. A subset of the validators is Byzantine. Its
 *      behaviour is a bitmask (AdvBit) consulted by ConsensusApp at every
 *      point where an honest node would have followed the protocol. It sends
 *      only consensus-port traffic, and it is *authorised* -- it holds valid
 *      credentials and the network has no reason to drop its frames. The
 *      validator behaviours need --pbftModel=full: the v1 model has no
 *      digests, no view change and a fixed primary, so a fault there could
 *      only stall it, never be recovered from.
 *
 *   2. THE NETWORK ADVERSARY. A compromised end station (InjectorApp) that
 *      does not run consensus at all and simply emits frames. It models a
 *      field device that an attacker owns, and it is the control for the
 *      question "is the damage caused by a Byzantine validator anything more
 *      than the damage caused by the same number of bytes from anywhere?"
 *
 * WHY BOTH ARE NEEDED FOR A TSN CO-TENANCY STUDY
 *
 * In a classical BFT evaluation the interesting adversarial outcome is a
 * safety or liveness failure of the ledger. Here there is a second victim: the
 * control loop sharing the wire. A Byzantine validator that merely *floods*
 * costs the ledger nothing -- honest nodes still reach quorum -- while
 * spending the consensus gate window down to nothing. A Byzantine validator
 * that *equivocates* costs almost no extra bytes in the attack itself, but
 * detonates an O(n^2) VIEW-CHANGE burst as a side effect. The byte cost and
 * the protocol cost are decoupled, and either can be the one that misses a
 * control deadline.
 *
 * THE TSN-SPECIFIC ATTACK
 *
 * ADV_MISMARK has no analogue in the wired-internet BFT literature. An
 * authorised validator sets the IP ToS byte of its consensus frames to the
 * control codepoint, so its traffic is classified into the control traffic
 * class and released through the *control* gate window rather than the
 * consensus one. Nothing in 802.1Qbv authenticates the class of a frame: the
 * shaper honours whatever the sender claimed. This turns a bandwidth attack
 * into a deadline attack, and it is invisible to any measurement that looks
 * only at aggregate load.
 *
 * WHAT IS NOT MODELLED
 *
 * No cryptography, so no forged signatures, no invalid MACs, and no cost
 * asymmetry between verifying a good and a bad signature. Digests are opaque
 * 32-bit tokens standing in for the hash of a batched request; equivocation
 * means "emit two different tokens", not "emit two conflicting request sets".
 * A real deployment would also have 802.1X port authentication and stream
 * identification (802.1CB), either of which changes the mismark story; the
 * point of modelling it unguarded is to quantify what those defences are
 * worth.
 */

#ifndef ADVERSARY_H
#define ADVERSARY_H

#include "ns3/application.h"
#include "ns3/data-rate.h"
#include "ns3/inet-socket-address.h"
#include "ns3/ipv4-address.h"
#include "ns3/nstime.h"
#include "ns3/packet.h"
#include "ns3/simple-ref-count.h"
#include "ns3/simulator.h"
#include "ns3/socket.h"
#include "ns3/udp-socket-factory.h"

#include <algorithm>
#include <cstdint>
#include <map>
#include <ostream>
#include <set>
#include <sstream>
#include <string>
#include <vector>

namespace ns3 {

// ---------------------------------------------------------------------------
// Behaviour bitmask.
//
// These compose. --attack=equivocate,mismark gives a primary that splits the
// committee AND launders the resulting VIEW-CHANGE burst through the control
// gate, which is the worst cell in the matrix and the one worth a figure.
// ---------------------------------------------------------------------------
enum AdvBit : uint32_t
{
    ADV_NONE = 0,
    ADV_CRASH = 1u << 0,      //!< stops sending and processing at attackStart
    ADV_WITHHOLD = 1u << 1,   //!< participates, but never emits COMMIT
    ADV_EQUIVOCATE = 1u << 2, //!< as primary, splits the committee across two digests
    ADV_FLOOD = 1u << 3,      //!< emits floodFactor copies of every broadcast
    ADV_DELAY = 1u << 4,      //!< adds attackDelay before reacting to anything
    ADV_MISMARK = 1u << 5,    //!< emits consensus frames at the CONTROL codepoint
    ADV_INJECT = 1u << 6,     //!< enables the non-validator InjectorApp nodes
};

/**
 * Parse a comma-separated attack list. Returns false and sets `bad` to the
 * offending token on the first unrecognised name, so the caller can abort with
 * a message naming what was misspelled rather than silently running a
 * no-attack simulation and reporting it as an attack result.
 */
inline bool
ParseAttack(const std::string& spec, uint32_t& out, std::string& bad)
{
    out = ADV_NONE;
    std::stringstream ss(spec);
    std::string tok;
    while (std::getline(ss, tok, ','))
    {
        tok.erase(0, tok.find_first_not_of(" \t"));
        tok.erase(tok.find_last_not_of(" \t") + 1);
        if (tok.empty() || tok == "none")
        {
            continue;
        }
        else if (tok == "crash")
        {
            out |= ADV_CRASH;
        }
        else if (tok == "withhold")
        {
            out |= ADV_WITHHOLD;
        }
        else if (tok == "equivocate")
        {
            out |= ADV_EQUIVOCATE;
        }
        else if (tok == "flood")
        {
            out |= ADV_FLOOD;
        }
        else if (tok == "delay")
        {
            out |= ADV_DELAY;
        }
        else if (tok == "mismark")
        {
            out |= ADV_MISMARK;
        }
        else if (tok == "inject")
        {
            out |= ADV_INJECT;
        }
        else
        {
            bad = tok;
            return false;
        }
    }
    return true;
}

/** Human-readable rendering of a bitmask, for the report and the manifest. */
inline std::string
AttackName(uint32_t m)
{
    if (m == ADV_NONE)
    {
        return "none";
    }
    std::string s;
    auto add = [&](uint32_t bit, const char* name) {
        if (m & bit)
        {
            if (!s.empty())
            {
                s += "+";
            }
            s += name;
        }
    };
    add(ADV_CRASH, "crash");
    add(ADV_WITHHOLD, "withhold");
    add(ADV_EQUIVOCATE, "equivocate");
    add(ADV_FLOOD, "flood");
    add(ADV_DELAY, "delay");
    add(ADV_MISMARK, "mismark");
    add(ADV_INJECT, "inject");
    return s;
}

/** True if the mask contains anything a *validator* acts on. */
inline bool
IsValidatorAttack(uint32_t m)
{
    return (m & (ADV_CRASH | ADV_WITHHOLD | ADV_EQUIVOCATE | ADV_FLOOD | ADV_DELAY |
                 ADV_MISMARK)) != 0;
}

// ---------------------------------------------------------------------------
// Which validators are Byzantine.
//
// This is not cosmetic. Validator i attaches to switch (i % nSwitches), so the
// selection policy decides whether the faulty nodes' traffic converges on one
// trunk link or spreads across the backbone -- and the control path runs along
// that same backbone.
//
//   primary : 0, 1, 2, ...   the initial primary is faulty, so a
//                            liveness attack triggers a view change
//   spread  : evenly spaced, so faulty nodes hang off distinct switches
//   last    : n-1, n-2, ...  the primary stays honest, isolating the cost of
//                            faulty *backups* from the cost of view change
// ---------------------------------------------------------------------------
inline std::set<uint32_t>
SelectByzantine(const std::string& policy, uint32_t n, uint32_t b)
{
    std::set<uint32_t> s;
    if (b == 0 || n == 0)
    {
        return s;
    }
    b = std::min(b, n);
    if (policy == "last")
    {
        for (uint32_t i = 0; i < b; ++i)
        {
            s.insert(n - 1 - i);
        }
    }
    else if (policy == "spread")
    {
        for (uint32_t i = 0; i < b; ++i)
        {
            s.insert((i * n) / b);
        }
        // (i*n)/b can collide for awkward ratios; top up deterministically
        // from the low end rather than silently returning fewer faulty nodes
        // than the run was configured for.
        for (uint32_t i = 0; s.size() < b && i < n; ++i)
        {
            s.insert(i);
        }
    }
    else // "primary"
    {
        for (uint32_t i = 0; i < b; ++i)
        {
            s.insert(i);
        }
    }
    return s;
}

// ---------------------------------------------------------------------------
// ConsensusOracle -- the measurement instrument, not a protocol participant.
//
// It has global knowledge, sends no packets, occupies no node and consumes no
// bandwidth. Everything it reports would in reality require an out-of-band
// auditor; it exists so that safety violations are *detected* rather than
// inferred from a latency plot.
//
// Only honest nodes register commits. A Byzantine node committing to whatever
// it likes is not a safety violation -- the property is agreement among the
// correct nodes.
// ---------------------------------------------------------------------------
class ConsensusOracle : public SimpleRefCount<ConsensusOracle>
{
  public:
    /** Called by the primary (honest or not) when it opens a round. */
    void NoteRoundOpened(uint32_t round, int64_t nowNs)
    {
        Round& r = m_rounds[round];
        if (r.openedNs < 0)
        {
            r.openedNs = nowNs;
        }
    }

    /** Called by an HONEST node when it collects a commit certificate. */
    void NoteCommit(uint32_t round, uint32_t node, uint32_t digest, int64_t nowNs)
    {
        Round& r = m_rounds[round];
        if (r.firstCommitNs < 0)
        {
            r.firstCommitNs = nowNs;
        }
        r.lastCommitNs = nowNs;
        r.byDigest[digest].insert(node);
        // Count each violating round once. (Counting every later commit, as an
        // earlier version did, scaled the figure with committee size.)
        if (r.byDigest.size() > 1 && !r.violated)
        {
            r.violated = true;
            m_safetyViolations++;
        }
    }

    /** Called by a trusted node that abandons an uncommitted round at a view change. */
    void NoteAbandoned(uint32_t round)
    {
        // Only rounds already known: an entry made here would show up in the CSV.
        auto it = m_rounds.find(round);
        if (it != m_rounds.end())
        {
            it->second.abandoned = true;
        }
    }

    /** Opened rounds that some trusted node abandoned and that never reached a quorum. */
    uint32_t RoundsAbandoned(uint32_t quorum) const
    {
        uint32_t k = 0;
        for (const auto& kv : m_rounds)
        {
            const Round& r = kv.second;
            if (r.openedNs < 0 || !r.abandoned)
            {
                continue;
            }
            bool complete = false;
            for (const auto& d : r.byDigest)
            {
                complete = complete || d.second.size() >= quorum;
            }
            k += complete ? 0 : 1;
        }
        return k;
    }

    void NoteViewChange(uint32_t /*node*/, uint32_t toView)
    {
        m_viewChanges++;
        m_maxView = std::max(m_maxView, toView);
    }

    /**
     * A round is "quorum-complete" when at least 2f+1 honest nodes hold a
     * certificate for the SAME digest. Counting nodes that merely committed
     * something overstates progress under equivocation.
     */
    uint32_t QuorumComplete(uint32_t quorum) const
    {
        uint32_t k = 0;
        for (const auto& kv : m_rounds)
        {
            for (const auto& d : kv.second.byDigest)
            {
                if (d.second.size() >= quorum)
                {
                    k++;
                    break;
                }
            }
        }
        return k;
    }

    uint32_t RoundsOpened() const
    {
        return static_cast<uint32_t>(m_rounds.size());
    }

    uint32_t RoundsWithAnyCommit() const
    {
        uint32_t k = 0;
        for (const auto& kv : m_rounds)
        {
            if (kv.second.firstCommitNs >= 0)
            {
                k++;
            }
        }
        return k;
    }

    /** Rounds in which correct nodes committed different digests. */
    uint32_t SafetyViolations() const
    {
        return m_safetyViolations;
    }

    uint32_t ViewChanges() const
    {
        return m_viewChanges;
    }

    uint32_t MaxView() const
    {
        return m_maxView;
    }

    /**
     * Longest interval, in ns, during which no round reached a first honest
     * commit. This is the ledger-side cost of the attack, and it is the number
     * that a liveness attack moves while message counts stay flat.
     *
     * Rounds that never committed at all are charged up to `endNs`, otherwise
     * a total stall at the end of the run would score zero.
     */
    int64_t MaxStallNs(int64_t endNs) const
    {
        int64_t worst = 0;
        int64_t prev = -1;
        for (const auto& kv : m_rounds)
        {
            const Round& r = kv.second;
            if (r.firstCommitNs < 0)
            {
                continue;
            }
            if (prev >= 0)
            {
                worst = std::max(worst, r.firstCommitNs - prev);
            }
            prev = r.firstCommitNs;
        }
        if (prev >= 0 && endNs > prev)
        {
            worst = std::max(worst, endNs - prev);
        }
        return worst;
    }

    /** Per-round detail, for the adversary CSV. */
    void DumpCsv(std::ostream& os, uint32_t quorum) const
    {
        os << "round,opened_ns,first_commit_ns,last_commit_ns,distinct_digests,"
              "committers,quorum_complete\n";
        for (const auto& kv : m_rounds)
        {
            const Round& r = kv.second;
            size_t committers = 0;
            bool complete = false;
            for (const auto& d : r.byDigest)
            {
                committers += d.second.size();
                if (d.second.size() >= quorum)
                {
                    complete = true;
                }
            }
            os << kv.first << "," << r.openedNs << "," << r.firstCommitNs << ","
               << r.lastCommitNs << "," << r.byDigest.size() << "," << committers << ","
               << (complete ? 1 : 0) << "\n";
        }
    }

  private:
    struct Round
    {
        int64_t openedNs{-1};
        int64_t firstCommitNs{-1};
        int64_t lastCommitNs{-1};
        bool violated{false};
        bool abandoned{false};
        std::map<uint32_t, std::set<uint32_t>> byDigest;
    };

    std::map<uint32_t, Round> m_rounds;
    uint32_t m_safetyViolations{0};
    uint32_t m_viewChanges{0};
    uint32_t m_maxView{0};
};

// ---------------------------------------------------------------------------
// InjectorApp -- compromised end station, no consensus role.
//
// Emits `burst` frames every `interval` at a fixed ToS. Sizing is by explicit
// burst and interval rather than by a target DataRate because the *shape*
// matters more than the mean under a time-gated shaper: 100 Mbps delivered as
// one frame per microsecond and 100 Mbps delivered as a burst once per cycle
// are the same load and completely different attacks.
// ---------------------------------------------------------------------------
class InjectorApp : public Application
{
  public:
    static TypeId GetTypeId()
    {
        static TypeId tid = TypeId("InjectorApp")
                                .SetParent<Application>()
                                .AddConstructor<InjectorApp>();
        return tid;
    }

    void Setup(Ipv4Address dst,
               uint16_t port,
               uint8_t tos,
               uint32_t frameBytes,
               uint32_t burst,
               Time interval,
               Time start,
               Time stop)
    {
        m_dst = dst;
        m_port = port;
        m_tos = tos;
        m_bytes = std::max<uint32_t>(frameBytes, 16);
        m_burst = std::max<uint32_t>(burst, 1);
        m_interval = interval;
        m_windowStart = start;
        m_windowStop = stop;
    }

    uint32_t GetFramesSent() const
    {
        return m_frames;
    }

    uint64_t GetBytesSent() const
    {
        return m_byteCount;
    }

  private:
    void StartApplication() override
    {
        m_sock = Socket::CreateSocket(GetNode(), UdpSocketFactory::GetTypeId());
        m_sock->Bind();
        m_sock->SetIpTos(m_tos);
        m_sock->Connect(InetSocketAddress(m_dst, m_port));
        m_ev = Simulator::Schedule(std::max(m_windowStart - Simulator::Now(), Time(0)),
                                   &InjectorApp::Tick,
                                   this);
    }

    void StopApplication() override
    {
        m_ev.Cancel();
        if (m_sock)
        {
            m_sock->Close();
        }
    }

    void Tick()
    {
        Time now = Simulator::Now();
        if (now >= m_windowStop)
        {
            return;
        }
        for (uint32_t i = 0; i < m_burst; ++i)
        {
            Ptr<Packet> p = Create<Packet>(m_bytes);
            m_sock->Send(p);
            m_frames++;
            m_byteCount += m_bytes;
        }
        m_ev = Simulator::Schedule(m_interval, &InjectorApp::Tick, this);
    }

    Ptr<Socket> m_sock;
    Ipv4Address m_dst;
    uint16_t m_port{5001};
    uint8_t m_tos{0};
    uint32_t m_bytes{1024};
    uint32_t m_burst{1};
    Time m_interval;
    Time m_windowStart;
    Time m_windowStop{Time::Max()};
    uint32_t m_frames{0};
    uint64_t m_byteCount{0};
    EventId m_ev;
};

// ---------------------------------------------------------------------------
// CountingSinkApp -- absorbs injected traffic at the victim.
//
// Written out rather than using PacketSinkHelper for two reasons: an unbound
// port would generate ICMP unreachables that pollute the very links under
// measurement, and the count of frames that actually *arrived* is the
// difference between "the attack consumed backbone capacity" and "the attack
// was dropped at the first queue", which the sender-side count cannot tell you.
// ---------------------------------------------------------------------------
class CountingSinkApp : public Application
{
  public:
    static TypeId GetTypeId()
    {
        static TypeId tid = TypeId("CountingSinkApp")
                                .SetParent<Application>()
                                .AddConstructor<CountingSinkApp>();
        return tid;
    }

    void Setup(uint16_t port)
    {
        m_port = port;
    }

    uint32_t GetFrames() const
    {
        return m_frames;
    }

    uint64_t GetBytes() const
    {
        return m_byteCount;
    }

  private:
    void StartApplication() override
    {
        m_sock = Socket::CreateSocket(GetNode(), UdpSocketFactory::GetTypeId());
        m_sock->Bind(InetSocketAddress(Ipv4Address::GetAny(), m_port));
        m_sock->SetRecvCallback(MakeCallback(&CountingSinkApp::Rx, this));
    }

    void StopApplication() override
    {
        if (m_sock)
        {
            m_sock->Close();
        }
    }

    void Rx(Ptr<Socket> s)
    {
        Ptr<Packet> p;
        Address from;
        while ((p = s->RecvFrom(from)))
        {
            m_frames++;
            m_byteCount += p->GetSize();
        }
    }

    Ptr<Socket> m_sock;
    uint16_t m_port{5001};
    uint32_t m_frames{0};
    uint64_t m_byteCount{0};
};

NS_OBJECT_ENSURE_REGISTERED(InjectorApp);
NS_OBJECT_ENSURE_REGISTERED(CountingSinkApp);

} // namespace ns3
#endif // ADVERSARY_H
