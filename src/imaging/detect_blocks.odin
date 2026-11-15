package imaging

// Splitting blocks of touching or overlapping cards without knowing the card
// size (an addition to the ported detector, not part of detector 1.5.0).
//
// Rounded cards that touch or overlap leave two kinds of bed-coloured marks:
// a notch in the block's outline where two corners meet, and a small pocket
// inside the block where four corners meet. A seam is a line that crosses the
// block from a notch on one side to a notch on the opposite side.
//
//   1. Walk each side of the block and measure how far the bed reaches into
//      the outline (the outline profile). A notch is a pointed, isolated peak
//      above the profile's running median.
//   2. Pair notches on opposite sides into column and row seams along the
//      block's axes. The scan border, a scanner lid strip or a deep overlap
//      can leave a seam with one notch only; such a seam is accepted when the
//      image confirms it (a pocket at each crossing, or a visible line).
//   3. The seams form a lattice. Interior crossings snap to the pocket there.
//   4. Each cell's outer sides are fitted to the outer edge as usual. Its seam
//      sides are fitted to the strongest straight line near the seam, never
//      looking past the first bed pixel (which belongs to the neighbour).
//   5. Where cards overlap, the lower card's edge is hidden. If the cards of
//      the block agree on a size, a short cell is restored to that size.
//
// Cells are guesses about where one card ends and the next begins, so they
// come back as Layout_Recovery and are marked for review.

import "core:math"
import "core:slice"

// Lengths are fractions of the scan's shorter side, so they scale with the
// scan resolution: 2550 px (letter at 300 dpi) gives the values in brackets.
@(private = "file") BLOCK_NOTCH_SPAN_RATIO :: 1.0 / 25 // half-width of the widest notch: the largest corner radius [102 px]
@(private = "file") BLOCK_NOTCH_DEPTH_RATIO :: 1.0 / 400 // least notch depth [6 px]
@(private = "file") BLOCK_NOTCH_NARROW_RATIO :: 1.0 / 120 // widest gap between two cards that still counts as a notch [21 px]
@(private = "file") BLOCK_NOTCH_TIP_LEVEL :: 0.6 // "near its tip": above this fraction of its depth
@(private = "file") BLOCK_NOTCH_TAPER :: 0.6 // width near the tip against the width at the mouth
@(private = "file") BLOCK_NOTCH_TIP_WIDTH :: 0.75 // width near the tip against the depth
@(private = "file") BLOCK_STRIP_RATIO :: 1.0 / 128 // widest scanner lid strip to look under for a card's outline [20 px]
@(private = "file") BLOCK_POCKET_RATIO :: 1.0 / 64 // search radius for the pocket at a seam crossing [40 px]
@(private = "file") BLOCK_MAX_SKEW :: 0.07 // sine of the largest angle between a seam and the block's axis (4 degrees)
@(private = "file") BLOCK_SEAM_REACH_RATIO :: 1.0 / 180 // seam search distance on each side [14 px]
@(private = "file") BLOCK_SEAM_MIN_GRADIENT :: 2.0 // mean gradient along a seam line, gray levels per pixel
@(private = "file") BLOCK_SEAM_MIN_CONTRAST :: 1.6 // ... and relative to the typical parallel line
@(private = "file") BLOCK_SEAM_GAP_LEVEL :: 0.4 // a gap between two cards is closer to the bed than this fraction of either frame's distance
@(private = "file") BLOCK_SIZE_AGREE_RATIO :: 0.005 // two measurements of one card size agree within this fraction ...
@(private = "file") BLOCK_SIZE_AGREE_MIN :: 2.5 // ... or this many pixels
@(private = "file") BLOCK_OWN_SKEW :: 0.004 // sine of the largest angle between a card's edge and the card's direction (0.23 degrees)
@(private = "file") BLOCK_MAX_HIDDEN :: 0.05 // the most of a card's size that may lie hidden under a neighbour
@(private = "file") BLOCK_SEAM_GAP_SUPPORT :: 0.7 // share of a seam that must show such a gap for both edges to count as visible
@(private = "file") BLOCK_OPEN_LINE_COVER :: 0.8 // share of an open seam's length along which its line must show
@(private = "file") BLOCK_OPEN_END_CARD :: 0.8 // share of card pixels beside a seam where it runs off the scan
@(private = "file") BLOCK_CELL_SIZE_TOL :: 0.12 // the cells of one block agree on a size within this fraction
@(private = "file") BLOCK_MIN_CELL_RATIO :: 0.25 // a cell's shorter side against the block's shorter cell pitch

@(private)
Block_Cell :: struct {
	corners: Quad,
	seams:   bit_set[0 ..< 4], // sides shared with a neighbour (0 top, 1 right, 2 bottom, 3 left)
	fitted:  bit_set[0 ..< 4], // sides whose line was fitted to image evidence
	gapped:  bit_set[0 ..< 4], // seams with bed showing between the two cards: both edges are visible
	clipped: bit_set[0 ..< 4], // sides on the scan border: the card runs off the scan
	lines:   [4]Line, // top, right, bottom, left; each runs clockwise
}

@(private = "file")
Notch :: struct {
	t:   f64, // position along the side, pixels from its first corner
	tip: Vec2, // deepest bed point: where the two cards meet
}

@(private = "file")
Profile :: struct {
	a, dir, out_n: Vec2,
	d:             []int, // bed depth inside the side line (negative: the outline lies outside it)
	known:         []bool, // false where no bed was found outside the line: something else adjoins the block there
	bed:           []bool, // the depth was measured against real bed, not against the scan border
	base:          []int, // running median of the known depths
	base_known:    []bool,
	max_in:        int,
	max_out:       int,
}

