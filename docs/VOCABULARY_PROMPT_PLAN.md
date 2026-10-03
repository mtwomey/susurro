# Custom Vocabulary (Whisper prompt biasing) — feature plan

> Status: **proposed, not started.** Recorded 2026-10-02 so the idea and the
> evidence behind it aren't lost. Companion to `ARCHITECTURE.md` (as-built) —
> when this gets built, update this doc with what actually shipped, per the
> repo's usual convention (see `SMART_SPACING_PLAN.md`).

## Problem

The whisper models Susurro uses are frozen in time. `small.en` (the default,
and the active model on the dev machine) has not changed upstream since
**2023-03-22** — the local file is byte-identical to Hugging Face `main`:

| | Local `ggml-small.en.bin` | HF `ggerganov/whisper.cpp` `main` |
|---|---|---|
| Size | 487,614,201 | 487,614,201 |
| SHA-256 | `c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d` | same (LFS oid) |
| Last upstream commit | — | `80da2d8` "Migrate from HG dataset into HG model", 2023-03-22 |

So "download a newer model" is not an option: there is no newer `small.en`
(or `medium.en`). Tech vocabulary moves much faster than that. Concrete case:
**Dagster** (the orchestrator we run dbt under) is transcribed as DEXTER,
DAXTER, DAGGER, dangster, DAGSDA, DAGSAR, …

### Why substitutions in `rules.json` don't solve it

A substitution `daxter → Dagster` is blind string replacement after the fact.
Most of the mis-hearings (*Dexter*, *dagger*) are real words that are correct
in other contexts, so blanket replacements corrupt legitimate dictation. And
the set of mis-hearings is open-ended — you'd chase variants forever.

## Proposal

Use whisper's **initial prompt** (`whisper_full_params.initial_prompt`). The
prompt is fed to the decoder as if it were *preceding transcript*, so the
model expects those words and spellings and prefers them during decoding —
using the actual audio and surrounding context, not post-hoc string matching.

The vendored whisper.cpp already supports this (`include/whisper.h`):

```c
const char * initial_prompt;
bool carry_initial_prompt; // always prepend initial_prompt to every decode window
const whisper_token * prompt_tokens;
```

Susurro does not use it today: `WhisperEngine.transcribe()` builds
`whisper_full_default_params(WHISPER_SAMPLING_GREEDY)` and never sets a prompt.

## Evidence (spike, 2026-10-02)

### Method

- Engine: `whisper-cli` built from Susurro's vendored `vendor/whisper.cpp`
  (commit `f049fff9`, libwhisper 1.9.1) — same library the app links.
- Model: the real local `~/Library/Application Support/Susurro/models/ggml-small.en.bin`.
- Audio: synthesized with macOS `say` in three voices (Samantha, Daniel,
  Fred), converted to 16 kHz mono WAV. **Caveat:** TTS is not the user's
  voice; real-voice clips must be part of acceptance testing.
- Decoding: greedy (matches the app); beam-5 spot-checked.

Test sentences (× 3 voices = 12 clips):

| ID | Sentence | Purpose |
|---|---|---|
| A | "We moved the dbt models into Dagster and the Dagster asset graph now runs nightly." | target term |
| B | "Can you check why the Dagster sensor failed on the dbt run?" | target term |
| C | "He pulled a dagger from his belt." | look-alike real word (control) |
| D | "My favorite show was Dexter's Laboratory." | sound-alike real word (control) |

Clip numbering: Samantha t0–t3, Daniel t4–t7, Fred t8–t11 (A, B, C, D in order).

### Results — baseline (no prompt; what Susurro does today)

| Clip | Output |
|---|---|
| A Samantha | We moved the DBT models into DAGSTER and the DAGSTER asset graph now runs nightly. |
| A Daniel | We moved the dbt models into **DAGSDA** and the **DAGSDA** asset graph now runs nightly. |
| A Fred | We move the DBT models into **Daxter** and the **Daxter** asset graph now runs nightly. |
| B Samantha | Can you check why the DAGSTER sensor failed on the **DBT Ron**? |
| B Daniel | Can you check why the **DAGSDA** sensor failed on the DBT run? |
| B Fred | **new check while** the **DAGSAR** sensor failed on the DBT run. |
| C (all 3) | He pulled a dagger from his belt. |
| D (all 3) | My favorite show was Dexter's Laboratory / Laboratories. |

