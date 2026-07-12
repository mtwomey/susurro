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

## Fresh-machine install (before sharing)

- [ ] New user account: install per README, reach working dictation without terminal
