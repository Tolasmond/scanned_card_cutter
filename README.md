# Scan Tool

Extracts straightened card images from a flatbed scan and saves them as PNGs with transparent rounded corners. It is written in Odin with raylib/raygui and builds with **only what ships with Odin**: no other libraries, no Python, no ImageMagick.

## Workflow

1. **Open a scan.** Use *Open scan…* (Ctrl+O), copy the PNG in your file manager and press **Ctrl+V** in the app, drop a PNG on the window, or pass the path as an argument.
2. **Mark the cards.** Press **D** (*Detect cards*) to find them automatically, or press **A** and click a card's 4 corners in any order. The orange edge marks the card's top; press **R** to rotate it. Detected cards the detector is unsure of are drawn pink and marked *review* until you adjust them.
3. **Adjust.** Drag corners or whole cards, or nudge them with the arrow keys. The preview shows the exact export output and updates as you edit. **P** opens it at full size.
4. **Set the output.** Width, height, corner radius (output pixels) and edge trim (scan pixels). Tick **Remove moiré** (M) to filter out the printed halftone pattern (see below).
5. **Export** (Ctrl+E). Each card is written as `<prefix>_NN.png` to the chosen folder. Pasting (Ctrl+V) or dropping a folder sets the output folder.

**Drag and drop on Hyprland:** the app runs under XWayland, because Odin's bundled raylib is built for X11. Hyprland 0.56 does not deliver drags from native Wayland apps, such as GNOME Files, to XWayland windows. Use Ctrl+C in the file manager and Ctrl+V in the app instead. Drops from X11 apps, and on Windows and macOS, work normally.

## Controls

| Input | Action |
| --- | --- |
| D | Detect cards automatically (adds only cards not already marked) |
| A / N | Add a card (click its 4 corners; Esc cancels) |
| Drag corner / card | Move a corner / the whole card |
| Arrows (Shift = 10 px) | Nudge the focused corner, or the whole card when no corner is focused |
| Tab / Shift+Tab | Cycle focus: whole card → corners 1–4 |
| R / Shift+R | Rotate the card's orientation 90° clockwise / counter-clockwise |
| Del / Backspace | Delete the selected card |
| Wheel, right/middle drag, drag on empty space | Zoom, pan |
| F | Fit the scan to the window |
| P / Space | Full-size preview (wheel zoom, drag pan, 1 = 100%, F = fit, Esc closes) |
| M | Moiré removal on/off |
| Ctrl+= / Ctrl+- / Ctrl+0 | Larger / smaller interface, or back to automatic |
| Ctrl+V | Paste a file copied in a file manager: a PNG opens as the scan, a folder becomes the output folder |
| Ctrl+Q / Exit button | Quit (waits for a running export to finish writing its files) |

### Card detection

**Detect cards** is a pure-Odin port of the original tool's classical detector (`src/imaging/detect.odin`, ported from detector 1.5.0), with three stages added to it. It reads the original scan, never the moiré-filtered copy. About 0.3 s per 2550 x 3507 scan.

The port finds the scanner-bed color along the border and builds foreground masks from color distance and Canny edges. It removes scanner-lid strips, carves the thin gaps between tightly packed cards, and turns the outlines into four-corner proposals. It then fits each side to the card's outer edge at full resolution, splits outlines that are grids of touching rounded cards of a known size, and fills holes in a regular layout.

The added stages cover what the original could not:

- **Blocks of touching or overlapping cards** (`detect_blocks.odin`). Rounded cards that touch leave a notch in the block's outline where two corners meet, and a small pocket of scanner bed where four meet. The block is split along the lines from notch to notch, so no card has to lie on its own to show the card size. Each seam is then fitted to the edge the image shows there. Where one card lies over another, the lower card's edge is hidden: if the cards of the block agree on a size, the hidden edge is placed by that size.
- **Frames in the color of the scanner bed** (`detect_frames.odin`). A white frame on a white lid is background to the color masks, so the first fit ends at the artwork. The card's real edge still shows as a faint step or shadow line. It is found by averaging along each side, and accepted only when all four sides show one.
- **Artwork taken for a card.** When most cards on the scan share a size, a proposal inside one of them that is not of that size is dropped.

Each detected card becomes an ordinary editable card. Cards whose edges were fitted at full resolution are trusted. Everything that involves a guess is marked *review* (pink) and needs a check: block and grid splits, edges placed by size, faint outer edges, layout guesses and coarse outlines. Detection never replaces cards you already have; it only adds cards that don't overlap them.

During development the port was checked against the original detector on private scans of tightly packed rounded cards with hand-corrected corners. It found every card, made the same single false proposal as the original, and matched its corner accuracy: a typical corner error of about 6 px, with the largest errors (up to 36 px) on touching cards whose shared seam was placed by the grid alone. With the block stage those seams are fitted, and on the same scans the typical error is about 5 px and the largest 21 px.

`./build.sh bench ANNOTATIONS.json IMAGE_DIR` scores detection against any annotation file in the format of `tools/detect_bench`. When the scans name a preset, it prints one line per preset before each split's total.

