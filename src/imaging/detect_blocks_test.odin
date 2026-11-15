package imaging

// Tests for the additions to the ported detector: blocks split at their
// notches (detect_blocks.odin), faint outer edges of bed-coloured frames
// (detect_frames.odin) and artwork proposals inside cards.

import "core:testing"

// A rounded card with a frame and a plain artwork window.
@(private = "file")
draw_card :: proc(img: ^Image, q: [4][2]int, radius: int, frame, art: [3]u8, inset := 30) {
	fill_rounded(img, q, radius, frame)
	fill_rect(img, q[0].x + inset, q[0].y + inset, q[2].x - inset, q[2].y - inset, art)
}

@(private = "file")
rect :: proc(l, t, w, h: int) -> [4][2]int {
	return {{l, t}, {l + w, t}, {l + w, t + h}, {l, t + h}}
}

@(test)
test_detect_splits_touching_block_without_a_lone_card :: proc(t: ^testing.T) {
	// Four touching cards and nothing else on the scan: no proposal shows the
	// card size, so only the notches and the pocket can split the block.
	img := background(1100, 1300)
	defer image_destroy(&img)
	expected: [4][4][2]int
	frames := [2][3]u8{bgr(150, 160, 170), bgr(90, 100, 120)}
	for row in 0 ..< 2 do for col in 0 ..< 2 {
		q := rect(200 + col * 300, 150 + row * 420, 300, 420)
		expected[row * 2 + col] = q
		draw_card(&img, q, 30, frames[(row + col) % 2], bgr(30, 80, 180))
	}
	cands := detect_cards(img)
	defer delete(cands)
	if !testing.expect_value(t, len(cands), 4) do return
	for c, i in cands {
		expect_corners(t, c.corners, expected[i], 3)
		testing.expect_value(t, c.source, Card_Source.Layout_Recovery)
	}
}

@(test)
test_detect_splits_block_of_same_coloured_cards_at_notches :: proc(t: ^testing.T) {
	// The seam between two frames of one colour shows no line at all: the
	// notches alone place it.
	img := background(1100, 800)
	defer image_destroy(&img)
	expected := [2][4][2]int{rect(200, 150, 300, 420), rect(500, 150, 300, 420)}
	for q in expected do draw_card(&img, q, 30, bgr(150, 160, 170), bgr(30, 80, 180))
	cands := detect_cards(img)
	defer delete(cands)
	if !testing.expect_value(t, len(cands), 2) do return
	for c, i in cands {
		expect_corners(t, c.corners, expected[i], 3)
		testing.expect_value(t, c.source, Card_Source.Layout_Recovery)
	}
}

@(test)
test_detect_separates_overlapping_cards_and_restores_hidden_edge :: proc(t: ^testing.T) {
	img := background(1300, 1300)
	defer image_destroy(&img)
	// The second card lies 10 px over the first one's right edge. A third card
	// of the same size, on its own, confirms the size.
	under := rect(200, 150, 300, 420)
	over := rect(490, 150, 300, 420)
	alone := rect(250, 700, 300, 420)
	draw_card(&img, under, 30, bgr(150, 160, 170), bgr(30, 80, 180))
	draw_card(&img, over, 30, bgr(60, 70, 90), bgr(40, 150, 70))
	draw_card(&img, alone, 30, bgr(150, 160, 170), bgr(120, 40, 150))
	cands := detect_cards(img)
	defer delete(cands)
	if !testing.expect_value(t, len(cands), 3) do return
	// The hidden right edge of the lower card comes from the card size.
	expect_corners(t, cands[0].corners, under, 3)
	expect_corners(t, cands[1].corners, over, 3)
	expect_corners(t, cands[2].corners, alone, 3)
	testing.expect_value(t, cands[0].source, Card_Source.Layout_Recovery)
	testing.expect_value(t, cands[1].source, Card_Source.Layout_Recovery)
	testing.expect_value(t, cands[2].source, Card_Source.Full_Resolution_Edges)
}