@(private = "file")
Ground :: enum {
	Bed,
	Card,
	Outside, // beyond the scan
}

@(private = "file")
ground_at :: #force_inline proc(bgdist: Plane, p: Vec2) -> Ground {
	x := int(math.floor(p.x + 0.5))
	y := int(math.floor(p.y + 0.5))
	if x < 0 || y < 0 || x >= bgdist.w || y >= bgdist.h do return .Outside
	return .Card if bgdist.pix[y * bgdist.w + x] >= LAB_THRESHOLDS[0] else .Bed
}

// Bed depth along the side a -> b, one value per pixel. `strip` is the widest
// scanner lid strip to look under; `on_border` says the side lies on the scan
// border, where the cards are cut off and there is no strip to look under.
@(private = "file")
outline_profile :: proc(bgdist: Plane, a, b: Vec2, span, strip: int, on_border: bool) -> (p: Profile, ok: bool) {
	d := b - a
	length := vec_len(d)
	if length < f64(span) * 4 do return
	p.a = a
	p.dir = d / length
	p.out_n = {p.dir.y, -p.dir.x}
	p.max_in = span * 5 / 2
	p.max_out = span
	n := int(length) + 1
	p.d = make([]int, n, context.temp_allocator)
	p.known = make([]bool, n, context.temp_allocator)
	p.bed = make([]bool, n, context.temp_allocator)
	p.base = make([]int, n, context.temp_allocator)
	p.base_known = make([]bool, n, context.temp_allocator)
	for t in 0 ..< n {
		o := a + p.dir * f64(t)
		switch ground_at(bgdist, o) {
		case .Outside:
		case .Card:
			// Outwards to the bed.
			walk: for s in 1 ..= p.max_out {
				g := ground_at(bgdist, o + p.out_n * f64(s))
				if g == .Card do continue
				p.d[t] = -(s - 1)
				p.known[t] = true
				p.bed[t] = g == .Bed
				break walk
			}
			if p.known[t] && !p.bed[t] && !on_border {
				// Card all the way to the scan border, from a side that is not
				// on the border itself: the line runs along a scanner lid
				// strip. If bed follows just inside it, the outline is where
				// that bed ends. Otherwise the cards touch the strip, and the
				// border stands in for the outline.
				first_bed := 0
				for s in 1 ..= p.max_in {
					g := ground_at(bgdist, o - p.out_n * f64(s))
					if first_bed == 0 {
						if g == .Bed do first_bed = s
						else if s > strip do break
					} else if g != .Bed {
						p.d[t] = s
						p.bed[t] = true
						break
					}
				}
			}
		case .Bed:
			p.d[t] = p.max_in
			p.known[t] = true
			p.bed[t] = true
			for s in 1 ..= p.max_in {
				if ground_at(bgdist, o - p.out_n * f64(s)) != .Bed {p.d[t] = s; break}
			}
		}
	}
	// Running median over +-2 spans (a sliding histogram): wide enough that a
	// notch is always a minority of the window, and it follows the steps of a
	// block whose cards are not level.
	bins := make([]int, p.max_in + p.max_out + 1, context.temp_allocator)
	half := span * 2
	lo, hi := 0, -1 // window [lo, hi]
	count := 0
	for t in 0 ..< n {
		for hi < min(n - 1, t + half) {
			hi += 1
			if p.known[hi] {
				bins[p.d[hi] + p.max_out] += 1
				count += 1
			}
		}
		for lo < t - half {
			if p.known[lo] {
				bins[p.d[lo] + p.max_out] -= 1
				count -= 1
			}
			lo += 1
		}
		if count * 4 < hi - lo + 1 do continue
		p.base_known[t] = true
		target := count / 2
		acc := 0
		for c, v in bins {
			acc += c
			if acc > target {p.base[t] = v - p.max_out; break}
		}
	}
	return p, true
}

// Narrow, pointed, isolated peaks of the profile above its baseline.
@(private = "file")
find_notches :: proc(p: Profile, span: int, min_depth, narrow: f64) -> [dynamic]Notch {
	notches := make([dynamic]Notch, context.temp_allocator)
	n := len(p.d)
	excess :: #force_inline proc(p: Profile, t: int) -> (e: int, ok: bool) {
		if !p.known[t] || !p.base_known[t] do return 0, false
		return p.d[t] - p.base[t], true
	}
	t := 0
	for t < n {
		if e, ok := excess(p, t); !ok || e < 2 {t += 1; continue}
		start := t
		peak := 0
		for t < n {
			e, ok := excess(p, t)
			if !ok || e < 2 do break
			peak = max(peak, e)
			t += 1
		}
		end := t // the run is [start, end)
		// No seam lies this close to the block's corner: that is its own rounding.
		if start < span * 2 || end > n - span * 2 do continue
		if f64(peak) < min_depth || end - start > span * 5 / 2 do continue
		// Isolated: the outline on both sides is known and flat.
		flat := true
		for side in 0 ..< 2 {
			f0, f1 := start - span, start
			if side == 1 do f0, f1 = end, end + span
			known := 0
			for k in f0 ..< f1 {
				e, ok := excess(p, k)
				if !ok do continue
				known += 1
				if e * 2 >= peak do flat = false
			}
			if known * 5 < span * 3 do flat = false
		}
		if !flat do continue
		level := int(math.ceil(BLOCK_NOTCH_TIP_LEVEL * f64(min(peak, span))))
		first, last := -1, -1
		bottomless := false
		for k in start ..< end {
			if p.d[k] - p.base[k] >= level {
				if first < 0 do first = k
				last = k
			}
			if p.d[k] >= p.max_in do bottomless = true
		}
		if first < 0 do continue
		// Shape. Two rounded corners meet in a point: the notch is much
		// narrower near its tip than at its mouth. A notch with no bottom in
		// reach is a gap between two cards, and must be as thin as one. Wide
		// or flat-bottomed marks are artwork that runs to the card's edge.
		near_tip := f64(last - first + 1)
		if bottomless {
			if near_tip > narrow do continue
		} else if near_tip > BLOCK_NOTCH_TAPER * f64(end - start) || near_tip > BLOCK_NOTCH_TIP_WIDTH * f64(peak) + narrow / 2 {
			continue
		}
		// The tip: the middle of the deepest stretch.
		deepest := p.d[first]
		for k in first ..= last do deepest = max(deepest, p.d[k])
		tf, tl := -1, -1
		for k in first ..= last {
			if p.d[k] >= deepest - 1 {
				if tf < 0 do tf = k
				tl = k
			}
		}
		center := f64(tf + tl) / 2
		o := p.a + p.dir * center
		append(&notches, Notch{t = center, tip = o - p.out_n * f64(deepest)})
	}
	return notches
}

