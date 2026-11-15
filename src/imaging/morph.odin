package imaging

// Binary mask operations used by card detection, following OpenCV's
// conventions: foreground is 255, background 0; morphology ignores pixels
// outside the image (erode treats them as foreground, dilate as background).

import "core:math"

Mask :: struct {
	w, h: int,
	pix:  []u8,
}

mask_make :: proc(w, h: int, allocator := context.allocator) -> Mask {
	return Mask{w, h, make([]u8, w * h, allocator)}
}

mask_clone :: proc(m: Mask, allocator := context.allocator) -> Mask {
	c := mask_make(m.w, m.h, allocator)
	copy(c.pix, m.pix)
	return c
}

mask_destroy :: proc(m: ^Mask) {
	delete(m.pix)
	m^ = {}
}

// One row of a structuring element: offsets dy and x0..x1 (inclusive) from the anchor.
Span :: struct {
	dy, x0, x1: int,
}

Kernel :: struct {
	rect:   bool,
	kw, kh: int, // rect size (width, height), anchor at the centre
	spans:  []Span, // non-rect shapes
}

rect_kernel :: proc(kw, kh: int) -> Kernel {
	return Kernel{rect = true, kw = kw, kh = kh}
}

// OpenCV getStructuringElement(MORPH_ELLIPSE, (k, k)).
ellipse_kernel :: proc(k: int, allocator := context.allocator) -> Kernel {
	r := k / 2
	c := k / 2
	inv_r2 := 1.0 / f64(r * r) if r != 0 else 0
	spans := make([dynamic]Span, allocator)
	for i in 0 ..< k {
		dy := i - r
		if abs(dy) > r do continue
		dx := cv_round_half_even(f64(c) * math.sqrt(f64(r * r - dy * dy) * inv_r2))
		j1 := max(c - dx, 0)
		j2 := min(c + dx + 1, k)
		if j2 > j1 do append(&spans, Span{dy, j1 - c, j2 - 1 - c})
	}
	return Kernel{spans = spans[:], kw = k, kh = k}
}

kernel_destroy :: proc(k: ^Kernel) {
	delete(k.spans)
}

@(private = "file")
Morph_Ctx :: struct {
	src, dst: Mask,
	prefix:   []i32, // per-row prefix counts of foreground, (w+1) per row
	spans:    []Span,
	erode:    bool,
	win:      int, // 1-D window for rect passes
	vertical: bool,
}

// 1-D rect pass (horizontal or vertical) using running counts.
@(private = "file")
morph_1d :: proc(src: Mask, win: int, vertical, erode: bool, allocator := context.allocator) -> Mask {
	ctx := Morph_Ctx{src = src, dst = mask_make(src.w, src.h, allocator), win = win, vertical = vertical, erode = erode}
	lines := src.w if vertical else src.h
	parallel_rows(lines, &ctx, proc(data: rawptr, l0, l1: int) {
		c := (^Morph_Ctx)(data)
		w, h := c.src.w, c.src.h
		n := h if c.vertical else w
		stride := w if c.vertical else 1
		a := c.win / 2
		pre := make([]i32, n + 1)
		defer delete(pre)
		for line in l0 ..< l1 {
			base := line if c.vertical else line * w
			pre[0] = 0
			for i in 0 ..< n do pre[i + 1] = pre[i] + (1 if c.src.pix[base + i * stride] != 0 else 0)
			for i in 0 ..< n {
				lo := max(i - a, 0)
				hi := min(i + c.win - 1 - a, n - 1)
				cnt := pre[hi + 1] - pre[lo]
				on := cnt == i32(hi - lo + 1) if c.erode else cnt > 0
				c.dst.pix[base + i * stride] = 255 if on else 0
			}
		}
	})
	return ctx.dst
}

@(private = "file")
morph_spans :: proc(src: Mask, spans: []Span, erode: bool, allocator := context.allocator) -> Mask {
	w, h := src.w, src.h
	prefix := make([]i32, (w + 1) * h)
	defer delete(prefix)
	for y in 0 ..< h {
		row := prefix[y * (w + 1):]
		for x in 0 ..< w do row[x + 1] = row[x] + (1 if src.pix[y * w + x] != 0 else 0)
	}
	ctx := Morph_Ctx{src = src, dst = mask_make(w, h, allocator), prefix = prefix, spans = spans, erode = erode}
	parallel_rows(h, &ctx, proc(data: rawptr, y0, y1: int) {
		c := (^Morph_Ctx)(data)
		w, h := c.src.w, c.src.h
		for y in y0 ..< y1 {
			for x in 0 ..< w {
				on := c.erode
				for s in c.spans {
					yy := y + s.dy
					if yy < 0 || yy >= h do continue
					xa, xb := max(x + s.x0, 0), min(x + s.x1, w - 1)
					if xa > xb do continue
					row := c.prefix[yy * (w + 1):]
					cnt := row[xb + 1] - row[xa]
					if c.erode {
						if cnt != i32(xb - xa + 1) {on = false; break}
					} else if cnt > 0 {on = true; break}
				}
				c.dst.pix[y * w + x] = 255 if on else 0
			}
		}
	})
	return ctx.dst
}

morph :: proc(src: Mask, k: Kernel, erode: bool, allocator := context.allocator) -> Mask {
	if !k.rect do return morph_spans(src, k.spans, erode, allocator)
	tmp := morph_1d(src, k.kw, false, erode)
	defer mask_destroy(&tmp)
	return morph_1d(tmp, k.kh, true, erode, allocator)
}

