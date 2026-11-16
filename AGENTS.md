# AGENTS.md

Guidance for coding agents working on Scanned Card Cutter. Read `README.md` first, then the docs it links: `doc/usage.md` (workflow and controls), `doc/development.md` (building, tests, benchmarks and the baseline) and `doc/arch.md` (source layout and pipelines).

## Ground rules

- **Only what ships with Odin.** Use `core:` and `vendor:raylib`/raygui. Don't add third-party libraries, Python, ImageMagick or any other external program to the app or its build. Image algorithms belong in `src/imaging/` as pure Odin, with unit tests. The one bundled third-party file is the Inter font in `assets/fonts/` (SIL OFL 1.1, license alongside), compiled in with `#load`. It is data, not code. Don't load fonts from the system.
- **One exception: the user's scanner command.** *Scan* runs a command the user writes in `scanners.ini` (`src/scanner.odin`). Nothing ships with the app or depends on it, and without the file the app is unchanged. Keep it that way: don't bundle, require or default to any scanning program, and add support for another scanner as an example profile, not code.
- **Cross-platform.** The app must keep building on Windows, macOS and Linux. The record/replay harness uses only raylib, so it should work on all three; so far it has only been run on Linux.
- **Keep the workflow simple:** one scan per session. There are no projects, autosave or export history, by design.

## Build and check

```sh
./build.sh            # optimized build -> build/scanned_card_cutter
./build.sh debug      # bounds checks and symbols
./build.sh test       # imaging, app (src) and synthetic-scan unit tests (headless)
./build.sh replay     # replay tests (opens a window, needs a display)
./build.sh check      # all of the above plus the debug build and the tools: what CI runs
```

All builds use `-vet -strict-style`. A change is done when `./build.sh check` passes: the debug and optimized builds, `odin check` of the tools, `./build.sh test` and `./build.sh replay`. CI (`.github/workflows/check.yml`) runs it on Linux and `build.bat check` (everything but the replays) on Windows.

## Card detection

