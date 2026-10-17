#!/usr/bin/env python3
"""Honest coverage: counts lib/ files no test imports as 0%, which lcov alone omits.

Usage: tools/coverage_report.py [--min PERCENT] [--by-dir DEPTH] [lcov files...]
Excludes platform-only code (see PLATFORM_CODE) and generated code (*.g.dart, *.freezed.dart, *.chopper.dart, lib/l10n, lib/gen).
"""
import argparse, os, re, sys

ap = argparse.ArgumentParser()
ap.add_argument("--min", type=float, default=0)
ap.add_argument("--by-dir", type=int, default=2)
ap.add_argument("lcov", nargs="*", default=["coverage/lcov.info"])
a = ap.parse_args()

PLATFORM_CODE = (
    "lib/services/android_auto_helper.dart",
    "lib/services/carplay_helper.dart",
    "lib/services/ios_helpers.dart",
    "lib/services/audio_service_smtc.dart",
    "lib/services/tvos/",
    "lib/screens/ipod/",
    "lib/screens/tv/",
    "lib/screens/watch/",
)


def skip(p):
    return (
        p.endswith((".g.dart", ".freezed.dart", ".chopper.dart"))
        or p.startswith(("lib/l10n/", "lib/gen/"))
        or p.startswith(PLATFORM_CODE)
    )

def code_lines(path):
    n = 0
    for l in open(path, encoding="utf-8", errors="ignore"):
        s = l.strip()
        if s and not s.startswith(("//", "import ", "export ", "part ", "library ")) and s not in ("}", ");", "];", "});"):
            n += 1
    return n

cov = {}
for f in a.lcov:
    cur = None
    for l in open(f):
        l = l.strip()
        if l.startswith("SF:"):
            cur = l[3:]
            cov.setdefault(cur, {})
        elif l.startswith("DA:") and cur:
            ln, h = l[3:].split(",")[:2]
            cov[cur][ln] = max(cov[cur].get(ln, 0), int(h))

rows = {}
for root, _, names in os.walk("lib"):
    for n in names:
        p = os.path.join(root, n)
        if not n.endswith(".dart") or skip(p):
            continue
        if p in cov:
            tot, hit = len(cov[p]), sum(1 for v in cov[p].values() if v)
        else:
            tot, hit = code_lines(p), 0
        d = "/".join(p.split("/")[: a.by_dir + 0])
        t = rows.setdefault(d, [0, 0])
        t[0] += tot; t[1] += hit

T = sum(v[0] for v in rows.values()); H = sum(v[1] for v in rows.values())
for d, (t, h) in sorted(rows.items(), key=lambda kv: -(kv[1][0] - kv[1][1])):
    print(f"{100*h/t if t else 100:5.1f}%  {h:6}/{t:<6} {d}")
pct = 100 * H / T
print(f"\nTOTAL {pct:.1f}%  ({H}/{T} lines, generated code excluded)")
if pct < a.min:
    print(f"below required {a.min}%"); sys.exit(1)
