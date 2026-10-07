#!/usr/bin/env python3
"""A/B benchmark: the same scripted camera run on gridtest_vis and gridtest_grid.

For each variant it:
  1. records a demo of the run (the mod quits at the end in bench mode, scratch3 1)
     and reads the mod's "GRIDVIS ..." lines (monsters in the PVS per pass);
  2. plays the demo back with timedemo (the demo ends with "disconnect; quit",
     which prints the timedemo result and closes the game).

Results go to the console and to testmap/bench_history.txt.

    bench.py [--quake D:\quake] [--variants vis grid] [--count N] [--static] [--vsync] [--label text]
"""
import argparse
import datetime
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HISTORY = os.path.join(ROOT, 'testmap', 'bench_history.txt')
GAME = 'gridvis'
# a normal 1280x720 window, as play.bat (screen recorders can capture it)
VIDEO = ['+vid_fullscreen', '0', '+vid_desktopfullscreen', '0', '+vid_borderless', '0',
         '+vid_width', '1280', '+vid_height', '720', '+vid_restart']

PASS_RE = re.compile(r'GRIDVIS map=(\S+) pass=(\S+) total=(\d+) avg=(\d+) min=(\d+) max=(\d+)')
TIMEDEMO_RE = re.compile(r'(\d+) frames\s+([\d.]+) seconds\s+([\d.]+) fps')


def find_log(quake):
    for path in (os.path.join(quake, GAME, 'qconsole.log'), os.path.join(quake, 'qconsole.log')):
        if os.path.exists(path):
            return path
    return None


def run_game(quake, args, timeout):
    for path in (os.path.join(quake, GAME, 'qconsole.log'), os.path.join(quake, 'qconsole.log')):
        if os.path.exists(path):
            os.remove(path)
    cmd = [os.path.join(quake, 'ironwail.exe'), '-basedir', quake, '-game', GAME, '-condebug'] + VIDEO + args
    subprocess.run(cmd, cwd=quake, timeout=timeout, check=False)
    log = find_log(quake)
    if not log:
        sys.exit('[bench] no qconsole.log after: %s' % ' '.join(cmd))
    with open(log, encoding='latin-1') as f:
        return f.read()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--quake', default=r'D:\quake')
    ap.add_argument('--variants', nargs='+', default=['vis', 'grid'])
    ap.add_argument('--static', action='store_true', help='monsters as static entities (scratch2 1)')
    ap.add_argument('--count', type=int, default=0, help='number of monsters (scratch1, 0 = mod default)')
    ap.add_argument('--label', default='')
    ap.add_argument('--vsync', action='store_true', help='keep vsync and the fps cap in the timedemo')
    args = ap.parse_args()

    results = []
    for variant in args.variants:
        mapname = 'gridtest_' + variant
        demo = 'gv_' + variant
        print('[bench] %s: recording %s' % (mapname, demo))
        log = run_game(args.quake, ['+max_edicts', str(max(8192, args.count + 512)), '+scratch1', str(args.count),
                                    '+scratch2', '1' if args.static else '0',
                                    '+scratch3', '1', '+record', demo, mapname], timeout=300)
        passes = {m.group(2): m.groups() for m in PASS_RE.finditer(log)}
        if 'packet overflow' in log.lower():
            print('[bench] WARNING: packet overflow while recording %s: the server dropped entities' % mapname)

        print('[bench] %s: timedemo %s' % (mapname, demo))
        # unthrottled: no vsync, no fps cap (saved in the gridvis game dir's config.cfg only)
        uncapped = [] if args.vsync else ['+vid_vsync', '0', '+host_maxfps', '0']
        log = run_game(args.quake, uncapped + ['+timedemo', demo], timeout=300)
        m = TIMEDEMO_RE.search(log)
        fps = m.group(3) if m else '?'
        seconds = m.group(2) if m else '?'
        # demo size per frame: what the server sends to the client each frame
        demo_bytes = os.path.getsize(os.path.join(args.quake, GAME, demo + '.dem'))
        net = '%.1fKB' % (demo_bytes / int(m.group(1)) / 1024) if m else '?'
        results.append((variant, passes, fps, seconds, net))

    stamp = datetime.datetime.now().strftime('%Y-%m-%d %H:%M')
    lines = []
    for variant, passes, fps, seconds, net in results:
        parts = ['%s %-5s' % (stamp, variant), 'fps=%s' % fps, 'time=%ss' % seconds, 'net/frame=%s' % net]
        for name in ('normal', 'far'):
            if name in passes:
                _, _, total, avg, mn, mx = passes[name]
                parts.append('%s_sent=%s/%s (%s-%s)' % (name, avg, total, mn, mx))
        if args.static:
            parts.append('static')
        if args.label:
            parts.append('label=' + args.label)
        lines.append('  '.join(parts))

    print()
    for line in lines:
        print(line)
    with open(HISTORY, 'a', encoding='utf-8') as f:
        for line in lines:
            f.write(line + '\n')


if __name__ == '__main__':
    sys.exit(main())
