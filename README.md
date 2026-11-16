# Scan Tool

Turn a flatbed scan of card game or board game cards into clean, straightened card images.

Scan Tool finds the cards on a scan, lets you check and adjust each one with a live preview, and saves every card as a PNG with transparent rounded corners. It can also remove the moiré pattern that printed halftone dots leave on a scan.

It is a small desktop app written in [Odin](https://odin-lang.org) with raylib, and it builds with only what ships with Odin. It runs on Linux, Windows and macOS (untested).

## Features

- **Automatic card detection** that copes with cards packed tightly together, touching, overlapping, or rotated. Cards it is unsure of are marked for review.
- **Manual adjustment** of every corner, with the mouse or the keyboard, and a preview that shows the exact output.
- **Straightening and sizing:** each card is warped to a rectangle and written at the width, height and corner radius you choose, with transparent corners.
- **Moiré removal** for printed cards, applied only to the output, never to what detection sees.
- **Scan straight into the app** with any scanning program you can run from a command line.
- **Open scans your way:** the built-in file browser, Ctrl+V after copying a file in your file manager, drag and drop, or the command line.
- **Sharp on high-density monitors**, with the Inter font built in.

## Quick start

Programs for Linux and Windows (x86-64) are on the [releases page](https://github.com/Tolasmond/odin_scan_tool/releases).

- **Linux:** needs glibc 2.38 or newer (Ubuntu 24.04, Debian 13, Fedora 39 or later) and an X11 or XWayland desktop.
- **Windows:** needs Windows 10 version 1903 or later and the [Microsoft Visual C++ Redistributable](https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist) (2015–2022, x64), which most Windows computers already have.

To build it yourself, install the [Odin toolchain](https://odin-lang.org/docs/install/) for your OS, then:

```sh
./build.sh                 # Linux and macOS: builds build/scan_tool
build/scan_tool scan.png
```

On Windows, run `build.bat` from a prompt where Odin can find the MSVC linker, which gives `build\scan_tool.exe`.

Then:

1. Press **D** to detect the cards, or **A** and click a card's four corners.
2. Drag corners to adjust them. Pink cards are guesses: check them.
3. Set the output size and folder in the side panel, and tick **Remove moiré** (M) if you need it.
4. Press **Ctrl+E** to export. Each card is saved as `<prefix>_NN.png`.

## Documentation

- **[Usage](doc/usage.md):** the workflow, every control, scanning, detection, moiré removal and interface scale.
- **[Development](doc/development.md):** building, the unit and replay tests, the synthetic test scans and the benchmarks.
- **[Architecture](doc/arch.md):** how the source is laid out and how the image pipeline works.

## License

Scan Tool is released under the [MIT License](LICENSE). The Inter font, raylib and other included components keep their own licenses; see [THIRD_PARTY.md](THIRD_PARTY.md).