@(private = "file")
Seam :: struct {
	p0, p1:   Vec2, // from the top (or left) side to the bottom (or right) side
	t0, t1:   f64, // positions along those sides (from each side's first corner)
	open:     bool, // one end has no notch: it runs into the scan border, where the corners are cut off
	at_first: bool, // an open seam's notch is at p0
}

@(private = "file")
cross2 :: #force_inline proc(a, b: Vec2) -> f64 {return a.x * b.y - a.y * b.x}

@(private = "file")
line_through :: proc(a, b: Vec2) -> Line {
	d := b - a
	l := vec_len(d)
	return Line{a, d / l if l > 0 else Vec2{1, 0}}
}

// Pairs the notches of two opposite sides into seams that run along `axis`
// (pointing from the first side to the second). A notch without a partner
// starts an open seam, straight along the axis to the other side: the far
// notch can be missing because the scan border or a scanner lid strip cuts
// the corners off there, or because the cards overlap too far to leave one.
// Open seams are candidates only (see confirm_open).
@(private = "file")
pair_notches :: proc(first, second: []Notch, axis: Vec2, first_side, second_side: Line) -> [dynamic]Seam {
	seams := make([dynamic]Seam, context.temp_allocator)
	Pair :: struct {
		i, j: int,
		skew: f64,
	}
	pairs := make([dynamic]Pair, context.temp_allocator)
	for a, i in first {
		for b, j in second {
			d := b.tip - a.tip
			l := vec_len(d)
			if l <= 0 do continue
			skew := abs(cross2(d / l, axis))
			if skew <= BLOCK_MAX_SKEW && (d.x * axis.x + d.y * axis.y) > 0 do append(&pairs, Pair{i, j, skew})
		}
	}
	slice.sort_by(pairs[:], proc(a, b: Pair) -> bool {return a.skew < b.skew})
	used_a := make([]bool, len(first), context.temp_allocator)
	used_b := make([]bool, len(second), context.temp_allocator)
	for pr in pairs {
		if used_a[pr.i] || used_b[pr.j] do continue
		used_a[pr.i], used_b[pr.j] = true, true
		append(&seams, Seam{first[pr.i].tip, second[pr.j].tip, first[pr.i].t, second[pr.j].t, false, false})
	}
	// The far end of an open seam: straight along the axis to the other side.
	far_end :: proc(tip, axis: Vec2, side: Line) -> (p: Vec2, t: f64, ok: bool) {
		p, ok = line_intersection(Line{tip, axis}, side)
		if !ok do return
		rel := p - side.point
		return p, rel.x * side.dir.x + rel.y * side.dir.y, true
	}
	for a, i in first {
		if used_a[i] do continue
		if p, t, ok := far_end(a.tip, axis, second_side); ok do append(&seams, Seam{a.tip, p, a.t, t, true, true})
	}
	for b, j in second {
		if used_b[j] do continue
		if p, t, ok := far_end(b.tip, axis, first_side); ok do append(&seams, Seam{p, b.tip, t, b.t, true, false})
	}
	return seams
}

// Centre of the bed-coloured pocket near `x`, where four rounded corners meet.
@(private = "file")
snap_to_pocket :: proc(bgdist: Plane, x: Vec2, radius: int) -> (center: Vec2, found: bool) {
	center = x
	r := radius
	for _ in 0 ..< 2 {
		sum: Vec2
		count := 0
		cx, cy := int(math.floor(center.x + 0.5)), int(math.floor(center.y + 0.5))
		for y in max(0, cy - r) ..= min(bgdist.h - 1, cy + r) {
			for px in max(0, cx - r) ..= min(bgdist.w - 1, cx + r) {
				if (px - cx) * (px - cx) + (y - cy) * (y - cy) > r * r do continue
				if bgdist.pix[y * bgdist.w + px] < LAB_THRESHOLDS[0] {
					sum += {f64(px), f64(y)}
					count += 1
				}
			}
		}
		if count < 6 do break
		center = sum / f64(count)
		found = true
		r = max(4, r / 2)
	}
	return
}

