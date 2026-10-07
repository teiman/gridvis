#!/usr/bin/env python3
"""Checks, from the client side, how many entities the server really sends.

Runs the scripted camera on each test map in debug mode (scratch4 1). At four points
of the run the mod turns on cl_shownet 2 for a couple of frames: the client then logs
every message it receives, with one "fast update" line per entity update. This script
counts those lines per packet and compares them with the mod's own count
(checkclient), which it prints next to each sample.

    netcheck.py [--quake D:/quake] [--variants vis grid]

The entity count includes the player entity itself (the server always sends it).
"""
import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench import run_game  # noqa: E402

SAMPLE_RE = re.compile(r'gridvis: sample (\d+) map=(\S+) checkclient=(\d+)')
SAMPLE_NAMES = ['start (normal zoom)', 'pass 1, normal zoom', 'pass 2, far zoom (start)', 'pass 2, far zoom (middle)']


def count_samples(log):
    """For each sample marker: (sample, checkclient, [entity updates per packet])."""
    samples = []
    current = None
    packet = None
    for line in log.splitlines():
        m = SAMPLE_RE.search(line)
        if m:
            current = {'n': int(m.group(1)), 'checkclient': int(m.group(3)), 'packets': []}
            samples.append(current)
            packet = None
            continue
        if current is None:
            continue
        if line.startswith('------------------'):
            packet = 0
            current['packets'].append(packet)
        elif 'fast update' in line and current['packets']:
            current['packets'][-1] += 1
    return samples


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--quake', default=r'D:\quake')
    ap.add_argument('--variants', nargs='+', default=['vis', 'grid'])
    args = ap.parse_args()

    rows = []
    for variant in args.variants:
        mapname = 'gridtest_' + variant
        print('[netcheck] %s: running' % mapname)
        log = run_game(args.quake, ['+scratch2', '0', '+scratch3', '1', '+scratch4', '1', '+map', mapname],
                       timeout=300)
        for s in count_samples(log):
            # the datagram with the entities is the biggest packet of the sample
            received = max(s['packets']) if s['packets'] else 0
            rows.append((mapname, SAMPLE_NAMES[s['n']] if s['n'] < len(SAMPLE_NAMES) else str(s['n']),
                         s['checkclient'], received, s['packets']))

    print()
    print('%-14s %-28s %12s %22s' % ('map', 'moment', 'checkclient', 'entities received'))
    for mapname, moment, cc, received, packets in rows:
        print('%-14s %-28s %12d %12d (+player)   packets: %s' % (mapname, moment, cc, max(received - 1, 0),
                                                              ' '.join(str(p) for p in packets)))


if __name__ == '__main__':
    sys.exit(main())
