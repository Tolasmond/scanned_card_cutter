package imaging

// Contours and planar geometry for card detection: the subset of OpenCV that
// candidate detection uses (findContours RETR_EXTERNAL + CHAIN_APPROX_SIMPLE,
// contourArea, arcLength, boundingRect, approxPolyDP, minAreaRect,
// intersectConvexConvex, fitLine with DIST_HUBER).

import "core:math"
import "core:slice"

// Outer contours of 8-connected foreground components that are not enclosed
// by another component, as boundary pixel chains with straight runs reduced
// to their end points. Pixels beyond the image count as background.
find_external_contours :: proc(m: Mask, allocator := context.allocator) -> [][]Vec2 {
	w, h := m.w + 2, m.h + 2 // one-pixel background frame
	fg :: #force_inline proc(m: Mask, x, y: int) -> bool {
		// x, y in framed coordinates
		if x <= 0 || y <= 0 || x > m.w || y > m.h do return false
		return m.pix[(y - 1) * m.w + x - 1] != 0
	}
	// Background reachable from the frame (4-connected): everything outside every component.
	outside := make([]bool, w * h)
	defer delete(outside)
	stack := make([dynamic]int)
	defer delete(stack)
	outside[0] = true
	append(&stack, 0)
	for len(stack) > 0 {
		i := pop(&stack)
		x, y := i % w, i / w
		for d in ([4][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) {
			nx, ny := x + d.x, y + d.y
			if nx < 0 || ny < 0 || nx >= w || ny >= h do continue
			ni := ny * w + nx
			if outside[ni] || fg(m, nx, ny) do continue
			outside[ni] = true
			append(&stack, ni)
		}
	}

	visited := make([]bool, w * h)
	defer delete(visited)
	contours := make([dynamic][]Vec2, allocator)
	for y in 1 ..= m.h {
		for x in 1 ..= m.w {
			if visited[y * w + x] || !fg(m, x, y) do continue
			// Flood the component; it is external if it borders the outside region.
			external := false
			append(&stack, y * w + x)
			visited[y * w + x] = true
			for len(stack) > 0 {
				i := pop(&stack)
				cx, cy := i % w, i / w
				for oy in -1 ..= 1 {
					for ox in -1 ..= 1 {
						if ox == 0 && oy == 0 do continue
						nx, ny := cx + ox, cy + oy
						ni := ny * w + nx
						if fg(m, nx, ny) {
							if !visited[ni] {
								visited[ni] = true
								append(&stack, ni)
							}
						} else if (ox == 0 || oy == 0) && outside[ni] {
							external = true
						}
					}
				}
			}
			// (x, y) is the component's first pixel in raster order: its top-left.
			if external do append(&contours, trace_outer(m, x, y, allocator))
		}
	}
	return contours[:]
}

