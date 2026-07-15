# Echo Cancellation (Voice Processing I/O) — investigation notes

> Status: **prototyped, parked, not merged.** Lives on branch
> `prototype-voice-processing-aec` (commit `3547b1c`), intentionally left
> as-is rather than merged or deleted, in case it's worth resuming later.
> This document exists independent of whether that branch survives — the
> debugging journey and trade-offs below are the valuable part, more than
> the code itself.
>
> Tested on: MacBook Pro (M2 Pro), macOS 26.5.1, built-in microphone.
> Findings about channel layout, timing, and ducking behavior are from
> this one machine/OS combination and may not generalize.

## Goal

Apple's Voice Processing I/O (the same system audio unit FaceTime/Zoom/Teams
build on) bundles acoustic echo cancellation, noise suppression, and
automatic gain control. The idea: expose it as an experimental, off-by-default
menu toggle ("Echo Cancellation (Experimental)"), so dictating while other
audio plays through the Mac's built-in speakers doesn't pick up an echo of
that audio. It only helps in that specific scenario — headphones/AirPods have
nothing bleeding into the mic to cancel in the first place.

Capture must stay on `AVAudioEngine.inputNode` regardless of this feature —
see `PLAN.md`'s "mic-mode pill" section for why (ScreenCaptureKit was tried
and rejected for a different feature, for Control Center pill + latency
reasons). This investigation never touched that constraint.

## tl;dr — current state on the branch

- Echo cancellation **works**: real, correctly-captured audio, verified via
  headless self-test and live dictation.
- It adds **no extra per-recording latency** (down from an initial
  measured ~250-400ms penalty).
- It has **one unresolved rough edge**: enabling it causes macOS to duck
  (quiet down) other apps' audio, and that duck doesn't fully lift between
  recordings — only reduced, not eliminated. See "The ducking trade-off"
  below.
- Noise suppression/AGC's effect on whisper transcription accuracy was
  **never A/B tested** — this prototype only validated that real audio
  gets captured, not that it transcribes better or worse than the plain
  path.

## The debugging journey

Enabling voice processing via `input.setVoiceProcessingEnabled(true)` makes
`AVAudioEngine.inputNode.outputFormat(forBus: 0)` report a non-standard
format — on this hardware, **9 channels @ 48 kHz** — instead of the normal
1-channel format. Every attempt below was really about coping with that one
surprise; each seemed reasonable and failed for a different, informative
reason.

**Attempt 1 — raw tap + `AVAudioConverter`.** Tap `inputNode` directly at the
bogus 9-channel format, feed straight into an `AVAudioConverter` targeting
16 kHz mono (same converter the plain path already uses). Result: converter
output was exactly 0.0 peak, silence. Raw *pre-conversion* buffers also
showed only near-noise-floor peaks (~0.001) on all 9 channels, even while
someone was actively talking. This exact symptom — enabling voice processing
explodes a clean 1-channel input into a bogus multichannel layout that
downstream code can't handle — is independently documented in at least two
unanswered Apple Developer Forums threads (one saw 3 channels, another 7; we
saw 9). Nobody in either thread had a confirmed fix.

**Attempt 2 — `AVAudioMixerNode` downmix.** The forum consensus/guess was
that `AVAudioConverter` can't downmix this layout but `AVAudioMixerNode` is
built for arbitrary channel counts. Attach a dedicated mixer, connect
`input → mixer → mainMixerNode` (mixer must reach a real render path to be
pulled by the engine at all), mute `mainMixerNode.outputVolume = 0` so the
mic-to-speaker path isn't audible, tap the mixer for the mono buffer. Three
variants of the `mixer → mainMixerNode` connection format were tried —
forced mono, `nil` (auto-negotiate), and mainMixerNode's own queried
format — and **all three failed identically**: `engine.start()` threw
`Error -10875 "PerformCommand(*outputNode, kAUInitialize...)"` on the first
attempt in a fresh process, and a second attempt (same code, no changes)
"succeeded" but delivered exactly 0.0 peak on the mixer's tap. Changing the
connection format never changed the outcome — strong evidence the format
choice was never the actual cause.

**Root cause of the `-10875`, found via research, not guessing:** Apple's
own header docs for `setVoiceProcessingEnabled` state voice processing
requires *both* input and output nodes to be in voice-processing mode —
enabling it on one automatically enables it on the other, since it's really
one bidirectional audio unit. The literal CoreAudio diagnostic text behind
`-10875` is `"client-side input and output formats do not match"`. Whatever
fed into `outputNode` (via `mainMixerNode`) had to match the input's own
(bogus 9ch/48kHz) format for the unit to initialize — an app that's never
used its output path for anything before (Susurro is capture-only) doesn't
naturally satisfy that.

