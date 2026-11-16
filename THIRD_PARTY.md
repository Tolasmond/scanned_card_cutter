# Third-party components

Scan Tool's own code is under the [MIT License](LICENSE). It includes, links or adapts the components below, which keep their own licenses.

## Bundled with this repository

### Inter

The interface font: `assets/fonts/Inter-Regular.ttf` and `assets/fonts/Inter-SemiBold.ttf`, compiled into the executable.

- Copyright (c) 2016 The Inter Project Authors (<https://github.com/rsms/inter>)
- License: SIL Open Font License 1.1, in [`assets/fonts/Inter-LICENSE.txt`](assets/fonts/Inter-LICENSE.txt)

## Linked into the executable

These ship with the Odin toolchain and are linked when the app is built.

### Odin core library

- Copyright (c) 2016-2025 Ginger Bill (<https://odin-lang.org>)
- License: zlib, in `LICENSE` in the Odin installation

### raylib

Windowing, input, drawing, image loading and PNG writing. Linked statically from Odin's `vendor:raylib`.

- Copyright (c) 2013-2026 Ramon Santamaria (@raysan5) (<https://www.raylib.com>)
- License: zlib, in `vendor/raylib/LICENSE` in the Odin installation

raylib includes further libraries, among them GLFW (zlib), stb_image, stb_image_write and stb_truetype (MIT or public domain) and miniaudio (MIT-0 or public domain). Their notices are in raylib's source under `src/external` (<https://github.com/raysan5/raylib/tree/master/src/external>).

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
- License: Apache License 2.0 (<https://www.apache.org/licenses/LICENSE-2.0>)

The ports are rewritten in Odin and differ from OpenCV in structure; they keep OpenCV's arithmetic, rounding and border handling so their output can be compared with OpenCV's.
