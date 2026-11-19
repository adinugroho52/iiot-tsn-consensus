#!/usr/bin/env python3
"""
round_check.py -- for each run, when is the last frame of each consensus round delivered?

    tools/round_check.py PCAPDIR RUN=INTERVAL [RUN=INTERVAL ...]

This is the receive-capture check behind the sufficiency argument for the consensus-window
counting rule (README, rule 4): if every round of a configuration has left the network
before the next round starts, rounds do not overlap and the rule is proved for it.
tools/round_check.sh runs it over every feasible TAS configuration of the paper.

PCAPDIR holds <run>-val<i>-eg-rx.pcap: receive captures (PhyRxEnd, nanosecond
timestamps, PPP framing) on every validator's own port, as written by
iiot-consensus-tsn with --pcapPoints=validators --pcapMode=rx. INTERVAL is the
round interval of that run, such as 10ms.

Every consensus frame (UDP port 7000) ends at a validator, so the last receive
record of a round is the moment its last frame leaves the network. A message
larger than the link MTU arrives as IP fragments; they are matched by source,
destination and IP ID, and the message counts as delivered when its last fragment
arrives. The first fragment's payload carries the round number at offset 4 and
the round's start time (ns) at offset 16.

For each run it prints the rounds checked, the latest delivery after round start
("tail"), the slack against the interval, how many rounds deliver a frame after
the next round has started, and how many distinct tails there are (1 means every
round is delivered on exactly the same schedule). Rounds that started within one
interval of either end of the capture window are left out, since part of them
may lie outside it.
"""
import glob
import os
import struct
import sys

PPP = 2


def frames(path):
    """(time, message key, fragment offset, header or None) for each UDP frame.

    A message's fragments share its source and destination addresses and IP ID
    (ns-3 numbers IDs per source-destination pair). Only the first fragment
    (offset 0) carries the UDP and application headers; a later fragment's bytes
    are never read as a header.
    """
    data = open(path, 'rb').read()
    if len(data) < 24:
        return
    magic = struct.unpack('<I', data[:4])[0]
    if magic != 0xA1B23C4D:
        sys.exit('%s: not a little-endian nanosecond pcap' % path)
    off = 24
    while off + 16 <= len(data):
        sec, nsec, incl, _ = struct.unpack('<IIII', data[off:off + 16])
        pkt = data[off + 16:off + 16 + incl]
        off += 16 + incl
        ip = pkt[PPP:]
        if len(ip) < 20 or ip[9] != 17:
            continue
        ihl = (ip[0] & 0x0F) * 4
        key = (ip[12:16], ip[16:20], struct.unpack('>H', ip[4:6])[0])
        frag_off = (struct.unpack('>H', ip[6:8])[0] & 0x1FFF) * 8
        hdr = None
        if frag_off == 0:
            udp = ip[ihl:]
            if len(udp) < 8 or struct.unpack('>H', udp[2:4])[0] != 7000:
                continue
            app = udp[8:]
            if len(app) < 24:
                continue
            hdr = (struct.unpack('<I', app[4:8])[0], struct.unpack('<q', app[16:24])[0])
        yield sec * 10**9 + nsec, key, frag_off, hdr


def parse_interval(s):
    s = s.strip()
    for unit, mult in (('ms', 10**6), ('us', 10**3), ('ns', 1), ('s', 10**9)):
        if s.endswith(unit):
            return int(float(s[:-len(unit)]) * mult)
    sys.exit('bad interval %s' % s)


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    pdir = argv[0]
    print('%-40s %7s %12s %10s %12s %10s %9s' % ('run', 'rounds', 'tail max us', 'T_con us',
                                                  'slack us', 'late rnds', 'tails'))
    for spec in argv[1:]:
        name, iv = spec.split('=', 1)
        T = parse_interval(iv)
        files = sorted(glob.glob(os.path.join(pdir, '%s-val*-eg-rx.pcap' % name)))
        if not files:
            print('%-40s no captures' % name)
            continue
        hdrs, tlast, seen_first = {}, {}, {}
        first_rx = last_rx = None
        for f in files:
            for t, key, fo, hdr in frames(f):
                if hdr is not None:
                    seen_first[key] = seen_first.get(key, 0) + 1
                    hdrs[key] = hdr
                tlast[key] = max(tlast.get(key, 0), t)
                first_rx = t if first_rx is None else min(first_rx, t)
                last_rx = t if last_rx is None else max(last_rx, t)
        dup = sum(1 for n in seen_first.values() if n > 1)
        if dup:
            print('%-40s warning: %d messages seen more than once' % (name, dup))
        last, start = {}, {}
        for key, (rnd, s0) in hdrs.items():
            last[rnd] = max(last.get(rnd, 0), tlast[key])
            start[rnd] = s0
        keep = [r for r in last if start[r] >= first_rx + T and start[r] + 2 * T <= last_rx]
        if not keep:
            print('%-40s no complete rounds' % name)
            continue
        tails = [last[r] - start[r] for r in keep]
        tmax = max(tails)
        late = sum(1 for x in tails if x > T)
        print('%-40s %7d %12.3f %10.0f %12.3f %10d %9d' % (
            name, len(keep), tmax / 1000, T / 1000, (T - tmax) / 1000, late, len(set(tails))))
    print('\n"late rnds" 0: every round has left the network before the next one starts, so rounds')
    print('do not overlap. Otherwise rounds overlap and the counting rule is observed, not proved.')


if __name__ == '__main__':
    main(sys.argv[1:])