// Moore-neighbour tracing (clockwise on screen) from a component's top-left
// pixel, returning image coordinates with collinear runs compressed.
@(private = "file")
trace_outer :: proc(m: Mask, sx, sy: int, allocator := context.allocator) -> []Vec2 {
	DIRS :: [8][2]int{{1, 0}, {1, 1}, {0, 1}, {-1, 1}, {-1, 0}, {-1, -1}, {0, -1}, {1, -1}} // E SE S SW W NW N NE
	fg :: #force_inline proc(m: Mask, x, y: int) -> bool {
		if x <= 0 || y <= 0 || x > m.w || y > m.h do return false
		return m.pix[(y - 1) * m.w + x - 1] != 0
	}
	dir_of :: #force_inline proc(dx, dy: int) -> int {
		D := DIRS
		for d, i in D do if d.x == dx && d.y == dy do return i
		return 0
	}
	pts := make([dynamic][2]int, context.temp_allocator)
	cx, cy := sx, sy
	back := 4 // the pixel to the west is background (raster order)
	append(&pts, [2]int{cx, cy})
	D := DIRS
	first_next: [2]int
	have_first := false
	// Jacob's stopping criterion: stop when leaving the start pixel towards the
	// same pixel as the very first step.
	for _ in 0 ..< m.w * m.h * 4 + 16 {
		found := false
		nx, ny, nb := 0, 0, 0
		for k in 1 ..= 8 {
			d := (back + k) % 8
			tx, ty := cx + D[d].x, cy + D[d].y
			if fg(m, tx, ty) {
				// The previously examined neighbour is background: the next backtrack.
				pd := (back + k - 1) % 8
				nx, ny = tx, ty
				nb = dir_of(cx + D[pd].x - tx, cy + D[pd].y - ty)
				found = true
				break
			}
		}
		if !found do break // isolated pixel
		if have_first && cx == sx && cy == sy && nx == first_next.x && ny == first_next.y do break
		if !have_first {first_next = {nx, ny}; have_first = true}
		cx, cy, back = nx, ny, nb
		append(&pts, [2]int{cx, cy})
	}
	if len(pts) > 1 && pts[len(pts) - 1] == pts[0] do pop(&pts)

	// CHAIN_APPROX_SIMPLE: keep only points where the step direction changes.
	n := len(pts)
	out := make([dynamic]Vec2, allocator)
	for i in 0 ..< n {
		if n < 3 {
			append(&out, Vec2{f64(pts[i].x - 1), f64(pts[i].y - 1)})
			continue
		}
		prev, next := pts[(i + n - 1) % n], pts[(i + 1) % n]
		d1 := pts[i] - prev
		d2 := next - pts[i]
		if i == 0 || d1 != d2 do append(&out, Vec2{f64(pts[i].x - 1), f64(pts[i].y - 1)})
	}
	return out[:]
}

// Absolute polygon area (shoelace).
polygon_area :: proc(p: []Vec2) -> f64 {
	a := 0.0
	n := len(p)
	for i in 0 ..< n {
		j := (i + 1) % n
		a += p[i].x * p[j].y - p[j].x * p[i].y
	}
	return abs(a) / 2
}

polygon_signed_area :: proc(p: []Vec2) -> f64 {
	a := 0.0
	n := len(p)
	for i in 0 ..< n {
		j := (i + 1) % n
		a += p[i].x * p[j].y - p[j].x * p[i].y
	}
	return a / 2
}

arc_length_closed :: proc(p: []Vec2) -> f64 {
	l := 0.0
	n := len(p)
	for i in 0 ..< n do l += vec_len(p[(i + 1) % n] - p[i])
	return l
}

vec_len :: #force_inline proc(v: Vec2) -> f64 {
	return math.sqrt(v.x * v.x + v.y * v.y)
}

// OpenCV boundingRect of integer points: x, y, width, height (inclusive extents).
bounding_rect :: proc(p: []Vec2) -> [4]f64 {
	lo, hi := p[0], p[0]
	for q in p {
		lo = {min(lo.x, q.x), min(lo.y, q.y)}
		hi = {max(hi.x, q.x), max(hi.y, q.y)}
	}
	return {lo.x, lo.y, hi.x - lo.x + 1, hi.y - lo.y + 1}
}