erode :: proc(src: Mask, k: Kernel, allocator := context.allocator) -> Mask {
	return morph(src, k, true, allocator)
}

dilate :: proc(src: Mask, k: Kernel, iterations := 1, allocator := context.allocator) -> Mask {
	out := morph(src, k, false, allocator)
	for _ in 1 ..< iterations {
		next := morph(out, k, false, allocator)
		mask_destroy(&out)
		out = next
	}
	return out
}

morph_open :: proc(src: Mask, k: Kernel, allocator := context.allocator) -> Mask {
	e := erode(src, k)
	defer mask_destroy(&e)
	return dilate(e, k, 1, allocator)
}

// MORPH_CLOSE with `iterations`: dilate that many times, then erode as many.
morph_close :: proc(src: Mask, k: Kernel, iterations := 1, allocator := context.allocator) -> Mask {
	out := dilate(src, k, iterations)
	for i in 0 ..< iterations {
		next := erode(out, k, allocator if i == iterations - 1 else context.allocator)
		mask_destroy(&out)
		out = next
	}
	return out
}

// ---------------------------------------------------------------------------
// Grayscale
// ---------------------------------------------------------------------------

Gray :: struct {
	w, h: int,
	pix:  []u8,
}

// OpenCV COLOR_BGR2GRAY fixed point (0.299 R + 0.587 G + 0.114 B).
gray_from_rgba :: proc(src: Image, allocator := context.allocator) -> Gray {
	g := Gray{src.w, src.h, make([]u8, src.w * src.h, allocator)}
	for i in 0 ..< src.w * src.h {
		p := src.pix[i * 4:]
		g.pix[i] = u8((u32(p[0]) * 4899 + u32(p[1]) * 9617 + u32(p[2]) * 1868 + (1 << 13)) >> 14)
	}
	return g
}

// ---------------------------------------------------------------------------
// Canny (OpenCV: 3x3 Sobel with replicated border, L1 magnitude)
// ---------------------------------------------------------------------------

canny :: proc(g: Gray, low_thresh, high_thresh: int, allocator := context.allocator) -> Mask {
	w, h := g.w, g.h
	px :: #force_inline proc(g: Gray, x, y: int) -> i32 {
		return i32(g.pix[clamp(y, 0, g.h - 1) * g.w + clamp(x, 0, g.w - 1)])
	}
	dxs := make([]i32, w * h)
	dys := make([]i32, w * h)
	// Magnitude with a zero frame so neighbours outside the image never win.
	mw := w + 2
	mag := make([]i32, mw * (h + 2))
	defer {delete(dxs); delete(dys); delete(mag)}
	for y in 0 ..< h {
		for x in 0 ..< w {
			dx := (px(g, x + 1, y - 1) + 2 * px(g, x + 1, y) + px(g, x + 1, y + 1)) - (px(g, x - 1, y - 1) + 2 * px(g, x - 1, y) + px(g, x - 1, y + 1))
			dy := (px(g, x - 1, y + 1) + 2 * px(g, x, y + 1) + px(g, x + 1, y + 1)) - (px(g, x - 1, y - 1) + 2 * px(g, x, y - 1) + px(g, x + 1, y - 1))
			dxs[y * w + x] = dx
			dys[y * w + x] = dy
			mag[(y + 1) * mw + x + 1] = abs(dx) + abs(dy)
		}
	}
	// 0 = candidate, 1 = not an edge, 2 = edge.
	state := make([]u8, w * h)
	defer delete(state)
	stack := make([dynamic]int)
	defer delete(stack)
	CANNY_SHIFT :: 15
	TG22 :: i32(13573) // round(tan(22.5°) * 2^15), as OpenCV
	low, high := i32(low_thresh), i32(high_thresh)
	for y in 0 ..< h {
		for x in 0 ..< w {
			mi := (y + 1) * mw + x + 1
			m := mag[mi]
			state[y * w + x] = 1
			if m <= low do continue
			dx, dy := dxs[y * w + x], dys[y * w + x]
			xs := abs(dx)
			ys := abs(dy) << CANNY_SHIFT
			tg22x := xs * TG22
			keep: bool
			if ys < tg22x {
				keep = m > mag[mi - 1] && m >= mag[mi + 1]
			} else {
				tg67x := tg22x + (xs << (CANNY_SHIFT + 1))
				if ys > tg67x {
					keep = m > mag[mi - mw] && m >= mag[mi + mw]
				} else {
					s := -1 if (dx ~ dy) < 0 else 1
					keep = m > mag[mi - mw - s] && m > mag[mi + mw + s]
				}
			}
			if !keep do continue
			if m > high {
				state[y * w + x] = 2
				append(&stack, y * w + x)
			} else {
				state[y * w + x] = 0
			}
		}
	}
	for len(stack) > 0 {
		i := pop(&stack)
		x, y := i % w, i / w
		for oy in -1 ..= 1 {
			for ox in -1 ..= 1 {
				nx, ny := x + ox, y + oy
				if nx < 0 || ny < 0 || nx >= w || ny >= h do continue
				if state[ny * w + nx] == 0 {
					state[ny * w + nx] = 2
					append(&stack, ny * w + nx)
				}
			}
		}
	}
	out := mask_make(w, h, allocator)
	for i in 0 ..< w * h do out.pix[i] = 255 if state[i] == 2 else 0
	return out
}
