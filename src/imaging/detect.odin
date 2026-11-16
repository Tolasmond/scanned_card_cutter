package imaging

// Card detection: a classical computer-vision pipeline in pure Odin.
//
//   1. Downscale the scan; find the scanner-bed colour as the dominant border
//      colour (Lab).
//   2. Foreground masks at three Lab-distance thresholds plus Canny edges,
//      with scanner-frame strips cleared and thin full-resolution gaps between
//      tightly packed cards carved out.
//   3. Outer contours -> four-corner proposals (polygon or min-area rectangle),
//      de-duplicated.
//   4. At full resolution, fit each side to the card's outer edge and
//      intersect the lines. Split proposals that are grids of touching cards,
//      drop proposals that contain several others, and recover missing cards
//      from the row/column layout.
//
// Three further stages handle what the base pipeline cannot, each measured on
// the synthetic corpus (see doc/development.md, "Synthetic scans"):
//
//   * detect_blocks.odin splits blocks of touching or overlapping cards at
//     the notches their rounded corners leave, without needing a card size,
//     and restores edges hidden under an overlapping card. It runs before the
//     grid split, which still handles what it leaves.
//   * suppress_artwork (below) drops proposals that are artwork inside a card.
//   * detect_frames.odin moves a card's sides from the artwork out to the
//     faint real edge when its frame has the colour of the scanner bed.
//
// Anything a stage infers rather than measures comes back with a source other
// than Full_Resolution_Edges, so the application marks the card for review.
//
// Always run this on the original scan, never on the moiré-filtered copy:
// the filter softens edges and the bed texture the detector relies on.

import "core:math"
import "core:slice"
import "core:sync"

Card_Source :: enum {
	Full_Resolution_Edges, // sides fitted to real edges: high confidence
	Coarse_Geometry, // edge fit failed, mask outline only: review
	Layout_Recovery, // grid cell, block cell or inferred from the layout: review
	Faint_Outer_Edges, // sides moved out to a faint edge around a bed-coloured frame: review
}

Card_Candidate :: struct {
	corners: [4]Vec2, // TL, TR, BR, BL in source pixels
	source:  Card_Source,
}

// Settings.
@(private = "file") MAX_DETECTION_W :: 1800
@(private = "file") MAX_DETECTION_H :: 1200
@(private = "file") MIN_DETECTION_SIDE :: 8
@(private = "file") MIN_AREA_RATIO :: 0.01
@(private = "file") MAX_AREA_RATIO :: 0.80
@(private = "file") POLY_EPS_RATIO :: 0.02
@(private) LAB_THRESHOLDS :: [3]f32{12, 18, 26}
@(private = "file") MIN_RECTANGULARITY :: 0.72
@(private = "file") CANNY_LOW :: 24
@(private = "file") CANNY_HIGH :: 72
@(private = "file") REF_MAX_OUTWARD :: 32
@(private = "file") REF_MAX_INWARD :: 16
@(private = "file") REF_OUTWARD_RATIO :: 0.12
@(private = "file") REF_INWARD_RATIO :: 0.02
@(private = "file") REF_MIN_GRADIENT :: 2.0
@(private = "file") REF_REL_GRADIENT :: 0.08
@(private = "file") REF_MIN_ALIGNMENT :: 0.985
@(private = "file") LAYOUT_ROW_TOL :: 0.35
@(private = "file") LAYOUT_DIM_TOL :: 0.12
@(private = "file") LAYOUT_MIN_SUPPORT :: 4
@(private = "file") LAYOUT_VERIFY_RATIO :: 0.04
@(private = "file") LAYOUT_MIN_SIDE_SUPPORT :: 0.45
@(private = "file") LAYOUT_MIN_VERIFY_GRADIENT :: 1.0
@(private = "file") SCANNER_FRAME_COVERAGE :: 0.85
@(private = "file") THIN_GAP_REACHES :: [4]int{6, 8, 11, 14}
@(private = "file") THIN_GAP_FLANK :: 7
@(private = "file") THIN_GAP_COVERAGE :: 0.15
@(private = "file") THIN_GAP_LINE_DIVISOR :: 30
@(private) GRID_MAX_CELLS :: 8
@(private = "file") GRID_NOTCH_DEPTH_RATIO :: 0.04
@(private = "file") GRID_NOTCH_HALF_WIDTH_RATIO :: 0.01
@(private = "file") GRID_NOTCH_MIN_FRACTION :: 0.5
@(private = "file") GRID_NOTCH_MAX_CONTROL :: 0.25
@(private = "file") GRID_CELL_DUP_OVERLAP :: 0.5
@(private = "file") BLOCK_AGREE_RATIO :: 0.008 // a proposal and a block cell agree within this fraction of the card's shorter side
@(private = "file") CONTAINER_MIN_INSIDE :: 0.90
@(private = "file") CONTAINER_MAX_INNER_RATIO :: 0.75
@(private = "file") ARTWORK_MIN_SUPPORT :: 3 // cards that must share a size before a proposal inside one of them counts as artwork
@(private = "file") ARTWORK_MAX_AREA_RATIO :: 0.90 // ... and the proposal's area against that card's

Quad :: [4]Vec2

