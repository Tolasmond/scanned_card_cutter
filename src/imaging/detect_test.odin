package imaging

// Synthetic scans ported from the original detector's test suite
// (workers/test_candidate_detector.py).

import "core:testing"

@(private = "file")
BED :: [3]u8{240, 236, 232} // the original tests' BGR (232, 236, 240)

@(private = "file")
background :: proc(w, h: int) -> Image {
	img := image_make(w, h)
	bed := BED
	for i := 0; i < len(img.pix); i += 4 do img.pix[i], img.pix[i + 1], img.pix[i + 2], img.pix[i + 3] = bed[0], bed[1], bed[2], 255
	return img
}

@(private = "file")
put :: #force_inline proc(img: ^Image, x, y: int, c: [3]u8) {
	if x < 0 || y < 0 || x >= img.w || y >= img.h do return
	p := img.pix[(y * img.w + x) * 4:]
	p[0], p[1], p[2] = c[0], c[1], c[2]
}

// Colours are written as in the Python tests (BGR) and stored as RGB.
@(private = "file")
bgr :: proc(b, g, r: u8) -> [3]u8 {return {r, g, b}}

@(private = "file")
fill_convex :: proc(img: ^Image, q: [4][2]int, c: [3]u8) {
	lo, hi := q[0], q[0]
	for p in q {lo = {min(lo.x, p.x), min(lo.y, p.y)}; hi = {max(hi.x, p.x), max(hi.y, p.y)}}
	for y in lo.y ..= hi.y {
		for x in lo.x ..= hi.x {
			sign := 0
			inside := true
			for i in 0 ..< 4 {
				a, b := q[i], q[(i + 1) % 4]
				cr := (b.x - a.x) * (y - a.y) - (b.y - a.y) * (x - a.x)
				if cr == 0 do continue
				s := 1 if cr > 0 else -1
				if sign == 0 do sign = s
				else if s != sign {inside = false; break}
			}
			if inside do put(img, x, y, c)
		}
	}
}

@(private = "file")
fill_rect :: proc(img: ^Image, x0, y0, x1, y1: int, c: [3]u8) {
	for y in y0 ..= y1 do for x in x0 ..= x1 do put(img, x, y, c)
}

