#!/usr/bin/env python3
"""Hands-free join evaluation (BEA-657).

Builds stitched hands-free sessions and scores the join decisions made by
`susurro-cli --handsfree` (same segmenter + held-mark joiner as the app):
  - real sentence breaks: Matthew's clip i + gap + clip i+1   -> expect sentenceBreak
  - mid-sentence pauses: one clip split at its quietest point
    in the middle third + gap                                  -> expect continuation
  - synthetic `say` halves for both kinds.
Gaps cycle 0.8 / 1.2 / 1.8 / 2.5 s. A case only scores as correct when the
segmenter made exactly one cut at the gap and the decision matches; unmatched
counts as wrong for a break only if the mark would be lost (it isn't: unmatched
keeps A's mark), so unmatched is scored as "break" (the mark is typed).
Words check: typed words == concatenated per-chunk words (case/punct-insensitive).

usage: handsfree_join_eval.py <voice-dir> <out-dir> [--min-pause S] [--engine parakeet]
"""
import array, json, os, re, subprocess, sys, wave

GAPS = [0.8, 1.2, 1.8, 2.5]
SR = 16000

def to16k(src, dst):
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", src, dst], check=True)

def read(path):
    with wave.open(path) as w:
        assert w.getframerate() == SR and w.getnchannels() == 1
        a = array.array("h"); a.frombytes(w.readframes(w.getnframes())); return list(a)

def write(path, s):
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes(array.array("h", s).tobytes())

def silence(sec): return [0] * int(sec * SR)

def quietest_split(s):
    # Split at the middle of the longest quiet run (a word gap) in the middle
    # 30-70% of the clip, so the cut doesn't land inside a word.
    win = int(0.01 * SR); lo, hi = int(len(s) * 0.3), int(len(s) * 0.7)
    es = [sum(x * x for x in s[i:i + win]) / win for i in range(lo, hi - win, win)]
    thr = sorted(es)[len(es) // 10] * 4 + 1
    best = (0, lo); run = 0
    for n, e in enumerate(es):
        run = run + 1 if e <= thr else 0
        if run > best[0]: best = (run, lo + (n - run // 2) * win)
    return best[1]

def say(text, dst, tmp):
    aiff = dst + ".aiff"
    subprocess.run(["say", "-o", aiff, text], check=True); to16k(aiff, dst); os.remove(aiff)

SAY_MID = [("So I was thinking that we should probably", "move the deploy to Thursday because the tests are still flaky"),
           ("Can you send me the", "quarterly report before the meeting on Friday"),
           ("I think the main problem with the new design is", "that it takes too long to load"),
           ("We need to talk to the", "vendor about the contract renewal"),
           ("Please make sure that", "everyone has access to the shared folder"),
           ("The reason I am asking is", "because the numbers do not add up")]
SAY_BREAK = [("Yes, that works for me.", "Send it to the team tomorrow morning."),
             ("The build is finally green.", "Let us ship it this afternoon."),
             ("Are you coming to lunch today?", "We are meeting at the usual place."),
             ("Thanks for the quick reply.", "I will review the draft tonight."),
             ("The tests passed on my machine.", "Can you try them on yours?"),
             ("I fixed the login bug.", "The next release should go out on Monday.")]

def main():
    voice, out = sys.argv[1], sys.argv[2]
    extra = sys.argv[3:]
    os.makedirs(out, exist_ok=True)
    cases = []  # (name, kind, expected)
    clips = sorted(f for f in os.listdir(voice) if f.endswith(".wav"))
    v = {}
    for f in clips:
        dst = os.path.join(out, "src_" + f); to16k(os.path.join(voice, f), dst); v[f] = read(dst)
    for i in range(len(clips) - 1):
        g = GAPS[i % 4]; name = f"voice_break_{i+1:02d}.wav"
        write(os.path.join(out, name), v[clips[i]] + silence(g) + v[clips[i + 1]])
        cases.append((name, "voice-break", "sentenceBreak", g))
    for i, f in enumerate(clips):
        g = GAPS[i % 4]; s = v[f]; k = quietest_split(s); name = f"voice_mid_{i+1:02d}.wav"
        write(os.path.join(out, name), s[:k] + silence(g) + s[k:])
        cases.append((name, "voice-mid", "continuation", g))
    for i, (a, b) in enumerate(SAY_MID + SAY_BREAK):
        mid = i < len(SAY_MID); g = GAPS[i % 4]
        say(a, os.path.join(out, "a.wav"), out); say(b, os.path.join(out, "b.wav"), out)
        name = f"say_{'mid' if mid else 'break'}_{i+1:02d}.wav"
        write(os.path.join(out, name), read(os.path.join(out, "a.wav")) + silence(g) + read(os.path.join(out, "b.wav")))
        cases.append((name, "say-mid" if mid else "say-break", "continuation" if mid else "sentenceBreak", g))
    cli = os.environ.get("SUSURRO_CLI", ".build/debug/susurro-cli")
    res = subprocess.run([cli, "--engine", "parakeet", "--handsfree", *extra] + [os.path.join(out, c[0]) for c in cases],
                         capture_output=True, text=True, check=True)
    rows = [json.loads(l[l.index("{"):]) for l in res.stdout.splitlines() if "{\"chunks" in l]
    by = {r["file"]: r for r in rows}
    norm = lambda t: re.sub(r"[^a-z0-9 ]", "", t.lower()).split()
    stats, words_ok, detail = {}, True, []
    for name, kind, exp, g in cases:
        r = by[name]; d = r["decisions"]
        # No mark held (A ended unmarked) = continuation via ContinuationCase.
        got = d[0] if len(d) == 1 else ("continuation" if len(r["chunks"]) == 2 and not d else f"cuts={len(r['chunks'])}")
        if got == "unmatched": got_eff = "sentenceBreak"
        else: got_eff = got
        ok = got_eff == exp
        st = stats.setdefault(kind, [0, 0]); st[0] += ok; st[1] += 1
        w_ok = norm(r["typed"]) == norm(" ".join(r["chunks"]))
        words_ok &= w_ok
        detail.append(f"{'OK ' if ok else 'BAD'} {kind:12s} gap={g:.1f} {got:14s} words={'same' if w_ok else 'DIFF'} | {r['typed']}")
    print("\n".join(detail))
    print()
    for k, (a, n) in stats.items(): print(f"{k:12s} {a}/{n} = {100*a/n:.0f}%")
    js = [r["jointSeconds"] for r in rows if r["decisions"]]
    print(f"words identical to per-chunk: {words_ok}; joint transcribe total {sum(js):.2f}s over {len(js)} joins")

if __name__ == "__main__":
    main()
