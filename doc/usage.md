# Using Scan Tool

Scan Tool works on one scan per session. Open a scan, mark the cards, adjust them, and export. There are no projects to save: once the cards are exported, the scan is done.

## Workflow

1. **Open a scan.** Use *Open…* (Ctrl+O), copy the PNG in your file manager and press **Ctrl+V** in the app, drop a PNG on the window, or pass the path as an argument. Or **Scan** (Ctrl+N) straight into the app with a scanner you have set up (see [Scanning](#scanning)).
2. **Mark the cards.** Press **D** (*Detect cards*) to find them automatically, or press **A** and click a card's 4 corners in any order. The orange edge marks the card's top; press **R** to rotate it. Detected cards the detector is unsure of are drawn pink and marked *review* until you adjust them.
3. **Adjust.** Drag corners or whole cards, or nudge them with the arrow keys. The preview shows the exact export output and updates as you edit. **P** opens it at full size.
4. **Set the output.** Width, height, corner radius (output pixels) and edge trim (scan pixels). Tick **Remove moiré** (M) to filter out the printed halftone pattern (see [Moiré removal](#moiré-removal)).
5. **Export** (Ctrl+E). Each card is written as `<prefix>_NN.png` to the chosen folder. Pasting (Ctrl+V) or dropping a folder sets the output folder.

**Drag and drop on Hyprland:** the app runs under XWayland, because Odin's bundled raylib is built for X11. Hyprland 0.56 does not deliver drags from native Wayland apps, such as GNOME Files, to XWayland windows. Use Ctrl+C in the file manager and Ctrl+V in the app instead. Drops from X11 apps, and on Windows and macOS, work normally.

## Controls

| Input | Action |
| --- | --- |
| D | Detect cards automatically (adds only cards not already marked) |
| A / N | Add a card (click its 4 corners; Esc cancels) |
| Drag corner / card | Move a corner / the whole card |
| Arrows (Shift = 10 px) | Nudge the focused corner, or the whole card when no corner is focused |
| C / Shift+C | Focus the next / previous corner of the card (1 → 2 → 3 → 4 → 1). The view pans to center a corner that is off screen or near the edge. Esc goes back to nudging the whole card |
| Alt+C / Shift+Alt+C | Focus corner 1 of the next / previous card |
| Tab / Shift+Tab | Move keyboard focus through the panel's buttons and boxes. A box is ready to type in when focused |
| Enter / Space | Press the focused button or tick the focused box. Enter edits a focused box again after Esc |
| Up / Down | With the card list focused (click it, or Tab to it): select the previous / next card |
| Esc | Stop editing a box, then give the keys back to the canvas (so do clicks) |
| R / Shift+R | Rotate the card's orientation 90° clockwise / counter-clockwise |
| Del / Backspace | Delete the selected card |
| Wheel, right/middle drag, drag on empty space | Zoom, pan |
| F | Fit the scan to the window |
| P / Space | Full-size preview (wheel zoom, drag pan, 1 = 100%, F = fit, Esc closes) |
| M | Moiré removal on/off |
| Ctrl+= / Ctrl+- / Ctrl+0 | Larger / smaller interface, or back to automatic |
| Ctrl+N / Scan button | Scan with the chosen scanner profile (the button cancels a running scan) |
| Ctrl+V | Paste a file copied in a file manager: a PNG opens as the scan, a folder becomes the output folder |
| Ctrl+Q / Exit button | Quit (waits for a running export to finish writing its files) |

## Scanning

**Scan** runs a command you set up that writes a PNG, opens the PNG as the scan and deletes the file. The app has no scanner drivers of its own: any program that can scan to a PNG works, so each scanner, driver or platform is a few lines of configuration rather than code. The profiles live in `scanners.ini` in your config folder:

| OS | File |
| --- | --- |
| Linux | `~/.config/scan_tool/scanners.ini` (or under `$XDG_CONFIG_HOME`) |
| macOS | `~/Library/Application Support/scan_tool/scanners.ini` |
| Windows | `%LOCALAPPDATA%\scan_tool\scanners.ini` |

Pressing *Scan* before the file exists writes it with commented-out examples. Each section is one profile:

```ini
[Flatbed 300 dpi]
command = scanimage --source Flatbed --mode Color --resolution 300 --format=png -o {out}

[Flatbed 600 dpi]
command = scanimage --source Flatbed --mode Color --resolution 600 --format=png -o {out}
```

- **`{out}`** is where the command must write the PNG: a new file in a temporary folder, removed after the scan opens. It can be part of an argument (`--output={out}`).
- **The command runs directly, not through a shell.** It is split into arguments at spaces, and `"..."` or `'...'` group an argument that contains spaces. There are no backslash escapes, so Windows paths work as written. For pipes or several steps, point the command at a script.
- **Choosing a profile.** With more than one profile a *Scanner* selector appears under the Scan button; click it or press Enter on it to step through them. The file is read again on every scan, so edits apply without restarting.
- **While it runs** the status line says so, and the button becomes *Cancel scan*, which kills the command (not programs a script started). If the command fails, the status line shows its exit code and the last line it printed.
- **The scan is not kept.** It is named after the time (`scan-20261115-170802.png`), which becomes the file prefix, so cards from scans made one after another get different names. The export folder is not changed: choose one before the first export.

### Scanning tips

- **Scan at 300 dpi**: detection is tuned for it.
- **White-bordered cards: cover them with a matte black sheet.** On the white lid a white border is almost invisible, and detection ends up on the printed frame inside it. Detection takes the scanner bed's color from the edges of the scan, so the sheet must fill the whole glass out to every edge; glossy black reflects the lamp and comes out patchy. Cards with dark or colored borders scan best on the plain lid.

## Card detection

**Detect cards** (D) finds the cards on the scan and adds each one as an ordinary editable card. It takes about 0.3 s for a 2550 x 3507 scan, and always works on the original scan, never on the moiré-filtered copy.

It handles cards laid out with gaps, packed tightly together, touching, overlapping a little, rotated, and with frames the color of the scanner bed. See [Architecture](arch.md#card-detection) for how.

- **Trusted cards** have all four sides fitted to edges the scan shows clearly.
- **Review cards** (pink) involve a guess: a seam between touching cards, an edge hidden under another card and placed by the card size, a faint outer edge, a gap in a regular layout, or a coarse outline. Check them. The mark clears when you adjust the card.
- **Detection never replaces your cards.** It only adds cards that don't overlap the ones you already have, so you can run it again after deleting a wrong card.

Typical corner error is about 2 px on simple layouts and about 5 px on tightly packed real scans. What it still gets wrong:

- **Hidden edges are estimates.** The edge of a card under another card is placed by the size the other cards agree on, to within a few pixels at best.
- **Touching square-cornered cards** are split only when another card on the scan shows the card size.
- **Shadow sides.** On a white-framed card, the side next to the lamp shadow can land 2 to 4 px outside the card.

## Moiré removal

Printed cards are made of halftone dots, and a flatbed scan of them shows a grainy or wavy moiré pattern. **Remove moiré** runs a descreen filter once over the whole scan in the background. A 2550 x 3507 scan takes about 2.5 s on 16 threads.

- Previews, the full-size preview and exports use the cleaned scan once it is ready.
- The canvas where you place corners always shows the original scan, and card detection uses it too: the filter softens card edges, which makes them harder to find.
- Export waits while the filter runs.
- Turning the filter off keeps the result, so turning it back on is instant.

## Interface scale

The interface scales for high-density monitors and follows the window when it moves to another monitor. Text uses Inter, which is rendered again at the exact pixel size for each scale, so it stays sharp at any scale.

- **Windows:** uses the display scale set in Windows.
- **macOS:** 1x. macOS already lays windows out in points and scales them.
- **Linux:** uses `Xft.dpi` when set. Otherwise it uses the monitor's pixel density in whole steps (about 150–250 dpi gives 2x). Under XWayland with `force_zero_scaling`, this is what makes the text readable.

Ctrl+= and Ctrl+- override the automatic choice for the session, in 0.25 steps. Ctrl+0 goes back to automatic.
