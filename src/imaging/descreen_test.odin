package imaging

import "core:testing"

@(private = "file")
flat :: proc(w, h: int, c: [4]u8) -> Image {
	img := image_make(w, h)
	c := c
	for i := 0; i < len(img.pix); i += 4 do copy(img.pix[i:][:4], c[:])
	return img
}

@(private = "file")
max_channel_diff :: proc(img: Image, c: [4]u8) -> int {
	worst := 0
	for i := 0; i < len(img.pix); i += 4 {
		for k in 0 ..< 4 do worst = max(worst, abs(int(img.pix[i + k]) - int(c[k])))
	}
	return worst
}

// A uniform window pushes the NL-means sum to the edge of 32 bits; this once
// turned white areas black. OpenCV's Lab round trip maps white to 254, and so
// does the same filter built with OpenCV, so 254 is the expected result.
@(test)
test_descreen_keeps_white_white :: proc(t: ^testing.T) {
	src := flat(48, 40, {255, 255, 255, 255})
	defer image_destroy(&src)
	out, ok := descreen_soft(src)
	defer image_destroy(&out)
	testing.expect(t, ok)
	testing.expect_value(t, max_channel_diff(out, {254, 254, 254, 255}), 0)
}

@(test)
test_descreen_keeps_flat_colour :: proc(t: ^testing.T) {
	c := [4]u8{200, 100, 50, 255}
	src := flat(40, 48, c)
	defer image_destroy(&src)
	out, ok := descreen_soft(src)
	defer image_destroy(&out)
	testing.expect(t, ok)
	testing.expect_value(t, out.w, src.w)
	testing.expect_value(t, out.h, src.h)
	d := max_channel_diff(out, c)
	testing.expectf(t, d <= 2, "flat colour drifted by %d", d) // Lab round trip rounding only
}

@(test)
test_descreen_preserves_alpha :: proc(t: ^testing.T) {
	src := flat(32, 32, {90, 90, 90, 255})
	defer image_destroy(&src)
	src.pix[(5 * 32 + 7) * 4 + 3] = 17
	out, _ := descreen_soft(src)
	defer image_destroy(&out)
	testing.expect_value(t, out.pix[(5 * 32 + 7) * 4 + 3], 17)
	testing.expect_value(t, out.pix[3], 255)
}

// A fine halftone dot grid (every third pixel, contrast 40) is flattened; the
// same filter built with OpenCV takes its standard deviation from 12.7 to 0.0.
@(test)
test_descreen_smooths_halftone :: proc(t: ^testing.T) {
	W, H :: 96, 96
	src := image_make(W, H)
	defer image_destroy(&src)
	for y in 0 ..< H do for x in 0 ..< W {
		v: u8 = 120 if x % 3 == 0 && y % 3 == 0 else 160
		p := src.pix[(y * W + x) * 4:]
		p[0], p[1], p[2], p[3] = v, v, v, 255
	}
	out, _ := descreen_soft(src)
	defer image_destroy(&out)
	variance :: proc(img: Image) -> f64 {
		// Ignore the border, where reflection padding matters.
		sum, sq, n := 0.0, 0.0, 0.0
		for y in 8 ..< img.h - 8 do for x in 8 ..< img.w - 8 {
			v := f64(img.pix[(y * img.w + x) * 4])
			sum += v; sq += v * v; n += 1
		}
		mean := sum / n
		return sq / n - mean * mean
	}
	before, after := variance(src), variance(out)
	testing.expectf(t, before > 100 && after < 1, "halftone variance %.1f -> %.1f, expected it flattened", before, after)
}

@(test)
test_descreen_cancel :: proc(t: ^testing.T) {
	src := flat(64, 64, {10, 20, 30, 255})
	defer image_destroy(&src)
	p := Descreen_Progress{cancel = true}
	out, ok := descreen_soft(src, &p)
	testing.expect(t, !ok)
	testing.expect(t, out.pix == nil)
}

@(test)
test_median3_removes_outlier :: proc(t: ^testing.T) {
	src := flat(9, 9, {100, 100, 100, 255})
	defer image_destroy(&src)
	src.pix[(4 * 9 + 4) * 4] = 255
	out := median3(src)
	defer image_destroy(&out)
	testing.expect_value(t, out.pix[(4 * 9 + 4) * 4], 100)
}

@(test)
test_lab8_known_values :: proc(t: ^testing.T) {
	testing.expect_value(t, rgb_to_lab8(255, 255, 255), [3]u8{255, 128, 128})
	testing.expect_value(t, rgb_to_lab8(0, 0, 0), [3]u8{0, 128, 128})
	testing.expect_value(t, lab8_to_rgb(255, 128, 128), [3]u8{254, 254, 254}) // as OpenCV
	testing.expect_value(t, lab8_to_rgb(0, 128, 128), [3]u8{0, 0, 0})
}

@(test)
test_reflect101 :: proc(t: ^testing.T) {
	want := [?]int{2, 1, 0, 1, 2, 3, 4, 3, 2}
	for i in -2 ..= 6 do testing.expect_value(t, reflect101(i, 5), want[i + 2])
}
