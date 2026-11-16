package imaging

import "core:math"

// Output settings for one extracted card.
Extract_Settings :: struct {
	width, height: int, // final PNG size in pixels
	corner_radius: int, // rounded-corner radius in output pixels (0 = square)
	edge_trim:     int, // pixels shaved from each edge of the straightened card, in source scale
}

// Straightens the quad `corners` (TL, TR, BR, BL in source pixel space, where
// pixel (i, j) covers [i, i+1) x [j, j+1)) and returns a `settings.width` x
// `settings.height` RGBA image with transparent rounded corners.
//
// Pipeline:
//   1. perspective warp at the quad's natural size (bicubic, ~1:1 scale)
//   2. shave `edge_trim` pixels from each side
//   3. Lanczos-3 resize to the target size
//   4. anti-aliased rounded-rectangle alpha mask
extract_card :: proc(src: Image, corners: [4]Vec2, settings: Extract_Settings, allocator := context.allocator) -> (out: Image, ok: bool) {
	if settings.width <= 0 || settings.height <= 0 || !quad_is_valid(corners) do return {}, false

	nw, nh := quad_native_size(corners)
	trim := max(settings.edge_trim, 0)
	if trim * 2 >= nw || trim * 2 >= nh do return {}, false

	rect := [4]Vec2{{0, 0}, {f64(nw), 0}, {f64(nw), f64(nh)}, {0, f64(nh)}}
	m := homography_from_points(rect, corners) or_return

	straight := warp_perspective(src, m, nw - trim * 2, nh - trim * 2, f64(trim), context.temp_allocator)
	out = resize_lanczos3(straight, settings.width, settings.height, allocator)
	apply_rounded_mask(&out, f64(settings.corner_radius))
	return out, true
}

// For each output pixel (x, y), samples `src` at m((x + 0.5 + offset, y + 0.5 + offset)).
warp_perspective :: proc(src: Image, m: Homography, w, h: int, offset: f64, allocator := context.allocator) -> Image {
	Ctx :: struct {
		src:    Image,
		dst:    Image,
		m:      Homography,
		offset: f64,
	}
	ctx := Ctx{src, image_make(w, h, allocator), m, offset}
	parallel_rows(h, &ctx, proc(data: rawptr, y0, y1: int) {
		ctx := (^Ctx)(data)
		for y in y0 ..< y1 {
			row := ctx.dst.pix[y * ctx.dst.w * 4:]
			for x in 0 ..< ctx.dst.w {
				p := homography_apply(ctx.m, {f64(x) + 0.5 + ctx.offset, f64(y) + 0.5 + ctx.offset})
				px := sample_bicubic(ctx.src, f32(p.x - 0.5), f32(p.y - 0.5))
				for c in 0 ..< 4 do row[x * 4 + c] = px[c]
			}
		}
	})
	return ctx.dst
}

@(private)
cubic_weights :: #force_inline proc(t: f32) -> [4]f32 {
	// Catmull-Rom (Keys, a = -0.5).
	t2 := t * t
	t3 := t2 * t
	return {
		-0.5 * t3 + t2 - 0.5 * t,
		1.5 * t3 - 2.5 * t2 + 1,
		-1.5 * t3 + 2 * t2 + 0.5 * t,
		0.5 * t3 - 0.5 * t2,
	}
}

// Bicubic sample at pixel-center coordinates (0,0 = center of the first pixel), clamped to the edge.
sample_bicubic :: proc(img: Image, fx, fy: f32) -> [4]u8 {
	x0 := int(math.floor(fx))
	y0 := int(math.floor(fy))
	wx := cubic_weights(fx - f32(x0))
	wy := cubic_weights(fy - f32(y0))
	acc: [4]f32
	for j in 0 ..< 4 {
		yy := clamp(y0 - 1 + j, 0, img.h - 1)
		row := img.pix[yy * img.w * 4:]
		racc: [4]f32
		for i in 0 ..< 4 {
			xx := clamp(x0 - 1 + i, 0, img.w - 1)
			p := row[xx * 4:]
			for c in 0 ..< 4 do racc[c] += wx[i] * f32(p[c])
		}
		for c in 0 ..< 4 do acc[c] += wy[j] * racc[c]
	}
	out: [4]u8
	for c in 0 ..< 4 do out[c] = u8(clamp(acc[c] + 0.5, 0, 255))
	return out
}

// ---------------------------------------------------------------------------
// Lanczos-3 resize (separable)
// ---------------------------------------------------------------------------

@(private)
Filter_Taps :: struct {
	first:   []int, // first source index per output index
	count:   []int, // number of taps per output index
	weights: []f32, // `stride` weights per output index
	stride:  int,
}

@(private)
lanczos3 :: proc(v: f64) -> f64 {
	x := abs(v)
	if x < 1e-9 do return 1
	if x >= 3 do return 0
	px := math.PI * x
	return 3 * math.sin(px) * math.sin(px / 3) / (px * px)
}

