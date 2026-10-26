#!/usr/bin/env python3
"""Summarise one run's client logs.

usage: summarize.py <outdir> <tag> <cpu_before> <cpu_after> <alive> <nprocs>

Each client process measures the same rounds, so the aggregate rate is the
per-process rate times the number of processes; the median round time is the
one number that is independent of how the clients were split.
"""
import glob
import statistics
import sys

outdir, tag, c1, c2, alive, nprocs = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5], int(sys.argv[6])
rates, times = [], []
for f in glob.glob(f"{outdir}/client.*.log"):
    for line in open(f):
        if line.startswith("round "):
            parts = line.split()
            times.append(float(parts[2]))
            rates.append(int(parts[-2]))
if not rates:
    print(f"{tag}: no rounds (client failed)")
    sys.exit(1)
print(f"{tag:22s} {nprocs} client proc(s)  round={statistics.median(times):7.1f} ms  "
      f"aggregate={sum(rates) / len(rates) * nprocs:>9.0f} msg/s  "
      f"server_cpu={(c2 - c1) / 100:6.2f}s  alive={alive}")