### Moiré removal

Printed cards are made of halftone dots, and a flatbed scan of them shows a grainy or wavy moiré pattern. **Remove moiré** runs the original tool's "Soft" descreen filter once over the whole scan in the background: a 1.5x cubic upscale, a 3x3 median, non-local-means denoising in Lab color, a bilateral filter, an area downscale and a light unsharp mask. A 2550 x 3507 scan takes about 2.5 s on 16 threads. Previews, the full-size preview and exports use the cleaned scan once it is ready. The canvas where you place corners always shows the original scan, and card detection will too: the filter softens card edges, which makes them harder to find. Export waits while it runs. Turning the filter off keeps the result, so turning it back on is instant.

The filter is a pure-Odin port of the OpenCV version (`src/imaging/descreen.odin`). Against OpenCV 4.12 it matches 98.4% of output values exactly (never more than 2 levels off), and its non-local-means and Lab stages are bit-exact. The original's own output varies more than that between OpenCV builds, depending on whether OpenCV uses Intel IPP for the cubic resize.

### Interface scale

The interface scales for high-density monitors and follows the window when it moves to another monitor. Text uses Inter, which is rendered again at the exact pixel size for each scale, so it stays sharp at any scale.

- **Windows:** uses the display scale set in Windows.
- **macOS:** 1x. macOS already lays windows out in points and scales them.
- **Linux:** uses `Xft.dpi` when set. Otherwise it uses the monitor's pixel density in whole steps (about 150–250 dpi gives 2x). Under XWayland with `force_zero_scaling`, this is what makes the text readable.

Ctrl+= and Ctrl+- override the automatic choice for the session, in 0.25 steps.

## Building

