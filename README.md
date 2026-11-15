# Scan Tool

Extracts straightened card images from a flatbed scan and saves them as PNGs with transparent rounded corners. It is written in Odin with raylib/raygui and builds with **only what ships with Odin**: no other libraries, no Python, no ImageMagick.

## Workflow

1. **Open a scan.** Use *Open scan…* (Ctrl+O), drop a PNG on the window, or pass the path as an argument.
2. **Mark the cards.** Press **A**, then click a card's 4 corners in any order. A magnifier appears while you click or drag. The orange edge marks the card's top; press **R** to rotate it.
3. **Adjust.** Drag corners or whole cards, or nudge them with the arrow keys. The preview shows the exact export output and updates as you edit. **P** opens it at full size.
4. **Set the output.** Width, height, corner radius (output pixels) and edge trim (scan pixels).
5. **Export** (Ctrl+E). Each card is written as `<prefix>_NN.png` to the chosen folder. Dropping a folder on the window sets the output folder.

## Controls

| Input | Action |
| --- | --- |
| A / N | Add a card (click its 4 corners; Esc cancels) |
| Drag corner / card | Move a corner / the whole card |
| Arrows (Shift = 10 px) | Nudge the focused corner, or the whole card when no corner is focused |
| Tab / Shift+Tab | Cycle focus: whole card → corners 1–4 |
| R / Shift+R | Rotate the card's orientation 90° clockwise / counter-clockwise |
| Del / Backspace | Delete the selected card |
| Wheel, right/middle drag, drag on empty space | Zoom, pan |
| F | Fit the scan to the window |
| P / Space | Full-size preview (wheel zoom, drag pan, 1 = 100%, F = fit, Esc closes) |
| Ctrl+= / Ctrl+- / Ctrl+0 | Larger / smaller interface, or back to automatic |

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

## Layout

| Path | Contents |
| --- | --- |
| `src/imaging/` | Pure-Odin image processing (no raylib): homography, bicubic perspective warp, Lanczos-3 resize, anti-aliased rounded-corner mask, multithreaded row helper. Unit tested. |
| `src/app.odin` | Application state, scan loading, card editing, preview, export requests |
| `src/main.odin` | Window loop, canvas input and drawing, magnifier, full-size preview |
| `src/panel.odin` | Side panel UI |
| `src/file_browser.odin` | Built-in file/folder browser (no OS dialog dependency) |
| `src/export.odin` | Background export thread and PNG writing |
| `src/ui_scale.odin` | Interface scale: monitor detection, `S()`/`fs()` sizing helpers, scaled dialog frame |
| `src/fonts.odin` | Inter fonts compiled into the executable, re-rendered for each scale; `draw_text`/`measure_text` |
| `assets/fonts/` | Inter Regular and SemiBold (SIL Open Font License 1.1, license alongside) |
| `src/replay.odin` | Input record/replay harness and the state dump replays are checked against |
| `tests/replay/` | Recorded sessions (`*.rec`), their scans, and expected results (`*.expected/`) |

## Roadmap

- [x] Manual card regions, straightening, rounded corners, transparent PNG export, live preview
- [ ] Moiré (halftone) removal: pure-Odin port of the original "Soft" filter
- [ ] Automatic card detection that proposes regions for the same editor
- [ ] Native file dialogs on Windows (`IFileOpenDialog`) and macOS (`NSOpenPanel`); multi-OS CI builds