// A float image plane (background distance).
@(private)
Plane :: struct {
	w, h: int,
	pix:  []f32,
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

detect_cards :: proc(src: Image, allocator := context.allocator) -> []Card_Candidate {
	scale := min(1.0, f64(MAX_DETECTION_W) / f64(src.w), f64(MAX_DETECTION_H) / f64(src.h))
	dw := max(1, int(math.floor(f64(src.w) * scale + 0.5)))
	dh := max(1, int(math.floor(f64(src.h) * scale + 0.5)))
	// Too small to hold a card, and too thin for the border strips and the
	// 3x3 kernels below.
	if min(dw, dh) < MIN_DETECTION_SIDE do return make([]Card_Candidate, 0, allocator)
	det: Image
	if dw == src.w && dh == src.h {
		det = image_make(dw, dh)
		copy(det.pix, src.pix)
	} else {
		det = resize_area_cv(src, dw, dh)
	}
	defer image_destroy(&det)

	gray := gray_from_rgba(src)
	defer delete(gray.pix)
	det_lab := lab_plane(det)
	defer delete(det_lab)
	bg := background_color(det_lab, dw, dh)
	bgdist := background_distance(src, bg)
	defer delete(bgdist.pix)
	gap, gap_any := thin_gap_mask(bgdist, dw, dh)
	defer mask_destroy(&gap)
	masks := foreground_masks(det, det_lab, bg, gap, gap_any)
	defer {
		for &m in masks do mask_destroy(&m)
		delete(masks)
	}

	// Proposals in detection coordinates.
	scan_area := f64(dw * dh)
	proposals := make([dynamic]Proposal, context.temp_allocator)
	for m in masks {
		contours := find_external_contours(m, context.temp_allocator)
		for c in contours {
			if p, ok := proposal_for_contour(c, dw, dh, scan_area); ok do append(&proposals, p)
		}
	}
	proposals = deduplicate(proposals[:])
	ordered := stable_order(proposals[:])

	// Map to source coordinates and fit the edges at full resolution.
	sx, sy := f64(src.w) / f64(dw), f64(src.h) / f64(dh)
	Entry :: struct {
		corners: Quad,
		source:  Card_Source,
	}
	entries := make([dynamic]Entry, context.temp_allocator)
	for p in ordered {
		mapped: Quad
		for c, i in p.corners {
			mapped[i] = {clamp(math.floor(c.x * sx + 0.5), 0, f64(src.w - 1)), clamp(math.floor(c.y * sy + 0.5), 0, f64(src.h - 1))}
		}
		refined := refine_corners(gray, bgdist, mapped, {})
		if any_same(refined, entries[:]) do continue
		append(&entries, Entry{refined, .Full_Resolution_Edges if refined != mapped else .Coarse_Geometry})
	}

	// Blocks of touching or overlapping cards split at their notches, largest
	// block first; the cells then take part in everything below like proposals.
	by_area := make([]int, len(entries), context.temp_allocator)
	for _, i in entries do by_area[i] = i
	areas := make([]f64, len(entries), context.temp_allocator)
	for e, i in entries {
		q := e.corners
		areas[i] = polygon_area(q[:])
	}
	for i in 1 ..< len(by_area) {
		for j := i; j > 0 && areas[by_area[j]] > areas[by_area[j - 1]]; j -= 1 do by_area[j], by_area[j - 1] = by_area[j - 1], by_area[j]
	}
	was_split := make([]bool, len(entries), context.temp_allocator)
	block_cells := make([dynamic]Quad, context.temp_allocator)
	cell_sound := make([dynamic]bool, context.temp_allocator) // no side of the cell is a guess past visible bed
	// Sizes of the cards found directly: witnesses for the size of block cells.
	sizes := make([dynamic]f64, context.temp_allocator)
	for e in entries {
		if e.source != .Full_Resolution_Edges do continue
		d := quad_dimensions(e.corners)
		append(&sizes, d.x, d.y)
	}
	for i in by_area {
		cells, cols, rows, ok := split_block(gray, bgdist, entries[i].corners)
		if !ok do continue
		was_split[i] = true
		restore_hidden_sides(cells[:], cols, rows, sizes[:], gray.w, gray.h)
		next: for c in cells {
			for o in block_cells {
				if overlap_fraction(c.corners, o) >= GRID_CELL_DUP_OVERLAP || overlap_fraction(o, c.corners) >= GRID_CELL_DUP_OVERLAP do continue next
			}
			append(&block_cells, c.corners)
			// An unfitted side is sound only as a seam between touching cards,
			// where the notches place it; with bed in between, the card's edge
			// is somewhere short of the seam.
			append(&cell_sound, c.fitted + (c.seams - c.gapped) == {0, 1, 2, 3})
		}
	}
	if len(block_cells) > 0 {
		// A direct proposal for the same card as a cell. When the two agree the
		// proposal stands (its edges are confirmed). Otherwise the cell does,
		// because the proposal's side towards its neighbour had no bed to stop
		// at, unless one of the cell's own sides is a guess (see cell_sound).
		unsplit := make([dynamic]Entry, context.temp_allocator)
		cell_dropped := make([]bool, len(block_cells), context.temp_allocator)
		for e, i in entries {
			if was_split[i] do continue
			keep := true
			for c, ci in block_cells {
				if cell_dropped[ci] do continue
				if overlap_fraction(c, e.corners) < GRID_CELL_DUP_OVERLAP || overlap_fraction(e.corners, c) < GRID_CELL_DUP_OVERLAP do continue
				dims := quad_dimensions(c)
				tol := max(4.0, min(dims.x, dims.y) * BLOCK_AGREE_RATIO)
				agree := true
				for k in 0 ..< 4 do if vec_len(c[k] - e.corners[k]) > tol do agree = false
				if e.source == .Full_Resolution_Edges && (agree || !cell_sound[ci]) do cell_dropped[ci] = true
				else do keep = false
			}
			if keep do append(&unsplit, e)
		}
		for c, ci in block_cells do if !cell_dropped[ci] do append(&unsplit, Entry{c, .Layout_Recovery})
		entries = unsplit
	}

	quads := make([dynamic]Quad, context.temp_allocator)
	for e in entries do append(&quads, e.corners)
	direct, cells := decompose_composites(quads[:], bgdist)
	kept := make([dynamic]Entry, context.temp_allocator)
	for i in direct do append(&kept, entries[i])
	for cell in cells {
		refined := refine_corners(gray, bgdist, cell.corners, cell.internal)
		if any_same(refined, kept[:]) do continue
		append(&kept, Entry{refined, .Layout_Recovery})
	}
	kept = suppress_containers(kept[:])
	kept = suppress_artwork(kept[:])
	kept_quads := make([dynamic]Quad, context.temp_allocator)
	for e in kept do append(&kept_quads, e.corners)
	order := stable_corner_order(kept_quads[:])
	final := make([dynamic]Entry, context.temp_allocator)
	for i in order do append(&final, kept[i])

	// Layout recovery adds cards the masks missed.
	final_quads := make([dynamic]Quad, context.temp_allocator)
	for e in final do append(&final_quads, e.corners)
	recovered := recover_layout(gray, bgdist, final_quads[:])

	out := make([dynamic]Card_Candidate, allocator)
	for q in recovered {
		source := Card_Source.Layout_Recovery
		for e in final {
			if same_corners(q, e.corners) {source = e.source; break}
		}
		append(&out, Card_Candidate{q, source})
	}
	// Frames in the bed's colour: move the sides from the artwork out to the
	// card's faint real edge. Every card is tested against the others as they
	// were found, so the result does not depend on the order.
	found := make([]Quad, len(out), context.temp_allocator)
	for c, i in out do found[i] = c.corners
	others := make([dynamic]Quad, context.temp_allocator)
	for &c, i in out {
		if c.source != .Full_Resolution_Edges do continue
		clear(&others)
		for q, j in found do if j != i do append(&others, q)
		if grown, ok := grow_to_faint_edges(gray, found[i], others[:]); ok {
			c.corners = grown
			c.source = .Faint_Outer_Edges
		}
	}
	return out[:]

	any_same :: proc(q: Quad, entries: []Entry) -> bool {
		for e in entries do if same_corners(q, e.corners) do return true
		return false
	}
	// Artwork inside a card can be a proposal of its own (a dark figure on a
	// pale frame). When most cards on the scan share one size, a proposal that
	// lies inside a card of that size, and is not of that size itself, is
	// artwork. Without a common size nothing says which of the two is the card.
	suppress_artwork :: proc(entries: []Entry) -> [dynamic]Entry {
		kept := make([dynamic]Entry, context.temp_allocator)
		n := len(entries)
		ws := make([]f64, n, context.temp_allocator)
		hs := make([]f64, n, context.temp_allocator)
		areas := make([]f64, n, context.temp_allocator)
		for e, i in entries {
			q := e.corners
			d := quad_dimensions(q)
			ws[i], hs[i] = d.x, d.y
			areas[i] = polygon_area(q[:])
		}
		// The common size: the one most proposals share (the larger on a tie).
		common := make([]bool, n, context.temp_allocator)
		support := 0
		best := -1
		for i in 0 ..< n {
			count := 0
			for j in 0 ..< n {
				if abs(ws[j] - ws[i]) <= ws[i] * LAYOUT_DIM_TOL && abs(hs[j] - hs[i]) <= hs[i] * LAYOUT_DIM_TOL do count += 1
			}
			if count > support || (count == support && best >= 0 && areas[i] > areas[best]) {
				support = count
				best = i
			}
		}
		for i in 0 ..< n {
			if best < 0 do break
			common[i] = abs(ws[i] - ws[best]) <= ws[best] * LAYOUT_DIM_TOL && abs(hs[i] - hs[best]) <= hs[best] * LAYOUT_DIM_TOL
		}
		for e, i in entries {
			artwork := false
			if support >= ARTWORK_MIN_SUPPORT && !common[i] {
				for o, j in entries {
					if j != i && common[j] && areas[i] < areas[j] * ARTWORK_MAX_AREA_RATIO && overlap_fraction(e.corners, o.corners) >= CONTAINER_MIN_INSIDE {
						artwork = true
						break
					}
				}
			}
			if !artwork do append(&kept, e)
		}
		return kept
	}
	suppress_containers :: proc(entries: []Entry) -> [dynamic]Entry {
		kept := make([dynamic]Entry, context.temp_allocator)
		areas := make([]f64, len(entries), context.temp_allocator)
		for e, i in entries {
			q := e.corners
			areas[i] = polygon_area(q[:])
		}
		for e, i in entries {
			contained := 0
			for o, j in entries {
				if j != i && areas[j] < areas[i] * CONTAINER_MAX_INNER_RATIO && overlap_fraction(o.corners, e.corners) >= CONTAINER_MIN_INSIDE {
					contained += 1
				}
			}
			if contained < 2 do append(&kept, e)
		}
		return kept
	}
}

// ---------------------------------------------------------------------------
// Colour and background
// ---------------------------------------------------------------------------

@(private = "file") srgb_linear: [256]f32
@(private = "file") srgb_once: sync.Once

// OpenCV-style 8-bit Lab with sRGB gamma (COLOR_BGR2Lab), as floats.
@(private = "file")
lab8_srgb :: #force_inline proc(r, g, b: u8) -> [3]f32 {
	f :: #force_inline proc(t: f32) -> f32 {
		return math.pow(t, 1.0 / 3.0) if t > 0.008856 else 7.787 * t + 16.0 / 116.0
	}
	R, G, B := srgb_linear[r], srgb_linear[g], srgb_linear[b]
	x := (0.412453 * R + 0.357580 * G + 0.180423 * B) / 0.950456
	y := 0.212671 * R + 0.715160 * G + 0.072169 * B
	z := (0.019334 * R + 0.119193 * G + 0.950227 * B) / 1.088754
	fy := f(y)
	l := 116 * fy - 16 if y > 0.008856 else 903.3 * y
	return {
		clamp(math.round(l * 255 / 100), 0, 255),
		clamp(math.round(500 * (f(x) - fy) + 128), 0, 255),
		clamp(math.round(200 * (fy - f(z)) + 128), 0, 255),
	}
}

