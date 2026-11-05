#!/usr/bin/env python3
"""Cross-dictation join eval (BEA-677).

Generates pairs of separate dictations with macOS `say` (split mid-sentence
vs at a real sentence end), runs `susurro-cli --xjoin` on each pair, and
checks the field text: mid-sentence splits must join lower-case without a
stray full stop; real sentence ends must be kept.

  python3 scripts/xjoin_eval.py [--engine parakeet] [--voice Samantha] [--gap 3]
  python3 scripts/xjoin_eval.py --clips a.wav b.wav --expect continue   # own voice clips

Clips go to build/xjoin-fixtures (untracked). Exit code 1 on any failure.
"""
import argparse, json, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "build", "xjoin-fixtures")

# (first dictation, second dictation, expected: continue | break)
CASES = [
    ("Yesterday I went to the store", "and bought bananas", "continue"),
    ("Today I plan", "to go for a bike ride", "continue"),
    ("I was thinking that we should probably", "move the meeting to Thursday", "continue"),
    # The engine hears a question here; "?" is never retracted (guard), so it stays.
    ("Can you send me the report", "when you get a chance", "break"),
    ("Yesterday I went to the store and bought bananas.", "Today I plan to go for a bike ride.", "break"),
    ("The build is green.", "Let's ship it tomorrow morning.", "break"),
    ("Thanks for the update.", "I will review it tonight.", "break"),
]


# Matthew's recorded pairs (scripts/xjoin_pairs.tsv -> Fixtures/voice/x*.wav, untracked).
VOICE_EXPECT = {"x01": "continue", "x02": "continue", "x03": "continue", "x04": "break", "x05": "break"}


def say(text, path, voice):
    if not os.path.exists(path):
        cmd = ["say", "-o", path, "--data-format=LEI16@16000"]
        if voice:
            cmd += ["-v", voice]
        subprocess.run(cmd + [text], check=True)


def run_cli(engine, gap, clips):
    cli = os.path.join(ROOT, ".build", "debug", "susurro-cli")
    if not os.path.exists(cli):
        subprocess.run(["swift", "build", "--product", "susurro-cli"], cwd=ROOT, check=True)
    r = subprocess.run([cli, "--xjoin", "--gap", str(gap), "--engine", engine, *clips],
                       capture_output=True, text=True, check=True)
    out = r.stdout
    return json.loads(out[out.rindex('{"decisions"'):].strip())


def verdict(result, expect):
    typed = result["typed"]
    # The join point: the second dictation's first word must follow either
    # ". X" (break) or " x" with no full stop (continue).
    second = result["texts"][1].strip()
    first_word = re.sub(r"[^\w']", "", second.split()[0]) if second else ""
    m = re.search(r"([.?!]?)\s+(" + re.escape(first_word) + r")\b", typed, re.IGNORECASE)
    if not m:
        return False, "join not found"
    mark, word = m.group(1), m.group(2)
    if expect == "continue":
        ok = mark == "" and (word[0].islower() or word in ("I",) or word.isupper())
    else:
        ok = mark != "" and word[0].isupper()
    return ok, f"mark={mark or '-'} word={word}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", default="parakeet")
    ap.add_argument("--voice", default="Samantha")
    ap.add_argument("--gap", type=float, default=3)
    ap.add_argument("--clips", nargs=2)
    ap.add_argument("--voice-pairs", action="store_true", help="use Fixtures/voice/x*.wav (own voice)")
    ap.add_argument("--expect", choices=["continue", "break"])
    a = ap.parse_args()
    os.makedirs(OUT, exist_ok=True)
    jobs = []
    if a.clips:
        jobs.append((a.clips, a.expect or "continue", "clips"))
    elif a.voice_pairs:
        vdir = os.path.join(ROOT, "Fixtures", "voice")
        for name, exp in VOICE_EXPECT.items():
            pa, pb = os.path.join(vdir, f"{name}a.wav"), os.path.join(vdir, f"{name}b.wav")
            if os.path.exists(pa) and os.path.exists(pb):
                jobs.append(([pa, pb], exp, name))
        if not jobs:
            sys.exit("no Fixtures/voice/x*.wav pairs; record: scripts/record_voice_clips.py --tsv scripts/xjoin_pairs.tsv")
    else:
        for i, (x, y, exp) in enumerate(CASES):
            pa, pb = os.path.join(OUT, f"c{i:02d}a.wav"), os.path.join(OUT, f"c{i:02d}b.wav")
            say(x, pa, a.voice); say(y, pb, a.voice)
            jobs.append(([pa, pb], exp, f"c{i:02d}"))
    fails = 0
    for clips, exp, name in jobs:
        res = run_cli(a.engine, a.gap, clips)
        ok, why = verdict(res, exp)
        fails += not ok
        print(f"{'PASS' if ok else 'FAIL'} {name} expect={exp} {why} {res['decisions'][-1]} | {res['typed']}")
    print(f"{len(jobs) - fails}/{len(jobs)} passed")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