// The strongest straight line within `reach` pixels of the side a -> b of a
// cell (a, b clockwise, so the neighbour lies on the outward side). Evidence
// past the first bed pixel belongs to the neighbour and is ignored.
@(private)
fit_seam_side :: proc(gray: Gray, bgdist: Plane, a, b: Vec2, reach: int) -> (line: Line, gap: bool, cover: f64, ok: bool) {
	d := b - a
	length := vec_len(d)
	if length < 32 do return
	dir := d / length
	out_n := Vec2{dir.y, -dir.x}
	n := clamp(int(length * 0.8 / 4), 16, 160)
	width := 2 * reach + 1
	g := make([]f32, n * width, context.temp_allocator)
	values := make([]f64, width + 2, context.temp_allocator)
	raw := make([]f64, width, context.temp_allocator)
	// "Bed" here is relative to the two frames: a narrow gap is shaded by both
	// cards and rarely reaches the bed colour itself, but it is far closer to
	// it than either frame.
	inner := make([]f64, n, context.temp_allocator)
	outer := make([]f64, n, context.temp_allocator)
	for s in 0 ..< n {
		o := a + d * (0.1 + 0.8 * f64(s) / f64(n - 1))
		p, q := o - out_n * f64(reach), o + out_n * f64(reach)
		inner[s] = sample_plane(bgdist, p.x, p.y)
		outer[s] = sample_plane(bgdist, q.x, q.y)
	}
	thr := max(f64(LAB_THRESHOLDS[0]), min(median_f64(inner), median_f64(outer)) * BLOCK_SEAM_GAP_LEVEL)
	with_bed := 0
	for s in 0 ..< n {
		o := a + d * (0.1 + 0.8 * f64(s) / f64(n - 1))
		for k in 0 ..< width + 2 {
			p := o + out_n * f64(k - reach - 1)
			acc := 0.0
			for m in -2 ..= 2 do acc += sample_gray(gray, p.x + dir.x * f64(m), p.y + dir.y * f64(m))
			values[k] = acc / 5
		}
		limit := width
		for k in 0 ..< width {
			p := o + out_n * f64(k - reach)
			if sample_plane(bgdist, p.x, p.y) < thr {limit = k + 2; break}
		}
		if limit < width do with_bed += 1
		for k in 0 ..< width do raw[k] = abs(values[k + 2] - values[k]) / 2 if k < limit else 0
		for k in 0 ..< width {
			l := raw[max(k - 1, 0)]
			r := raw[min(k + 1, width - 1)]
			g[s * width + k] = f32((l + 2 * raw[k] + r) / 4)
		}
	}
	// Every line from offset k0 at the first sample to k1 at the last.
	max_tilt := max(2, int(length * 0.8 * BLOCK_MAX_SKEW))
	best := -1.0
	best_k0, best_k1 := 0, 0
	parallel := make([]f64, width, context.temp_allocator)
	for k0 in 0 ..< width {
		for k1 in max(0, k0 - max_tilt) ..= min(width - 1, k0 + max_tilt) {
			score := 0.0
			step := f64(k1 - k0) / f64(n - 1)
			for s in 0 ..< n do score += f64(g[s * width + int(f64(k0) + step * f64(s) + 0.5)])
			if k0 == k1 do parallel[k0] = score
			if score > best {
				best = score
				best_k0, best_k1 = k0, k1
			}
		}
	}
	gap = f64(with_bed) >= f64(n) * BLOCK_SEAM_GAP_SUPPORT
	typical := median_f64(parallel)
	mean := best / f64(n)
	if mean < BLOCK_SEAM_MIN_GRADIENT || best < typical * BLOCK_SEAM_MIN_CONTRAST do return
	// Sub-pixel: the gradient's centre of mass around the line at each sample.
	points := make([dynamic]Vec2, context.temp_allocator)
	shown := 0 // samples where the line itself shows
	step := f64(best_k1 - best_k0) / f64(n - 1)
	for s in 0 ..< n {
		c := int(f64(best_k0) + step * f64(s) + 0.5)
		wsum, ksum := 0.0, 0.0
		for k in max(0, c - 2) ..= min(width - 1, c + 2) {
			w := f64(g[s * width + k])
			wsum += w
			ksum += w * f64(k)
		}
		if wsum <= 0 do continue
		if f64(g[s * width + c]) >= BLOCK_SEAM_MIN_GRADIENT do shown += 1
		o := a + d * (0.1 + 0.8 * f64(s) / f64(n - 1))
		append(&points, o + out_n * (ksum / wsum - f64(reach)))
	}
	if len(points) < n / 2 do return
	lp, ld := fit_line_huber(points[:])
	if ld.x * dir.x + ld.y * dir.y < 0 do ld = -ld
	if ld.x * dir.x + ld.y * dir.y < 0.995 do return
	return Line{lp, ld}, gap, f64(shown) / f64(n), true
}

// The outer side of one cell: a line through the outline between two notches.
@(private = "file")
outline_line :: proc(p: Profile, t0, t1: f64, fallback: Line) -> Line {
	points := make([dynamic]Vec2, context.temp_allocator)
	lo, hi := t0 + (t1 - t0) * 0.2, t0 + (t1 - t0) * 0.8
	for t := lo; t <= hi; t += 3 {
		k := clamp(int(t), 0, len(p.d) - 1)
		if p.d[k] >= p.max_in || !p.bed[k] do continue
		append(&points, p.a + p.dir * f64(k) - p.out_n * f64(p.d[k]))
	}
	if len(points) < 8 do return fallback
	lp, ld := fit_line_huber(points[:])
	if ld.x * p.dir.x + ld.y * p.dir.y < 0 do ld = -ld
	if ld.x * p.dir.x + ld.y * p.dir.y < 0.98 do return fallback
	return Line{lp, ld}
}