`src/imaging/detect.odin` is a classical computer-vision pipeline (see `doc/arch.md` → Card detection). Three stages handle what the base pipeline cannot: `detect_blocks.odin` (splits blocks of touching or overlapping cards at their rounded-corner notches and restores edges hidden under an overlapping card), `detect_frames.odin` (moves a card's sides from the artwork out to the faint real edge of a bed-coloured frame) and `suppress_artwork` in `detect.odin`. All of it reads only the original scan.

Changing detection behavior is a quality decision, so measure it first on the synthetic corpus (see "Synthetic scans" below) with `./build.sh bench` (development split while tuning, holdout only as the final check), and compare with the baseline in `doc/development.md`. `bench` prints one line per preset, so check the preset your change targets and the others for regressions. The synthetic tests in `detect_test.odin` cover the base pipeline and `detect_blocks_test.odin` covers the added stages; both must keep passing.

**A guess must ask for a check.** Detected cards with `source != .Full_Resolution_Edges` get `Region.review`, which is cleared when the user edits the card. Any stage that infers a side rather than measuring it (a seam between touching cards, a size taken from other cards, a faint edge) must return such a source. Record/replay runs detection synchronously.

## Synthetic scans

`tools/synth` generates the test scans; see `doc/development.md` → Synthetic scans. Rules:

- **No real card art in the repository**, not even small crops. Scans of published games can't be redistributed. Test data is synthetic: procedural art, or public-domain images if ever needed.
- **Keep it deterministic.** The generator uses its own PRNG and noise on purpose. Changing a preset or the rendering changes the corpus, so re-run both benchmarks and update the baseline in `doc/development.md` in the same change, saying why.
- **Realism is part of correctness.** The simulation earns its keep only if it fails the detector and the filter in the ways real scans do. When you change it, compare with a real scan side by side at 1:1.
- Generated corpora go in a temporary folder, never in the repository. The committed scans are `tests/replay/synthetic_cards.png`, from the small `replay_small` preset, and `tests/replay/synthetic_scan.png`, flat rectangles. Keep any new one small and synthetic.

## Moiré filter

Measure changes with `./build.sh moire-bench` on a corpus made with `./build.sh synth DIR --clean`. `src/imaging/descreen.odin` ports OpenCV's kernels stage by stage: `INTER_CUBIC` resize, `medianBlur`, `fastNlMeansDenoisingColored` with OpenCV's integer Lab tables, `bilateralFilter`, `INTER_AREA` resize, and float32 unsharp. Keep it numerically faithful. A change to its output is a behavior change: check it against the same filter built with OpenCV 4.12 on a real scan before updating any expected results. Record/replay runs the filter synchronously (`app.sync_jobs`) so replays never depend on timing.

**Never locate cards on filtered pixels.** The canvas, corner placement and card detection read the original scan (`app.scan_px`, `app.tex`). Only extraction (previews and exports) reads `extract_source(app)`. The filter softens card edges and the scanner background, which makes detection much worse. It keeps the image geometry, so corners found on the original apply to the cleaned pixels unchanged.

## Interface scale

All layout sizes are written for 1x and go through `S()` (sizes) and `fs()` (font sizes) in `src/ui_scale.odin`. New UI code must do the same. Draw text with `draw_text`/`measure_text` (or the `_big_` versions) from `src/fonts.odin`, not `rl.DrawText`, which uses raylib's built-in bitmap font. raygui controls already use Inter. Record and replay always run at 1x, so a 1x layout change moves the controls that recordings click. If a replay fails because of one, re-record the test rather than updating its expected results.

## The replay harness

`src/replay.odin` records input frame by frame with raylib's automation events and plays it back. A replay ends with a state dump: settings, each card's corners, the selection and the status line. The runner compares that dump and every exported PNG with the saved expected results.

```sh
build/scanned_card_cutter --record FILE.rec [--out DIR] SCAN.png     # closing the window saves
build/scanned_card_cutter --replay FILE.rec [--out DIR] [--dump STATE.txt] [--fast]
```

Exit codes: 0 done, 1 could not write the recording or dump, 2 bad arguments or an unreadable recording, 3 the replay window size differs from the recording, 4 the replay timed out waiting for previews or export.

### Running the tests

`./build.sh replay` replays every `tests/replay/*.rec` with `--fast` into a temporary folder and diffs it against `tests/replay/NAME.expected/` (`state.txt` plus the exported PNGs). A replay needs no input from you. It opens a floating window, runs, and exits on its own.

When a replay fails, read the diff. A `state.txt` difference shows which card or setting changed, and a PNG difference means the export pipeline's output changed.

- **Unintended change:** fix the code.
- **Intended change** (for example, an improved resampler): run `./build.sh replay --update`, then tell the user which expected results changed and why. Never update expected results just to make a failure go away.

### Adding a test

1. Put a small scan in `tests/replay/` (a synthetic one is fine; keep committed scans small). Use an empty scratch folder for `--out`.
2. Run `build/scanned_card_cutter --record tests/replay/NAME.rec --out SCRATCH/out tests/replay/SCAN.png`, use the app, and close the window. The console says `recorded N events over M frames`. Input can come from a person or from any tool that drives the window.
3. Replay with `--dump` and check that the dump and the exported PNGs show what was intended. The replay's exports must be byte-identical to the live session's.
4. Delete the `out` line from the `.rec` file (the runner passes its own `--out`), keep the `scan` line relative to the recording (`scan SCAN.png`), then run `./build.sh replay --update`.

### What a recording cannot capture

- **Text typed into the panel's text and number boxes.** raylib records keys, not the characters they produce. Set the output folder with `--out` and leave other values at their defaults.
- **OS key repeat.** Send a key several times instead of holding it.
- **Dropped files, and the file browser's dependence on what's on disk.** Pass the scan on the command line.
- **A resized window.** Recording stops at the resize, and a replay at another size exits with code 3.
- **Touchpad smooth scrolling,** which is rounded to whole wheel steps.