@(private = "file")
init_srgb :: proc() {
	for i in 0 ..< 256 {
		v := f64(i) / 255
		srgb_linear[i] = f32(v / 12.92 if v <= 0.04045 else math.pow((v + 0.055) / 1.055, 2.4))
	}
}

@(private)
lab_plane :: proc(img: Image) -> []f32 {
	sync.once_do(&srgb_once, init_srgb)
	out := make([]f32, img.w * img.h * 3)
	Ctx :: struct {
		img: Image,
		out: []f32,
	}
	ctx := Ctx{img, out}
	parallel_rows(img.h, &ctx, proc(data: rawptr, y0, y1: int) {
		c := (^Ctx)(data)
		for i in y0 * c.img.w ..< y1 * c.img.w {
			v := lab8_srgb(c.img.pix[i * 4], c.img.pix[i * 4 + 1], c.img.pix[i * 4 + 2])
			c.out[i * 3], c.out[i * 3 + 1], c.out[i * 3 + 2] = v[0], v[1], v[2]
		}
	})
	return out
}

// Dominant border colour: the most populated 8-unit Lab bin among the border
// pixels, then the per-channel median of the pixels in that bin.
@(private)
background_color :: proc(lab: []f32, w, h: int) -> [3]f32 {
	strip := max(2, min(w, h) / 80)
	border := make([dynamic][3]f32, context.temp_allocator)
	add :: proc(border: ^[dynamic][3]f32, lab: []f32, w, x, y: int) {
		i := (y * w + x) * 3
		append(border, [3]f32{lab[i], lab[i + 1], lab[i + 2]})
	}
	// Border strips in a fixed order, overlapping at the corners: top, bottom, left, right.
	for y in 0 ..< strip do for x in 0 ..< w do add(&border, lab, w, x, y)
	for y in h - strip ..< h do for x in 0 ..< w do add(&border, lab, w, x, y)
	for y in 0 ..< h do for x in 0 ..< strip do add(&border, lab, w, x, y)
	for y in 0 ..< h do for x in w - strip ..< w do add(&border, lab, w, x, y)
	counts := make([]int, 32 * 32 * 32, context.temp_allocator)
	key :: proc(c: [3]f32) -> int {
		b: [3]int
		for k in 0 ..< 3 do b[k] = clamp(int(math.floor(c[k] / 8)), 0, 31)
		return b[0] * 1024 + b[1] * 32 + b[2]
	}
	for c in border do counts[key(c)] += 1
	dominant := 0
	for n, k in counts do if n > counts[dominant] do dominant = k
	chan := make([][dynamic]f32, 3, context.temp_allocator)
	for k in 0 ..< 3 do chan[k] = make([dynamic]f32, context.temp_allocator)
	for c in border do if key(c) == dominant do for k in 0 ..< 3 do append(&chan[k], c[k])
	return {median_f32(chan[0][:]), median_f32(chan[1][:]), median_f32(chan[2][:])}
}

@(private = "file")
median_f32 :: proc(v: []f32) -> f32 {
	if len(v) == 0 do return 0
	s := slice.clone(v, context.temp_allocator)
	slice.sort(s)
	n := len(s)
	return s[n / 2] if n % 2 == 1 else (s[n / 2 - 1] + s[n / 2]) / 2
}

@(private)
median_f64 :: proc(v: []f64) -> f64 {
	if len(v) == 0 do return 0
	s := slice.clone(v, context.temp_allocator)
	slice.sort(s)
	n := len(s)
	return s[n / 2] if n % 2 == 1 else (s[n / 2 - 1] + s[n / 2]) / 2
}