@(private)
make_taps :: proc(src_len, dst_len: int, allocator := context.allocator) -> Filter_Taps {
	scale := f64(src_len) / f64(dst_len)
	fscale := max(scale, 1)
	support := 3 * fscale
	stride := int(math.ceil(support)) * 2 + 1
	t := Filter_Taps {
		first   = make([]int, dst_len, allocator),
		count   = make([]int, dst_len, allocator),
		weights = make([]f32, dst_len * stride, allocator),
		stride  = stride,
	}
	for i in 0 ..< dst_len {
		center := (f64(i) + 0.5) * scale - 0.5
		lo := max(int(math.floor(center - support)) + 1, 0)
		hi := min(int(math.floor(center + support)), src_len - 1)
		n := min(hi - lo + 1, stride)
		sum := 0.0
		w := t.weights[i * stride:][:stride]
		for k in 0 ..< n {
			v := lanczos3((f64(lo + k) - center) / fscale)
			w[k] = f32(v)
			sum += v
		}
		if sum != 0 do for k in 0 ..< n do w[k] = f32(f64(w[k]) / sum)
		t.first[i] = lo
		t.count[i] = n
	}
	return t
}

resize_lanczos3 :: proc(src: Image, dw, dh: int, allocator := context.allocator) -> Image {
	Ctx :: struct {
		src:    Image,
		dst:    Image,
		tmp:    []f32, // dw x src.h x 4, horizontally filtered
		tx, ty: Filter_Taps,
	}
	ctx := Ctx {
		src = src,
		dst = image_make(dw, dh, allocator),
		tmp = make([]f32, dw * src.h * 4, context.temp_allocator),
		tx  = make_taps(src.w, dw, context.temp_allocator),
		ty  = make_taps(src.h, dh, context.temp_allocator),
	}
	parallel_rows(src.h, &ctx, proc(data: rawptr, y0, y1: int) {
		ctx := (^Ctx)(data)
		dw := ctx.dst.w
		for y in y0 ..< y1 {
			srow := ctx.src.pix[y * ctx.src.w * 4:]
			trow := ctx.tmp[y * dw * 4:]
			for x in 0 ..< dw {
				w := ctx.tx.weights[x * ctx.tx.stride:]
				acc: [4]f32
				for k in 0 ..< ctx.tx.count[x] {
					p := srow[(ctx.tx.first[x] + k) * 4:]
					for c in 0 ..< 4 do acc[c] += w[k] * f32(p[c])
				}
				for c in 0 ..< 4 do trow[x * 4 + c] = acc[c]
			}
		}
	})
	parallel_rows(dh, &ctx, proc(data: rawptr, y0, y1: int) {
		ctx := (^Ctx)(data)
		dw := ctx.dst.w
		for y in y0 ..< y1 {
			w := ctx.ty.weights[y * ctx.ty.stride:]
			first, count := ctx.ty.first[y], ctx.ty.count[y]
			drow := ctx.dst.pix[y * dw * 4:]
			for x in 0 ..< dw {
				acc: [4]f32
				for k in 0 ..< count {
					p := ctx.tmp[((first + k) * dw + x) * 4:]
					for c in 0 ..< 4 do acc[c] += w[k] * p[c]
				}
				for c in 0 ..< 4 do drow[x * 4 + c] = u8(clamp(acc[c] + 0.5, 0, 255))
			}
		}
	})
	return ctx.dst
}

// ---------------------------------------------------------------------------
// Rounded corners
// ---------------------------------------------------------------------------

// Multiplies alpha by the coverage of a rounded rectangle spanning the whole
// image. Coverage is computed from the signed distance at each pixel center, which
// gives a one-pixel anti-aliased edge.
apply_rounded_mask :: proc(img: ^Image, radius: f64) {
	r := clamp(radius, 0, f64(min(img.w, img.h)) / 2)
	if r <= 0 do return
	hw, hh := f64(img.w) / 2, f64(img.h) / 2
	ri := int(math.ceil(r)) + 1
	for y in 0 ..< img.h {
		// Only the corner bands can be partially covered.
		if y >= ri && y < img.h - ri do continue
		for x in 0 ..< img.w {
			if x >= ri && x < img.w - ri do continue
			qx := abs(f64(x) + 0.5 - hw) - (hw - r)
			qy := abs(f64(y) + 0.5 - hh) - (hh - r)
			d := math.sqrt(max(qx, 0) * max(qx, 0) + max(qy, 0) * max(qy, 0)) + min(max(qx, qy), 0) - r
			cov := clamp(0.5 - d, 0, 1)
			a := &img.pix[(y * img.w + x) * 4 + 3]
			a^ = u8(f64(a^) * cov + 0.5)
		}
	}
}
