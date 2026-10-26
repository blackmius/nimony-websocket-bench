#!/usr/bin/env python3
"""Merge RTT sample files and print one JSON line of percentiles.

    scripts/scale.py out.json samples1.rtt samples2.rtt ...
"""
import json
import sys

out = sys.argv[1]
vals = []
for path in sys.argv[2:]:
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                vals.append(float(line))
vals.sort()
n = len(vals)


def q(p):
    if n == 0:
        return 0
    return round(vals[min(n - 1, int(n * p))], 1)


json.dump({"samples": n, "p50us": q(0.5), "p90us": q(0.9), "p99us": q(0.99),
           "maxus": round(vals[-1], 1) if n else 0}, open(out, "w"))