@(private)
background_distance :: proc(img: Image, bg: [3]f32) -> Plane {
	sync.once_do(&srgb_once, init_srgb)
	p := Plane{img.w, img.h, make([]f32, img.w * img.h)}
	Ctx :: struct {
		img: Image,
		p:   Plane,
		bg:  [3]f32,
	}
	ctx := Ctx{img, p, bg}
	parallel_rows(img.h, &ctx, proc(data: rawptr, y0, y1: int) {
		c := (^Ctx)(data)
		for i in y0 * c.img.w ..< y1 * c.img.w {
			v := lab8_srgb(c.img.pix[i * 4], c.img.pix[i * 4 + 1], c.img.pix[i * 4 + 2])
			d := v - c.bg
			c.p.pix[i] = math.sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2])
		}
	})
	return p
}

// ---------------------------------------------------------------------------
// Masks
// ---------------------------------------------------------------------------

@(private = "file")
resize_area_plane :: proc(src: []f32, sw, sh, dw, dh: int) -> []f32 {
	tx, fx := area_taps(sw, dw, context.temp_allocator)
	ty, fy := area_taps(sh, dh, context.temp_allocator)
	tmp := make([]f32, dw * sh)
	defer delete(tmp)
	for y in 0 ..< sh {
		for x in 0 ..< dw {
			acc: f32
			for t in tx[fx[x]:fx[x + 1]] do acc += src[y * sw + t.src] * t.weight
			tmp[y * dw + x] = acc
		}
	}
	out := make([]f32, dw * dh)
	for y in 0 ..< dh {
		for x in 0 ..< dw {
			acc: f32
			for t in ty[fy[y]:fy[y + 1]] do acc += tmp[t.src * dw + x] * t.weight
			out[y * dw + x] = acc
		}
	}
	return out
}

// Thin background gaps between closely packed cards, found at full resolution
// (a short background run with solid foreground on both sides) and kept only
// where they form long straight lines at detection scale.
@(private = "file")
thin_gap_mask :: proc(bgdist: Plane, dw, dh: int) -> (combined: Mask, any_gap: bool) {
	w, h := bgdist.w, bgdist.h
	thr := LAB_THRESHOLDS[len(LAB_THRESHOLDS) - 1]
	fgm := mask_make(w, h)
	defer mask_destroy(&fgm)
	for i in 0 ..< w * h do fgm.pix[i] = 255 if bgdist.pix[i] >= thr else 0
	line_length := max(3, min(dh, dw) / THIN_GAP_LINE_DIVISOR)
	combined = mask_make(dw, dh)
	reaches := THIN_GAP_REACHES
	for axis in ([2]int{1, 0}) {
		solid := erode(fgm, rect_kernel(THIN_GAP_FLANK, 1) if axis == 1 else rect_kernel(1, THIN_GAP_FLANK))
		gap := make([]f32, w * h)
		for y in 0 ..< h {
			for x in 0 ..< w {
				i := y * w + x
				if fgm.pix[i] != 0 do continue
				for r in reaches {
					before, after: bool
					if axis == 1 {
						before = x >= r && solid.pix[i - r] != 0
						after = x + r < w && solid.pix[i + r] != 0
					} else {
						before = y >= r && solid.pix[i - r * w] != 0
						after = y + r < h && solid.pix[i + r * w] != 0
					}
					if before && after {gap[i] = 1; break}
				}
			}
		}
		mask_destroy(&solid)
		reduced := gap
		if w != dw || h != dh do reduced = resize_area_plane(gap, w, h, dw, dh)
		line := mask_make(dw, dh)
		for i in 0 ..< dw * dh do line.pix[i] = 255 if reduced[i] > THIN_GAP_COVERAGE else 0
		if raw_data(reduced) != raw_data(gap) do delete(reduced)
		delete(gap)
		widened := dilate(line, rect_kernel(3, 1) if axis == 1 else rect_kernel(1, 3))
		mask_destroy(&line)
		along := rect_kernel(1, line_length) if axis == 1 else rect_kernel(line_length, 1)
		closed := morph_close(widened, along)
		mask_destroy(&widened)
		opened := morph_open(closed, along)
		mask_destroy(&closed)
		for i in 0 ..< dw * dh {
			if opened.pix[i] != 0 {combined.pix[i] = 255; any_gap = true}
		}
		mask_destroy(&opened)
	}
	return
}

// Clears a side's margin when a line within it is almost entirely foreground:
// a scanner lid strip or bed edge that would join every card along that side.
@(private = "file")
clear_scanner_frame :: proc(m: ^Mask, margin: int) {
	w, h := m.w, m.h
	row_full :: proc(m: ^Mask, y: int) -> bool {
		n := 0
		for x in 0 ..< m.w do if m.pix[y * m.w + x] != 0 do n += 1
		return f64(n) * 255 / f64(m.w) >= SCANNER_FRAME_COVERAGE * 255
	}
	col_full :: proc(m: ^Mask, x: int) -> bool {
		n := 0
		for y in 0 ..< m.h do if m.pix[y * m.w + x] != 0 do n += 1
		return f64(n) * 255 / f64(m.h) >= SCANNER_FRAME_COVERAGE * 255
	}
	top, bottom, left, right: bool
	for y in 0 ..< margin do top ||= row_full(m, y)
	for y in h - margin ..< h do bottom ||= row_full(m, y)
	for x in 0 ..< margin do left ||= col_full(m, x)
	for x in w - margin ..< w do right ||= col_full(m, x)
	if top do for y in 0 ..< margin do for x in 0 ..< w do m.pix[y * w + x] = 0
	if bottom do for y in h - margin ..< h do for x in 0 ..< w do m.pix[y * w + x] = 0
	if left do for y in 0 ..< h do for x in 0 ..< margin do m.pix[y * w + x] = 0
	if right do for y in 0 ..< h do for x in w - margin ..< w do m.pix[y * w + x] = 0
}

@(private = "file")
foreground_masks :: proc(det: Image, lab: []f32, bg: [3]f32, gap: Mask, gap_any: bool) -> [dynamic]Mask {
	w, h := det.w, det.h
	dist := make([]f32, w * h)
	defer delete(dist)
	for i in 0 ..< w * h {
		d := [3]f32{lab[i * 3], lab[i * 3 + 1], lab[i * 3 + 2]} - bg
		dist[i] = math.sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2])
	}
	ks := max(3, min(w, h) / 250)
	if ks % 2 == 0 do ks += 1
	kernel := ellipse_kernel(ks)
	defer kernel_destroy(&kernel)
	margin := max(2, min(w, h) / 120)
	closed := make([dynamic]Mask, context.temp_allocator)
	for t in LAB_THRESHOLDS {
		m := mask_make(w, h)
		for i in 0 ..< w * h do m.pix[i] = 255 if dist[i] >= t else 0
		o := morph_open(m, kernel)
		mask_destroy(&m)
		append(&closed, morph_close(o, kernel, 2))
		mask_destroy(&o)
	}
	g := gray_from_rgba(det)
	edges := canny(g, CANNY_LOW, CANNY_HIGH)
	delete(g.pix)
	ce := morph_close(edges, kernel, 2)
	mask_destroy(&edges)
	append(&closed, dilate(ce, kernel, 1))
	mask_destroy(&ce)

	masks := make([dynamic]Mask)
	for &m in closed {
		clear_scanner_frame(&m, margin)
		append(&masks, m)
		if gap_any {
			carved := mask_clone(m)
			for i in 0 ..< w * h do if gap.pix[i] != 0 do carved.pix[i] = 0
			append(&masks, morph_open(carved, kernel))
			mask_destroy(&carved)
		}
	}
	return masks
}

