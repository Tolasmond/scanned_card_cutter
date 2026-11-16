# Architecture

Scanned Card Cutter is one Odin program in two packages: the application (`src/`), which owns the window, the interface and the background jobs, and a pure image-processing library (`src/imaging/`), which has no raylib dependency and is unit tested headless. Development tools in `tools/` reuse the library.

## Source layout

| Path | Contents |
| --- | --- |
| `src/main.odin` | Window loop, canvas input and drawing, full-size preview |
| `src/app.odin` | Application state, scan loading, card editing, preview, export requests |
| `src/panel.odin` | Side panel UI |
| `src/focus.odin` | Keyboard focus for the panel's controls (Tab order, Enter/Space, Esc) |
| `src/file_browser.odin` | Built-in file and folder browser (no OS dialog dependency) |
| `src/detection.odin` | Runs card detection in the background and adds the results as cards |
| `src/moire.odin` | Runs the moiré filter once per scan in the background; picks the cleaned or original pixels for extraction |
| `src/export.odin` | Background export thread and PNG writing |
| `src/scanner.odin` | Scan button: reads `scanners.ini`, runs the chosen profile's command in the background, opens its PNG |
| `src/paste.odin` | Ctrl+V: parses clipboard paths (plain, `file://` URIs, GNOME copied files, Windows paths) |
| `src/paste_windows.odin`, `src/paste_other.odin` | The Windows clipboard file list (`CF_HDROP`); a no-op elsewhere |
| `src/ui_scale.odin` | Interface scale: monitor detection, `S()`/`fs()` sizing helpers, scaled dialog frame |
| `src/fonts.odin` | Inter fonts compiled into the executable, re-rendered for each scale; `draw_text`/`measure_text` |
| `src/replay.odin` | Input record/replay harness and the state dump replays are checked against |
| `src/imaging/image.odin` | Image type, homography, multithreaded row helper |
| `src/imaging/warp.odin` | Card extraction: perspective warp, trim, Lanczos-3 resize, rounded-corner mask |
| `src/imaging/descreen.odin` | The moiré filter |
| `src/imaging/detect.odin` | Card detection: the main pipeline and artwork suppression |
| `src/imaging/detect_blocks.odin` | Splitting blocks of touching or overlapping cards |
| `src/imaging/detect_frames.odin` | Faint outer edges of frames the color of the scanner bed |
| `src/imaging/morph.odin` | Binary masks, morphology, grayscale and Canny edges |
| `src/imaging/contours.odin` | Contours and planar geometry |
| `tools/synth/` | Synthetic printed-and-scanned card generator with exact ground truth |
| `tools/detect_bench/` | Detection benchmark against annotated corners |
| `tools/moire_bench/` | Moiré removal score against the clean twins |
| `assets/fonts/` | Inter Regular and SemiBold (SIL Open Font License 1.1, license alongside) |
| `tests/replay/` | Recorded sessions (`*.rec`), their scans, and expected results (`*.expected/`) |

## Application

The app keeps one scan in memory as RGBA pixels (`app.scan_px`) and as a GPU texture for the canvas. Each card is a `Region`: the output card's top-left, top-right, bottom-right and bottom-left corners in scan pixels (rotating a card reorders them), and a `review` flag set by detection and cleared when the user edits the card. The preview is rendered with the same extraction code as the export.

Slow work runs on background threads so the window stays responsive: detection, the moiré filter, export and scanner commands. Each job hands its result back to the main loop, which applies it between frames. Record and replay run detection and the moiré filter synchronously (`app.sync_jobs`) so that a replay never depends on timing.

Interface sizes are written for 1x and multiplied by the current scale through `S()` and `fs()`. The scale comes from the OS on Windows, is 1x on macOS (which scales windows itself), and comes from `Xft.dpi` or the monitor's pixel density on Linux. raylib rasterizes a TrueType font at one size, so the embedded Inter fonts are reloaded at the exact pixel size whenever the scale changes.

There are no OS file dialogs: `file_browser.odin` draws its own with raygui, which works the same on every platform. Ctrl+V reads file paths from the clipboard as text, and on Windows also reads Explorer's file list, which has no text form.

## Original scan and filtered scan

Everything that locates cards reads the original scan: the canvas, corner placement and detection. The moiré filter softens card edges and the scanner background, which makes edge finding much worse. Only extraction (previews and exports) reads `extract_source(app)`, which is the filtered scan when moiré removal is on and ready. The filter keeps the image size and alignment, so corners found on the original apply to the filtered pixels unchanged.

## Card extraction

`extract_card` in `warp.odin` turns four corners into one output image:

1. Perspective warp of the quad at its natural size, bicubic, at about 1:1 scale.
2. Shave `edge_trim` pixels from each side.
3. Lanczos-3 resize to the output width and height.
4. Anti-aliased rounded-rectangle alpha mask for the transparent corners.

Corners are in scan pixel space, where pixel (i, j) covers [i, i+1) x [j, j+1).

## Card detection

`detect_cards` in `detect.odin` is a classical computer-vision pipeline. It reads only the original scan.

1. **Background.** Downscale the scan to at most 1800 x 1200, and find the scanner bed's color as the dominant border color in Lab.
2. **Masks.** Build foreground masks at three Lab-distance thresholds plus Canny edges. Clear dark scanner-lid strips, and carve the thin full-resolution gaps between tightly packed cards.
3. **Proposals.** Trace the outer contours and turn each into a four-corner proposal (a simplified polygon or a minimum-area rectangle), removing duplicates.
4. **Edge fit.** At full resolution, fit each side of a proposal to the card's outer edge with a robust (Huber) line fit, and intersect the lines.
5. **Blocks** (`detect_blocks.odin`). Rounded cards that touch leave a notch in the block's outline where two corners meet, and a small pocket of scanner bed where four meet. The block is split along the lines from notch to notch, so no card has to lie on its own to show the card size. Each seam is then fitted to the edge the image shows there. Where one card lies over another, the lower card's edge is hidden: if the cards of the block agree on a size, the hidden edge is placed by that size.
6. **Grids.** Split what is left that is a grid of touching cards of a known size, fit the cells' edges, and drop proposals that contain several others.
7. **Artwork** (`suppress_artwork`). When most cards on the scan share a size, a proposal inside one of them that is not of that size is dropped.
8. **Layout.** Recover cards the masks missed from the row and column layout of the others.
9. **Frames** (`detect_frames.odin`). A white frame on a white lid is background to the color masks, so the first fit ends at the artwork. The card's real edge still shows as a faint step or shadow line. It is found by averaging brightness along each side, and accepted only when all four sides show one.

Each result carries a `Card_Source`. `.Full_Resolution_Edges` means all four sides were fitted to edges the scan shows. Anything inferred rather than measured (grid or block cells, sizes taken from other cards, faint outer edges, layout guesses, coarse mask outlines) gets another source, and the app marks those cards for review.

The geometry follows OpenCV's conventions closely: `contours.odin` covers the subset of OpenCV the detector needs (external contours, `approxPolyDP`, `minAreaRect`, convex polygon intersection, `fitLine` with `DIST_HUBER`), and `morph.odin` covers elliptical morphology, grayscale conversion and Canny.

## Moiré removal

`descreen_soft` in `descreen.odin` removes the halftone pattern in six stages:

```
up   = resize(src, x1.5, INTER_CUBIC)
up   = medianBlur(up, 3)
up   = fastNlMeansDenoisingColored(up, h=7, hColor=7, template=7, search=21)
up   = bilateralFilter(up, d=7, sigmaColor=50, sigmaSpace=50)
down = resize(up, original size, INTER_AREA)
out  = unsharp(down, sigma=0.9, amount=0.9)
```

Each stage is a pure-Odin port of the matching OpenCV 4.12 kernel, following its border modes, fixed-point arithmetic and rounding closely enough to compare stage by stage. The non-local-means denoiser uses OpenCV's integer Lab conversion tables, so it sees exactly the values OpenCV does. Against OpenCV 4.12 the whole filter matches 98.4% of output values exactly and is never more than 2 levels off; its non-local-means and Lab stages are bit-exact. The remaining differences come from the cubic resize, which OpenCV itself computes differently depending on whether it was built with Intel IPP.

Work is split across threads by rows with `parallel_rows` in `image.odin`. Alpha is carried through from the source unchanged.

## Replay harness

`replay.odin` records input frame by frame with raylib's automation events and plays it back at the same frames in a fixed 1500 x 950 window at a 1x interface scale. When playback ends and all background work has finished, it writes a state dump: settings, each card's corners, the selection and the status line. The replay runner in `build.sh` compares the dump and every exported PNG with the saved expected results. See [Development](development.md#replay-tests) for how to use it.

## Scanner commands

`scanner.odin` reads `scanners.ini` from the user's config folder on every scan. A profile's command is split into arguments itself (quotes group, no backslash escapes) and run directly, not through a shell, with `{out}` replaced by a new file in a temporary folder. The command runs on a background thread; when it exits successfully, the PNG is opened as the scan and deleted. Nothing in the app depends on any particular scanning program.
