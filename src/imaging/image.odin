// Pure-Odin image processing for card extraction. No raylib or other vendor
// dependencies, so it can be unit tested headless with `odin test src/imaging`.
package imaging

import "core:math"
import "core:os"
import "core:sync"
import "core:thread"

// 8-bit RGBA, row-major, tightly packed (stride = w * 4).
Image :: struct {
	w, h: int,
	pix:  []u8,
}

Vec2 :: [2]f64

image_make :: proc(w, h: int, allocator := context.allocator) -> Image {
	return Image{w = w, h = h, pix = make([]u8, w * h * 4, allocator)}
}

image_destroy :: proc(img: ^Image, allocator := context.allocator) {
	delete(img.pix, allocator)
	img^ = {}
}

// ---------------------------------------------------------------------------
// Parallel row helper
// ---------------------------------------------------------------------------

@(private)
Row_Job :: struct {
	next:  int, // atomically incremented row-chunk cursor
	rows:  int,
	chunk: int,
	data:  rawptr,
	fn:    proc(data: rawptr, y0, y1: int),
}

@(private)
row_worker :: proc(job: ^Row_Job) {
	for {
		y0 := sync.atomic_add(&job.next, job.chunk)
		if y0 >= job.rows do return
		job.fn(job.data, y0, min(y0 + job.chunk, job.rows))
	}
}

// Runs fn over [0, rows) split into chunks across all CPU cores.
parallel_rows :: proc(rows: int, data: rawptr, fn: proc(data: rawptr, y0, y1: int)) {
	if rows <= 0 do return
	workers := clamp(os.get_processor_core_count(), 1, 64)
	job := Row_Job{rows = rows, chunk = max(1, min(32, rows / (workers * 4))), data = data, fn = fn}
	if workers == 1 || rows < 2 {
		fn(data, 0, rows)
		return
	}
	threads := make([]^thread.Thread, workers - 1, context.temp_allocator)
	for &t in threads {
		t = thread.create_and_start_with_poly_data(&job, row_worker) // nil context: workers do not allocate
	}
	row_worker(&job)
	for t in threads {
		thread.join(t)
		thread.destroy(t)
	}
}

// ---------------------------------------------------------------------------
// Geometry
// ---------------------------------------------------------------------------

// Projective transform: maps (x, y) -> (u, v) = ((a x + b y + c) / (g x + h y + 1), (d x + e y + f) / (...)).
Homography :: [9]f64

homography_apply :: #force_inline proc(m: Homography, p: Vec2) -> Vec2 {
	w := m[6] * p.x + m[7] * p.y + m[8]
	return {(m[0] * p.x + m[1] * p.y + m[2]) / w, (m[3] * p.x + m[4] * p.y + m[5]) / w}
}

// Solves the homography mapping each `from[i]` onto `to[i]`. Returns ok=false
// for degenerate input (three collinear points, repeated points).
homography_from_points :: proc(from, to: [4]Vec2) -> (m: Homography, ok: bool) {
	a: [8][9]f64 // augmented 8x8 system
	for i in 0 ..< 4 {
		x, y := from[i].x, from[i].y
		u, v := to[i].x, to[i].y
		a[i * 2] = {x, y, 1, 0, 0, 0, -u * x, -u * y, u}
		a[i * 2 + 1] = {0, 0, 0, x, y, 1, -v * x, -v * y, v}
	}
	for col in 0 ..< 8 {
		pivot := col
		for r in col + 1 ..< 8 {
			if abs(a[r][col]) > abs(a[pivot][col]) do pivot = r
		}
		if abs(a[pivot][col]) < 1e-12 do return {}, false
		a[col], a[pivot] = a[pivot], a[col]
		for r in 0 ..< 8 {
			if r == col do continue
			f := a[r][col] / a[col][col]
			if f == 0 do continue
			for c in col ..< 9 do a[r][c] -= f * a[col][c]
		}
	}
	for i in 0 ..< 8 do m[i] = a[i][8] / a[i][i]
	m[8] = 1
	return m, true
}

// Orders four points clockwise (in y-down image space) starting with the
// top-left-most point. Input order does not matter.
order_corners :: proc(pts: [4]Vec2) -> [4]Vec2 {
	c := (pts[0] + pts[1] + pts[2] + pts[3]) / 4
	sorted := pts
	angle :: proc(p, c: Vec2) -> f64 {return math.atan2(p.y - c.y, p.x - c.x)}
	// Insertion sort by angle; atan2 increases clockwise on screen when y points down.
	for i in 1 ..< 4 {
		for j := i; j > 0 && angle(sorted[j], c) < angle(sorted[j - 1], c); j -= 1 {
			sorted[j], sorted[j - 1] = sorted[j - 1], sorted[j]
		}
	}
	start := 0
	for i in 1 ..< 4 {
		if sorted[i].x + sorted[i].y < sorted[start].x + sorted[start].y do start = i
	}
	out: [4]Vec2
	for i in 0 ..< 4 do out[i] = sorted[(start + i) % 4]
	return out
}

// True when the quad is convex, non-degenerate and consistently wound.
quad_is_valid :: proc(q: [4]Vec2) -> bool {
	sign := 0.0
	for i in 0 ..< 4 {
		a, b, c := q[i], q[(i + 1) % 4], q[(i + 2) % 4]
		cr := (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
		if abs(cr) < 1e-6 do return false
		if sign == 0 do sign = cr
		else if (cr > 0) != (sign > 0) do return false
	}
	return true
}

// Natural pixel size of a quad: average lengths of opposite edges.
// Corners are ordered TL, TR, BR, BL.
quad_native_size :: proc(q: [4]Vec2) -> (w, h: int) {
	dist :: proc(a, b: Vec2) -> f64 {return math.sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y))}
	w = max(1, int(math.round((dist(q[0], q[1]) + dist(q[3], q[2])) / 2)))
	h = max(1, int(math.round((dist(q[0], q[3]) + dist(q[1], q[2])) / 2)))
	return
}