Dagster correct-cased: **0 / 6**. Recognisably wrong: 4 / 6 (DAGSDA, Daxter,
DAGSAR). "dbt" casing wrong in 5 / 6.

### Results — prompt variants (greedy)

| Prompt | A/B: Dagster correct | dbt correct | C: dagger kept | D: Dexter kept |
|---|---|---|---|---|
| *(none)* | 0 / 6 | 1 / 6 | 3 / 3 ✅ | 3 / 3 ✅ |
| `Dagster, dbt, Snowflake, Airflow.` | 2 / 6 (Daniel A only; Samantha all-caps, Daniel B "DAGSDA", Fred "Daxter") | 6 / 6 | 3 / 3 ✅ | not run |
| `Glossary: Dagster, dbt, Snowflake, Kubernetes, Terraform.` | **6 / 6** | 6 / 6 (one "dbt Ron") | 3 / 3 ✅ | **0 / 3 ❌** ("Dagster's Laboratory") |
| `We orchestrate our dbt models with Dagster.` | **6 / 6** | 6 / 6 (one "dbt Ron") | 3 / 3 ✅ | **0 / 3 ❌** |
| `We orchestrate our dbt models with Dagster. The Dagster assets, Dagster sensors and Dagster jobs run in Dagster Cloud.` | **6 / 6** | 6 / 6 | 3 / 3 ✅ | **0 / 3 ❌** |

Beam search (`-bs 5`) with the long prompt gave identical output to greedy on
all 12 clips — no reason to change the sampling strategy for this feature.

Side benefit: the prompt also fixed Fred's B ("new check while the DAGSAR…" →
"Can you check why the Dagster…") — prompt context improves the whole
utterance, not just the target word.

### Findings

1. **Prompting works for the target term.** A prompt naming the term in a
   sentence or "Glossary:" form fixed every Dagster mis-hearing, including
   Daxter. A bare comma list was noticeably weaker (2 / 6) — the `Glossary:`
   framing or a natural sentence matters.
2. **Phonetically distinct look-alikes are safe.** "dagger" was never pulled to
   Dagster under any prompt.
3. **True sound-alikes get captured.** "Dexter" → "Dagster" in 3 / 3 under
   every effective prompt. Wording didn't help; this is inherent to biasing.
   It's the core tradeoff and drives the profile design below.
4. Casing/spelling of terms ("dbt" not "DBT") is fixed reliably as a bonus.

## Design

### 1. Vocabulary in `rules.json` (MVP)

Add an optional section to the existing rules file (already live-reloaded on
every dictation by `PostProcessor.loadRules()`):

```json
"vocabulary": {
  "enabled": true,
  "terms": ["Dagster", "dbt", "Snowflake", "Kubernetes", "Terraform"]
}
```

- Schema: add `public var vocabulary: Vocabulary?` to `PostProcessingRules`
  (optional so existing user files keep decoding). `Vocabulary { enabled:
  Bool?, terms: [String] }`.
- Prompt built as `"Glossary: " + terms.joined(", ") + "."` — the framing that
  scored 6 / 6 above. (Optionally allow a raw `prompt` string override for
  power users who want sentence-style context.)
- Users list words only; they don't write prompts.
- Ship the default `rules.json` with an empty/disabled vocabulary block plus a
  comment-style example, matching how substitutions ship disabled today.

### 2. Engine plumbing

- `WhisperEngine.transcribe(samples:prompt:)` — new optional `prompt: String?`.
  Set `params.initial_prompt` inside `prompt.withCString { … }` so the C
  pointer is valid for the duration of `whisper_full`.
- `params.carry_initial_prompt = true` so long dictations (> 30 s, multiple
  decode windows) keep the bias instead of only the first window.
- `AppDelegate` (~line 605): read the current vocabulary from the rules
  (same load as post-processing), pass the prompt into `transcribe`.
- `susurro-cli`: add `--prompt "<text>"` and `--rules <path>` so the spike
  above can be re-run through the real Swift code path.

### 3. Guardrails

- **Length cap.** whisper.cpp caps prompt context at `n_text_ctx / 2` = 224
  tokens (`src/whisper.cpp`, `max_prompt_ctx`); excess is silently truncated
  from the front. Tokenize with `whisper_tokenize` at load time; if over
  ~200 tokens, log a warning and drop terms from the end. Rough capacity
  ≈ 100–150 terms.
