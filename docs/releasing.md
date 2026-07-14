# Releasing Susurro

This document covers the full release process: building the distributable zip,
publishing a GitHub Release, and keeping the Homebrew tap in sync.

## Prerequisites

- `../homebrew-susurro` must exist as a sibling directory:
  ```bash
  git clone https://github.com/mtwomey/homebrew-susurro ../homebrew-susurro
  ```
- `gh` CLI must be authenticated (`gh auth status`)
- whisper.cpp static libs already built (`make whisper` — only needed once, or after submodule update)

---

## Step 1 — Bump the version

Edit `Support/Info.plist` and increment `CFBundleShortVersionString`:

```xml
<key>CFBundleShortVersionString</key>
<string>0.1.7</string>
```

Also bump `CFBundleVersion` (integer build number) if desired.

---

## Step 2 — Run `make release`

```bash
make release
```

This single command:

1. Runs `make dist` — compiles a release build, assembles `build/Susurro.app`,
   and zips it to `build/Susurro-<version>.zip`
2. Reads the version from `Info.plist` automatically
3. Computes the SHA256 of the zip
4. Patches `version` and `sha256` in `../homebrew-susurro/Casks/susurro.rb`

When it finishes you'll see:

```
Version : 0.1.7
SHA256  : abc123...
✓ Updated ../homebrew-susurro/Casks/susurro.rb

Next steps:
  1. Upload build/Susurro-0.1.7.zip to a new GitHub release tagged v0.1.7
  2. cd ../homebrew-susurro && git diff   # verify the cask changes
  3. git -C ../homebrew-susurro commit -am 'Bump to 0.1.7' && git push
```

---

## Step 3 — Create the GitHub Release

Upload the zip to a new GitHub Release. Using the `gh` CLI:

```bash
gh release create v0.1.7 build/Susurro-0.1.7.zip \
  --title "Susurro 0.1.7" \
  --generate-notes
```

`--generate-notes` auto-populates the release notes from commits since the last
tag. Edit them in the browser afterward if you want to add highlights.

Alternatively, create the release in the browser at
https://github.com/mtwomey/susurro/releases/new and upload the zip manually.

---

## Step 4 — Push the Homebrew tap

```bash
cd ../homebrew-susurro
git diff                                      # verify version + sha256 look right
git commit -am "Bump to 0.1.7"
git push
```

Once pushed, `brew upgrade --cask susurro` will pick up the new version for
anyone who already has it installed.

---

## Summary

| Step | Command |
|------|---------|
| Bump version | Edit `Support/Info.plist` |
| Build + update tap | `make release` |
| Publish GitHub Release | `gh release create v<ver> build/Susurro-<ver>.zip --title "Susurro <ver>" --generate-notes` |
| Push tap | `cd ../homebrew-susurro && git commit -am "Bump to <ver>" && git push` |

---

## Why the tap is a separate repo

Homebrew requires taps to live in their own repository (`homebrew-<name>`) so
that `brew tap mtwomey/susurro` can add it as a remote. Keeping the cask
separate also means a bad release doesn't require touching the main app repo —
you can roll back the tap independently if needed.

## Why the app isn't notarized

Notarization requires an Apple Developer Program membership ($99/year).
Susurro is distributed as a self-signed build. Homebrew's `--cask` installer
strips the quarantine flag automatically, so users installing via Homebrew
never see the Gatekeeper warning. Users installing manually from the zip need
the "Open Anyway" step documented in the README, or can run:

```bash
xattr -dr com.apple.quarantine /Applications/Susurro.app
```
