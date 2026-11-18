#!/usr/bin/env python3
"""
compare_reference.py -- check experiment results against the reference results of the paper.

    tools/compare_reference.py check RESULTS REFERENCE [SET ...]
    tools/compare_reference.py make  RESULTS REFERENCE [SET ...]

RESULTS holds one folder per experiment set (e1, e2e3e4, ..., figs), each as written by
tools/sweep.sh: summary.csv, log/, csv/ and pcap/. A set may carry csv-sha256.txt in place
of csv/, as in the archive that tools/verify_reproducibility.sh packs.

REFERENCE (tools/reference/ in this repository) holds, per set:
  summary.csv   every column of every run except the wall-clock time
  sha256.txt    a SHA-256 checksum of every run log, per-frame CSV and capture file

The simulation is deterministic, so a correct build reproduces all of these exactly:
`check` reports each set as IDENTICAL, DIFFERS or MISSING and exits non-zero unless every
set it checks is identical. `make` writes a reference from a set of results.

With no SET arguments, every set in REFERENCE (check) or RESULTS (make) is used.
"""
import csv
import hashlib
import io
import os
import sys

DROP = ('wall_s',)          # varies from machine to machine


def sha(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''):
            h.update(block)
    return h.hexdigest()


def summary_rows(path):
    """summary.csv without the wall-clock column, as (header, {cell: row})."""
    with open(path, newline='') as f:
        rows = list(csv.reader(f))
    if not rows:
        return [], {}
    keep = [i for i, c in enumerate(rows[0]) if c not in DROP]
    head = [rows[0][i] for i in keep]
    return head, {r[0]: [r[i] for i in keep] for r in rows[1:] if r}


def file_sums(setdir):
    """{relative path: sha256} for log/, csv/ (or csv-sha256.txt) and pcap/."""
    out = {}
    for sub in ('log', 'csv', 'pcap'):
        d = os.path.join(setdir, sub)
        if os.path.isdir(d):
            for name in sorted(os.listdir(d)):
                p = os.path.join(d, name)
                if os.path.isfile(p):
                    out[f'{sub}/{name}'] = sha(p)
    listed = os.path.join(setdir, 'csv-sha256.txt')
    if not os.path.isdir(os.path.join(setdir, 'csv')) and os.path.isfile(listed):
        for line in open(listed):
            parts = line.split(None, 1)
            if len(parts) == 2:
                out['csv/' + parts[1].strip().lstrip('*')] = parts[0]
    return out


def make(results, reference, sets):
    for s in sets:
        src, dst = os.path.join(results, s), os.path.join(reference, s)
        os.makedirs(dst, exist_ok=True)
        sp = os.path.join(src, 'summary.csv')
        if os.path.isfile(sp):
            head, rows = summary_rows(sp)
            with open(os.path.join(dst, 'summary.csv'), 'w', newline='') as f:
                w = csv.writer(f, lineterminator='\n')
                w.writerow(head)
                for cell in sorted(rows):
                    w.writerow(rows[cell])
        sums = file_sums(src)
        with open(os.path.join(dst, 'sha256.txt'), 'w') as f:
            for rel in sorted(sums):
                f.write(f'{sums[rel]}  {rel}\n')
        print(f'{s:15s} {len(sums)} files')
    return 0


def check(results, reference, sets):
    bad = 0
    for s in sets:
        ref, new = os.path.join(reference, s), os.path.join(results, s)
        issues, n_runs = [], 0
        if not os.path.isdir(new):
            print(f'MISSING   {s}')
            bad += 1
            continue
        rp = os.path.join(ref, 'summary.csv')
        if os.path.isfile(rp):
            rhead, rrows = summary_rows(rp)
            np_ = os.path.join(new, 'summary.csv')
            nhead, nrows = summary_rows(np_) if os.path.isfile(np_) else ([], {})
            for cell, rrow in sorted(rrows.items()):
                if cell not in nrows:
                    issues.append(f'{cell}: not run')
                    continue
                n_runs += 1
                nrow = dict(zip(nhead, nrows[cell]))
                for col, val in zip(rhead, rrow):
                    if nrow.get(col) != val:
                        issues.append(f'{cell}: {col} {val} -> {nrow.get(col)}')
            issues += [f'{cell}: not in the reference' for cell in sorted(set(nrows) - set(rrows))]
        want = {}
        for line in open(os.path.join(ref, 'sha256.txt')):
            digest, rel = line.rstrip('\n').split('  ', 1)
            want[rel] = digest
        got = file_sums(new)
        for rel, digest in sorted(want.items()):
            if rel not in got:
                issues.append(f'{rel}: missing')
            elif got[rel] != digest:
                issues.append(f'{rel}: contents differ')
        verdict = 'IDENTICAL' if not issues else 'DIFFERS'
        bad += bool(issues)
        runs = f'{n_runs} runs, ' if os.path.isfile(rp) and rrows else ''
        print(f'{verdict:9s} {s:15s} {runs}{len(want)} files')
        for line in issues[:8]:
            print(f'          {line}')
        if len(issues) > 8:
            print(f'          ... {len(issues) - 8} more')
    return 1 if bad else 0


def main(argv):
    if len(argv) < 3 or argv[0] not in ('check', 'make'):
        sys.exit(__doc__)
    mode, results, reference, sets = argv[0], argv[1], argv[2], argv[3:]
    if not sets:
        base = reference if mode == 'check' else results
        sets = sorted(d for d in os.listdir(base) if os.path.isdir(os.path.join(base, d)))
    return (check if mode == 'check' else make)(results, reference, sets)


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
