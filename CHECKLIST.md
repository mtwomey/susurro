# Susurro manual acceptance checklist

Run before each release (and during the dogfooding week). Automated coverage —
unit tests + fixture corpus — lives in `make test`; this list is what can't be
automated: real apps, real permissions, real hardware events.

## Core dictation

- [ ] Dictate into: Slack, a terminal, a browser text field, Notes
- [ ] Dictate into a full-screen app — overlay appears above it, focus unmoved
- [ ] Dictate into a password field — expect no typed text (secure input blocks
      synthetic keystrokes); transcript lands on the clipboard with a toast,
      even with the clipboard toggle off
- [ ] Clipboard toggle off (default): dictating leaves existing clipboard
      contents untouched; toggle on: transcript is copied
- [ ] Rapid dictations back-to-back — no overlap, no dropped transcripts
- [ ] Hold key, say nothing, release — nothing typed (hallucination filter)
- [ ] Very long dictation (60s+) — transcript complete, memory returns to baseline

## Recording indicators

- [ ] Overlay shows/hides with the key; waveform tracks voice; timer counts
- [ ] System mic pill and orange dot appear during recording, vanish after

## Resilience

- [ ] Close laptop lid mid-idle, reopen — hotkey still works (event tap survives)
- [ ] Switch default mic (connect/disconnect AirPods) while idle — next dictation works
- [ ] Disconnect mic mid-recording — "Recording interrupted" toast, no crash
- [ ] Corrupt/delete active model file, relaunch — falls back or shows clear error
- [ ] Revoke Accessibility in System Settings — menu reflects it, re-grant recovers

## Settings

- [ ] Switch PTT key; dictate with new key; old key inert; survives relaunch
- [ ] Model switch mid-session; dictation uses new model (listen for accuracy change)
- [ ] Edit rules.json (add a substitution), dictate — applies without restart
- [ ] AI Cleanup on: long dictation cleaned; short dictation instant; off: raw
- [ ] Start at Login on → reboot → Susurro present and working
- [ ] Help… window opens, and its content matches the current menu items
- [ ] Fresh launch: menu briefly shows "Loading model…" (or "Downloading
      model…" on first run), then that item disappears once the model is
      ready — no lingering "Start Test Recording" item
- [ ] Revoke Microphone permission, relaunch: menu shows "Mic access denied
      — click to open Settings"; clicking opens System Settings
- [ ] About Susurro (bottom of menu, under its own divider) shows the
      correct installed version number

## Smart Spacing (opt-in, default off)

Self-tracked (Susurro remembers what *it* typed and where — no field read).
See SMART_SPACING_PLAN.md for why an earlier Accessibility-based design was
abandoned (it silently did nothing in Electron apps, browsers, and Terminal).

- [ ] Toggle on: dictate anything, then dictate again into the same field
      without switching apps — a space appears before the new text,
      regardless of what the first dictation ended with (letter, digit,
      comma, `.`, `!`, `?`, closing quote/paren — all the same now)
- [ ] Dictate something ending in a space you said explicitly (or that
      already ends in whitespace) — no doubled-up space
- [ ] Toggle off (default): no behavior change at all vs. today
- [ ] Works the same in TextEdit/Notes, in an Electron app (Slack, VS Code,
      or this app itself), in Terminal, and in a browser text field — this
      is the whole point of the self-tracking redesign; regressions here are
      the highest-priority thing to catch
- [ ] Dictate, then switch to a different app, then switch back and dictate
      again — no space (memory resets on app switch, as designed)
- [ ] Dictate, then manually type or delete characters by hand, then dictate
      again — Susurro won't notice the manual edit (documented limitation,
      not a bug); confirm this doesn't crash or misbehave, just doesn't
      account for the hand-typed change
- [ ] First dictation after launch (nothing typed yet this session) — no
      space, no crash
- [ ] Password field — unaffected; typing still blocked/copied as before,
      and the memory is cleared rather than recording secure-field content

## Fresh-machine install (before sharing)

- [ ] New user account: install per README, reach working dictation without terminal
