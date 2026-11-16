package imaging

// Cards whose frame has the colour of the scanner bed.
//
// A white frame on a white lid is "background" to the colour masks, so the
// proposal and its edge fit end at the artwork inside the frame. The card's
// real edge still shows, faintly: a small step in brightness, or the thin
// shadow line of the cut edge. A single pixel row cannot tell it from noise,
// but an average along the side can.
//
// For each side the brightness is averaged along short stretches (chunks) and
// the first clear change outside the fitted side is located in each. The
// changes must line up as one straight line parallel to the side, and every
// side of the card must find one, at a comparable distance, clear of every
// other card, with a different brightness inside than outside. The moved sides
// are weaker evidence than a full-resolution edge fit, so the card comes back
// as Faint_Outer_Edges and is marked for review.

import "core:math"

@(private = "file") FRAME_MAX_RATIO :: 0.10 // search this fraction of the card's shorter side outwards ...
@(private = "file") FRAME_MAX_SCAN_RATIO :: 0.04 // ... but no more than this fraction of the scan's shorter side
@(private = "file") FRAME_SKIP :: 3 // pixels outside the fitted side that still belong to its own edge
@(private = "file") FRAME_MIN_WIDTH :: 6 // a narrower frame is not worth a guess
@(private = "file") FRAME_CHUNK :: 64 // pixels of side averaged into one profile
@(private = "file") FRAME_MIN_STEP :: 4.0 // gray levels between the two sides of the edge
@(private = "file") FRAME_LINE_WIDTH :: 6 // pixels within which a darkening and a brightening make one thin line
@(private = "file") FRAME_MIN_CHUNKS :: 0.75 // share of a side's chunks that must lie on the line
@(private = "file") FRAME_LINE_TOL :: 2.0 // pixels a chunk may lie off the line
@(private = "file") FRAME_MIN_ALIGNMENT :: 0.9998 // cosine between the new edge and the fitted side (about 1 degree)
@(private = "file") FRAME_MIN_STEPPED_SIDES :: 2 // sides where the band inside the new edge and the bed beyond it differ in brightness
@(private = "file") FRAME_MAX_UNEVEN :: 3.0 // widest frame side against the narrowest
@(private = "file") FRAME_CLEARANCE :: 6.0 // pixels the grown card must keep from every other card