@(test)
test_detect_overlap_without_size_witness_stops_at_visible_edge :: proc(t: ^testing.T) {
	// Two overlapping cards alone: nothing confirms the card size, so the
	// lower card ends at the upper card's edge rather than at a guess.
	img := background(1300, 800)
	defer image_destroy(&img)
	under := rect(200, 150, 300, 420)
	over := rect(490, 150, 300, 420)
	draw_card(&img, under, 30, bgr(150, 160, 170), bgr(30, 80, 180))
	draw_card(&img, over, 30, bgr(60, 70, 90), bgr(40, 150, 70))
	cands := detect_cards(img)
	defer delete(cands)
	if !testing.expect_value(t, len(cands), 2) do return
	expect_corners(t, cands[0].corners, rect(200, 150, 290, 420), 3)
	expect_corners(t, cands[1].corners, over, 3)
}

@(test)
test_detect_splits_block_cut_by_scan_border :: proc(t: ^testing.T) {
	// The right column runs off the scan beyond its rounded corners, so the
	// row seam has a notch on the left only; the pocket confirms it.
	img := background(1000, 1300)
	defer image_destroy(&img)
	frames := [2][3]u8{bgr(150, 160, 170), bgr(90, 100, 120)}
	expected: [4][4][2]int
	for row in 0 ..< 2 do for col in 0 ..< 2 {
		q := rect(440 + col * 300, 150 + row * 420, 300, 420)
		draw_card(&img, q, 30, frames[(row + col) % 2], bgr(30, 80, 180))
		for &p in q do p.x = min(p.x, 999)
		expected[row * 2 + col] = q
	}
	cands := detect_cards(img)
	defer delete(cands)
	if !testing.expect_value(t, len(cands), 4) do return
	for c, i in cands do expect_corners(t, c.corners, expected[i], 3)
}

@(test)
test_detect_splits_block_against_scanner_lid_strip :: proc(t: ^testing.T) {
	// The top row touches the dark lid strip, which closes the notches on
	// that side. The column seam has its bottom notch only; the pocket where
	// it crosses the row seam confirms it.
	img := background(1100, 1300)
	defer image_destroy(&img)
	fill_rect(&img, 0, 0, 1099, 5, bgr(20, 20, 20))
	frames := [2][3]u8{bgr(150, 160, 170), bgr(90, 100, 120)}
	expected: [4][4][2]int
	for row in 0 ..< 2 do for col in 0 ..< 2 {
		q := rect(200 + col * 300, 6 + row * 420, 300, 420)
		expected[row * 2 + col] = q
		draw_card(&img, q, 30, frames[(row + col) % 2], bgr(30, 80, 180))
	}
	cands := detect_cards(img)
	defer delete(cands)
	if !testing.expect_value(t, len(cands), 4) do return
	for c, i in cands do expect_corners(t, c.corners, expected[i], 4)
}

@(test)
test_detect_keeps_card_with_a_mark_on_one_side_whole :: proc(t: ^testing.T) {
	// A bed-coloured wedge in the top edge looks like a notch, but nothing
	// answers it on the bottom edge: one card, not two.
	img := background(900, 900)
	defer image_destroy(&img)
	want := rect(200, 150, 480, 600)
	fill_rounded(&img, want, 30, bgr(150, 160, 170))
	bed := BED
	for d in 0 ..< 36 do fill_rect(&img, 440 - (36 - d) / 3, 150 + d, 440 + (36 - d) / 3, 150 + d, bed)
	cands := detect_cards(img)
	defer delete(cands)
	if !testing.expect_value(t, len(cands), 1) do return
	expect_corners(t, cands[0].corners, want, 3)
	testing.expect_value(t, cands[0].source, Card_Source.Full_Resolution_Edges)
}

// A frame 8 gray levels below the bed: inside every colour threshold.
@(private = "file")
PALE_FRAME :: [3]u8{232, 228, 224}

@(test)
test_detect_grows_to_faint_edge_of_bed_coloured_frame :: proc(t: ^testing.T) {
	img := background(900, 900)
	defer image_destroy(&img)
	want := rect(250, 200, 360, 480)
	draw_card(&img, want, 24, PALE_FRAME, bgr(30, 80, 180), 26)
	cands := detect_cards(img)
	defer delete(cands)
	if !testing.expect_value(t, len(cands), 1) do return
	expect_corners(t, cands[0].corners, want, 2)
	testing.expect_value(t, cands[0].source, Card_Source.Faint_Outer_Edges)
}