// Douglas–Peucker for a closed curve, following OpenCV's approxPolyDP: the
// initial split is found by three rounds of "farthest point from here".
approx_poly_dp_closed :: proc(src: []Vec2, epsilon: f64, allocator := context.allocator) -> []Vec2 {
	n := len(src)
	out := make([dynamic]Vec2, allocator)
	if n <= 2 {
		for p in src do append(&out, p)
		return out[:]
	}
	eps2 := epsilon * epsilon
	start := 0
	far := 0
	le_eps := false
	for _ in 0 ..< 3 {
		start = (start + far) % n
		max_d := 0.0
		far = 0
		for j in 1 ..< n {
			d := src[(start + j) % n] - src[start]
			dd := d.x * d.x + d.y * d.y
			if dd > max_d {max_d = dd; far = j}
		}
		le_eps = max_d <= eps2
	}
	if le_eps {
		append(&out, src[start])
		return out[:]
	}
	Slice :: struct {
		a, b: int,
	}
	stack := make([dynamic]Slice, context.temp_allocator)
	split := (start + far) % n
	append(&stack, Slice{split, start}) // right part
	append(&stack, Slice{start, split}) // left part, processed first
	for len(stack) > 0 {
		s := pop(&stack)
		a, b := src[s.a], src[s.b]
		if (s.a + 1) % n == s.b || s.a == s.b {
			append(&out, a)
			continue
		}
		d := b - a
		max_d := 0.0
		idx := -1
		for i := (s.a + 1) % n; i != s.b; i = (i + 1) % n {
			p := src[i]
			dist := abs((p.y - a.y) * d.x - (p.x - a.x) * d.y)
			if dist > max_d {max_d = dist; idx = i}
		}
		if idx < 0 || max_d * max_d <= eps2 * (d.x * d.x + d.y * d.y) {
			append(&out, a)
		} else {
			append(&stack, Slice{idx, s.b})
			append(&stack, Slice{s.a, idx})
		}
	}
	// Final clean-up: drop points on (almost) straight lines, as OpenCV does.
	for changed := true; changed && len(out) > 2; {
		changed = false
		m := len(out)
		for i in 0 ..< m {
			p0, p, p1 := out[(i + m - 1) % m], out[i], out[(i + 1) % m]
			d := p1 - p0
			dist := abs((p.x - p0.x) * d.y - (p.y - p0.y) * d.x)
			inner := (p.x - p0.x) * (p1.x - p.x) + (p.y - p0.y) * (p1.y - p.y)
			if dist * dist <= 0.5 * eps2 * (d.x * d.x + d.y * d.y) && d.x != 0 && d.y != 0 && inner >= 0 {
				ordered_remove(&out, i)
				changed = true
				break
			}
		}
	}
	return out[:]
}

// Convex hull (Andrew's monotone chain), counter-clockwise in math orientation.
convex_hull :: proc(points: []Vec2, allocator := context.allocator) -> []Vec2 {
	p := slice.clone(points, context.temp_allocator)
	slice.sort_by(p, proc(a, b: Vec2) -> bool {return a.x < b.x || (a.x == b.x && a.y < b.y)})
	cross :: #force_inline proc(o, a, b: Vec2) -> f64 {return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)}
	hull := make([dynamic]Vec2, allocator)
	if len(p) < 3 {
		for q in p do append(&hull, q)
		return hull[:]
	}
	for q in p {
		for len(hull) >= 2 && cross(hull[len(hull) - 2], hull[len(hull) - 1], q) <= 0 do pop(&hull)
		append(&hull, q)
	}
	lower := len(hull) + 1
	#reverse for q in p[:len(p) - 1] {
		for len(hull) >= lower && cross(hull[len(hull) - 2], hull[len(hull) - 1], q) <= 0 do pop(&hull)
		append(&hull, q)
	}
	pop(&hull)
	return hull[:]
}

// Minimum-area enclosing rectangle (rotating calipers over the hull edges).
// Returns its four corners and its area.
min_area_rect :: proc(points: []Vec2) -> (box: [4]Vec2, area: f64) {
	hull := convex_hull(points, context.temp_allocator)
	if len(hull) == 0 do return {}, 0
	if len(hull) == 1 do return {hull[0], hull[0], hull[0], hull[0]}, 0
	best := math.INF_F64
	n := len(hull)
	for i in 0 ..< n {
		e := hull[(i + 1) % n] - hull[i]
		l := vec_len(e)
		if l == 0 do continue
		u := e / l
		v := Vec2{-u.y, u.x}
		umin, umax, vmin, vmax := math.INF_F64, -math.INF_F64, math.INF_F64, -math.INF_F64
		for q in hull {
			pu := q.x * u.x + q.y * u.y
			pv := q.x * v.x + q.y * v.y
			umin, umax = min(umin, pu), max(umax, pu)
			vmin, vmax = min(vmin, pv), max(vmax, pv)
		}
		a := (umax - umin) * (vmax - vmin)
		if a < best {
			best = a
			box = {u * umin + v * vmin, u * umax + v * vmin, u * umax + v * vmax, u * umin + v * vmax}
		}
	}
	return box, best
}

