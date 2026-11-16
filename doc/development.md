# Developing Scan Tool

How to build Scan Tool, run its tests, and measure changes to detection and moiré removal. For how the code is organized, see [Architecture](arch.md).

## Ground rules

- **Only what ships with Odin.** The app uses `core:` and `vendor:raylib`/raygui and nothing else: no third-party libraries, no Python, no ImageMagick, no external programs in the app or its build. Image algorithms live in `src/imaging/` as pure Odin, with unit tests. The one bundled third-party file is the Inter font in `assets/fonts/`, compiled in with `#load`.
- **The one exception is the user's own scanner command** (`scanners.ini`, see [Usage](usage.md#scanning)). Nothing ships with the app or depends on it, and without the file the app is unchanged. Support for another scanner is an example profile, not code.
- **Cross-platform.** The app must keep building on Linux, Windows and macOS.
- **One scan per session.** No projects, autosave or export history, by design.
- **No real card art in the repository**, not even small crops. Scans of published games can't be redistributed, so all test data is synthetic.

## Building

Requires the [Odin](https://odin-lang.org) toolchain for your OS. Each OS's Odin release includes the matching prebuilt raylib in `vendor:raylib`. CI and releases are pinned to Odin `dev-2026-10` (commit `84bc3fc`) in `.github/actions/install-odin`.

```sh
./build.sh                    # optimized build -> build/scan_tool
./build.sh debug              # bounds checks and symbols
./build.sh test               # imaging, app and synthetic-scan unit tests (headless)
./build.sh replay [--update]  # replay tests (opens a window)
./build.sh check              # every check a change must pass: builds, tools, unit and replay tests
./build.sh synth DIR [...]    # generate synthetic test scans
./build.sh bench ANN DIR [split] [--dump FILE]  # score card detection against annotation file ANN
./build.sh moire-bench DIR [split]              # score moiré removal on a synthetic corpus
```

On Windows, `build.bat` builds `build\scan_tool.exe` (needs the MSVC linker, as Odin does). `build.bat debug` makes a debug build, `build.bat test` runs the unit tests, and `build.bat check` runs every check except the replay tests.

All builds use `-vet -strict-style`. A change is done when `./build.sh check` passes: the debug and optimized builds, `odin check` of the tools, the unit tests and the replay tests.

raylib is linked statically. The Linux binary needs only the system X11/GL libraries every desktop has. Build each platform on that platform (or in CI): Odin can target another OS, but producing the final program needs that OS's linker and system libraries.

## Continuous integration

`.github/workflows/check.yml` runs on every push to `main` and every pull request: `./build.sh check` on Ubuntu 24.04, with the replay tests in a virtual X display (Xvfb with Mesa's software OpenGL), and `build.bat check` on Windows Server 2025. Both install the pinned Odin release with `.github/actions/install-odin`, which checks the download's SHA-256.

## Releases

Pushing a tag that starts with `v` publishes a GitHub release of the tagged commit:

```sh
git tag v0.1.0
git push origin v0.1.0
```

`.github/workflows/release.yml` runs the checks on Linux (Ubuntu 24.04) and on Windows, builds Scan Tool with `-o:speed` on each, and packages the program with `LICENSE`, `THIRD_PARTY.md`, `README.md`, `doc/`, the Inter font's license and the Apache License 2.0 text (for the OpenCV ports and glad): `scan_tool-<tag>-linux-amd64.tar.gz` and `scan_tool-<tag>-windows-amd64.zip`. The release, named for the tag, has notes GitHub generates from the pull requests since the last release, the two archives, and `SHA256SUMS`. A tag with a hyphen (`v0.2.0-rc.1`) makes a pre-release. If a check fails, nothing is published; delete the tag (`git push --delete origin v0.1.0`), fix the commit, and tag again. A pull request that changes the workflow or `install-odin` builds and packages the archives without publishing them, and they can be downloaded from the run's artifacts.

The Linux program needs glibc 2.38 or newer (Ubuntu 24.04, Debian 13, Fedora 39 and later), because Odin's prebuilt raylib is built against it. The programs are built for the baseline x86-64-v2 instruction set, Odin's default, so they run on any x86-64 CPU with SSE4.2 (Intel since 2008, AMD since 2011). There is no macOS release: Odin ships raylib for macOS, but the app has not been tested there.

## Unit tests

`./build.sh test` runs three suites, all headless:

- `src/imaging`: the image processing, including the detector's synthetic scenes (`detect_test.odin`, `detect_blocks_test.odin`) and the moiré filter.
- `src`: the app's own logic, such as clipboard paths, scanner profiles, keyboard focus and view panning.
- `tools/synth`: the synthetic scan generator stays deterministic and its ground truth matches its cards.

## Replay tests

Whole editing sessions can be recorded and replayed. This uses raylib's automation events, so it needs nothing beyond Odin.

```sh
build/scan_tool --record tests/replay/NAME.rec [--out DIR] SCAN.png
./build.sh replay --update   # save NAME.expected/ from the current build
./build.sh replay            # replay every recording and compare
```

Recording saves the mouse and keyboard input frame by frame when you close the window. A replay plays it back at the same frames, waits for previews, detection, the moiré filter and any export to finish, and writes a state dump: settings, cards with corner positions, selection and the status line. The runner replays every `tests/replay/*.rec` with `--fast` into a temporary folder and compares the dump and every exported PNG with `tests/replay/NAME.expected/`. To run one replay by hand:

```sh
build/scan_tool --replay NAME.rec [--out DIR] [--dump state.txt] [--fast]
```

A recording names its scan. A relative path is looked up in the working directory, then next to the recording.

Exit codes: 0 done, 1 could not write the recording or dump, 2 bad arguments or an unreadable recording, 3 the replay window size differs from the recording, 4 the replay timed out waiting for previews or export.

### When a replay fails

Read the diff. A `state.txt` difference shows which card or setting changed, and a PNG difference means the export pipeline's output changed.

- **Unintended change:** fix the code.
- **Intended change** (for example, an improved resampler): run `./build.sh replay --update`, and say in the commit which expected results changed and why. Never update expected results just to make a failure go away.
- **Layout change:** record and replay always run at a 1x interface scale, so moving a control at 1x moves what recordings click. Re-record the test rather than updating its expected results.

### Adding a replay test

1. Put a small scan in `tests/replay/`. A synthetic one is fine, and every committed scan must be small. Use an empty scratch folder for `--out`.
2. Run `build/scan_tool --record tests/replay/NAME.rec --out SCRATCH/out tests/replay/SCAN.png`, use the app, and close the window. The console says `recorded N events over M frames`. Input can come from a person or from any tool that drives the window.
3. Replay with `--dump` and check that the dump and the exported PNGs show what was intended. The replay's exports must be byte-identical to the live session's.
4. Delete the `out` line from the `.rec` file (the runner passes its own `--out`), keep the `scan` line relative to the recording (`scan SCAN.png`), then run `./build.sh replay --update`.

### What a recording cannot capture

- **A different window size.** Record and replay use a 1500 x 950 window that cannot be resized, which tiling window managers float. Mouse positions are window pixels, so a replay at any other size fails immediately (exit 3). If the window is resized while recording, recording stops there.
- **Text typed into the panel's text and number boxes.** raylib records keys, not the characters they produce. Set the output folder with `--out` and leave other values at their defaults.
- **OS key repeat.** Tap a key several times instead of holding it.
- **Dropped files, and the file browser's dependence on what's on disk.** Pass the scan on the command line.
- **Touchpad smooth scrolling,** which is recorded in whole wheel steps. Use a mouse wheel or F (fit) when zoom matters.
- **Scanning.** Record and replay never run a scanner command.

Keep your hands off the window during a replay: a real pointer wandering over it is overridden, but real clicks and keys are not.

On Windows, `build.bat` has no `replay` runner yet; run `scan_tool.exe --replay` directly.

## Synthetic scans

Detection and moiré removal are measured on synthetic scans that `tools/synth` generates. It simulates printing and scanning rather than drawing the result:

- **Printing:** procedural card art is converted to CMYK. Each ink is printed as an AM halftone at its usual screen angle (C 15°, M 75°, Y 0°, K 45°, 133–175 lpi), with dot gain and uneven ink spread, and overlapping inks multiply.
- **Scanning:** the scanner integrates 4x4 samples per 300 dpi pixel. Resampling the halftone this way is what produces real moiré. Scanner effects are layered on top: lid texture and vignetting, lamp shadow beside card edges and on overlapped cards, an optional dark lid strip, optical blur, sensor and line noise, and a slight color cast.
- **Layouts (presets):** `separated`, `packed` (gaps of 0–8 px, some cards touching, a lid strip, the last column cut by the scan edge), `overlap` (cards lying up to 12 px over each other), `rotated` (up to 10°), `pale` (white frames on the white lid) and `poker_packed`.
- **Ground truth:** every scan comes with its cards' exact corners, written to `annotations.json` in the format `tools/detect_bench` reads. With `--clean`, each scan also gets a twin printed without halftone and without noise, which is the target for moiré removal.

Rules for changing the generator:

- **Keep it deterministic.** The generator carries its own PRNG and noise on purpose. Changing a preset or the rendering changes the corpus, so re-run both benchmarks and update the baseline below in the same change, saying why.
- **Realism is part of correctness.** The simulation earns its keep only if it fails the detector and the filter in the ways real scans do. When you change it, compare with a real scan side by side at 1:1.
- **Corpora stay out of the repository.** Generate them in a temporary folder. Two small synthetic scans are committed for the replay tests: `tests/replay/synthetic_cards.png`, from the `replay_small` preset (three cards at 150 dpi, with a touching pair that has to be split), and `tests/replay/synthetic_scan.png`, a 1200 x 900 scan of flat rectangles.

Two scans per preset per split take about 2 minutes:

```sh
./build.sh synth /tmp/corpus --count 2 --clean
./build.sh bench /tmp/corpus/annotations.json /tmp/corpus development
./build.sh moire-bench /tmp/corpus development
```

`./build.sh bench` scores detection against any annotation file in the format of `tools/detect_bench`, so it also works on your own hand-annotated scans. When the scans name a preset, it prints one line per preset before each split's total. Tune on the development split, and use the holdout split only as the final check.

## Baseline

2 scans per preset per split, 2026-11-15.

| Detection | Recall | False proposals | Median corner error | P95 |
| --- | ---: | ---: | ---: | ---: |
| `separated` | 24/24 | 0 | 2.2 px | 4.6 px |
| `rotated` | 16/16 | 0 | 2.2 px | 3.7 px |
| `poker_packed` | 36/36 | 0 | 1.7 px | 5.3 px |
| `packed` | 24/24 | 0 | 1.7 px | 22.2 px |
| `overlap` | 24/24 | 0 | 2.4 px | 7.1 px |
| `pale` | 36/36 | 0 | 1.0 px | 3.1 px |
| **development** | 80/80 | 0 | 1.6 px | 4.2 px |
| **holdout** | 80/80 | 0 | 1.8 px | 6.6 px |

Before the block, frame and artwork stages were added (see [Architecture](arch.md#card-detection)), the base detector scored 66/80 with 5 false proposals on development (median 4.7 px, P95 60.0 px) and 78/80 with 1 on holdout (median 7.6 px, P95 61.1 px). It merged overlapping cards into one outline (`overlap` 13/24), left blocks of touching cards whole when no single card showed the card size (`packed` 19/24), and put every corner of a white-framed card on the art window, about 50 px inside the card (`pale` median 52.8 px).

On private real scans of tightly packed rounded cards with hand-corrected corners, detection finds every card with a typical corner error of about 5 px and a largest error of 21 px.

| Moiré removal (PSNR against the clean twin, card interiors) | Raw scan | Filtered | Gain |
| --- | ---: | ---: | ---: |
| development | 32.18 dB | 38.95 dB | +6.77 dB |
| holdout | 32.28 dB | 38.87 dB | +6.60 dB |

### Known weaknesses

- **A hidden edge is a guess.** The edge of a card under another card is placed by the card size, to within a few pixels at best. Without a second card to confirm the size it stays at the upper card's edge. `overlap` has the largest typical error for this reason, and such cards are marked *review*.
- **Seams need rounded corners.** Blocks are split at the notches that rounded corners leave. Square-cornered cards that touch, and cards overlapping so far that no notch is left at either end of a seam, stay merged unless another card shows the card size for the grid split.
- **Shadow sides.** The lamp shadow beside a card has the brightness of a pale frame, so a faint outer edge on the shadow side can land 2 to 4 px outside the card.
- **Rare outliers.** One holdout `packed` scan has corners about 25 px off (its P95), and one `rotated` scan in a larger development run keeps a card on its art window on three sides. Both also fail in the base detector.

## Changing detection or the moiré filter

- **Detection** is a quality decision. Measure the change on the synthetic corpus first and compare with the baseline above. `bench` prints one line per preset, so check the preset your change targets and the others for regressions. The tests in `detect_test.odin` and `detect_blocks_test.odin` must keep passing.
- **A guess must ask for a check.** Any detection stage that infers a side rather than measuring it (a seam between touching cards, a size taken from other cards, a faint edge) must return a `Card_Source` other than `.Full_Resolution_Edges`, so the card is marked for review.
- **The moiré filter** ports OpenCV's kernels stage by stage and is kept numerically faithful (see [Architecture](arch.md#moiré-removal)). A change to its output is a behavior change: measure it with `./build.sh moire-bench` on a corpus made with `--clean`, and compare it with the same filter built with OpenCV 4.12 on a real scan before updating any expected results.
- **Never locate cards on filtered pixels.** The canvas, corner placement and detection read the original scan; only extraction reads the filtered one.

## Interface code

All layout sizes are written for 1x and go through `S()` (sizes) and `fs()` (font sizes) in `src/ui_scale.odin`. New UI code must do the same. Draw text with `draw_text`/`measure_text` (or the `_big_` versions) from `src/fonts.odin`, not `rl.DrawText`, which uses raylib's built-in bitmap font. raygui controls already use Inter.