// ---------------------------------------------------------------------------
// Proposals
// ---------------------------------------------------------------------------

@(private = "file")
Proposal :: struct {
	corners:        Quad,
	area:           f64,
	rectangularity: f64,
	centroid:       Vec2,
	bounds:         [4]f64, // x, y, w, h
}

@(private = "file")
cross3 :: #force_inline proc(a, b, c: Vec2) -> f64 {
	return (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
}

// Sort by angle around the centre, start at the smallest x+y, make clockwise.
@(private)
order_quad :: proc(points: Quad) -> Quad {
	c := (points[0] + points[1] + points[2] + points[3]) / 4
	p := points
	ang :: proc(p, c: Vec2) -> f64 {return math.atan2(p.y - c.y, p.x - c.x)}
	for i in 1 ..< 4 {
		for j := i; j > 0 && ang(p[j], c) < ang(p[j - 1], c); j -= 1 do p[j], p[j - 1] = p[j - 1], p[j]
	}
	start := 0
	for i in 1 ..< 4 do if p[i].x + p[i].y < p[start].x + p[start].y do start = i
	o: Quad
	for i in 0 ..< 4 do o[i] = p[(start + i) % 4]
	if cross3(o[0], o[1], o[2]) < 0 do o = {o[0], o[3], o[2], o[1]}
	return o
}

@(private)
valid_quad :: proc(q: Quad) -> bool {
	for i in 0 ..< 4 {
		if cross3(q[i], q[(i + 1) % 4], q[(i + 2) % 4]) <= 0 do return false
		d := q[(i + 1) % 4] - q[i]
		if d.x * d.x + d.y * d.y < 16 do return false
	}
	return true
}

@(private = "file")
proposal_for_contour :: proc(contour: []Vec2, w, h: int, scan_area: f64) -> (p: Proposal, ok: bool) {
	if len(contour) < 3 do return
	area := polygon_area(contour)
	ratio := area / scan_area
	if ratio < MIN_AREA_RATIO || ratio > MAX_AREA_RATIO do return
	b := bounding_rect(contour)
	touched := int(b[0] <= 0) + int(b[1] <= 0) + int(b[0] + b[2] >= f64(w)) + int(b[1] + b[3] >= f64(h))
	if touched >= 3 do return // the scan frame, not a card clipped by one or two borders
	polygon := approx_poly_dp_closed(contour, POLY_EPS_RATIO * arc_length_closed(contour), context.temp_allocator)
	box, rect_area := min_area_rect(contour)
	if rect_area <= 0 || area / rect_area < MIN_RECTANGULARITY do return
	points: Quad = box
	if len(polygon) == 4 && polygon_is_convex(polygon) do points = {polygon[0], polygon[1], polygon[2], polygon[3]}
	corners := order_quad(points)
	if !valid_quad(corners) do return
	return Proposal{corners, area, area / rect_area, (corners[0] + corners[1] + corners[2] + corners[3]) / 4, b}, true
}

@(private = "file")
bounds_intersection :: proc(a, b: [4]f64) -> f64 {
	l, t := max(a[0], b[0]), max(a[1], b[1])
	r, bt := min(a[0] + a[2], b[0] + b[2]), min(a[1] + a[3], b[1] + b[3])
	return max(0, r - l) * max(0, bt - t)
}

@(private = "file")
same_region :: proc(a, b: Proposal) -> bool {
	inter := bounds_intersection(a.bounds, b.bounds)
	union_ := a.bounds[2] * a.bounds[3] + b.bounds[2] * b.bounds[3] - inter
	iou := 0.0 if union_ <= 0 else inter / union_
	d := a.centroid - b.centroid
	avg_h := (a.bounds[3] + b.bounds[3]) / 2
	return iou >= 0.85 || (d.x * d.x + d.y * d.y <= (avg_h * 0.05) * (avg_h * 0.05) && iou >= 0.70)
}

@(private = "file")
deduplicate :: proc(proposals: []Proposal) -> [dynamic]Proposal {
	ranked := slice.clone(proposals, context.temp_allocator)
	slice.stable_sort_by(ranked, proc(a, b: Proposal) -> bool {
		if a.rectangularity != b.rectangularity do return a.rectangularity > b.rectangularity
		if a.area != b.area do return a.area > b.area
		if a.centroid.x != b.centroid.x do return a.centroid.x < b.centroid.x
		return a.centroid.y < b.centroid.y
	})
	kept := make([dynamic]Proposal, context.temp_allocator)
	outer: for p in ranked {
		for k in kept do if same_region(p, k) do continue outer
		append(&kept, p)
	}
	return kept
}

// Reading order: rows by centroid y (tolerance from the median height), then x.
@(private = "file")
stable_order :: proc(proposals: []Proposal) -> []Proposal {
	if len(proposals) == 0 do return {}
	heights := make([]f64, len(proposals), context.temp_allocator)
	for p, i in proposals do heights[i] = p.bounds[3]
	slice.sort(heights)
	tol := max(4.0, heights[len(heights) / 2] * 0.35)
	remaining := make([dynamic]Proposal, context.temp_allocator)
	for p in proposals do append(&remaining, p)
	slice.stable_sort_by(remaining[:], proc(a, b: Proposal) -> bool {
		if a.centroid.y != b.centroid.y do return a.centroid.y < b.centroid.y
		return a.centroid.x < b.centroid.x
	})
	out := make([dynamic]Proposal, context.temp_allocator)
	for len(remaining) > 0 {
		anchor := remaining[0].centroid.y
		row := make([dynamic]Proposal, context.temp_allocator)
		rest := make([dynamic]Proposal, context.temp_allocator)
		for p in remaining {
			if abs(p.centroid.y - anchor) <= tol do append(&row, p)
			else do append(&rest, p)
		}
		slice.stable_sort_by(row[:], proc(a, b: Proposal) -> bool {
			if a.centroid.x != b.centroid.x do return a.centroid.x < b.centroid.x
			return a.centroid.y < b.centroid.y
		})
		for p in row do append(&out, p)
		remaining = rest
	}
	return out[:]
}

// Indices of `quads` in reading order.
@(private = "file")
stable_corner_order :: proc(quads: []Quad) -> []int {
	props := make([dynamic]Proposal, context.temp_allocator)
	for q, i in quads {
		lo, hi := q[0], q[0]
		for p in q {
			lo = {min(lo.x, p.x), min(lo.y, p.y)}
			hi = {max(hi.x, p.x), max(hi.y, p.y)}
		}
		// The index rides in `area` so it survives the sort.
		append(&props, Proposal{corners = q, centroid = quad_center(q), bounds = {lo.x, lo.y, hi.x - lo.x, hi.y - lo.y}, area = f64(i)})
	}
	ordered := stable_order(props[:])
	idx := make([]int, len(ordered), context.temp_allocator)
	for p, i in ordered do idx[i] = int(p.area)
	return idx
}

