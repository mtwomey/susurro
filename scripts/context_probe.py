#!/usr/bin/env python3
"""Live context probe harness (BEA-677).

Drives a scratch TextEdit document through the running Susurro's real
pre-insert pipeline (FocusedFieldReader + InsertContext.resolve +
TextHandlingStage) via the dev probe hook. Nothing is typed by Susurro; the
harness only sets the scratch document's text with AppleScript and presses
the probe hook moves the scratch field's caret to its end through
Accessibility. TextEdit does NOT need to be frontmost (AX reads each app's own
focused element), so the harness never sends keys to the app the user is in.

Prereq: defaults write com.mtwomey.susurro DevFeedHook -bool YES; relaunch.
  python3 scripts/context_probe.py
"""
import json, os, subprocess, sys, time

PROBE = os.path.expanduser("~/Library/Logs/Susurro/probe.json")
TARGET = "com.apple.TextEdit"

# Cross-dictation guard against the live field: (field text, what Susurro
# "typed" last, expected verdict). Edited / extra text must never be eligible.
XJOIN = [
    ("Notes: Yesterday I went to the store.", " Yesterday I went to the store.", "eligible"),
    ("Yesterday I went to the shop.", " Yesterday I went to the store.", "edited"),
    ("Yesterday I went to the store. ", " Yesterday I went to the store.", "edited"),
    ("Yesterday I went to the store", " Yesterday I went to the store.", "edited"),
    ("Are you coming?", " Are you coming?", "no_period"),
]

# (field text before the cursor, transcript, expected stage output)
CASES = [
    ("", "hello there.", "Hello there."),                       # empty field: no leading space (BEA-673)
    ("Hello there.", "and bought bananas.", " And bought bananas."),  # after a sentence end
    ("Yesterday I went", "to the store.", " to the store."),     # mid-sentence: lower case
    ("Trailing space ", "next words.", "Next words." ),          # placeholder; fixed below
    ("First line.\n", "second line.", "Second line."),           # start of a line: no space
]
# After "Trailing space " (no end mark) the sentence continues: lower case, no extra space.
CASES[3] = ("Trailing space ", "next words.", "next words.")


def osa(script):
    return subprocess.run(["osascript", "-e", script], capture_output=True, text=True).stdout.strip()


def frontmost():
    return osa('tell application "System Events" to get bundle identifier of first process whose frontmost is true')


def probe(before, payload):
    osa('tell application "TextEdit" to set text of front document to ' + json.dumps(before))
    time.sleep(0.3)
    if os.path.exists(PROBE):
        os.remove(PROBE)
    subprocess.run(["swift", "-e",
                    'import Foundation; DistributedNotificationCenter.default().postNotificationName('
                    '.init("com.susurro.dev.probe"), object: CommandLine.arguments[1], userInfo: nil, '
                    'deliverImmediately: true)', f"{TARGET}|end|{payload}"], check=True)
    for _ in range(30):
        if os.path.exists(PROBE):
            time.sleep(0.05)
            break
        time.sleep(0.1)
    return json.load(open(PROBE)) if os.path.exists(PROBE) else {"error": "no probe result (hook off?)"}


def main():
    subprocess.run(["open", "-g", "-a", "TextEdit"], check=True)  # -g: stay in background
    osa('tell application "TextEdit" to make new document')
    time.sleep(1.0)
    fails = 0
    for before, transcript, expected in CASES:
        res = probe(before, transcript)
        ok = res.get("output") == expected
        fails += not ok
        print(f"{'PASS' if ok else 'FAIL'} before={before!r} -> {res.get('output')!r} (want {expected!r}) "
              f"source={res.get('source')} provider={res.get('provider')} {res.get('error', '')}")
    for before, prev, expected in XJOIN:
        res = probe(before, f"prev={prev}|next words.")
        ok = res.get("xjoin") == expected
        fails += not ok
        print(f"{'PASS' if ok else 'FAIL'} xjoin field={before!r} prev={prev!r} -> {res.get('xjoin')} (want {expected})")
    osa('tell application "TextEdit" to close front document saving no')
    total = len(CASES) + len(XJOIN)
    print(f"{total - fails}/{total} passed")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
