# Contributing

Thanks for helping. mFix copies Windows 11 behavior, so the first question for any change is what Windows does. If you are not sure, say so in the issue or pull request and we can check together.

## Building

You need macOS 26 and Xcode 26. The code calls ScreenCaptureKit API that only the macOS 26 SDK has.

```sh
swift build
swift test
scripts/build.sh     # build/mFix.app, signed
scripts/dmg.sh       # build/mFix.dmg
```

`scripts/build.sh` signs ad hoc unless you have a signing certificate set up. Each ad hoc build has a new signature, so macOS asks for Accessibility and Screen Recording again after every rebuild. A self-signed certificate fixes that. See [docs/releasing.md](docs/releasing.md).

## Running it

Only run one copy of mFix at a time. Two copies fight over Cmd+Tab and over the saved state of the system shortcuts they turn off. Quit the installed app before you run your build.

Run the app from `build/mFix.app`, not straight from `.build/`, so the permissions you grant stick to the signed bundle. `MFIX_DEBUG=1` logs hotkeys, flags and focus changes:

```sh
open --env MFIX_DEBUG=1 --stderr /tmp/mfix.log build/mFix.app
```

The binary refuses any `--` flag it doesn't know and exits with status 64. That keeps a typo from starting a second copy of the app.

## Tests and checks

`swift test` covers the logic that needs no screen: the Win+Arrow transition table and the card layout math. Run it before every pull request.

The rest of mFix is about real windows, so there are also checks built into the binary. Each one runs in its own process, opens throwaway test windows where it needs them, and exits non-zero on a mismatch. These post no keyboard or mouse input:

| Flag | What it checks |
|---|---|
| `--snap-check` | Runs a Win+Arrow sequence on a test window and compares each step to the Windows table. |
| `--assist-repro` | Snaps a window, opens Snap Assist and picks the next window by id. |
| `--divider-check` | Drags the divider between four snapped test windows and checks every frame. |
| `--minimize-check` | Minimizes all but one test window and toggles them back. |
| `--pin-check` | Pins a test window on top and checks it ends up above another one. |
| `--render <dir>` | Builds the switcher, Snap Assist, the layouts flyout and the settings tabs off screen and writes them as PNGs. They show your real windows. |
| `--live-bench` | Measures the CPU and memory cost of live thumbnails. |

Run them from the debug build, for example `.build/debug/mFix --snap-check`. `--pin-check` also waits for an idle Mac first. `MFIX_CHECK_NOW=1` skips that wait.

### Checks that post input

Some checks drive the real keyboard and mouse (`--drive`, `--dock-check`, `--finder-check`, `--assist-check`). An event posted at the wrong moment lands in whatever window you are using. That can type into your files or move them.

So every check that posts input must go through `CheckGuard`. It refuses to start unless the keyboard and mouse have been idle for 10 seconds, tags every event the check posts, and stops the run the moment it sees an event without the tag. Run these checks only through `scripts/when-idle.sh`, which waits for an idle Mac and retries:

```sh
scripts/when-idle.sh --dock-check
```

A new check that posts input calls `CheckGuard.begin()` before its first event, `CheckGuard.mark` on every event and `CheckGuard.poll()` between steps. A pull request that adds one without the guard will not be merged.

## Style

Match the code around you. Comments are one line and explain a constraint the code can't show. Don't restate what the next line does.

Commits use a conventional subject under 72 characters, like `fix: keep the divider on screen with a side Dock`. Then a blank line and a few lines on why. No em-dashes in commits, docs or UI text.

One change per pull request. Fill in the template, and for anything visible describe what you saw on your own Mac.