quad_center :: proc(q: Quad) -> Vec2 {
	return (q[0] + q[1] + q[2] + q[3]) / 4
}

// Average opposite side lengths: (width, height).
quad_dimensions :: proc(q: Quad) -> Vec2 {
	return {(vec_len(q[1] - q[0]) + vec_len(q[2] - q[3])) / 2, (vec_len(q[2] - q[1]) + vec_len(q[3] - q[0])) / 2}
}

same_corners :: proc(a, b: Quad) -> bool {
	a, b := a, b
	aa, ab := polygon_area(a[:]), polygon_area(b[:])
	if aa <= 0 || ab <= 0 do return false
	inter := convex_intersection_area(a[:], b[:])
	u := aa + ab - inter
	return u > 0 && inter / u >= 0.90
}

@(private)
overlap_fraction :: proc(first, second: Quad) -> f64 {
	f, s := first, second
	a := polygon_area(f[:])
	if a <= 0 do return 0
	return convex_intersection_area(f[:], s[:]) / a
}

// ---------------------------------------------------------------------------
// Full-resolution edge refinement
// ---------------------------------------------------------------------------

@(private)
sample_gray :: #force_inline proc(g: Gray, x, y: f64) -> f64 {
	cx := clamp(int(math.floor(x + 0.5)), 0, g.w - 1)
	cy := clamp(int(math.floor(y + 0.5)), 0, g.h - 1)
	return f64(g.pix[cy * g.w + cx])
}

@(private)
sample_plane :: #force_inline proc(p: Plane, x, y: f64) -> f64 {
	cx := clamp(int(math.floor(x + 0.5)), 0, p.w - 1)
	cy := clamp(int(math.floor(y + 0.5)), 0, p.h - 1)
	return f64(p.pix[cy * p.w + cx])
}

@(private)
Line :: struct {
	point, dir: Vec2,
}

// Fits each side to the full-resolution outer edge and intersects adjacent
// lines. Sides in `fixed` (0 top, 1 right, 2 bottom, 3 left) keep their coarse
// line: shared seams between touching cards. Returns the input on failure.
@(private = "file")
refine_corners :: proc(gray: Gray, bgdist: Plane, corners: Quad, fixed: bit_set[0 ..< 4]) -> Quad {
	shortest := math.INF_F64
	for i in 0 ..< 4 do shortest = min(shortest, vec_len(corners[(i + 1) % 4] - corners[i]))
	outward := min(REF_MAX_OUTWARD, max(8, int(math.floor(shortest * REF_OUTWARD_RATIO + 0.5))))
	inward := min(REF_MAX_INWARD, max(6, int(math.floor(shortest * REF_INWARD_RATIO + 0.5))))
	lines: [4]Line
	for i in 0 ..< 4 {
		a, b := corners[i], corners[(i + 1) % 4]
		if i in fixed {
			lines[i] = {a, (b - a) / vec_len(b - a)}
			continue
		}
		l, ok := fit_outer_side(gray, bgdist, a, b, inward, outward)
		if !ok do return corners
		lines[i] = l
	}
	out: Quad
	for i in 0 ..< 4 {
		p, ok := line_intersection(lines[(i + 3) % 4], lines[i])
		if !ok do return corners
		out[i] = {clamp(math.floor(p.x + 0.5), 0, f64(gray.w - 1)), clamp(math.floor(p.y + 0.5), 0, f64(gray.h - 1))}
	}
	return out if valid_quad(out) else corners
}

@(private)
line_intersection :: proc(a, b: Line) -> (Vec2, bool) {
	den := a.dir.x * b.dir.y - a.dir.y * b.dir.x
	if abs(den) < 0.000001 do return {}, false
	o := b.point - a.point
	t := (o.x * b.dir.y - o.y * b.dir.x) / den
	return a.point + a.dir * t, true
}

@(private)
fit_outer_side :: proc(gray: Gray, bgdist: Plane, first, second: Vec2, inward, outward: int) -> (Line, bool) {
	d := second - first
	length := vec_len(d)
	if length < 8 do return {}, false
	dir := d / length
	out_n := Vec2{dir.y, -dir.x}
	thr := f64(LAB_THRESHOLDS[0])
	n := max(24, min(96, int(math.floor(length / 6 + 0.5))))
	points := make([dynamic]Vec2, context.temp_allocator)
	offsets := make([dynamic]f64, context.temp_allocator)
	values := make([]f64, inward + outward + 2, context.temp_allocator)
	for s in 0 ..< n {
		f := 0.15 + 0.70 * f64(s) / f64(n - 1)
		o := first + d * f
		for k in 0 ..< len(values) do values[k] = sample_gray(gray, o.x + out_n.x * f64(k - inward), o.y + out_n.y * f64(k - inward))
		// The outer edge cannot lie beyond the first background pixel outside it;
		// stopping there keeps a close neighbour's edge out of this side's fit.
		limit := outward
		for k in 0 ..= outward {
			if sample_plane(bgdist, o.x + out_n.x * f64(k), o.y + out_n.y * f64(k)) < thr {limit = k; break}
		}
		count := inward + limit
		maximum := 0.0
		for k in 0 ..< count do maximum = max(maximum, abs(values[k + 2] - values[k]) / 2)
		t := max(REF_MIN_GRADIENT, maximum * REF_REL_GRADIENT)
		best := -1
		for k in 0 ..< count do if abs(values[k + 2] - values[k]) / 2 >= t do best = k
		if best < 0 do continue
		off := f64(best - inward + 1)
		append(&offsets, off)
		append(&points, o + out_n * off)
	}
	need := max(12, n / 3)
	if len(points) < need do return {}, false
	med := median_f64(offsets[:])
	dev := make([]f64, len(offsets), context.temp_allocator)
	for v, i in offsets do dev[i] = abs(v - med)
	tol := max(3.0, median_f64(dev) * 2.5)
	retained := make([dynamic]Vec2, context.temp_allocator)
	for p, i in points do if abs(offsets[i] - med) <= tol do append(&retained, p)
	if len(retained) < need do return {}, false
	lp, ld := fit_line_huber(retained[:])
	align := ld.x * dir.x + ld.y * dir.y
	if align < 0 {ld = -ld; align = -align}
	if align < REF_MIN_ALIGNMENT do return {}, false
	return Line{lp, ld}, true
}

// ---------------------------------------------------------------------------
// Grids of touching cards
// ---------------------------------------------------------------------------

@(private = "file")
Grid_Cell :: struct {
	corners:  Quad,
	internal: bit_set[0 ..< 4],
}

@(private = "file")
grid_shape :: proc(dims, unit: Vec2) -> (cols, rows: int, ok: bool) {
	if unit.x <= 0 || unit.y <= 0 do return
	cols = int(math.floor(dims.x / unit.x + 0.5))
	rows = int(math.floor(dims.y / unit.y + 0.5))
	if !(1 <= cols && cols <= GRID_MAX_CELLS && 1 <= rows && rows <= GRID_MAX_CELLS) do return
	if abs(dims.x - f64(cols) * unit.x) > unit.x * LAYOUT_DIM_TOL do return
	if abs(dims.y - f64(rows) * unit.y) > unit.y * LAYOUT_DIM_TOL do return
	return cols, rows, true
}

