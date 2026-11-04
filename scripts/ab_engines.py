#!/usr/bin/env python3
"""A/B accuracy + latency harness: whisper vs Parakeet over the fixture corpus (BEA-637).

Usage: scripts/ab_engines.py [--cli .build/release/susurro-cli] [--refs Fixtures/ab/references.tsv]

Runs `susurro-cli --engine <e>` once per engine over every clip in the
references file (resolved against Fixtures/ then Fixtures/ab/), then prints a
Markdown table of per-clip WER and per-engine totals and latency.

WER normalisation is deliberately simple and engine-neutral: lowercase, strip
punctuation except inside numbers, split on whitespace. Both engines apply
their own inverse text normalisation, so a formatting choice ("3:30 p.m." vs
"three thirty") can count as an error for either engine; read the
transcripts, not just the numbers.
"""
import argparse, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def norm(s):
    s = s.lower().replace("’", "'")
    s = re.sub(r"(?<!\d)[.,](?!\d)|[?!;:\"“”()\[\]]|(?<=\d)[.,](?!\d)", " ", s)
    s = re.sub(r"(?<![a-z0-9])-|-(?![a-z0-9])", " ", s)
    return s.split()

def edits(ref, hyp):
    d = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, 1):
        prev, d[0] = d[0], i
        for j, h in enumerate(hyp, 1):
            prev, d[j] = d[j], min(d[j] + 1, d[j - 1] + 1, prev + (r != h))
    return d[-1]

def run(cli, engine, clips):
    p = subprocess.run([cli, "--engine", engine] + clips, capture_output=True, text=True)
    if p.returncode:
        sys.exit(f"{engine} failed: {p.stderr}")
    m = re.search(r"loaded in ([\d.]+)s", p.stderr)
    load = float(m.group(1)) if m else float("nan")
    times = [float(x) for x in re.findall(r"audio \| ([\d.]+)s \|", p.stderr)]
    audio = [float(x) for x in re.findall(r": ([\d.]+)s audio", p.stderr)]
    # Core ML's E5RT runtime writes a one-off shape-inference diagnostic straight
    # to stdout on Parakeet's first inference; it is not part of the transcript.
    out = re.sub(r"E5RT encountered an STL exception\..*?zero shape error\.", "", p.stdout)
    outs = out.rstrip("\n").split("\n")
    assert len(outs) == len(clips) == len(times), (engine, len(outs), len(times))
    return load, times, audio, outs

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cli", default=os.path.join(ROOT, ".build/release/susurro-cli"))
    ap.add_argument("--refs", default=os.path.join(ROOT, "Fixtures/ab/references.tsv"))
    ap.add_argument("--engines", default="whisper,parakeet")
    a = ap.parse_args()
    refs = []
    for line in open(a.refs):
        if line.startswith("#") or not line.strip():
            continue
        name, text = line.rstrip("\n").split("\t", 1)
        path = next(p for p in (os.path.join(ROOT, "Fixtures", name), os.path.join(ROOT, "Fixtures/ab", name)) if os.path.exists(p))
        refs.append((name, path, text))
    clips = [p for _, p, _ in refs]
    engines = a.engines.split(",")
    res = {e: run(a.cli, e, clips) for e in engines}

    print("| clip | words | " + " | ".join(f"{e} WER" for e in engines) + " |")
    print("|---|---|" + "---|" * len(engines))
    tot = {e: 0 for e in engines}; nwords = 0
    for i, (name, _, ref) in enumerate(refs):
        r = norm(ref); nwords += len(r)
        cells = []
        for e in engines:
            k = edits(r, norm(res[e][3][i])); tot[e] += k
            cells.append(f"{100 * k / len(r):.1f}% ({k})")
        print(f"| {name} | {len(r)} | " + " | ".join(cells) + " |")
    print(f"| **total** | {nwords} | " + " | ".join(f"**{100 * tot[e] / nwords:.1f}%** ({tot[e]})" for e in engines) + " |")
    print()
    print("| engine | load (s) | transcribe total (s) | mean per clip (s) | audio (s) | realtime |")
    print("|---|---|---|---|---|---|")
    for e in engines:
        load, times, audio, _ = res[e]
        print(f"| {e} | {load:.2f} | {sum(times):.2f} | {sum(times) / len(times):.2f} | {sum(audio):.1f} | {sum(audio) / max(sum(times), 1e-3):.0f}x |")
    print()
    for i, (name, _, ref) in enumerate(refs):
        print(f"- {name}\n  - ref: {ref}")
        for e in engines:
            print(f"  - {e}: {res[e][3][i]}")

if __name__ == "__main__":
    main()
