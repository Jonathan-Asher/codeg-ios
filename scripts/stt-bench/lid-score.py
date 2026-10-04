#!/usr/bin/env python3
"""Confusion tables for lid-cli output (docs/FORK.md, "Hebrew or English").

    lid-score.py results-lid/*.tsv [--thresholds 0.5,0.8,0.9,0.95,0.99]

The truth comes from the clip's directory: he-* is Hebrew, en-* is English.
A clip is called English when p(en), renormalized over Hebrew and English,
is at least the threshold. For each model and window it prints the
confusion table per threshold, the highest p(en) any Hebrew clip got (the
threshold must be above it), the Hebrew clips closest to English, and the
median time per call.
"""
import os
import statistics
import sys
from collections import defaultdict

args = [a for a in sys.argv[1:] if not a.startswith("--")]
thresholds = [0.5, 0.8, 0.9, 0.95, 0.99]
if "--thresholds" in sys.argv:
    thresholds = [float(x) for x in sys.argv[sys.argv.index("--thresholds") + 1].split(",")]
    args = [a for a in args if a != sys.argv[sys.argv.index("--thresholds") + 1]]

for path in args:
    model = os.path.basename(path).removesuffix(".tsv")
    rows = defaultdict(list)  # window -> [(clip, truth, p_en, ms)]
    load = None
    for line in open(path, encoding="utf-8"):
        parts = line.rstrip("\n").split("\t")
        if parts[0] == "#load":
            load = float(parts[1])
            continue
        clip, _speech, window, _p_he, p_en, ms = parts
        if window == "-":
            continue
        truth = "he" if clip.startswith("he-") else "en"
        rows[int(window)].append((clip, truth, float(p_en), float(ms)))
    for window in sorted(rows):
        data = rows[window]
        he = [r for r in data if r[1] == "he"]
        en = [r for r in data if r[1] == "en"]
        worst = sorted(he, key=lambda r: -r[2])[:3]
        ms = statistics.median(r[3] for r in data)
        print(f"\n{model}  window {window}s  load {load:.2f}s  median {ms:.1f} ms/call  "
              f"(Hebrew {len(he)}, English {len(en)})")
        print("  threshold  he→he  he→en  en→en  en→he")
        for t in thresholds:
            he_en = sum(r[2] >= t for r in he)
            en_en = sum(r[2] >= t for r in en)
            print(f"  {t:9.3f}  {len(he) - he_en:5d}  {he_en:5d}  {en_en:5d}  {len(en) - en_en:5d}")
        print("  Hebrew closest to English: " + ", ".join(f"{r[0]} {r[2]:.3f}" for r in worst))
        missed = sorted((r for r in en if r[2] < max(thresholds)), key=lambda r: r[2])[:4]
        if missed:
            print("  English lowest: " + ", ".join(f"{r[0]} {r[2]:.3f}" for r in missed))