@(private = "file")
fill_circle :: proc(img: ^Image, cx, cy, r: int, c: [3]u8) {
	for y in cy - r ..= cy + r do for x in cx - r ..= cx + r {
		if (x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r do put(img, x, y, c)
	}
}

@(private = "file")
fill_rounded :: proc(img: ^Image, q: [4][2]int, r: int, c: [3]u8) {
	l, t := q[0].x, q[0].y
	rt, b := q[2].x, q[2].y
	fill_rect(img, l + r, t, rt - r, b, c)
	fill_rect(img, l, t + r, rt, b - r, c)
	for p in ([4][2]int{{l + r, t + r}, {rt - r, t + r}, {rt - r, b - r}, {l + r, b - r}}) do fill_circle(img, p.x, p.y, r, c)
}

@(private = "file")
expect_corners :: proc(t: ^testing.T, got: Quad, want: [4][2]int, tol: f64, loc := #caller_location) {
	for k in 0 ..< 4 {
		if abs(got[k].x - f64(want[k].x)) > tol || abs(got[k].y - f64(want[k].y)) > tol {
			testing.expectf(t, false, "corner %d: got %v, want %v (±%v)", k, got[k], want[k], tol, loc = loc)
			return
		}
	}
}

@(test)
test_detect_rotated_and_axis_aligned_in_reading_order :: proc(t: ^testing.T) {
	img := background(900, 700)
	defer image_destroy(&img)
	expected := [4][4][2]int {
		{{80, 80}, {330, 80}, {330, 280}, {80, 280}},
		{{500, 60}, {760, 90}, {735, 300}, {475, 270}},
		{{120, 400}, {390, 380}, {405, 610}, {135, 630}},
		{{540, 390}, {790, 390}, {790, 620}, {540, 620}},
	}
	colors := [4][3]u8{bgr(40, 80, 180), bgr(180, 70, 30), bgr(50, 150, 70), bgr(120, 40, 150)}
	for q, i in expected do fill_convex(&img, q, colors[i])
	fill_circle(&img, 205, 180, 45, bgr(240, 240, 240))
	fill_rect(&img, 610, 450, 720, 560, bgr(20, 20, 20))
	fill_rect(&img, 15, 15, 17, 17, {0, 0, 0})

	cands := detect_cards(img)
	defer delete(cands)
	if !testing.expect_value(t, len(cands), 4) do return
	for c, i in cands do expect_corners(t, c.corners, expected[i], 3)
}

@(test)
test_detect_rejects_noise_and_concavity_keeps_border_clipped :: proc(t: ^testing.T) {
	img := background(640, 480)
	defer image_destroy(&img)
	fill_rect(&img, 30, 30, 35, 35, {0, 0, 0})
	// Concave L shape.
	fill_rect(&img, 180, 100, 420, 180, bgr(30, 70, 180))
	fill_rect(&img, 180, 180, 300, 330, bgr(30, 70, 180))
	fill_rect(&img, 0, 360, 180, 479, bgr(40, 120, 60))

	cands := detect_cards(img)
	defer delete(cands)
	if !testing.expect_value(t, len(cands), 1) do return
	expect_corners(t, cands[0].corners, {{0, 360}, {180, 360}, {180, 479}, {0, 479}}, 2)
}

@(test)
test_detect_rounded_card_to_virtual_corners :: proc(t: ^testing.T) {
	img := background(640, 480)
	defer image_destroy(&img)
	want := [4][2]int{{100, 80}, {360, 80}, {360, 380}, {100, 380}}
	fill_rounded(&img, want, 24, {255, 255, 255})
	fill_rect(&img, 122, 102, 338, 358, bgr(30, 80, 180))

	cands := detect_cards(img)
	defer delete(cands)
	if !testing.expect_value(t, len(cands), 1) do return
	expect_corners(t, cands[0].corners, want, 3)
	testing.expect_value(t, cands[0].source, Card_Source.Full_Resolution_Edges)
}

@(test)
test_detect_layout_recovers_missing_grid_card :: proc(t: ^testing.T) {
	img := background(700, 700)
	defer image_destroy(&img)
	expected: [9][4][2]int
	for row in 0 ..< 3 do for col in 0 ..< 3 {
		l, tp := 70 + col * 200, 55 + row * 210
		q := [4][2]int{{l, tp}, {l + 140, tp}, {l + 140, tp + 170}, {l, tp + 170}}
		expected[row * 3 + col] = q
		// The centre card is barely distinguishable from the bed.
		fill_convex(&img, q, bgr(234, 234, 234) if row == 1 && col == 1 else bgr(30, 80, 180))
	}
	cands := detect_cards(img)
	defer delete(cands)
	if !testing.expect_value(t, len(cands), 9) do return
	recovered := 0
	for c, i in cands {
		expect_corners(t, c.corners, expected[i], 3)
		if c.source == .Layout_Recovery do recovered += 1
	}
	testing.expect_value(t, recovered, 1)
	testing.expect_value(t, cands[4].source, Card_Source.Layout_Recovery)
}

@(test)
test_detect_separates_cards_across_thin_gap :: proc(t: ^testing.T) {
	img := background(3000, 1500)
	defer image_destroy(&img)
	expected := [2][4][2]int {
		{{300, 300}, {1000, 300}, {1000, 1200}, {300, 1200}},
		{{1004, 300}, {1704, 300}, {1704, 1200}, {1004, 1200}}, // 3 px gap: closes at detection scale
	}
	for q in expected do fill_convex(&img, q, bgr(30, 80, 180))
	cands := detect_cards(img)
	defer delete(cands)
	if !testing.expect_value(t, len(cands), 2) do return
	for c, i in cands do expect_corners(t, c.corners, expected[i], 4)
}

@(test)
test_detect_scanner_frame_does_not_join_cards :: proc(t: ^testing.T) {
	img := background(900, 700)
	defer image_destroy(&img)
	fill_rect(&img, 0, 0, 899, 3, bgr(20, 20, 20))
	expected := [2][4][2]int{{{100, 4}, {380, 4}, {380, 400}, {100, 400}}, {{460, 4}, {740, 4}, {740, 400}, {460, 400}}}
	for q in expected do fill_convex(&img, q, bgr(30, 80, 180))
	cands := detect_cards(img)
	defer delete(cands)
	if !testing.expect_value(t, len(cands), 2) do return
	for c, i in cands do expect_corners(t, c.corners, expected[i], 3)
}

@(test)
test_detect_splits_touching_rounded_cards_into_cells :: proc(t: ^testing.T) {
	img := background(1200, 900)
	defer image_destroy(&img)
	expected: [4][4][2]int
	for col in 0 ..< 3 do expected[col] = {{100 + 200 * col, 100}, {300 + 200 * col, 100}, {300 + 200 * col, 400}, {100 + 200 * col, 400}}
	expected[3] = {{850, 500}, {1050, 500}, {1050, 800}, {850, 800}}
	for q in expected {
		fill_rounded(&img, q, 24, bgr(150, 160, 170))
		fill_rect(&img, q[0].x + 20, q[0].y + 20, q[2].x - 20, q[2].y - 20, bgr(30, 80, 180))
	}
	cands := detect_cards(img)
	defer delete(cands)
	if !testing.expect_value(t, len(cands), 4) do return
	want_sources := [4]Card_Source{.Layout_Recovery, .Layout_Recovery, .Layout_Recovery, .Full_Resolution_Edges}
	for c, i in cands {
		expect_corners(t, c.corners, expected[i], 4)
		testing.expect_value(t, c.source, want_sources[i])
	}
}

@(test)
test_detect_does_not_split_square_cards_without_notches :: proc(t: ^testing.T) {
	img := background(1200, 900)
	defer image_destroy(&img)
	merged := [4][2]int{{100, 100}, {700, 100}, {700, 400}, {100, 400}}
	separate := [4][2]int{{850, 500}, {1050, 500}, {1050, 800}, {850, 800}}
	fill_convex(&img, merged, bgr(30, 80, 180))
	fill_convex(&img, separate, bgr(30, 80, 180))
	cands := detect_cards(img)
	defer delete(cands)
	if !testing.expect_value(t, len(cands), 2) do return
	expect_corners(t, cands[0].corners, merged, 3)
}

@(test)
test_find_external_contours_skips_holes :: proc(t: ^testing.T) {
	m := mask_make(20, 20)
	defer mask_destroy(&m)
	// A ring with a blob inside its hole: only the ring is external.
	for y in 2 ..< 18 do for x in 2 ..< 18 do m.pix[y * 20 + x] = 255
	for y in 5 ..< 15 do for x in 5 ..< 15 do m.pix[y * 20 + x] = 0
	for y in 8 ..< 11 do for x in 8 ..< 11 do m.pix[y * 20 + x] = 255
	cs := find_external_contours(m, context.temp_allocator)
	testing.expect_value(t, len(cs), 1)
	if len(cs) == 1 {
		testing.expect_value(t, len(cs[0]), 4) // a square's outline compresses to its corners
		testing.expect_value(t, polygon_area(cs[0]), 15.0 * 15.0)
	}
}