**Attempt 3 — `AVAudioSinkNode`.** Apple's newer (macOS 14+/iOS 15+) node
type built to terminate a render chain without needing to reach real
hardware output. Swap the mixer's downstream connection from
`mainMixerNode` to a sink node. Result: **fixed the `kAUInitialize` throw**
(both start/stop cycles succeeded cleanly) but the sink's buffers were
**still exactly 0.0 peak**, identical to attempt 2. This decoupled the two
symptoms — the initialization failure and the silence were never the same
bug.

**Attempt 4 — force a genuinely active output element.** Hypothesis: the
shared voice-processing unit needs its output element actively *rendering*
(not just connected-but-muted, and not absent) to unlock real gain on the
input side. Added a second `AVAudioPlayerNode` looping true digital silence
(memset zero, not just muted volume) through the real hardware output,
alongside the sink-node capture graph. Result: this alone reintroduced the
`-10875` throw (confirming *anything* touching real output while VP is
enabled risks it, independent of the capture graph), and even once past
that throw, capture was **still exactly 0.0 peak**. This falsified the
"output must be actively engaged" hypothesis.

**Attempt 5 — explicit device pinning.** Hypothesis: `AVAudioEngine`'s
default input device silently resolved to some aggregate/virtual device,
explaining the anomalous channel count. Pinned the underlying audio unit to
the verified built-in mic via `kAudioOutputUnitProperty_CurrentDevice` and
CoreAudio device enumeration. Result: pinning worked (verified device
match) but the format was still 9ch/48kHz and capture was still 0.0 peak —
falsified. Side finding: calling `AudioUnitSetProperty` here also
reintroduced flakiness on a second start/stop cycle in the same process,
so it was reverted rather than layered on top of anything.

**Attempt 6 (working) — bypass automatic downmixing entirely.** The one
common thread across every failed attempt: something was always asked to
*automatically mix* the 9 channels down to mono — a mixer node, a sink
node fed by a mixer, an `AVAudioConverter`. `AVAudioFormat(channels: 9)`
with no explicit `AVAudioChannelLayout` produces an "unspecified/discrete"
layout, and both `AVAudioMixerNode` and `AVAudioConverter` silently fall
back to zeroed output for channel maps they don't recognize — independent
of render-graph topology. The fix: stop asking anything to mix. Tap
`inputNode` directly at its own native (odd) format — mechanically
identical to how the plain path already taps it — then in the tap callback,
manually inspect every one of the 9 channels' peak per buffer and `memcpy`
(never sum/average) whichever channel is loudest into a genuine mono
buffer. That mono buffer feeds the same `AVAudioConverter` + `process()`
the plain path already uses, for the 16 kHz sample-rate step only (a
1-channel-to-1-channel conversion, so the converter's own channel-matrix
logic is never invoked either).

This produced real, consistently non-zero signal across repeated
start/stop cycles, confirmed via a headless self-test harness (a temporary
executable target that ran `AudioRecorder` directly while `afplay` played a
real speech fixture through the speakers, so hypotheses could be tested in
~15 seconds without needing a human to talk into the mic every time — worth
recreating if this work resumes) and then via live dictation.

Interesting secondary finding: all 9 reported channels carried *identical*
content on this hardware — likely a duplicated/broadcast layout rather than
9 distinct microphone signals. The implementation picks the loudest channel
once per recording (not re-picked every buffer) specifically because, on
hardware where the channels genuinely differ, re-picking per buffer could
audibly click at each switch — untested, since this machine's channels
never actually differed.

## Latency: enable once vs. enable every time

The first working version called `input.setVoiceProcessingEnabled(true)`
in `start()` and `setVoiceProcessingEnabled(false)` in `stop()` — every
single recording. Measured cost via temporary timing instrumentation
(real push-to-talk presses, not synthetic):

| | `start()` returns | first audio captured |
|---|---|---|
| Plain path (steady state) | ~78ms | ~183ms |
| VP, enabled/disabled every press | ~260-540ms | ~364-647ms |

That's roughly **250-400ms added to every single push-to-talk press**,
and it didn't amortize — the worst measurement was the *second* press, not
the first, ruling out simple one-time warm-up.

Fix: reconcile the audio unit's actual VP state against the desired
(toggled) state only in `start()`, only when they differ — i.e., only
pay the reconfiguration cost when the user actually flips the menu item,
not on every recording. `stop()` no longer disables voice processing at
all; it stays applied on `inputNode` across multiple recordings. This is
safe per Apple's own documented constraint that VP's format can only
change while the engine is stopped — which it always is at the point
`start()` reconciles, since `stop()` always leaves it that way.

Result after the fix: steady-state VP recording latency matched the plain
path (~80ms / ~190ms) — the toggle cost is paid once, at the moment of
toggling, not on every press.