// Splits a block of touching or overlapping cards at its notches. Returns
// ok=false when the outline shows no seam: an ordinary single card.
@(private)
split_block :: proc(gray: Gray, bgdist: Plane, q: Quad) -> (cells: [dynamic]Block_Cell, cols, rows: int, ok: bool) {
	short := f64(min(gray.w, gray.h))
	span := max(12, int(short * BLOCK_NOTCH_SPAN_RATIO))
	min_depth := max(4.0, short * BLOCK_NOTCH_DEPTH_RATIO)
	narrow := max(8.0, short * BLOCK_NOTCH_NARROW_RATIO)
	reach := max(6, int(short * BLOCK_SEAM_REACH_RATIO))
	pocket := max(8, int(short * BLOCK_POCKET_RATIO))
	strip := max(4, int(short * BLOCK_STRIP_RATIO))

	side_line :: proc(q: Quad, i: int) -> Line {return line_through(q[i], q[(i + 1) % 4])}
	// A side on the scan border: the cards run off the scan there.
	BORDER_TOL :: 3
	on_border :: proc(q: Quad, i, w, h: int) -> bool {
		a, b := q[i], q[(i + 1) % 4]
		return(
			(a.x <= BORDER_TOL && b.x <= BORDER_TOL) ||
			(a.y <= BORDER_TOL && b.y <= BORDER_TOL) ||
			(a.x >= f64(w - 1 - BORDER_TOL) && b.x >= f64(w - 1 - BORDER_TOL)) ||
			(a.y >= f64(h - 1 - BORDER_TOL) && b.y >= f64(h - 1 - BORDER_TOL)) \
		)
	}
	// An end of side `i` at the scan border that side faces: the card's edge
	// leaves the scan part of the way along.
	near_border :: proc(p: Vec2, i, w, h: int) -> bool {
		switch i {
		case 0: return p.y <= BORDER_TOL
		case 1: return p.x >= f64(w - 1 - BORDER_TOL)
		case 2: return p.y >= f64(h - 1 - BORDER_TOL)
		}
		return p.x <= BORDER_TOL
	}
	open: [4]bool
	for i in 0 ..< 4 do open[i] = on_border(q, i, gray.w, gray.h)

	profiles: [4]Profile
	notches: [4][dynamic]Notch
	for i in 0 ..< 4 {
		p, pok := outline_profile(bgdist, q[i], q[(i + 1) % 4], span, strip, open[i])
		if !pok do return
		profiles[i] = p
		notches[i] = find_notches(p, span, min_depth, narrow)
	}
	if len(notches[0]) + len(notches[1]) + len(notches[2]) + len(notches[3]) == 0 do return

	u_axis := (q[1] - q[0]) + (q[2] - q[3])
	v_axis := (q[3] - q[0]) + (q[2] - q[1])
	u_axis /= vec_len(u_axis)
	v_axis /= vec_len(v_axis)
	col_seams := pair_notches(notches[0][:], notches[2][:], v_axis, side_line(q, 0), side_line(q, 2)) // top -> bottom
	row_seams := pair_notches(notches[3][:], notches[1][:], u_axis, side_line(q, 3), side_line(q, 1)) // left -> right
	// An open seam has a notch at one end only, so the image must confirm it:
	// a pocket wherever it crosses a seam with two notches or, with nothing to
	// cross, a line that shows along nearly all of its length. `far_side` is
	// the direction of the block's side at the open end.
	confirm_open :: proc(gray: Gray, bgdist: Plane, seams: ^[dynamic]Seam, cross: []Seam, far_dirs: [2]Vec2, span, reach, pocket: int) {
		for i := len(seams) - 1; i >= 0; i -= 1 {
			s := seams[i]
			if !s.open do continue
			confirmed := true
			// Not a second seam beside one that is already there.
			for o, j in seams {
				if j == i || (o.open && j > i) do continue
				if abs((s.t0 - o.t0) if s.at_first else (s.t1 - o.t1)) < f64(span * 2) do confirmed = false
			}
			crossings, pockets := 0, 0
			for c in cross {
				if c.open do continue
				crossings += 1
				x, xok := line_intersection(line_through(s.p0, s.p1), line_through(c.p0, c.p1))
				if !xok do continue
				if _, found := snap_to_pocket(bgdist, x, pocket); found do pockets += 1
			}
			if pockets != crossings do confirmed = false
			if confirmed && crossings == 0 {
				// The seam need not run along the block's axis: try a few far ends.
				best := 0.0
				far_dir := far_dirs[1] if s.at_first else far_dirs[0]
				for step in ([5]f64{0, 1, -1, 2, -2}) {
					shift := far_dir * (step * f64(reach) * 1.5)
					p0, p1 := s.p0, s.p1 + shift
					if !s.at_first do p0, p1 = s.p0 + shift, s.p1
					if _, _, cover, ok := fit_seam_side(gray, bgdist, p0, p1, reach); ok && cover > best {
						best = cover
						seams[i].p0, seams[i].p1 = p0, p1
						t := shift.x * far_dir.x + shift.y * far_dir.y
						if s.at_first do seams[i].t1 = s.t1 + t
						else do seams[i].t0 = s.t0 + t
					}
				}
				if best < BLOCK_OPEN_LINE_COVER do confirmed = false
				s = seams[i]
			}
			// The cards must reach the open end side by side: card on both
			// sides of the seam right up to it (half a span aside, clear of
			// the rounded corners), and close beside the seam just before it.
			// Bed up to the end means the block's outline stops short of that
			// side (it merely includes something along it, such as a lid
			// strip). Bed beside the seam means the cards stand apart there:
			// no notch is missing, and each card has its own proposal.
			far, near := s.p1, s.p0
			if !s.at_first do far, near = s.p0, s.p1
			along := near - far
			length := vec_len(along)
			if confirmed && length > 0 {
				along /= length
				normal := Vec2{-along.y, along.x}
				card, total := 0, 0
				for k in 0 ..< span {
					for side in ([2]f64{-1, 1}) {
						total += 2
						if ground_at(bgdist, far + along * f64(k) + normal * (side * f64(span / 2))) == .Card do card += 1
						if ground_at(bgdist, far + along * f64(k + span) + normal * (side * f64(reach))) == .Card do card += 1
					}
				}
				if f64(card) < f64(total) * BLOCK_OPEN_END_CARD do confirmed = false
			}
			if !confirmed do ordered_remove(seams, i)
		}
	}
	col_far := [2]Vec2{side_line(q, 0).dir, side_line(q, 2).dir}
	row_far := [2]Vec2{side_line(q, 3).dir, side_line(q, 1).dir}
	confirm_open(gray, bgdist, &col_seams, row_seams[:], col_far, span, reach, pocket)
	confirm_open(gray, bgdist, &row_seams, col_seams[:], row_far, span, reach, pocket)
	if len(col_seams) + len(row_seams) == 0 do return
	if len(col_seams) >= GRID_MAX_CELLS || len(row_seams) >= GRID_MAX_CELLS do return
	slice.sort_by(col_seams[:], proc(a, b: Seam) -> bool {return a.t0 < b.t0})
	slice.sort_by(row_seams[:], proc(a, b: Seam) -> bool {return a.t0 > b.t0}) // the left side runs bottom to top
	cols, rows = len(col_seams) + 1, len(row_seams) + 1

	// Lattice nodes: seam ends on the outline, pockets inside.
	node :: proc(nodes: []Vec2, cols, i, j: int) -> ^Vec2 {return &nodes[j * (cols + 1) + i]}
	nodes := make([]Vec2, (cols + 1) * (rows + 1), context.temp_allocator)
	for s, i in col_seams {
		node(nodes, cols, i + 1, 0)^ = s.p0
		node(nodes, cols, i + 1, rows)^ = s.p1
	}
	for s, j in row_seams {
		node(nodes, cols, 0, j + 1)^ = s.p0
		node(nodes, cols, cols, j + 1)^ = s.p1
	}
	for cs, i in col_seams {
		for rs, j in row_seams {
			x, xok := line_intersection(line_through(cs.p0, cs.p1), line_through(rs.p0, rs.p1))
			if !xok do return
			node(nodes, cols, i + 1, j + 1)^, _ = snap_to_pocket(bgdist, x, pocket)
		}
	}
	// Aim an open seam's far end through its pockets rather than along the block's axis.
	for s, i in col_seams {
		if !s.open || len(row_seams) == 0 do continue
		if s.at_first {
			if p, hit := line_intersection(line_through(s.p0, node(nodes, cols, i + 1, rows - 1)^), side_line(q, 2)); hit do node(nodes, cols, i + 1, rows)^ = p
		} else if p, hit := line_intersection(line_through(s.p1, node(nodes, cols, i + 1, 1)^), side_line(q, 0)); hit {
			node(nodes, cols, i + 1, 0)^ = p
		}
	}
	for s, j in row_seams {
		if !s.open || len(col_seams) == 0 do continue
		if s.at_first {
			if p, hit := line_intersection(line_through(s.p0, node(nodes, cols, cols - 1, j + 1)^), side_line(q, 1)); hit do node(nodes, cols, cols, j + 1)^ = p
		} else if p, hit := line_intersection(line_through(s.p1, node(nodes, cols, 1, j + 1)^), side_line(q, 3)); hit {
			node(nodes, cols, 0, j + 1)^ = p
		}
	}
	cells = make([dynamic]Block_Cell, context.temp_allocator)
	pitch := min(vec_len(q[1] - q[0]) / f64(cols), vec_len(q[3] - q[0]) / f64(rows))
	for r in 0 ..< rows {
		for c in 0 ..< cols {
			cell: Block_Cell
			lines: [4]Line
			// Top and bottom.
			if r == 0 {
				t0 := 0.0 if c == 0 else col_seams[c - 1].t0
				t1 := f64(len(profiles[0].d) - 1) if c == cols - 1 else col_seams[c].t0
				lines[0] = outline_line(profiles[0], t0, t1, side_line(q, 0))
			} else {
				lines[0] = line_through(node(nodes, cols, c, r)^, node(nodes, cols, c + 1, r)^)
				cell.seams += {0}
			}
			if r == rows - 1 {
				// The bottom side runs right to left.
				t0 := 0.0 if c == cols - 1 else col_seams[c].t1
				t1 := f64(len(profiles[2].d) - 1) if c == 0 else col_seams[c - 1].t1
				lines[2] = outline_line(profiles[2], t0, t1, side_line(q, 2))
			} else {
				lines[2] = line_through(node(nodes, cols, c + 1, r + 1)^, node(nodes, cols, c, r + 1)^)
				cell.seams += {2}
			}
			// Right and left.
			if c == cols - 1 {
				t0 := 0.0 if r == 0 else row_seams[r - 1].t1
				t1 := f64(len(profiles[1].d) - 1) if r == rows - 1 else row_seams[r].t1
				lines[1] = outline_line(profiles[1], t0, t1, side_line(q, 1))
			} else {
				lines[1] = line_through(node(nodes, cols, c + 1, r)^, node(nodes, cols, c + 1, r + 1)^)
				cell.seams += {1}
			}
			if c == 0 {
				// The left side runs bottom to top.
				t0 := 0.0 if r == rows - 1 else row_seams[r].t0
				t1 := f64(len(profiles[3].d) - 1) if r == 0 else row_seams[r - 1].t0
				lines[3] = outline_line(profiles[3], t0, t1, side_line(q, 3))
			} else {
				lines[3] = line_through(node(nodes, cols, c, r + 1)^, node(nodes, cols, c, r)^)
				cell.seams += {3}
			}
			init, iok := quad_from_lines(lines, gray.w, gray.h)
			if !iok do return nil, 0, 0, false
			dims := quad_dimensions(init)
			if min(dims.x, dims.y) < pitch * BLOCK_MIN_CELL_RATIO do return nil, 0, 0, false

			// Fit each side at full resolution; a side without evidence keeps its line.
			shortest := min(dims.x, dims.y)
			outward := min(32, max(8, int(math.floor(shortest * 0.12 + 0.5))))
			inward := min(16, max(6, int(math.floor(shortest * 0.02 + 0.5))))
			for i in 0 ..< 4 {
				a, b := init[i], init[(i + 1) % 4]
				if i in cell.seams {
					l, gap, _, lok := fit_seam_side(gray, bgdist, a, b, reach)
					if gap do cell.gapped += {i}
					if lok {
						lines[i] = l
						cell.fitted += {i}
					}
				} else {
					if open[i] || near_border(a, i, gray.w, gray.h) || near_border(b, i, gray.w, gray.h) do cell.clipped += {i}
					if l, lok := fit_outer_side(gray, bgdist, a, b, inward, outward); lok {
						lines[i] = l
						cell.fitted += {i}
					}
				}
			}
			cell.lines = lines
			refined, rok := quad_from_lines(lines, gray.w, gray.h)
			cell.corners = refined if rok else init
			append(&cells, cell)
		}
	}
	// The cards of a block share a size; a card cut off by the scan border may
	// be smaller. Cells that disagree mean a seam that is not one.
	for axis in 0 ..< 2 {
		sizes := make([dynamic]f64, context.temp_allocator)
		cut: bit_set[0 ..< 4] = {3, 1} if axis == 0 else {0, 2}
		for c in cells do if c.clipped & cut == {} do append(&sizes, quad_dimensions(c.corners)[axis])
		if len(sizes) == 0 do continue
		common := median_f64(sizes[:])
		for c in cells {
			size := quad_dimensions(c.corners)[axis]
			if size > common * (1 + BLOCK_CELL_SIZE_TOL) do return nil, 0, 0, false
			if c.clipped & cut == {} && size < common * (1 - BLOCK_CELL_SIZE_TOL) do return nil, 0, 0, false
		}
	}
	return cells, cols, rows, true
}

