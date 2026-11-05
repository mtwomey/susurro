#!/usr/bin/env python3
"""Record Matthew's push-to-talk clips for the BEA-643 padding decision.

Usage: scripts/record_voice_clips.py [--only v03,v07] [--tsv scripts/xjoin_pairs.tsv]

For each line in Fixtures/voice/references.tsv: press Enter, read the sentence
after a short beat (rec takes ~0.2 s to start) in your normal dictation voice, press Enter right after the last word (like
releasing the hotkey). Records 16 kHz mono WAV from the default input device
with sox. Re-run with --only to redo individual clips.
"""
import argparse, os, subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TSV = os.path.join(ROOT, "Fixtures/voice/references.tsv")

ap = argparse.ArgumentParser()
ap.add_argument("--only", default="")
ap.add_argument("--tsv", default=TSV, help="prompt list (e.g. scripts/xjoin_pairs.tsv)")
a = ap.parse_args()
only = {x.strip().removesuffix(".wav") for x in a.only.split(",") if x.strip()}
rows = [l.rstrip("\n").split("\t", 1) for l in open(a.tsv) if l.strip() and not l.startswith("#")]
for name, text in rows:
    if only and name.removesuffix(".wav") not in only:
        continue
    out = os.path.join(ROOT, "Fixtures/voice", name)
    print(f"\n{name}:  {text}")
    input("  Enter to start... ")
    p = subprocess.Popen(["rec", "-q", "-c", "1", "-r", "16000", "-b", "16", out],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    input("  recording - Enter right after the last word ")
    p.terminate()  # sox finalises the WAV on SIGTERM (SIGINT does not stop it from a pipe)
    p.wait()
    print(f"  saved {os.path.relpath(out, ROOT)}")
print("\nDone. Tell the agent on BEA-643; it runs scripts/pad_eval.py Fixtures/voice/references.tsv")
