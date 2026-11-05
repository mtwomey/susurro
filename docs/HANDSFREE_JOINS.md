# Hands-free joins (BEA-657)

## Problem
Hands-free cuts the recording at each pause and transcribes each piece alone.
Parakeet (and Whisper) close every piece with an end mark, so a thinking pause
mid-sentence typed "we should probably. Move the deploy...".

## How it works
1. Each piece is transcribed as before; its final `.`/`?`/`!` is held back and
   the text is typed without it (`HandsFreeJoin.holdMark`).
2. When the next piece arrives, a joint clip is built
   (`HandsFreeJoin.jointClip`): the last 3 s of speech of the previous piece
   (from its last speech frame, trailing silence excluded), the real pause
   (capped at 2 s, middle removed), and the new piece's speech.
   PauseSegmenter cuts now report each segment's first/last speech sample.
3. The joint clip is transcribed with the active engine. The previous piece's
   last 3/2/1 words are located in the joint text (normalised; the first joint
   word may be the tail of a word) and only the punctuation at the join is read
   (`HandsFreeJoin.decide`):
   - end mark there -> type the held mark + space, then the piece as is;
   - no mark (or "p.m." followed by a lower-case word) -> type a space and the
     piece with its first word lower-cased (ContinuationCase: keeps "I", "I'm",
     acronyms);
   - can't match -> the held mark is used (today's behaviour).
   The piece's own final mark is then held for the next join.
4. Tap stop / auto-stop: the last held mark is typed (only if the same app is
   still frontmost). Esc drops it with the untyped audio.
5. Fallbacks: app switched -> existing clipboard rule, held mark included in
   the copied text; cursor moved (the field's text before the cursor no longer
   ends with the previous piece's last word) -> the piece is typed as a fresh
   dictation and the held mark is not typed anywhere else. Pieces never join
   across apps. Whisper uses the same mechanism.
6. `PauseSegmenter.minPause` 0.7 -> 1.0 s.

Hold-to-talk is unchanged. Typed words are always the per-piece words; only
the boundary punctuation and first-letter case can change.

## Evaluation
`swift build && python3 scripts/handsfree_join_eval.py <Fixtures/voice dir> <out dir> [--min-pause S]`
uses `susurro-cli --handsfree` (same segmenter + joiner as the app, Parakeet).
Fixtures:
- voice-break: Matthew's clip i + gap + clip i+1 (expect mark kept, capital).
- voice-mid: one clip split at a word gap + gap (expect no mark, lower-case).
  The split point is the first quiet-run candidate whose two halves transcribe
  to exactly the whole clip's words; clips with no clean split are reported as
  "split-in-word" (a real pause never falls inside a word).
- say-mid / say-break: synthetic `say` halves.
- Gaps cycle 0.8 / 1.2 / 1.8 / 2.5 s. v08 contains a spoken retake ("This
  one's messed up") and is reported separately as "dirty-clip".
"No cut" (the segmenter did not cut at a short gap) counts as correct: the
whole sentence is transcribed in one go, as hold-to-talk.

Results (2026-11-05, Parakeet tdt-v2, full output in
HANDSFREE_JOINS_EVAL_minpause{0.7,1.0}.txt):

| Set | minPause 0.7 | minPause 1.0 (shipped) |
|---|---|---|
| voice-break (clean) | 12/12 | 12/12 |
| voice-break incl. v08 | 12/14 (86%) | 14/14 (100%) |
| voice-mid (clean split) | 8/8 | 7/7 |
| voice-mid, all 15 clips | 14/15 (93%) | 14/15 (93%) |
| say-mid | 6/6 | 6/6 |
| say-break | 6/6 | 6/6 |
| words identical to per-piece | yes | yes |

The only miss at 1.0 is a split-in-word fixture ("from the f. Fifth"), where the
first piece's own words are already broken.

Cost: joint transcribe ~0.07 s per join (1.88 s over 28 joins). minPause 1.0
means each piece is typed 0.3 s later after you stop talking (cut at 1.0 s of
silence instead of 0.7 s); short gaps (0.8 s) no longer cut at all, which is
the best case (one transcript).