polygon_is_convex :: proc(p: []Vec2) -> bool {
	n := len(p)
	if n < 3 do return false
	sign := 0.0
	for i in 0 ..< n {
		a, b, c := p[i], p[(i + 1) % n], p[(i + 2) % n]
		cr := (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
		if cr == 0 do continue
		if sign == 0 do sign = cr
		else if (cr > 0) != (sign > 0) do return false
	}
	return true
}

// Area of the intersection of two convex polygons (Sutherland–Hodgman clipping).
convex_intersection_area :: proc(subject, clip: []Vec2) -> f64 {
	poly := make([dynamic]Vec2, context.temp_allocator)
	for p in subject do append(&poly, p)
	orient := 1.0 if polygon_signed_area(clip) >= 0 else -1.0
	n := len(clip)
	for i in 0 ..< n {
		if len(poly) == 0 do break
		a, b := clip[i], clip[(i + 1) % n]
		inside :: #force_inline proc(a, b, p: Vec2, orient: f64) -> bool {
			return orient * ((b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)) >= 0
		}
		input := poly
		poly = make([dynamic]Vec2, context.temp_allocator)
		m := len(input)
		for j in 0 ..< m {
			cur, prev := input[j], input[(j + m - 1) % m]
			ci, pi := inside(a, b, cur, orient), inside(a, b, prev, orient)
			if ci != pi {
				// Intersection of segment prev-cur with line a-b.
				d1 := cur - prev
				d2 := b - a
				den := d1.x * d2.y - d1.y * d2.x
				if den != 0 {
					t := ((a.x - prev.x) * d2.y - (a.y - prev.y) * d2.x) / den
					append(&poly, prev + d1 * t)
				}
			}
			if ci do append(&poly, cur)
		}
	}
	if len(poly) < 3 do return 0
	return polygon_area(poly[:])
}

// fitLine with DIST_HUBER (C = 1.345): iteratively reweighted least squares.
// Returns a point on the line and its unit direction.
fit_line_huber :: proc(points: []Vec2) -> (point, dir: Vec2) {
	n := len(points)
	w := make([]f64, n, context.temp_allocator)
	for &v in w do v = 1
	fit :: proc(points: []Vec2, w: []f64) -> (p, d: Vec2) {
		sw, sx, sy := 0.0, 0.0, 0.0
		for q, i in points {sw += w[i]; sx += w[i] * q.x; sy += w[i] * q.y}
		mx, my := sx / sw, sy / sw
		dxx, dyy, dxy := 0.0, 0.0, 0.0
		for q, i in points {
			ex, ey := q.x - mx, q.y - my
			dxx += w[i] * ex * ex
			dyy += w[i] * ey * ey
			dxy += w[i] * ex * ey
		}
		t := math.atan2(2 * dxy, dxx - dyy) / 2
		return {mx, my}, {math.cos(t), math.sin(t)}
	}
	C :: 1.345
	point, dir = fit(points, w)
	for _ in 0 ..< 30 {
		for q, i in points {
			r := abs((q.x - point.x) * dir.y - (q.y - point.y) * dir.x)
			w[i] = 1 if r < C else C / r
		}
		np, nd := fit(points, w)
		done := abs(np.x - point.x) < 0.01 && abs(np.y - point.y) < 0.01 && abs(nd.x * dir.x + nd.y * dir.y) > 1 - 1e-6
		point, dir = np, nd
		if done do break
	}
	return
}