@(private = "file")
grid_point :: proc(q: Quad, u, v: f64) -> Vec2 {
	top := q[0] + (q[1] - q[0]) * u
	bottom := q[3] + (q[2] - q[3]) * u
	return top + (bottom - top) * v
}

@(private = "file")
grid_cells :: proc(q: Quad, cols, rows, w, h: int) -> [dynamic]Grid_Cell {
	cells := make([dynamic]Grid_Cell, context.temp_allocator)
	for r in 0 ..< rows {
		for c in 0 ..< cols {
			uv := [4][2]f64 {
				{f64(c) / f64(cols), f64(r) / f64(rows)},
				{f64(c + 1) / f64(cols), f64(r) / f64(rows)},
				{f64(c + 1) / f64(cols), f64(r + 1) / f64(rows)},
				{f64(c) / f64(cols), f64(r + 1) / f64(rows)},
			}
			cell: Grid_Cell
			for k in 0 ..< 4 {
				p := grid_point(q, uv[k][0], uv[k][1])
				cell.corners[k] = {clamp(math.floor(p.x + 0.5), 0, f64(w - 1)), clamp(math.floor(p.y + 0.5), 0, f64(h - 1))}
			}
			if r > 0 do cell.internal += {0}
			if c < cols - 1 do cell.internal += {1}
			if r < rows - 1 do cell.internal += {2}
			if c > 0 do cell.internal += {3}
			append(&cells, cell)
		}
	}
	return cells
}

@(private = "file")
notch_fraction :: proc(bgdist: Plane, q: Quad, center: Vec2, pos: [2]f64, depth, half_width: int, thr: f64) -> f64 {
	origin := grid_point(q, pos[0], pos[1])
	inward := center - origin
	if vec_len(inward) <= 0 do return 0
	edge := q[1] - q[0] if pos[1] == 0 || pos[1] == 1 else q[3] - q[0]
	tangent := edge / vec_len(edge)
	normal := Vec2{-tangent.y, tangent.x}
	if normal.x * inward.x + normal.y * inward.y < 0 do normal = -normal
	background, samples := 0, 0
	for step in depth / 4 ..= depth {
		samples += 1
		for across in -half_width ..= half_width {
			p := origin + normal * f64(step) + tangent * f64(across)
			if sample_plane(bgdist, p.x, p.y) < thr {background += 1; break}
		}
	}
	return f64(background) / f64(samples)
}

// Every internal grid line must meet the outline at a background notch left
// by the rounded corners of the touching cards.
@(private = "file")
grid_notch_evidence :: proc(bgdist: Plane, q: Quad, cols, rows: int, unit_short: f64) -> bool {
	depth := max(6, int(math.floor(unit_short * GRID_NOTCH_DEPTH_RATIO + 0.5)))
	hw := max(2, int(math.floor(unit_short * GRID_NOTCH_HALF_WIDTH_RATIO + 0.5)))
	center := quad_center(q)
	thr := f64(LAB_THRESHOLDS[0])
	Grid_Line :: [4][2]f64 // first seam, second seam, first control, second control
	lines := make([dynamic]Grid_Line, context.temp_allocator)
	for c in 1 ..< cols {
		u, uc := f64(c) / f64(cols), (f64(c) - 0.5) / f64(cols)
		append(&lines, Grid_Line{{u, 0}, {u, 1}, {uc, 0}, {uc, 1}})
	}
	for r in 1 ..< rows {
		v, vc := f64(r) / f64(rows), (f64(r) - 0.5) / f64(rows)
		append(&lines, Grid_Line{{0, v}, {1, v}, {0, vc}, {1, vc}})
	}
	for l in lines {
		supported := false
		for k in 0 ..< 2 {
			seam := notch_fraction(bgdist, q, center, l[k], depth, hw, thr)
			control := notch_fraction(bgdist, q, center, l[k + 2], depth, hw, thr)
			if seam >= GRID_NOTCH_MIN_FRACTION && control <= GRID_NOTCH_MAX_CONTROL do supported = true
		}
		if !supported do return false
	}
	return true
}

@(private = "file")
covered :: proc(cell: Quad, pieces: []Quad) -> bool {
	for p in pieces do if overlap_fraction(cell, p) >= GRID_CELL_DUP_OVERLAP do return true
	return false
}

// Splits proposals that are whole grids of touching cards into their cells.
// Returns the indices of the remaining direct proposals and the new cells.
@(private = "file")
decompose_composites :: proc(proposals: []Quad, bgdist: Plane) -> (direct: [dynamic]int, cells: [dynamic]Grid_Cell) {
	direct = make([dynamic]int, context.temp_allocator)
	cells = make([dynamic]Grid_Cell, context.temp_allocator)
	n := len(proposals)
	dims := make([]Vec2, n, context.temp_allocator)
	for q, i in proposals do dims[i] = quad_dimensions(q)
	Shape :: struct {
		ok:         bool,
		cols, rows: int,
	}
	best_found := false
	best_key: [3]f64
	best_shapes := make([]Shape, n, context.temp_allocator)
	best_splits := make([]bool, n, context.temp_allocator)
	shapes := make([]Shape, n, context.temp_allocator)
	splits := make([]bool, n, context.temp_allocator)
	for unit in dims {
		nshapes, nsplits := 0, 0
		for i in 0 ..< n {
			c, r, ok := grid_shape(dims[i], unit)
			shapes[i] = {ok, c, r}
			splits[i] = false
			if !ok do continue
			nshapes += 1
			if (c != 1 || r != 1) && grid_notch_evidence(bgdist, proposals[i], c, r, min(unit.x, unit.y)) {
				splits[i] = true
				nsplits += 1
			}
		}
		key := [3]f64{f64(nsplits), f64(nshapes), -unit.x * unit.y}
		better := !best_found || key[0] > best_key[0] || (key[0] == best_key[0] && (key[1] > best_key[1] || (key[1] == best_key[1] && key[2] > best_key[2])))
		if better {
			best_found = true
			best_key = key
			copy(best_shapes, shapes)
			copy(best_splits, splits)
		}
	}
	if !best_found {
		for i in 0 ..< n do append(&direct, i)
		return
	}
	pieces := make([dynamic]Quad, context.temp_allocator)
	for s, i in best_shapes do if s.ok && s.cols == 1 && s.rows == 1 do append(&pieces, proposals[i])
	split_order := make([dynamic]int, context.temp_allocator)
	for i in 0 ..< n do if best_splits[i] do append(&split_order, i)
	// Largest proposals first, then by index (stable insertion sort).
	for i in 1 ..< len(split_order) {
		for j := i; j > 0; j -= 1 {
			a, b := split_order[j - 1], split_order[j]
			if dims[b].x * dims[b].y > dims[a].x * dims[a].y {
				split_order[j - 1], split_order[j] = b, a
			} else do break
		}
	}
	w, h := bgdist.w, bgdist.h
	all_cover := proc(cell: Quad, pieces: []Quad, cells: []Grid_Cell) -> bool {
		if covered(cell, pieces) do return true
		for c in cells do if overlap_fraction(cell, c.corners) >= GRID_CELL_DUP_OVERLAP do return true
		return false
	}
	for i in split_order {
		s := best_shapes[i]
		for cell in grid_cells(proposals[i], s.cols, s.rows, w, h) {
			if !all_cover(cell.corners, pieces[:], cells[:]) do append(&cells, cell)
		}
	}
	for i in 0 ..< n {
		if best_splits[i] do continue
		s := best_shapes[i]
		if s.ok && (s.cols != 1 || s.rows != 1) {
			redundant := true
			for cell in grid_cells(proposals[i], s.cols, s.rows, w, h) {
				if !all_cover(cell.corners, pieces[:], cells[:]) {redundant = false; break}
			}
			if redundant do continue
		}
		append(&direct, i)
	}
	return
}

