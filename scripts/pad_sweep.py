#!/usr/bin/env python3
"""End-of-sentence punctuation sweep for Parakeet (BEA-643).

Usage: scripts/pad_sweep.py [--cli .build/release/susurro-cli] [--out sweep.json] [--quick]

Runs `susurro-cli --engine parakeet` over the A/B fixtures (Fixtures/ab/references.tsv)
plus the push-to-talk punctuation set (Fixtures/punct/references.tsv) once per
candidate trailing pad, using the dev-only SUSURRO_DEV_PAD_* env vars (no
rebuild per value), then scores every candidate against the unpadded baseline:

- per-clip WER (punctuation-insensitive, ab_engines.norm) must be <= baseline on EVERY clip
- normalised tokens must equal the baseline's (catches hallucinated words and
  number/time formatting changes such as "3:30" -> "3.30", "22nd" -> "22")
- terminal ?/. must match the reference on >= 90% of the punctuation clips

Candidates: (a) zero pad 0-1500 ms in 50 ms steps; (b) frame-aligned pad and
low-level noise pad; (c) two-pass = unpadded body + only the final mark from a
padded pass; (d) deterministic end-of-text fallback (question-word start -> "?",
else "."); (c+d) two-pass with the fallback when the padded pass has no mark.
"""
import argparse, json, os, re, subprocess, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ab_engines import norm, edits, ROOT  # noqa: E402

QUESTION_WORDS = {"who", "what", "when", "where", "why", "how", "which", "whose", "whom",
                  "is", "are", "was", "were", "am", "do", "does", "did", "can", "could",
                  "will", "would", "should", "shall", "may", "might", "must", "have", "has",
                  "had", "isn't", "aren't", "wasn't", "weren't", "don't", "doesn't", "didn't",
                  "can't", "couldn't", "won't", "wouldn't", "shouldn't", "haven't", "hasn't"}
LEADING_FILLERS = {"hey", "so", "okay", "ok", "and", "but", "um", "uh", "well", "oh", "also"}
TERMINAL = ".?!"


def load_refs(tsv):
    out = []
    base = os.path.dirname(tsv)
    for line in open(tsv):
        if line.startswith("#") or not line.strip():
            continue
        name, text = line.rstrip("\n").split("\t", 1)
        path = next(p for p in (os.path.join(base, name), os.path.join(ROOT, "Fixtures", name)) if os.path.exists(p))
        out.append((name, path, text))
    return out


def run(cli, clips, env_extra):
    env = dict(os.environ, **env_extra)
    p = subprocess.run([cli, "--engine", "parakeet"] + clips, capture_output=True, text=True, env=env)
    if p.returncode:
        sys.exit(f"parakeet failed {env_extra}: {p.stderr}")
    out = re.sub(r"E5RT encountered an STL exception\..*?zero shape error\.", "", p.stdout)
    outs = out.rstrip("\n").split("\n")
    assert len(outs) == len(clips), (len(outs), len(clips))
    return outs


def fallback(text):
    """Candidate (d): deterministic end-of-text mark when the model left none."""
    t = text.rstrip()
    if not t or t[-1] in TERMINAL:
        return t
    words = [w.strip(",;:").lower().replace("’", "'") for w in t.split()]
    while words and words[0] in LEADING_FILLERS:
        words.pop(0)
    return t + ("?" if words and words[0] in QUESTION_WORDS else ".")


def two_pass(base, padded):
    """Candidate (c): unpadded body; take only a final ?/./! from the padded pass."""
    b = base.rstrip()
    if not b or b[-1] in TERMINAL:
        return b
    p = padded.rstrip()
    return b + p[-1] if p and p[-1] in TERMINAL else b


def score(refs, base, hyp, punct_names):
    wer_bad, tok_bad, punct_ok, punct_n, errs = [], [], 0, 0, 0
    for (name, _, ref), b, h in zip(refs, base, hyp):
        r = norm(ref)
        kb, kh = edits(r, norm(b)), edits(r, norm(h))
        errs += kh
        if kh > kb:
            wer_bad.append(f"{name} {kb}->{kh}")
        if norm(h) != norm(b):
            tok_bad.append(name)
        if name in punct_names:
            punct_n += 1
            punct_ok += bool(h.rstrip()) and h.rstrip()[-1] == ref.rstrip()[-1]
    return dict(errors=errs, wer_regressions=wer_bad, token_changes=tok_bad,
                punct=f"{punct_ok}/{punct_n}", punct_pct=100 * punct_ok / max(punct_n, 1),
                passes=not wer_bad and not tok_bad and punct_ok >= 0.9 * punct_n)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cli", default=os.path.join(ROOT, ".build/release/susurro-cli"))
    ap.add_argument("--out", default=None, help="write raw transcripts per candidate as JSON")
    ap.add_argument("--quick", action="store_true", help="only a few pad values")
    a = ap.parse_args()
    ab = load_refs(os.path.join(ROOT, "Fixtures/ab/references.tsv"))
    pu = load_refs(os.path.join(ROOT, "Fixtures/punct/references.tsv"))
    refs = ab + pu
    punct_names = {n for n, _, _ in pu}
    clips = [p for _, p, _ in refs]

    configs = {"baseline": {}}
    steps = [0, 300, 500, 1000, 1500] if a.quick else range(0, 1501, 50)
    for ms in steps:
        if ms:
            configs[f"a:zero {ms}ms"] = {"SUSURRO_DEV_PAD_MS": str(ms)}
    for ms in ([500, 1000] if a.quick else [250, 500, 750, 1000, 1500]):
        configs[f"b:zero {ms}ms align1280"] = {"SUSURRO_DEV_PAD_MS": str(ms), "SUSURRO_DEV_PAD_ALIGN": "1280"}
        for amp in ("0.0003", "0.001"):
            configs[f"b:noise{amp} {ms}ms"] = {"SUSURRO_DEV_PAD_MS": str(ms), "SUSURRO_DEV_PAD_NOISE": amp}
    raw = {}
    for k, env in configs.items():
        raw[k] = run(a.cli, clips, env)
        print(f"ran {k}", file=sys.stderr)
    base = raw["baseline"]
    if a.out:
        json.dump(dict(clips=[n for n, _, _ in refs], raw=raw), open(a.out, "w"), indent=1)

    rows = {k: v for k, v in raw.items()}
    rows["d:fallback"] = [fallback(t) for t in base]
    for k in list(raw):
        if k.startswith("a:") or k.startswith("b:"):
            rows["c:two-pass " + k[2:]] = [two_pass(b, p) for b, p in zip(base, raw[k])]
            rows["c+d:two-pass+fallback " + k[2:]] = [fallback(two_pass(b, p)) for b, p in zip(base, raw[k])]

    print("| candidate | WER errors (total) | per-clip WER regressions | token changes vs baseline | terminal ?/. | meets bar |")
    print("|---|---|---|---|---|---|")
    for k, hyp in rows.items():
        s = score(refs, base, hyp, punct_names)
        print(f"| {k} | {s['errors']} | {', '.join(s['wer_regressions']) or '-'} | "
              f"{len(s['token_changes'])} {', '.join(s['token_changes'][:4])}{'...' if len(s['token_changes']) > 4 else ''} | "
              f"{s['punct']} ({s['punct_pct']:.0f}%) | {'YES' if s['passes'] else 'no'} |")


if __name__ == "__main__":
    main()