- **Silence hallucination.** Prompts can make whisper emit prompt words on
  near-silent clips. Existing `TranscriptFilter` handles bracket tokens only;
  add a check: if the transcript is *only* vocabulary terms / "Glossary" and
  the clip RMS is low, discard. Include a silence clip in tests.
- Keep the list curated: every term pulls its sound-alikes (finding 3), so
  the list should hold terms Susurro actually misses, not a whole tech
  dictionary.

### 4. Profiles (phase 2 — addresses the Dexter problem)

- `vocabulary.profiles: { "Work": [...], "Personal": [] }` + active profile.
- Manual: menu-bar submenu to switch profile.
- Automatic (preferred): map frontmost app bundle ID → profile
  (Slack / VS Code / Terminal / browser → Work; Messages → none). Susurro
  already captures the frontmost app PID at dictation time
  (`DictationMemory`), so the plumbing exists.

### 5. Complementary: context-aware regex rules

For residual misses, the existing `regexRules` can be made context-gated
rather than blind, e.g. only rewrite `\b(dexter|daxter|dagsda)\b` when a
nearby word is `dbt|asset|sensor|job|pipeline|run|materializ\w*`. Document
this pattern in the default rules file; no code change required.

### Rejected / deferred alternatives

- **Newer model download** — none exists for `small.en`/`medium.en`.
- **Switch to `large-v3-turbo`** (already in the catalog) — trained ~late
  2023, better on rare words, but ~1.6 GB and slower; still frozen. Worth an
  A/B on the same clips, orthogonal to this feature.
- **Fine-tuning** — needs hours of labelled audio and redoing as vocabulary
  changes.
- **LLM post-correction** — latency and risk of rewriting what was said.
- **Auto-learning from corrections** — Susurro can't observe edits in target
  apps (see `SMART_SPACING_PLAN.md` "Pivot" for why field reading fails);
  at most a manual "add last word" hotkey.

## Implementation checklist

- [ ] `PostProcessingRules.vocabulary` (optional) + decode test with old files
- [ ] Prompt builder (`Glossary: …`) + unit test
- [ ] Token-length guard via `whisper_tokenize` + test
- [ ] `WhisperEngine.transcribe(samples:prompt:)`, `carry_initial_prompt`
- [ ] AppDelegate wiring (live-reload, no restart)
- [ ] `susurro-cli --prompt / --rules`
- [ ] Fixture clips: the 12 TTS clips above + silence clip + **real-voice
      recordings** of "Dagster"/"dbt" sentences and a Dexter control; golden
      test asserting Dagster 6/6, dagger kept
- [ ] Silence-hallucination check
- [ ] Docs: README rules section, ARCHITECTURE code map, update this doc's status
- [ ] Phase 2: profiles + per-app mapping

## Appendix: reproducing the spike

```bash
# build whisper-cli from the vendored tree
cmake -S vendor/whisper.cpp -B /tmp/wcli -DCMAKE_BUILD_TYPE=Release -DWHISPER_BUILD_TESTS=OFF
cmake --build /tmp/wcli -j --target whisper-cli

# make clips
S=("We moved the dbt models into Dagster and the Dagster asset graph now runs nightly."
   "Can you check why the Dagster sensor failed on the dbt run?"
   "He pulled a dagger from his belt."
   "My favorite show was Dexter's Laboratory.")
i=0; for v in Samantha Daniel Fred; do for s in "${S[@]}"; do
  say -v $v -o t$i.aiff "$s"; ffmpeg -loglevel error -y -i t$i.aiff -ar 16000 -ac 1 t$i.wav; i=$((i+1))
done; done

# compare
M=~/Library/Application\ Support/Susurro/models/ggml-small.en.bin
for f in t*.wav; do
  echo "$f | none: $(/tmp/wcli/bin/whisper-cli -m "$M" -f $f -nt -np 2>/dev/null)"
  echo "$f | vocab: $(/tmp/wcli/bin/whisper-cli -m "$M" -f $f -nt -np \
      --prompt 'Glossary: Dagster, dbt, Snowflake, Kubernetes, Terraform.' 2>/dev/null)"
done
```