## The ducking trade-off (unresolved, current state on branch)

The latency fix above has a side effect: macOS automatically ducks other
apps' audio playback while voice processing is engaged (the same behavior
FaceTime/Siri dictation have). Before the latency fix, this ducked and
un-ducked correctly on every press (since VP was fully disabled in every
`stop()`). After the latency fix, since VP now stays *configured* on the
input node continuously between recordings, the duck engaged on first
press and **did not lift on key release** — only when the feature was
toggled off entirely in the menu. This means ducking tracks whether voice
processing is configured on the node, not whether the engine is actively
rendering — `engine.stop()` alone isn't enough to un-duck.

Attempted mitigation: `AVAudioVoiceProcessingOtherAudioDuckingConfiguration`
(macOS 14+/iOS 17+), a documented API for exactly this — set once alongside
enabling VP:

```swift
var duckingConfig = AVAudioVoiceProcessingOtherAudioDuckingConfiguration()
duckingConfig.duckingLevel = .min
engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration = duckingConfig
```

Apple's API only exposes discrete levels (`.default`/`.min`/`.mid`/`.max`)
— there is no documented "off" switch. Real-world result on this hardware:
**noticeably reduced, but not eliminated.** The user's own verdict after
listening: "very little... but still noticeable."

**The actual unresolved trade-off, as it stands on the branch:**

| | Per-press latency | Ducking |
|---|---|---|
| Toggle VP on `start()`/off on `stop()`, every press | +250-400ms every press | Correct — ducks and un-ducks each press |
| Toggle VP only when the feature is flipped (current branch state) | None (matches plain path) | Reduced via `.min`, but still audible; doesn't fully lift between presses |

No option found eliminates both costs simultaneously. Resuming this work
should start by deciding which of these two feels worse in practice, or by
looking for a third option (e.g., disabling VP after some idle timeout
following `stop()`, rather than immediately or never — untried).

## Other findings worth knowing before resuming

- **Real apps mostly don't use this Apple API at all.** Research turned up
  that Chrome/WebRTC's macOS backend confirmed does *not* use
  `kAudioUnitSubType_VoiceProcessingIO` — it uses raw CoreAudio HAL APIs
  plus WebRTC's own AEC3 software echo-cancellation module, working from
  a self-supplied reference of whatever it's itself playing. This covers
  Discord and Teams' web/Electron calling stacks too (both WebRTC-derived).
  Zoom is reported (softer, non-code-level evidence) to ship its own
  proprietary DSP rather than delegate to a platform API. The "surely
  this is possible, other apps do it" intuition was right that AEC is
  achievable, just not evidence that *this specific Apple API* is the
  well-trodden path — it may be a much less-traveled one.
- **Noise suppression/AGC's effect on whisper accuracy is unverified.**
  This investigation only confirmed real audio gets captured, not whether
  the bundled noise suppression helps or hurts transcription quality
  compared to the plain path. Needs a real before/after comparison.
  Bundled with AEC — Apple's API doesn't let you enable one without the
  others.
- **Headphones make this a no-op.** Nothing bleeds from speakers into the
  mic if you're on headphones/AirPods, so the toggle has nothing to
  cancel in that case.
- **Repeated start/stop correctness matters.** State that must reset
  cleanly between recordings: `isVoiceProcessingActive`,
  `appliedVoiceProcessingState`, `pinnedVPChannel`. Failure-path cleanup
  (format-construction guards, `engine.start()` throwing) must also revert
  `appliedVoiceProcessingState` so a retry re-applies VP rather than
  assuming it's already on.
- **A headless self-test harness was the single most valuable debugging
  tool here.** A temporary executable target instantiated `AudioRecorder`
  directly, toggled VP, and ran multiple start/stop cycles while `afplay`
  played a real speech fixture (`Fixtures/clip1.wav`) through the Mac's
  speakers — reproducing the bug and testing fixes in ~15 seconds without
  needing a human to talk into the mic each time. It was removed once the
  fix was confirmed (to keep the shipped diff clean), but the technique —
  and the fixture files, still in the repo — are worth recreating if this
  resumes.

## How to resume

1. `git checkout prototype-voice-processing-aec` (or cherry-pick
   `3547b1c` onto a fresh branch if `main` has moved on significantly).
2. Decide on the ducking/latency trade-off above before doing anything
   else — it's the one open question blocking a real ship decision.
3. If pursuing further, recreate the `vp-diagnostic`-style headless
   harness (see git history on this branch for the exact implementation)
   before making changes — it made iteration dramatically faster than
   testing by hand every time.
4. A/B whisper transcription accuracy with VP on vs. off, since that was
   never actually measured.
