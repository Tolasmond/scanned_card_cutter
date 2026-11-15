# AGENTS.md

Guidance for coding agents working on Scan Tool. Read `README.md` first: it covers the workflow, the controls and the source layout.

## Ground rules

- **Only what ships with Odin.** Use `core:` and `vendor:raylib`/raygui. Don't add third-party libraries, Python, ImageMagick or any other external program to the app or its build. Image algorithms belong in `src/imaging/` as pure Odin, with unit tests.
- **Cross-platform.** The app must keep building on Windows, macOS and Linux. The record/replay harness uses only raylib, so it should work on all three; so far it has only been run on Linux.
- **Keep the workflow simple:** one scan per session. There are no projects, autosave or export history, by design.

## Build and check

```sh
./build.sh            # optimized build -> build/scan_tool
./build.sh debug      # bounds checks and symbols
./build.sh test       # imaging unit tests (headless)
./build.sh replay     # replay tests (opens a window, needs a display)
```

All builds use `-vet -strict-style`. A change is done when `./build.sh test` and `./build.sh replay` both pass.

## The replay harness

`src/replay.odin` records input frame by frame with raylib's automation events and plays it back. A replay ends with a state dump: settings, each card's corners, the selection and the status line. The runner compares that dump and every exported PNG with the saved expected results.

```sh
build/scan_tool --record FILE.rec [--out DIR] SCAN.png     # closing the window saves
build/scan_tool --replay FILE.rec [--out DIR] [--dump STATE.txt] [--fast]
```

Exit codes: 0 done, 1 could not write the recording or dump, 2 bad arguments or an unreadable recording, 3 the replay window size differs from the recording, 4 the replay timed out waiting for previews or export.

### Running the tests

`./build.sh replay` replays every `tests/replay/*.rec` with `--fast` into a temporary folder and diffs it against `tests/replay/NAME.expected/` (`state.txt` plus the exported PNGs). A replay needs no input from you. It opens a floating window, runs, and exits on its own.

When a replay fails, read the diff. A `state.txt` difference shows which card or setting changed, and a PNG difference means the export pipeline's output changed.

- **Unintended change:** fix the code.
- **Intended change** (for example, an improved resampler): run `./build.sh replay --update`, then tell the user which expected results changed and why. Never update expected results just to make a failure go away.

### Adding a test

1. Put a small scan in `tests/replay/` (a synthetic one is fine; keep committed scans small). Use an empty scratch folder for `--out`.
2. Run `build/scan_tool --record tests/replay/NAME.rec --out SCRATCH/out tests/replay/SCAN.png`, use the app, and close the window. The console says `recorded N events over M frames`. Input can come from a person or from any tool that drives the window.
3. Replay with `--dump` and check that the dump and the exported PNGs show what was intended. The replay's exports must be byte-identical to the live session's.
4. Delete the `out` line from the `.rec` file (the runner passes its own `--out`), keep the `scan` line relative to the recording (`scan SCAN.png`), then run `./build.sh replay --update`.

### What a recording cannot capture

- **Text typed into the panel's text and number boxes.** raylib records keys, not the characters they produce. Set the output folder with `--out` and leave other values at their defaults.
- **OS key repeat.** Send a key several times instead of holding it.
- **Dropped files, and the file browser's dependence on what's on disk.** Pass the scan on the command line.
- **A resized window.** Recording stops at the resize, and a replay at another size exits with code 3.
- **Touchpad smooth scrolling,** which is rounded to whole wheel steps.