Requires the [Odin](https://odin-lang.org) toolchain for your OS. Each OS's Odin release includes the matching prebuilt raylib in `vendor:raylib`.

```sh
./build.sh          # Linux / macOS -> build/scan_tool
./build.sh test     # imaging unit tests (headless)
./build.sh replay   # replay tests (opens a window; see Testing)
./build.sh synth DIR  # generate synthetic test scans (see Testing)
./build.sh bench ANN DIR  # score card detection against annotation file ANN
./build.sh moire-bench DIR  # score moiré removal on a synthetic corpus
build.bat           # Windows -> build\scan_tool.exe (needs the MSVC linker, as Odin does)
```

raylib is linked statically. The Linux binary needs only the system X11/GL libraries every desktop has. Build each platform on that platform (or in CI): Odin can target another OS, but producing the final program needs that OS's linker and system libraries.

## Testing

Besides the imaging unit tests, whole editing sessions can be recorded and replayed. This uses raylib's automation events, so it needs nothing beyond Odin either.

```sh
build/scan_tool --record tests/replay/NAME.rec [--out DIR] SCAN.png
./build.sh replay --update   # save NAME.expected/ from the current build
./build.sh replay            # replay every recording and compare
```

Recording saves the mouse and keyboard input frame by frame when you close the window. A replay plays it back at the same frames, waits for previews and any export to finish, and writes a state dump: settings, cards with corner positions, selection and the status line. The runner compares that dump and every exported PNG with `NAME.expected/`. To run one replay by hand:

```sh
build/scan_tool --replay NAME.rec [--out DIR] [--dump state.txt] [--fast]
```

A recording names its scan. A relative path is looked up in the working directory, then next to the recording.

Limits to keep in mind when recording:

- **Fixed window.** Record and replay use a 1500 x 950 window that cannot be resized, which tiling window managers float. They also always use a 1x interface scale, whatever the monitor, so controls stay at the recorded positions. Mouse positions are window pixels, so a replay at any other size fails immediately (exit 3). If the window is resized while recording, recording stops there.
- **Not recorded:** text typed into the panel's text and number boxes (raylib records keys, not the characters they type), the OS's held-key repeat (tap the arrow keys instead of holding them), dropped files, and anything inside the file browser that depends on the disk. Pass the scan on the command line and the folder with `--out`.
- **Smooth scrolling** from a touchpad is recorded in whole wheel steps, so use a mouse wheel or F (fit) when zoom matters.
- **Hands off during a replay.** A real pointer wandering over the window is overridden, but real clicks and keys are not.
- **Windows:** `build.bat` has no `replay` runner yet; run `scan_tool.exe --replay` directly.

### Synthetic scans

Real card art can't be published, so detection and moiré removal are measured on synthetic scans that `tools/synth` generates. It simulates printing and scanning rather than drawing the result:

- **Printing:** procedural card art is converted to CMYK. Each ink is printed as an AM halftone at its usual screen angle (C 15°, M 75°, Y 0°, K 45°, 133–175 lpi), with dot gain and uneven ink spread, and overlapping inks multiply.
- **Scanning:** the scanner integrates 4x4 samples per 300 dpi pixel. Resampling the halftone this way is what produces real moiré. Scanner effects are layered on top: lid texture and vignetting, lamp shadow beside card edges and on overlapped cards, an optional dark lid strip, optical blur, sensor and line noise, and a slight color cast.
- **Layouts (presets):** `separated`, `packed` (gaps of 0–8 px, some cards touching, a lid strip, the last column cut by the scan edge), `overlap` (cards lying up to 12 px over each other), `rotated` (up to 10°), `pale` (white frames on the white lid) and `poker_packed`.
- **Ground truth:** every scan comes with its cards' exact corners, written to `annotations.json` in the format `tools/detect_bench` reads. With `--clean`, each scan also gets a twin printed without halftone and without noise, which is the target for moiré removal.

Generation is deterministic: the generator carries its own PRNG and noise. Two scans per preset per split take about 2 minutes, and the files stay out of the repository:

```sh
./build.sh synth /tmp/corpus --count 2 --clean
./build.sh bench /tmp/corpus/annotations.json /tmp/corpus development
./build.sh moire-bench /tmp/corpus development
```

Baseline (2 scans per preset per split, 2026-11-15):

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

The port alone, before the block, frame and artwork stages, scored 66/80 with 5 false proposals on development (median 4.7 px, P95 60.0 px) and 78/80 with 1 on holdout (median 7.6 px, P95 61.1 px). It merged overlapping cards into one outline (`overlap` 13/24), left blocks of touching cards whole when no single card showed the card size (`packed` 19/24), and put every corner of a white-framed card on the art window, about 50 px inside the card (`pale` median 52.8 px).

| Moiré removal (PSNR against the clean twin, card interiors) | Raw scan | Filtered | Gain |
| --- | ---: | ---: | ---: |
| development | 32.18 dB | 38.95 dB | +6.77 dB |
| holdout | 32.28 dB | 38.87 dB | +6.60 dB |

What remains weak:

- **A hidden edge is a guess.** The edge of a card under another card is placed by the card size, to within a few pixels at best. Without a second card to confirm the size it stays at the upper card's edge. `overlap` has the largest typical error for this reason, and such cards are marked *review*.
- **Seams need rounded corners.** Blocks are split at the notches that rounded corners leave. Square-cornered cards that touch, and cards overlapping so far that no notch is left at either end of a seam, stay merged unless another card shows the card size for the original grid split.
- **Shadow sides.** The lamp shadow beside a card has the brightness of a pale frame, so a faint outer edge on the shadow side can land 2 to 4 px outside the card.
- **Rare outliers.** One holdout `packed` scan has corners about 25 px off (its P95), and one `rotated` scan in a larger development run keeps a card on its art window on three sides. Both also fail in the plain port.

On simple layouts the detector is accurate to about 2 px.

The replay scan `tests/replay/synthetic_cards.png` comes from the small `replay_small` preset: three cards at 150 dpi, with a touching pair that has to be split.

## Layout

| Path | Contents |
| --- | --- |
| `src/imaging/` | Pure-Odin image processing (no raylib): homography, bicubic perspective warp, Lanczos-3 resize, anti-aliased rounded-corner mask, the moiré filter (`descreen.odin`), card detection (`detect.odin`, with `detect_blocks.odin` for touching and overlapping cards, `detect_frames.odin` for bed-colored frames, `morph.odin` for masks/Canny and `contours.odin` for contours and geometry), multithreaded row helper. Unit tested. |
| `tools/detect_bench/` | Detection benchmark against annotated corners (`./build.sh bench ANN DIR`) |
| `tools/synth/` | Synthetic printed-and-scanned card generator with exact ground truth (`./build.sh synth DIR`) |
| `tools/moire_bench/` | Moiré removal score against the clean twins (`./build.sh moire-bench DIR`) |
| `src/app.odin` | Application state, scan loading, card editing, preview, export requests |
| `src/main.odin` | Window loop, canvas input and drawing, full-size preview |
| `src/panel.odin` | Side panel UI |
| `src/file_browser.odin` | Built-in file/folder browser (no OS dialog dependency) |
| `src/detection.odin` | Runs detection in the background and adds the results as cards |
| `src/moire.odin` | Runs the moiré filter once per scan in the background; picks the cleaned or original pixels |
| `src/paste.odin` | Ctrl+V: parse clipboard paths (plain, `file://` URIs, GNOME copied files) |
| `src/export.odin` | Background export thread and PNG writing |
| `src/ui_scale.odin` | Interface scale: monitor detection, `S()`/`fs()` sizing helpers, scaled dialog frame |
| `src/fonts.odin` | Inter fonts compiled into the executable, re-rendered for each scale; `draw_text`/`measure_text` |
| `assets/fonts/` | Inter Regular and SemiBold (SIL Open Font License 1.1, license alongside) |
| `src/replay.odin` | Input record/replay harness and the state dump replays are checked against |
| `tests/replay/` | Recorded sessions (`*.rec`), their scans, and expected results (`*.expected/`) |

## Roadmap

- [x] Manual card regions, straightening, rounded corners, transparent PNG export, live preview
- [x] Moiré (halftone) removal: pure-Odin port of the original "Soft" filter
- [x] Automatic card detection that proposes regions for the same editor
- [ ] Native file dialogs on Windows (`IFileOpenDialog`) and macOS (`NSOpenPanel`); multi-OS CI builds
