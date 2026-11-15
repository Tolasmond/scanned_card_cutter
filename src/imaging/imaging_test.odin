package imaging

import "core:testing"

@(private = "file")
near :: proc(a, b: Vec2, eps := 1e-6) -> bool {
	return abs(a.x - b.x) < eps && abs(a.y - b.y) < eps
}

@(test)
test_homography_maps_corners :: proc(t: ^testing.T) {
	from := [4]Vec2{{0, 0}, {100, 0}, {100, 50}, {0, 50}}
	to := [4]Vec2{{10, 12}, {120, 5}, {130, 70}, {4, 60}}
	m, ok := homography_from_points(from, to)
	testing.expect(t, ok)
	for i in 0 ..< 4 do testing.expectf(t, near(homography_apply(m, from[i]), to[i]), "corner %d", i)
}

@(test)
test_homography_rejects_degenerate :: proc(t: ^testing.T) {
	from := [4]Vec2{{0, 0}, {1, 0}, {1, 1}, {0, 1}}
	to := [4]Vec2{{0, 0}, {1, 1}, {2, 2}, {3, 3}}
	_, ok := homography_from_points(from, to)
	testing.expect(t, !ok)
}

@(test)
test_order_corners_any_input_order :: proc(t: ^testing.T) {
	want := [4]Vec2{{10, 12}, {120, 5}, {130, 70}, {4, 60}}
	got := order_corners({want[2], want[0], want[3], want[1]})
	for i in 0 ..< 4 do testing.expectf(t, near(got[i], want[i]), "corner %d: %v", i, got[i])
	testing.expect(t, quad_is_valid(got))
	testing.expect(t, !quad_is_valid({want[0], want[2], want[1], want[3]})) // bow-tie
}

// An axis-aligned quad at integer bounds must reproduce the exact source pixels.
@(test)
test_axis_aligned_extract_is_exact_crop :: proc(t: ^testing.T) {
	src := image_make(40, 30)
	defer image_destroy(&src)
	for y in 0 ..< 30 do for x in 0 ..< 40 {
		p := src.pix[(y * 40 + x) * 4:]
		p[0], p[1], p[2], p[3] = u8(x * 6), u8(y * 8), u8((x + y) * 3), 255
	}
	out, ok := extract_card(src, {{5, 4}, {25, 4}, {25, 20}, {5, 20}}, {width = 20, height = 16})
	defer image_destroy(&out)
	testing.expect(t, ok)
	for y in 0 ..< 16 do for x in 0 ..< 20 {
		got := out.pix[(y * 20 + x) * 4:][:4]
		want := src.pix[((y + 4) * 40 + x + 5) * 4:][:4]
		for c in 0 ..< 4 {
			if got[c] != want[c] {
				testing.expectf(t, false, "pixel %d,%d ch %d: got %d want %d", x, y, c, got[c], want[c])
				return
			}
		}
	}
}

@(test)
test_resize_preserves_flat_color :: proc(t: ^testing.T) {
	src := image_make(97, 61)
	defer image_destroy(&src)
	for i := 0; i < len(src.pix); i += 4 do src.pix[i], src.pix[i + 1], src.pix[i + 2], src.pix[i + 3] = 200, 100, 50, 255
	for size in ([][2]int{{30, 20}, {250, 160}}) {
		out := resize_lanczos3(src, size.x, size.y)
		defer image_destroy(&out)
		for i := 0; i < len(out.pix); i += 4 {
			testing.expect(t, out.pix[i] == 200 && out.pix[i + 1] == 100 && out.pix[i + 2] == 50 && out.pix[i + 3] == 255)
		}
	}
}

@(test)
test_rounded_mask :: proc(t: ^testing.T) {
	img := image_make(100, 140)
	defer image_destroy(&img)
	for i := 0; i < len(img.pix); i += 4 do img.pix[i + 3] = 255
	apply_rounded_mask(&img, 20)
	alpha :: proc(img: Image, x, y: int) -> u8 {return img.pix[(y * img.w + x) * 4 + 3]}
	testing.expect_value(t, alpha(img, 0, 0), 0)
	testing.expect_value(t, alpha(img, 99, 0), 0)
	testing.expect_value(t, alpha(img, 99, 139), 0)
	testing.expect_value(t, alpha(img, 0, 139), 0)
	testing.expect_value(t, alpha(img, 50, 0), 255)   // straight top edge stays opaque
	testing.expect_value(t, alpha(img, 0, 70), 255)   // straight left edge stays opaque
	testing.expect_value(t, alpha(img, 50, 70), 255)  // center
	testing.expect_value(t, alpha(img, 20, 20), 255)  // arc center
	a := alpha(img, 0, 15)                             // pixel center sits on the arc -> partial
	testing.expectf(t, a > 0 && a < 255, "arc pixel should be partially covered, got %d", a)
}
