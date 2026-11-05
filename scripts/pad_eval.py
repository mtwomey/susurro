#!/usr/bin/env python3
"""Trailing-pad evaluation against written references (BEA-643).

Usage: scripts/pad_eval.py <references.tsv> [--pads 0,1500,1750,2000,2500] [--no-trim]

Unlike pad_sweep.py (which scores against the unpadded output), this scores
every pad length against what was actually said. Clips are first trimmed to
10 ms after the last audible sample (push-to-talk release), unless --no-trim.
Pad 0 is the current engine (two-pass terminal mark; body = unpadded).
Reports total reference errors (ab_engines.norm WER, punctuation-insensitive),
clips better/worse than pad 0, final ?/. accuracy, and every differing transcript.
"""
import argparse, array, os, re, subprocess, sys, tempfile, wave

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ab_engines import norm, edits, ROOT  # noqa: E402


def trimmed(src, dst):
    w = wave.open(src); assert w.getframerate() == 16000 and w.getnchannels() == 1 and w.getsampwidth() == 2, src
    a = array.array("h", w.readframes(w.getnframes())); w.close()
    last = max((i for i, x in enumerate(a) if abs(x) > 300), default=len(a) - 1)
    o = wave.open(dst, "wb"); o.setnchannels(1); o.setsampwidth(2); o.setframerate(16000)
    o.writeframes(a[:last + 160].tobytes()); o.close()


def run(cli, clips, ms):
    env = {k: v for k, v in os.environ.items() if not k.startswith("SUSURRO_DEV_PAD")}
    if ms:
        env["SUSURRO_DEV_PAD_MS"] = str(ms)
    p = subprocess.run([cli, "--engine", "parakeet"] + clips, capture_output=True, text=True, env=env)
    if p.returncode:
        sys.exit(p.stderr)
    out = re.sub(r"E5RT encountered an STL exception\..*?zero shape error\.", "", p.stdout).rstrip("\n").split("\n")
    assert len(out) == len(clips)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("refs")
    ap.add_argument("--cli", default=os.path.join(ROOT, ".build/release/susurro-cli"))
    ap.add_argument("--pads", default="0,1500,1750,2000,2500")
    ap.add_argument("--no-trim", action="store_true")
    a = ap.parse_args()
    base = os.path.dirname(os.path.abspath(a.refs))
    refs = [l.rstrip("\n").split("\t", 1) for l in open(a.refs) if l.strip() and not l.startswith("#")]
    refs = [r for r in refs if os.path.exists(os.path.join(base, r[0]))]
    tmp = tempfile.mkdtemp()
    clips = []
    for name, _ in refs:
        src = os.path.join(base, name)
        if a.no_trim:
            clips.append(src)
        else:
            dst = os.path.join(tmp, name); trimmed(src, dst); clips.append(dst)
    pads = [int(x) for x in a.pads.split(",")]
    res = {ms: run(a.cli, clips, ms) for ms in pads}
    err = {ms: [edits(norm(r[1]), norm(h)) for r, h in zip(refs, o)] for ms, o in res.items()}
    b = err[pads[0]]
    print(f"{len(refs)} clips\n")
    print("| pad | reference errors | clips better | clips worse | final ?/. correct |")
    print("|---|---|---|---|---|")
    for ms in pads:
        e = err[ms]
        fin = sum(h.rstrip()[-1:] == r[1].rstrip()[-1:] for r, h in zip(refs, res[ms]))
        worse = [r[0] for r, x, y in zip(refs, e, b) if x > y]
        print(f"| {ms} ms | {sum(e)} | {sum(x < y for x, y in zip(e, b))} | {len(worse)} {' '.join(worse)} | {fin}/{len(refs)} |")
    print()
    for i, (name, ref) in enumerate(refs):
        if len({res[ms][i] for ms in pads}) > 1:
            print(f"- {name}  ref: {ref}")
            for ms in pads:
                print(f"  - {ms:5d} [{err[ms][i]}] {res[ms][i]}")


if __name__ == "__main__":
    main()
