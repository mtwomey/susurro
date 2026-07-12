# Susurro — Development Guide

Everything needed to resume development on a fresh machine (or with a fresh
AI assistant). Read `ARCHITECTURE.md` first for the code map and constraints.

## Setting up a development machine

Prerequisites: Apple Silicon Mac, macOS 15+ (26+ to work on AI Cleanup),
Xcode (full install, not just CLT — needed for the macOS SDK), cmake
(`brew install cmake`), gh CLI for releases (`brew install gh`).

```bash
git clone --recurse-submodules https://github.com/mtwomey/susurro
cd susurro
make whisper     # builds vendored whisper.cpp static libs (~1 min, once)
make test        # golden + unit tests should pass before you change anything
make run         # build, bundle, launch
```

### Signing identity (important — do this before iterating)

macOS ties Accessibility/mic permission grants to the app's code signature.
Ad-hoc signatures (`codesign -s -`) change on every rebuild, which resets the
grants and makes iteration miserable. Create a stable self-signed identity
named **Susurro Dev** (the Makefile's `SIGN_ID`):

```bash
cat > /tmp/cert.conf <<'EOF'
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = Susurro Dev
[ ext ]
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
basicConstraints = critical,CA:false
EOF
openssl req -x509 -newkey rsa:2048 -keyout /tmp/s.key -out /tmp/s.crt -days 3650 -nodes -config /tmp/cert.conf
# NOTE: -legacy is required with OpenSSL 3.x or the keychain import fails
openssl pkcs12 -export -legacy -inkey /tmp/s.key -in /tmp/s.crt -out /tmp/s.p12 -passout pass:susurro -name "Susurro Dev"
security import /tmp/s.p12 -k ~/Library/Keychains/login.keychain-db -P susurro -T /usr/bin/codesign
security add-trusted-cert -p codeSign -k ~/Library/Keychains/login.keychain-db /tmp/s.crt
security find-identity -v -p codesigning   # should list "Susurro Dev"
```

If you skip this, edit `SIGN_ID` in the Makefile to `-` (ad-hoc) and expect
permission re-grants after rebuilds.

## Make targets

| Target | What |
|---|---|
| `make whisper` | cmake-build vendored whisper.cpp → `build-whisper/` (rerun after submodule bumps) |
| `make app` | swift build + assemble `build/Susurro.app` + sign |
| `make run` | `make app` + relaunch |
| `make test` | swift test (goldens, filters, rules config) |
| `make install` | deploy to `/Applications` + relaunch from there |
| `make dist` | zip for distribution (version from Info.plist) |
| `make clean` | remove `.build/` and `build/` |

## Testing

- **Unit/golden tests** (`make test`): PostProcessor goldens are pinned to the
  output of the retired Python implementation (`~/Git_Repos/ptt`,
  `nemo_itn_daemon.py:apply_verbal_punctuation`) with two documented
  divergences (newline works, single backslash). Don't "fix" goldens casually.
- **Corpus regression**: `.build/release/susurro-cli <model.bin> Fixtures/*.wav`
  — expected transcripts live in the golden tests / git history. When a
  real-world mishear matters, record a clip into `Fixtures/` and note the
  expected text.
- **Manual acceptance**: `CHECKLIST.md`, run before each release. The
  "fresh user account install" line is the one that catches packaging bugs
  (0.1.0 shipped broken because it was skipped).

## Debugging

- Terminal launch shows live logs: `./build/Susurro.app/Contents/MacOS/Susurro`
  (all app logs use the `[susurro]` NSLog prefix; via `log show` the content is
  privacy-redacted, so prefer direct launch).
- `kill -USR1 $(pgrep -x Susurro)` toggles recording — scripted end-to-end
  tests without touching the hotkey.
- Watch permission attribution: `log stream --predicate 'process == "tccd"'`.
- Control Center indicator decisions: subsystem `com.apple.cameracapture`
  in ControlCenter's log (see PLAN.md mic-pill investigation for the method).

## Cutting a release

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Support/Info.plist`
2. `make test` + run CHECKLIST.md (including a fresh-user-account install!)
3. Commit, push
4. `make dist`
5. `gh release create v0.x.y build/Susurro-0.x.y.zip --title "Susurro 0.x.y" --notes-file <notes.md>`
6. Release notes: lead with user-visible changes; include the install steps
   (unnotarized build = "Open Anyway" instructions); if a prior release is
   broken, edit its notes with a warning banner (`gh release edit`)

Distribution is currently self-signed (rung 1). Moving to Developer ID +
notarization (`notarytool`) removes the "Open Anyway" step — see the
"Packaging" discussion in PLAN.md / README.

## Where future work is parked

`PLAN.md` bottom: v2 parking lot (overlay text preview, history, per-app
formatting, custom PTT key capture flow, streaming AI cleanup, notarization)
and the mic-pill investigation record. The predecessor Python implementation
lives in `~/Git_Repos/ptt` (local only) for reference; it is retired
(`make install` there resurrects it if ever needed).
