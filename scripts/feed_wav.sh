#!/bin/sh
# Feed WAV files into the running Susurro as separate push-to-talk dictations
# (BEA-677 dev hook). Susurro types each clip ONLY if TARGET_BUNDLE is the
# frontmost app; otherwise it refuses (logged). Enable the hook once with:
#   defaults write com.mtwomey.susurro DevFeedHook -bool YES   (then relaunch)
# Usage: scripts/feed_wav.sh --target com.apple.TextEdit [--gap SECONDS] a.wav [b.wav ...]
# Bring the target to the front yourself first: macOS may refuse a scripted
# `activate` while another app is in use, and then nothing is typed.
gap=3; target=
while [ $# -gt 0 ]; do
  case "$1" in
    --gap) gap=$2; shift 2 ;;
    --target) target=$2; shift 2 ;;
    *) break ;;
  esac
done
[ -n "$target" ] || { echo "usage: $0 --target <bundle id> [--gap s] a.wav ..." >&2; exit 2; }
for f in "$@"; do
  path=$(cd "$(dirname "$f")" && pwd)/$(basename "$f")
  swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("com.susurro.dev.feedWAV"), object: CommandLine.arguments[1], userInfo: nil, deliverImmediately: true)' "$target|$path"
  sleep "$gap"
done
