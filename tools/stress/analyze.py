#!/usr/bin/env python3
"""Summarise a memwatch CSV produced by run-lab.sh (or memwatch.sh on a router).

    python tools/stress/analyze.py /path/to/mem.csv

Prints, per process, the RSS/anon at the end of every phase and the peak inside
it, so a leak (baseline creeping up after each rest phase) is obvious.
"""
import csv
import sys
from collections import defaultdict


def main(path):
    rows = list(csv.reader(open(path, newline="")))
    header = rows[0]
    rows = rows[1:]
    phases = []  # (ts, label)
    series = defaultdict(list)  # name -> [(ts, rss, anon, fds, thr)]
    for r in rows:
        if len(r) < 7:
            continue
        ts, name = int(r[0]), r[1]
        if name == "_phase":
            phases.append((ts, r[3]))
        elif name == "_sys":
            series["_sys"].append((ts, int(r[3]), int(r[4]), int(r[5]), int(r[6])))
        else:
            series[name].append((ts, int(r[3]), int(r[4]), int(r[5]), int(r[6])))

    t0 = min(s[0][0] for s in series.values() if s)
    bounds = [(t0, "baseline")] + phases + [(10**12, None)]
    names = [n for n in series if n != "_sys"]
    print(f"{'phase':<14}", end="")
    for n in names:
        print(f" | {n:^38}", end="")
    print()
    print(f"{'':<14}", end="")
    for _ in names:
        print(f" | {'rss_end':>8} {'rss_max':>8} {'anon_end':>8} {'anon_max':>8}", end="")
    print("   (kB)")
    for i in range(len(bounds) - 1):
        a, label = bounds[i]
        b = bounds[i + 1][0]
        print(f"{label:<14}", end="")
        for n in names:
            pts = [p for p in series[n] if a <= p[0] < b]
            if not pts:
                print(f" | {'-':>38}", end="")
                continue
            print(f" | {pts[-1][1]:>8} {max(p[1] for p in pts):>8} {pts[-1][2]:>8} {max(p[2] for p in pts):>8}", end="")
        print()
    print()
    for n in names:
        s = series[n]
        print(f"{n}: samples={len(s)} rss first={s[0][1]} last={s[-1][1]} peak={max(p[1] for p in s)}  "
              f"anon first={s[0][2]} last={s[-1][2]} peak={max(p[2] for p in s)}  "
              f"fds max={max(p[3] for p in s)} threads max={max(p[4] for p in s)}")
    sysr = series.get("_sys")
    if sysr:
        print(f"_sys: MemAvailable first={sysr[0][1]} last={sysr[-1][1]} min={min(p[1] for p in sysr)}  "
              f"SUnreclaim first={sysr[0][2]} last={sysr[-1][2]}  sockets max={max(p[4] for p in sysr)}")


if __name__ == "__main__":
    main(sys.argv[1])