// The faint outer edge of side a -> b (clockwise, so outwards is to the left
// of the direction of travel), searched up to `reach` pixels out.
@(private = "file")
faint_outer_edge :: proc(gray: Gray, a, b: Vec2, reach: int) -> (line: Line, width: f64, stepped: bool, ok: bool) {
	d := b - a
	length := vec_len(d)
	if length < FRAME_CHUNK * 3 do return
	dir := d / length
	out_n := Vec2{dir.y, -dir.x}
	chunks := clamp(int(length * 0.8 / FRAME_CHUNK), 4, 32)
	chunk_len := length * 0.8 / f64(chunks)
	n := reach + 4 // offsets 0 ..< n outwards from the side
	profile := make([]f64, n, context.temp_allocator)
	points := make([dynamic]Vec2, context.temp_allocator)
	offsets := make([dynamic]f64, context.temp_allocator)
	levels := make([dynamic]f64, context.temp_allocator)
	for c in 0 ..< chunks {
		start := a + dir * (length * 0.1 + chunk_len * f64(c))
		samples := max(1, int(chunk_len / 2))
		for k in 0 ..< n {
			acc := 0.0
			for s in 0 ..< samples {
				p := start + dir * (f64(s) * 2) + out_n * f64(k)
				acc += sample_gray(gray, p.x, p.y)
			}
			profile[k] = acc / f64(samples)
		}
		// Brightness just outside minus just inside offset k.
		step :: proc(p: []f64, k: int) -> f64 {
			return (p[k + 1] + p[k + 2] + p[k + 3]) / 3 - (p[k - 1] + p[k - 2] + p[k - 3]) / 3
		}
		found := -1
		for k in FRAME_SKIP + 3 ..< n - 4 {
			s := abs(step(profile, k))
			if s >= FRAME_MIN_STEP && s >= abs(step(profile, k - 1)) && s >= abs(step(profile, k + 1)) {
				found = k
				break
			}
		}
		if found < 0 do continue
		first := step(profile, found)
		// A cut edge often shows as a thin dark line (its rim, or its shadow):
		// a darkening followed by a brightening. The card ends at the line's
		// darkest point, not where the line begins. A brightening alone is a
		// plain step from frame to bed and ends at its centre; so does a bright
		// "line", which is the bed in a narrow gap to the next card.
		off := 0.0
		back := -1
		if first < 0 {
			for k in found + 1 ..= min(n - 5, found + FRAME_LINE_WIDTH) {
				if step(profile, k) >= FRAME_MIN_STEP {back = k; break}
			}
		}
		if back > 0 {
			darkest := found
			for k in found ..= back do if profile[k] < profile[darkest] do darkest = k
			// Parabola through the darkest point and its neighbours.
			l, m, r := profile[darkest - 1], profile[darkest], profile[darkest + 1]
			den := l - 2 * m + r
			off = f64(darkest) + (clamp(0.5 * (l - r) / den, -0.5, 0.5) if den != 0 else 0)
		} else {
			// Centre of mass of the step response around the peak.
			wsum, ksum := 0.0, 0.0
			for k in max(4, found - 2) ..= min(n - 5, found + 2) {
				w := abs(step(profile, k))
				wsum += w
				ksum += w * f64(k)
			}
			off = ksum / wsum
		}
		append(&offsets, off)
		append(&points, start + dir * (chunk_len / 2) + out_n * off)
		// Brightness beyond the edge against the band before it.
		e := clamp(int(off + 0.5), 5, n - 6)
		append(&levels, (profile[e + 3] + profile[e + 4] + profile[e + 5]) / 3 - (profile[e - 3] + profile[e - 4] + profile[e - 5]) / 3)
	}
	need := int(math.ceil(f64(chunks) * FRAME_MIN_CHUNKS))
	if len(points) < need do return
	lp, ld := fit_line_huber(points[:])
	if ld.x * dir.x + ld.y * dir.y < 0 do ld = -ld
	if ld.x * dir.x + ld.y * dir.y < FRAME_MIN_ALIGNMENT do return
	on_line := 0
	for p in points {
		if abs((p.x - lp.x) * ld.y - (p.y - lp.y) * ld.x) <= FRAME_LINE_TOL do on_line += 1
	}
	if on_line < need do return
	width = median_f64(offsets[:])
	if width < FRAME_MIN_WIDTH do return
	return Line{lp, ld}, width, abs(median_f64(levels[:])) >= FRAME_MIN_STEP, true
}

// Moves the sides of `q` out to a faint outer edge when all four sides show
// one. `others` are the remaining cards: growing into one of them means the
// "edge" was that neighbour's, not this card's.
@(private)
grow_to_faint_edges :: proc(gray: Gray, q: Quad, others: []Quad) -> (grown: Quad, ok: bool) {
	dims := quad_dimensions(q)
	shortest := min(dims.x, dims.y)
	reach := int(min(shortest * FRAME_MAX_RATIO, f64(min(gray.w, gray.h)) * FRAME_MAX_SCAN_RATIO))
	if reach < FRAME_MIN_WIDTH * 2 do return
	lines, cleared: [4]Line
	narrowest, widest := math.INF_F64, 0.0
	stepped_sides := 0
	for i in 0 ..< 4 {
		a, b := q[i], q[(i + 1) % 4]
		l, width, stepped, lok := faint_outer_edge(gray, a, b, reach)
		if stepped do stepped_sides += 1
		if !lok do return
		lines[i] = l
		out_n := Vec2{l.dir.y, -l.dir.x}
		cleared[i] = Line{l.point + out_n * FRAME_CLEARANCE, l.dir}
		narrowest, widest = min(narrowest, width), max(widest, width)
	}
	if widest > narrowest * FRAME_MAX_UNEVEN do return
	// A frame differs from the bed beyond it, if only slightly. A thin line
	// with the same brightness on both sides is something lying around the
	// card, such as the rim of a clear sleeve.
	if stepped_sides < FRAME_MIN_STEPPED_SIDES do return
	with_clearance, cok := quad_from_lines(cleared, gray.w, gray.h)
	if !cok do return
	for o in others do if convex_intersection_area_quads(with_clearance, o) > 0 do return
	return quad_from_lines(lines, gray.w, gray.h)
}

@(private = "file")
convex_intersection_area_quads :: proc(a, b: Quad) -> f64 {
	a, b := a, b
	return convex_intersection_area(a[:], b[:])
}