// Corners where adjacent side lines (top, right, bottom, left) meet, rounded
// and clamped to the image.
@(private)
quad_from_lines :: proc(lines: [4]Line, w, h: int) -> (q: Quad, ok: bool) {
	for i in 0 ..< 4 {
		p, pok := line_intersection(lines[(i + 3) % 4], lines[i])
		if !pok do return
		q[i] = {clamp(math.floor(p.x + 0.5), 0, f64(w - 1)), clamp(math.floor(p.y + 0.5), 0, f64(h - 1))}
	}
	return q, valid_quad(q)
}

// ---------------------------------------------------------------------------
// Edges hidden under an overlapping neighbour
// ---------------------------------------------------------------------------

// Where two cards overlap, only the upper card's edge shows, and both cells
// were fitted to it: the lower card comes out too short, and its side follows
// the upper card's direction. A card is a rectangle, and the cards of one
// block are the same size. So when the cells agree on a size, each side that
// is not certainly the card's own edge is checked against the rectangle of
// that size laid against the sides that are: one that falls short of it is the
// neighbour's edge, and the rectangle's side replaces it. `extra` holds the
// sizes of other cards on the scan (both sides of each) as further witnesses.
@(private)
restore_hidden_sides :: proc(cells: []Block_Cell, cols, rows: int, extra: []f64, w, h: int) {
	n := len(cells)
	if n != cols * rows do return
	Status :: enum {
		Unknown,
		Own, // the card's own edge: an outer side, or a seam confirmed by the card's size
		Hidden, // under the neighbour: replaced by the rectangle's side
	}
	status := make([][4]Status, n, context.temp_allocator)
	// The card's direction along its top side, from the sides that are its own.
	card_dir := make([]Vec2, n, context.temp_allocator)
	has_dir := make([]bool, n, context.temp_allocator)
	certain :: proc(c: Block_Cell, i: int) -> bool {
		return i in c.fitted && i not_in c.clipped && (i not_in c.seams || i in c.gapped)
	}
	// Direction of side `i` of a card whose top side runs along `u` (clockwise).
	side_dir :: proc(u: Vec2, i: int) -> Vec2 {
		switch i {
		case 0: return u
		case 1: return {-u.y, u.x}
		case 2: return -u
		}
		return {u.y, -u.x}
	}
	for c, i in cells {
		sum: Vec2
		for k in 0 ..< 4 {
			if !certain(c, k) do continue
			status[i][k] = .Own
			// Undo side_dir: turn the side's direction back to the top side's.
			d := c.lines[k].dir
			back: Vec2
			switch k {
			case 0: back = d
			case 1: back = {d.y, -d.x}
			case 2: back = -d
			case 3: back = {-d.y, d.x}
			}
			sum += back * vec_len(c.corners[(k + 1) % 4] - c.corners[k])
		}
		if l := vec_len(sum); l > 0 {
			card_dir[i] = sum / l
			has_dir[i] = true
		}
	}
	// Distance between a cell's opposite sides, measured through its centre.
	span_of :: proc(c: Block_Cell, side: int) -> f64 {
		center := quad_center(c.corners)
		a, b := c.lines[side], c.lines[(side + 2) % 4]
		return abs(cross2(center - a.point, a.dir)) + abs(cross2(center - b.point, b.dir))
	}
	// Two measurements of one card size differ by a few pixels: shadows and
	// the cut edge shift each fitted side a little.
	size_agreement :: proc(v: f64) -> f64 {return max(BLOCK_SIZE_AGREE_MIN, v * BLOCK_SIZE_AGREE_RATIO)}
	// The size the cards agree on: the largest value near `v` that a second card confirms.
	reference :: proc(v: f64, pool: []f64) -> (ref: f64, ok: bool) {
		agree := size_agreement(v)
		near := make([dynamic]f64, context.temp_allocator)
		for x in pool do if x >= v - agree && x <= v * (1 + BLOCK_MAX_HIDDEN) do append(&near, x)
		slice.sort(near[:])
		#reverse for x, i in near {
			if i == 0 || x - near[i - 1] > agree do continue
			sum, count := 0.0, 0
			for y in near do if y <= x && x - y <= agree {sum += y; count += 1}
			return sum / f64(count), true
		}
		return
	}
	// Side `i` runs in the card's direction, as the card's own edge would.
	along :: proc(c: Block_Cell, u: Vec2, i: int) -> bool {
		return abs(cross2(c.lines[i].dir, side_dir(u, i))) <= BLOCK_OWN_SKEW
	}
	// Checks side `target` against the rectangle laid against its opposite
	// side `anchor`, which is the card's own edge.
	judge :: proc(c: ^Block_Cell, u: Vec2, anchor, target: int, size: f64) -> Status {
		center := quad_center(c.corners)
		al := c.lines[anchor]
		foot := al.point + al.dir * ((center.x - al.point.x) * al.dir.x + (center.y - al.point.y) * al.dir.y)
		ad := side_dir(u, anchor)
		inward := Vec2{-ad.y, ad.x}
		td := side_dir(u, target)
		out_n := Vec2{td.y, -td.x}
		expected := Line{foot + inward * size, td}
		// How far outside the fitted side the rectangle's side lies, at both ends.
		lo, hi := math.INF_F64, -math.INF_F64
		for k in 0 ..< 2 {
			e := c.corners[(target + k) % 4]
			d := (expected.point.x - e.x) * out_n.x + (expected.point.y - e.y) * out_n.y
			lo, hi = min(lo, d), max(hi, d)
		}
		tol := size_agreement(size)
		if lo < -tol do return .Unknown // the fitted side lies beyond the card: the size or the seam is off
		if hi <= tol do return .Own
		if hi > size * BLOCK_MAX_HIDDEN do return .Unknown
		c.lines[target] = expected
		return .Hidden
	}
	neighbour :: proc(i, side, cols, rows: int) -> int {
		c, r := i % cols, i / cols
		switch side {
		case 0: r -= 1
		case 1: c += 1
		case 2: r += 1
		case 3: c -= 1
		}
		if c < 0 || r < 0 || c >= cols || r >= rows do return -1
		return r * cols + c
	}
	// axis 0: widths (sides 3 and 1); axis 1: heights (sides 0 and 2).
	for axis in 0 ..< 2 {
		first, second := 3, 1
		if axis == 1 do first, second = 0, 2
		spans := make([]f64, n, context.temp_allocator)
		pool := make([dynamic]f64, context.temp_allocator)
		whole := make([]bool, n, context.temp_allocator) // not cut off by the scan border along this axis
		for c, i in cells {
			spans[i] = span_of(c, first)
			whole[i] = first not_in c.clipped && second not_in c.clipped
			if whole[i] do append(&pool, spans[i])
		}
		for x in extra do append(&pool, x)
		size := make([]f64, n, context.temp_allocator)
		usable := make([]bool, n, context.temp_allocator)
		for i in 0 ..< n {
			if !whole[i] || !has_dir[i] do continue
			size[i], usable[i] = reference(spans[i], pool[:])
		}
		// Cells with one side that is certainly their own.
		for &c, i in cells {
			if !usable[i] do continue
			own_first, own_second := status[i][first] == .Own, status[i][second] == .Own
			if own_first && !own_second do status[i][second] = judge(&c, card_dir[i], first, second, size[i])
			if own_second && !own_first do status[i][first] = judge(&c, card_dir[i], second, first, size[i])
		}
		// Cells between two seams. A neighbour found to lie under this card
		// makes that seam this card's own edge. A neighbour whose own edge the
		// seam is leaves the opposite seam as this card's, if it runs in the
		// card's direction.
		for &c, i in cells {
			if !usable[i] || status[i][first] != .Unknown || status[i][second] != .Unknown do continue
			before, after := neighbour(i, first, cols, rows), neighbour(i, second, cols, rows)
			shared :: proc(status: [][4]Status, j, side: int, want: Status) -> bool {return j >= 0 && status[j][side] == want}
			own := -1
			if shared(status, before, second, .Hidden) do own = first
			else if shared(status, after, first, .Hidden) do own = second
			else if shared(status, before, second, .Own) && !shared(status, after, first, .Own) && along(c, card_dir[i], second) do own = second
			else if shared(status, after, first, .Own) && !shared(status, before, second, .Own) && along(c, card_dir[i], first) do own = first
			if own < 0 do continue
			other := second if own == first else first
			status[i][own] = .Own
			status[i][other] = judge(&c, card_dir[i], own, other, size[i])
		}
		for &c in cells {
			if q, ok := quad_from_lines(c.lines, w, h); ok do c.corners = q
		}
	}
	// A seam that is still undecided and runs askew to the card follows the
	// neighbour's edge. The card's own edge lies under the neighbour, at an
	// unknown depth; the least assumption is that it starts where the seam is
	// farthest out, and runs in the card's direction from there.
	for &c, i in cells {
		if !has_dir[i] do continue
		for k in 0 ..< 4 {
			if status[i][k] != .Unknown || k not_in c.seams || k in c.gapped || along(c, card_dir[i], k) do continue
			td := side_dir(card_dir[i], k)
			out_n := Vec2{td.y, -td.x}
			a, b := c.corners[k], c.corners[(k + 1) % 4]
			outermost := a if a.x * out_n.x + a.y * out_n.y >= b.x * out_n.x + b.y * out_n.y else b
			c.lines[k] = Line{outermost, td}
		}
		if q, ok := quad_from_lines(c.lines, w, h); ok do c.corners = q
	}
}
