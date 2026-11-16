# Third-party components

Scanned Card Cutter's own code is under the [MIT License](LICENSE). It includes, links or adapts the components below, which keep their own licenses. Release archives carry this file, `Inter-LICENSE.txt` and `Apache-2.0.txt` next to the program.

## Bundled with this repository

### Inter

The interface font: `assets/fonts/Inter-Regular.ttf` and `assets/fonts/Inter-SemiBold.ttf`, compiled into the executable.

- Copyright (c) 2016 The Inter Project Authors (<https://github.com/rsms/inter>)
- License: SIL Open Font License 1.1, in [`assets/fonts/Inter-LICENSE.txt`](assets/fonts/Inter-LICENSE.txt) (`Inter-LICENSE.txt` in a release archive)

## Linked into the executable

These ship with the Odin toolchain and are linked when the app is built.

### Odin core library

- Copyright (c) 2016-2025 Ginger Bill (<https://odin-lang.org>)
- License: zlib, in `LICENSE` in the Odin installation

### raylib

Windowing, input, drawing, image loading and PNG writing. Linked statically from Odin's `vendor:raylib`.

- Copyright (c) 2013-2026 Ramon Santamaria (@raysan5) (<https://www.raylib.com>)
- License: zlib, in `vendor/raylib/LICENSE` in the Odin installation

raylib includes further libraries. These are the ones linked into Scanned Card Cutter; their notices are in raylib's source under `src/external` (<https://github.com/raysan5/raylib/tree/master/src/external>):

- GLFW, windows and input: zlib
- glad, the OpenGL loader: the generated loader is under WTFPL or CC0-1.0, and the OpenGL API definitions it is generated from are under the Apache License 2.0 (see [OpenCV](#opencv) for the text)
- stb_image, stb_image_write, stb_truetype and stb_rect_pack, by Sean Barrett: MIT or public domain, at the user's choice
- sdefl and sinfl, by Micha Mettke, compression for PNG writing: MIT or public domain, at the user's choice
- QOI, by Dominic Szablewski, an image format: MIT, notice [below](#qoi-notice)
- rprand and rl_gputex, by Ramon Santamaria: zlib

### raygui

The panel's buttons, boxes and sliders, from Odin's `vendor:raylib`.

- Copyright (c) 2014-2026 Ramon Santamaria (@raysan5) (<https://github.com/raysan5/raygui>)
- License: zlib

## Adapted algorithms

### OpenCV

Parts of `src/imaging/` are pure-Odin ports of OpenCV 4.12 algorithms, written to match OpenCV's results:

- `descreen.odin`: `resize` with `INTER_CUBIC` and `INTER_AREA`, `medianBlur`, `fastNlMeansDenoisingColored` (including OpenCV's integer Lab conversion tables), `bilateralFilter` and `GaussianBlur`.
- `morph.odin`: elliptical structuring elements, erosion and dilation, `COLOR_BGR2GRAY` and `Canny`.
- `contours.odin`: `findContours` (external contours), `contourArea`, `arcLength`, `boundingRect`, `approxPolyDP`, `minAreaRect`, `intersectConvexConvex` and `fitLine` with `DIST_HUBER`.
- `detect.odin`: 8-bit Lab color conversion (`COLOR_BGR2Lab`).

- Copyright (C) 2000-2022 Intel Corporation, Copyright (C) 2009-2011 Willow Garage Inc., Copyright (C) 2015-2023 OpenCV Foundation, and other contributors (<https://opencv.org>)
- License: Apache License 2.0, in [`licenses/Apache-2.0.txt`](licenses/Apache-2.0.txt) (`Apache-2.0.txt` in a release archive)

The ports are rewritten in Odin and differ from OpenCV in structure; they keep OpenCV's arithmetic, rounding and border handling so their output can be compared with OpenCV's.

## QOI notice

```
Copyright (c) 2021, Dominic Szablewski - https://phoboslab.org
SPDX-License-Identifier: MIT

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
