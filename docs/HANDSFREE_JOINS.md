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

## Shown-mark mode (board follow-up)
Holding the mark back looked odd when a sentence had clearly ended. Now, when
the focused field is readable (Accessibility, anchored value or app bridge),
each piece is typed WITH its end mark at the pause. At the next piece the same
joint transcript decides the join:
- sentence break / no match: type " " + the piece (capital kept);
- continuation: one Backspace removes the mark, then " " + the piece with its
  first word lower-cased.
The Backspace is guarded (`HandsFreeJoin.canRetract`): the field's text before
the cursor must end with the previous piece's last word immediately followed by
that same mark. Otherwise nothing is deleted, the mark stays, and the piece is
typed as a fresh dictation (the pre-BEA-657 result). Fields that can't be read
keep the hold-back behaviour above, so there is never a blind delete. A shown
mark is already in place at stop, Esc or an app switch.

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

Long thinking pauses (5 / 10 / 15 s, board note on BEA-657), minPause 1.0,
HANDSFREE_JOINS_EVAL_longpauses.txt: voice-break 12/12 clean (13/14 incl. v08,
whose retake makes 3 pieces the scorer can't grade), voice-mid 7/7 clean
(14/15 incl. split-in-word/v08), say 12/12. The join is pause-length
independent: the joint clip caps the pause at 2 s.

Long pauses exposed a pre-existing per-chunk bug (also on main): the segmenter
cuts 0.5 s into a pause, so a 15 s pause led the next chunk as ~14.5 s of
silence and Parakeet dropped or garbled the words after it ("Let me know what
you" + 15 s + "what do you think?" typed only "Let me know what you").
Fix: `HandsFreeJoin.trimmedStart` trims a chunk's lead-in silence to 1.5 s when
it is longer than 3 s. Chunks after ordinary pauses keep their audio (1 of 41
normal-gap cases changed words vs before the trim).

Cost: joint transcribe ~0.07 s per join (1.88 s over 28 joins). minPause 1.0
means each piece is typed 0.3 s later after you stop talking (cut at 1.0 s of
silence instead of 0.7 s); short gaps (0.8 s) no longer cut at all, which is
the best case (one transcript).