// ---------------------------------------------------------------------------
// Layout recovery
// ---------------------------------------------------------------------------

@(private = "file")
Cluster :: struct {
	center: f64,
	count:  int,
	sum:    f64,
}

@(private = "file")
cluster_axis :: proc(points: []Vec2, axis: int, tol: f64) -> [dynamic]Cluster {
	p := slice.clone(points, context.temp_allocator)
	less :: proc(a, b: Vec2, axis: int) -> bool {
		if a[axis] != b[axis] do return a[axis] < b[axis]
		return a[1 - axis] < b[1 - axis]
	}
	for i in 1 ..< len(p) {
		for j := i; j > 0 && less(p[j], p[j - 1], axis); j -= 1 do p[j], p[j - 1] = p[j - 1], p[j]
	}
	clusters := make([dynamic]Cluster, context.temp_allocator)
	for q in p {
		target := -1
		for c, i in clusters do if abs(q[axis] - c.center) <= tol {target = i; break}
		if target < 0 {
			append(&clusters, Cluster{center = q[axis]})
			target = len(clusters) - 1
		}
		c := &clusters[target]
		c.count += 1
		c.sum += q[axis]
		c.center = c.sum / f64(c.count)
	}
	return clusters
}

@(private = "file")
layout_evidence :: proc(gray: Gray, q: Quad) -> bool {
	dims := quad_dimensions(q)
	search := min(16, max(4, int(math.floor(min(dims.x, dims.y) * LAYOUT_VERIFY_RATIO + 0.5))))
	support: [4]f64
	for i in 0 ..< 4 {
		a, b := q[i], q[(i + 1) % 4]
		d := b - a
		length := vec_len(d)
		if length < 8 do return false
		normal := Vec2{d.y / length, -d.x / length}
		supported := 0
		SAMPLES :: 32
		values := make([]f64, 2 * search + 2, context.temp_allocator)
		for s in 0 ..< SAMPLES {
			o := a + d * (0.15 + 0.70 * f64(s) / f64(SAMPLES - 1))
			for k in 0 ..< len(values) do values[k] = sample_gray(gray, o.x + normal.x * f64(k - search), o.y + normal.y * f64(k - search))
			maximum := 0.0
			for k in 0 ..< len(values) - 2 do maximum = max(maximum, abs(values[k + 2] - values[k]) / 2)
			if maximum >= LAYOUT_MIN_VERIFY_GRADIENT do supported += 1
		}
		support[i] = f64(supported) / SAMPLES
	}
	strong := 0
	for v in support do if v >= LAYOUT_MIN_SIDE_SUPPORT do strong += 1
	return strong >= 3 && (support[0] + support[1] + support[2] + support[3]) / 4 >= LAYOUT_MIN_SIDE_SUPPORT
}

// Fills empty cells of a regular row/column layout when the image shows edges there.
@(private = "file")
recover_layout :: proc(gray: Gray, bgdist: Plane, candidates: []Quad) -> []Quad {
	if len(candidates) < LAYOUT_MIN_SUPPORT do return candidates
	n := len(candidates)
	ws := make([]f64, n, context.temp_allocator)
	hs := make([]f64, n, context.temp_allocator)
	for q, i in candidates {
		d := quad_dimensions(q)
		ws[i], hs[i] = d.x, d.y
	}
	mw, mh := median_f64(ws), median_f64(hs)
	consistent := make([dynamic]Quad, context.temp_allocator)
	for q, i in candidates {
		if abs(ws[i] - mw) <= mw * LAYOUT_DIM_TOL && abs(hs[i] - mh) <= mh * LAYOUT_DIM_TOL do append(&consistent, q)
	}
	if len(consistent) < LAYOUT_MIN_SUPPORT do return candidates
	centers := make([]Vec2, len(consistent), context.temp_allocator)
	for q, i in consistent do centers[i] = quad_center(q)
	rows_all := cluster_axis(centers, 1, mh * LAYOUT_ROW_TOL)
	cols_all := cluster_axis(centers, 0, mw * LAYOUT_ROW_TOL)
	rows := make([dynamic]f64, context.temp_allocator)
	cols := make([dynamic]f64, context.temp_allocator)
	for c in rows_all do if c.count >= 2 do append(&rows, c.center)
	for c in cols_all do if c.count >= 2 do append(&cols, c.center)
	if len(rows) < 2 || len(cols) < 2 do return candidates
	template: Quad
	for k in 0 ..< 4 {
		xs := make([]f64, len(consistent), context.temp_allocator)
		ys := make([]f64, len(consistent), context.temp_allocator)
		for q, i in consistent {
			off := q[k] - centers[i]
			xs[i], ys[i] = off.x, off.y
		}
		template[k] = {median_f64(xs), median_f64(ys)}
	}
	recovered := make([dynamic]Quad, context.temp_allocator)
	for q in candidates do append(&recovered, q)
	for r in rows {
		for c in cols {
			expected := Vec2{c, r}
			occupied := false
			for q in recovered {
				qc := quad_center(q)
				if abs(qc.x - expected.x) <= mw * 0.35 && abs(qc.y - expected.y) <= mh * 0.35 {occupied = true; break}
			}
			if occupied do continue
			hyp: Quad
			for k in 0 ..< 4 do hyp[k] = expected + template[k]
			if !layout_evidence(gray, hyp) do continue
			rounded: Quad
			for k in 0 ..< 4 do rounded[k] = {clamp(math.floor(hyp[k].x + 0.5), 0, f64(gray.w - 1)), clamp(math.floor(hyp[k].y + 0.5), 0, f64(gray.h - 1))}
			refined := refine_corners(gray, bgdist, rounded, {})
			if !valid_quad(refined) do continue
			dup := false
			for e in recovered do if same_corners(refined, e) {dup = true; break}
			if !dup do append(&recovered, refined)
		}
	}
	order := stable_corner_order(recovered[:])
	out := make([]Quad, len(order), context.temp_allocator)
	for i, k in order do out[k] = recovered[i]
	return out
}