@(test)
test_detect_faint_edge_needs_all_four_sides :: proc(t: ^testing.T) {
	// A pale band on three sides only is not a frame: the card stays as fitted.
	img := background(900, 900)
	defer image_destroy(&img)
	frame := PALE_FRAME
	fill_rect(&img, 250, 200, 610, 654, frame) // ends at the artwork's bottom edge
	want := rect(276, 226, 308, 428)
	fill_rect(&img, want[0].x, want[0].y, want[2].x, want[2].y, bgr(30, 80, 180))
	cands := detect_cards(img)
	defer delete(cands)
	if !testing.expect_value(t, len(cands), 1) do return
	expect_corners(t, cands[0].corners, want, 2)
	testing.expect_value(t, cands[0].source, Card_Source.Full_Resolution_Edges)
}

@(test)
test_detect_faint_edge_does_not_reach_for_neighbours :: proc(t: ^testing.T) {
	// The centre card of a tight grid has another card's edge within reach on
	// every side. Those edges belong to the neighbours.
	img := background(1200, 1500)
	defer image_destroy(&img)
	expected: [9][4][2]int
	for row in 0 ..< 3 do for col in 0 ..< 3 {
		q := rect(110 + col * 320, 100 + row * 440, 300, 420)
		expected[row * 3 + col] = q
		fill_convex(&img, q, bgr(30, 80, 180))
	}
	cands := detect_cards(img)
	defer delete(cands)
	if !testing.expect_value(t, len(cands), 9) do return
	for c, i in cands {
		expect_corners(t, c.corners, expected[i], 3)
		testing.expect_value(t, c.source, Card_Source.Full_Resolution_Edges)
	}
}

@(test)
test_detect_drops_artwork_inside_cards_of_the_common_size :: proc(t: ^testing.T) {
	// The frames pass only the lowest colour threshold, so the higher ones
	// propose the dark artwork alone. Three cards share a size: a proposal
	// inside one of them that is not of that size is artwork.
	img := background(1400, 800)
	defer image_destroy(&img)
	expected: [3][4][2]int
	for col in 0 ..< 3 {
		q := rect(100 + col * 420, 150, 300, 420)
		expected[col] = q
		fill_convex(&img, q, {222, 218, 214})
		fill_rect(&img, q[0].x + 80, q[0].y + 100, q[0].x + 220, q[0].y + 330, bgr(30, 40, 60))
	}
	cands := detect_cards(img)
	defer delete(cands)
	if !testing.expect_value(t, len(cands), 3) do return
	for c, i in cands do expect_corners(t, c.corners, expected[i], 3)
}

@(test)
test_fit_seam_side_follows_the_card_edge_not_the_neighbour :: proc(t: ^testing.T) {
	// Two cards with a 5 px bed gap. Each card's seam side must stop at its
	// own edge: evidence past the first bed pixel is the neighbour's.
	img := background(900, 700)
	defer image_destroy(&img)
	fill_rect(&img, 100, 100, 399, 600, bgr(90, 100, 120))
	fill_rect(&img, 405, 100, 700, 600, bgr(30, 40, 60)) // the stronger edge
	gray := gray_from_rgba(img)
	defer delete(gray.pix)
	lab := lab_plane(img)
	defer delete(lab)
	dist := background_distance(img, background_color(lab, img.w, img.h))
	defer delete(dist.pix)
	// The left card's right side, top to bottom, starting 3 px off.
	line, gap, _, ok := fit_seam_side(gray, dist, {402, 100}, {402, 600}, 8)
	testing.expect(t, ok)
	testing.expect(t, gap)
	testing.expectf(t, abs(line.point.x - 399.5) <= 1.5, "left card's edge at x = %v, want 399.5", line.point.x)
	// The right card's left side runs bottom to top.
	line, gap, _, ok = fit_seam_side(gray, dist, {402, 600}, {402, 100}, 8)
	testing.expect(t, ok)
	testing.expect(t, gap)
	testing.expectf(t, abs(line.point.x - 404.5) <= 1.5, "right card's edge at x = %v, want 404.5", line.point.x)
}
