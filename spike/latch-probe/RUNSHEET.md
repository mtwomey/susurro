# BEA-689 gap-probe run sheet

Build (binaries go to scratch, never $TMPDIR):

    S=~/.hermes/cache/scratch/bea689; mkdir -p $S
    swiftc -O probe2.swift -o $S/probe2; swiftc -O chordtap.swift -o $S/chordtap

Every `bg`/`front` run activates the target app (and `bg` then Finder): **it steals focus**.
Matthew is told first and keeps hands off the keyboard while it runs. The caret must already be
in a throwaway field; the probe writes into whatever is focused in the target.

| Target | Throwaway field | Command(s) |
|---|---|---|
| Slack `com.tinyspeck.slackmacgap` | self-DM composer, empty; never press Return | `bg`, `front` |
| Hermes desktop (bundle id from `osascript -e 'id of app "Hermes"'`) | fresh empty chat | `bg`, `front` |
| Warp `dev.warp.Warp-Stable` | fresh tab, empty prompt | `read`, `bg`, `front` |
| Terminal `com.apple.Terminal` | fresh window, empty prompt | `read` (criterion 2) |
| VS Code `com.microsoft.VSCode` | untitled file, Stage Manager off | `bg`, `front` |
| Zen `app.zen-browser.zen` | `react-test.html` (textarea, then contenteditable) | `bg`, `front`; read the page log + React state |
| Obsidian `md.obsidian` | scratch note, deleted afterwards | `bg` (read-back re-check) |
| TextEdit / Notes | new untitled doc / new note, deleted afterwards | `bg`, `front` |

`bg` prints C1 (AX write / postToPid landed, by read-back), C2 (value + range readable),
C3 (element valid, caret unmoved after focus left), C4 undo (background Cmd+Z), and verifies cleanup.
`front` runs `TRIALS` (default 10) frontmost AX writes and classifies each as all / none / partial / double.
Exit 3 = cleanup not verified; fix by hand before moving on.

Chord: `$S/chordtap 20`, hold rightOption, tap Cmd 3x, release; then the same with TextEdit,
Slack, Zen, VS Code frontmost and watch for any app reaction to Opt+Cmd with no key.
