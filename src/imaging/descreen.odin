package imaging

// Moiré (halftone) removal: a pure-Odin port of the original tool's "Soft"
// descreen (workers/descreen_image.py, OpenCV 4.12):
//
//   up    = resize(src, x1.5, INTER_CUBIC)
//   up    = medianBlur(up, 3)
//   up    = fastNlMeansDenoisingColored(up, h=7, hColor=7, template=7, search=21)
//   up    = bilateralFilter(up, d=7, sigmaColor=50, sigmaSpace=50)
//   down  = resize(up, original size, INTER_AREA)
//   out   = unsharp(down, sigma=0.9, amount=0.9)
//
// Each stage follows OpenCV's kernels, border modes and rounding closely
// enough to be compared against it stage by stage. Alpha is carried through
// from the source unchanged.

import "core:math"
import "core:sync"

Descreen_Progress :: struct {
	permille: int, // atomic, 0..1000
	cancel:   bool, // atomic; set from another thread to abandon the run
}

@(private = "file")
progress_set :: proc(p: ^Descreen_Progress, v: int) {
	if p != nil do sync.atomic_store(&p.permille, v)
}

@(private = "file")
cancelled :: proc(p: ^Descreen_Progress) -> bool {
	return p != nil && sync.atomic_load(&p.cancel)
}

// Runs the Soft descreen on `src`. Returns ok=false only when cancelled.
descreen_soft :: proc(src: Image, progress: ^Descreen_Progress = nil, allocator := context.allocator) -> (out: Image, ok: bool) {
	progress_set(progress, 0)
	uw := cv_round_half_even(f64(src.w) * 1.5)
	uh := cv_round_half_even(f64(src.h) * 1.5)

	up := resize_cubic_cv(src, uw, uh, 1.0 / 1.5, 1.0 / 1.5)
	progress_set(progress, 20)
	med := median3(up)
	image_destroy(&up)
	progress_set(progress, 40)
	if cancelled(progress) {image_destroy(&med); return {}, false}

	den, dok := nlmeans_colored(med, 7, 7, progress, 40, 860)
	if !dok {image_destroy(&med); return {}, false}
	image_destroy(&med)

	bil := bilateral_cv(den, 7, 50, 50)
	image_destroy(&den)
	progress_set(progress, 950)
	if cancelled(progress) {image_destroy(&bil); return {}, false}

	down := resize_area_cv(bil, src.w, src.h)
	image_destroy(&bil)
	out = unsharp_cv(down, 0.9, 0.9, allocator)
	image_destroy(&down)
	// Carry the source alpha through unchanged.
	for i := 3; i < len(out.pix); i += 4 do out.pix[i] = src.pix[i]
	progress_set(progress, 1000)
	return out, true
}

// cvRound on a double: round half to even.
cv_round_half_even :: proc(v: f64) -> int {
	r := math.round(v)
	if abs(v - math.trunc(v)) == 0.5 && int(r) % 2 != 0 do r -= math.sign(v)
	return int(r)
}

// BORDER_REFLECT_101: ... 2 1 | 0 1 2 ... n-2 n-1 | n-2 ...
reflect101 :: #force_inline proc(i, n: int) -> int {
	if n == 1 do return 0
	j := i
	for j < 0 || j >= n {
		if j < 0 do j = -j
		if j >= n do j = 2 * n - 2 - j
	}
	return j
}

// ---------------------------------------------------------------------------
// resize INTER_CUBIC (OpenCV resizeGeneric, 8-bit fixed point)
// ---------------------------------------------------------------------------

@(private = "file")
Cubic_Taps :: struct {
	first: []int, // src index of tap 0 (may be out of range; clamped when read)
	coef:  [][4]i32, // INTER_RESIZE_COEF_SCALE (2048) fixed point
}

@(private = "file")
cubic_taps :: proc(src_len, dst_len: int, scale: f64, allocator := context.allocator) -> Cubic_Taps {
	A :: f32(-0.75)
	t := Cubic_Taps{make([]int, dst_len, allocator), make([][4]i32, dst_len, allocator)}
	for d in 0 ..< dst_len {
		f := f32((f64(d) + 0.5) * scale - 0.5)
		s := int(math.floor(f))
		x := f - f32(s)
		c: [4]f32
		c[0] = ((A * (x + 1) - 5 * A) * (x + 1) + 8 * A) * (x + 1) - 4 * A
		c[1] = ((A + 2) * x - (A + 3)) * x * x + 1
		c[2] = ((A + 2) * (1 - x) - (A + 3)) * (1 - x) * (1 - x) + 1
		c[3] = 1 - c[0] - c[1] - c[2]
		for k in 0 ..< 4 do t.coef[d][k] = i32(cv_round_f32(c[k] * 2048))
		t.first[d] = s - 1
	}
	return t
}

resize_cubic_cv :: proc(src: Image, dw, dh: int, scale_x, scale_y: f64, allocator := context.allocator) -> Image {
	Ctx :: struct {
		src:    Image,
		dst:    Image,
		tmp:    []i32, // dw x src.h x 4, horizontal pass
		tx, ty: Cubic_Taps,
	}
	ctx := Ctx {
		src = src,
		dst = image_make(dw, dh, allocator),
		tmp = make([]i32, dw * src.h * 4),
		tx  = cubic_taps(src.w, dw, scale_x),
		ty  = cubic_taps(src.h, dh, scale_y),
	}
	defer {
		delete(ctx.tmp)
		delete(ctx.tx.first); delete(ctx.tx.coef)
		delete(ctx.ty.first); delete(ctx.ty.coef)
	}
	parallel_rows(src.h, &ctx, proc(data: rawptr, y0, y1: int) {
		c := (^Ctx)(data)
		for y in y0 ..< y1 {
			srow := c.src.pix[y * c.src.w * 4:]
			trow := c.tmp[y * c.dst.w * 4:]
			for x in 0 ..< c.dst.w {
				acc: [4]i32
				for k in 0 ..< 4 {
					sx := clamp(c.tx.first[x] + k, 0, c.src.w - 1)
					w := c.tx.coef[x][k]
					for ch in 0 ..< 4 do acc[ch] += i32(srow[sx * 4 + ch]) * w
				}
				for ch in 0 ..< 4 do trow[x * 4 + ch] = acc[ch]
			}
		}
	})
	parallel_rows(dh, &ctx, proc(data: rawptr, y0, y1: int) {
		c := (^Ctx)(data)
		dw := c.dst.w
		for y in y0 ..< y1 {
			drow := c.dst.pix[y * dw * 4:]
			rows: [4][]i32
			for k in 0 ..< 4 do rows[k] = c.tmp[clamp(c.ty.first[y] + k, 0, c.src.h - 1) * dw * 4:]
			w := c.ty.coef[y]
			for i in 0 ..< dw * 4 {
				v := i64(rows[0][i]) * i64(w[0]) + i64(rows[1][i]) * i64(w[1]) + i64(rows[2][i]) * i64(w[2]) + i64(rows[3][i]) * i64(w[3])
				drow[i] = u8(clamp((v + (1 << 21)) >> 22, 0, 255))
			}
		}
	})
	return ctx.dst
}

// ---------------------------------------------------------------------------
// medianBlur 3x3 (border replicate)
// ---------------------------------------------------------------------------

median3 :: proc(src: Image, allocator := context.allocator) -> Image {
	Ctx :: struct {
		src, dst: Image,
	}
	ctx := Ctx{src, image_make(src.w, src.h, allocator)}
	parallel_rows(src.h, &ctx, proc(data: rawptr, y0, y1: int) {
		c := (^Ctx)(data)
		w, h := c.src.w, c.src.h
		sort2 :: #force_inline proc(a, b: ^u8) {
			if a^ > b^ do a^, b^ = b^, a^
		}
		for y in y0 ..< y1 {
			r0 := c.src.pix[max(y - 1, 0) * w * 4:]
			r1 := c.src.pix[y * w * 4:]
			r2 := c.src.pix[min(y + 1, h - 1) * w * 4:]
			drow := c.dst.pix[y * w * 4:]
			for x in 0 ..< w {
				xl, xr := max(x - 1, 0) * 4, min(x + 1, w - 1) * 4
				xc := x * 4
				for ch in 0 ..< 4 {
					p := [9]u8 {
						r0[xl + ch], r0[xc + ch], r0[xr + ch],
						r1[xl + ch], r1[xc + ch], r1[xr + ch],
						r2[xl + ch], r2[xc + ch], r2[xr + ch],
					}
					// Paeth's 19-exchange median-of-9 network.
					sort2(&p[1], &p[2]); sort2(&p[4], &p[5]); sort2(&p[7], &p[8])
					sort2(&p[0], &p[1]); sort2(&p[3], &p[4]); sort2(&p[6], &p[7])
					sort2(&p[1], &p[2]); sort2(&p[4], &p[5]); sort2(&p[7], &p[8])
					sort2(&p[0], &p[3]); sort2(&p[5], &p[8]); sort2(&p[4], &p[7])
					sort2(&p[3], &p[6]); sort2(&p[1], &p[4]); sort2(&p[2], &p[5])
					sort2(&p[4], &p[7]); sort2(&p[4], &p[2]); sort2(&p[6], &p[4])
					sort2(&p[4], &p[2])
					drow[xc + ch] = p[4]
				}
			}
		}
	})
	return ctx.dst
}

// ---------------------------------------------------------------------------
// 8-bit Lab without sRGB gamma: OpenCV's bit-exact integer paths for
// COLOR_LBGR2Lab (RGB2Lab_b) and COLOR_Lab2LBGR (Lab2RGBinteger), including
// their lookup tables, so the denoiser sees exactly the values OpenCV does.
// ---------------------------------------------------------------------------

@(private = "file")
Lab_Tables :: struct {
	cbrt:    [256 * 3 / 2 * 8]u16, // LabCbrtTab_b
	l_to_yf: [256 * 2]u16, // LabToYF_b: y, fy per L
	ab_xz:   [LUT_BASE * 9 / 4]i32, // abToXZ_b
}

@(private = "file")
lab_tables: Lab_Tables
@(private = "file")
lab_once: sync.Once

@(private = "file")
LAB_SHIFT :: 12
@(private = "file")
LAB_SHIFT2 :: 15
@(private = "file")
LUT_BASE :: 1 << 14
@(private = "file")
MIN_AB :: -8145

// cvRound for float32: round half to even.
@(private = "file")
cv_round_f32 :: proc(v: f32) -> int {
	r := math.round(v)
	if abs(v - math.trunc(v)) == 0.5 && int(r) % 2 != 0 do r -= math.sign(v)
	return int(r)
}

@(private = "file")
descale :: #force_inline proc(x: i32, n: uint) -> i32 {
	return (x + (1 << (n - 1))) >> n
}

@(private = "file")
build_lab_tables :: proc() {
	t := &lab_tables
	lthresh := f32(216) / f32(24389)
	lscale := f32(841) / f32(108)
	lbias := f32(16) / f32(116)
	cb_scale := f32(1) / (f32(255) * f32(8))
	for i in 0 ..< len(t.cbrt) {
		x := cb_scale * f32(i)
		v: f32 = f32(f64(x) * f64(lscale) + f64(lbias)) if x < lthresh else f32(math.cbrt(f64(x)))
		t.cbrt[i] = u16(cv_round_f32(f32(1 << LAB_SHIFT2) * v))
	}
	for i in 0 ..< 256 {
		y, ify: int
		if i <= 20 {
			y = cv_round_f32(f32(i * LUT_BASE * 20 * 9) / f32(17 * 29 * 29 * 29))
			ify = cv_round_f32(f32(LUT_BASE) * (f32(16) / f32(116) + f32(i * 5) / f32(3 * 17 * 29)))
		} else {
			fy := f32(i * 100 * LUT_BASE) / f32(255 * 116) + f32(16 * LUT_BASE) / f32(116)
			ify = cv_round_f32(fy)
			y = cv_round_f32(fy * fy * fy / f32(LUT_BASE * LUT_BASE))
		}
		t.l_to_yf[i * 2] = u16(y)
		t.l_to_yf[i * 2 + 1] = u16(ify)
	}
	for i in MIN_AB ..< LUT_BASE * 9 / 4 + MIN_AB {
		v: int
		if i <= 3390 {
			v = i * 108 / 841 - LUT_BASE * 16 / 116 * 108 / 841
		} else {
			v = i * i / LUT_BASE * i / LUT_BASE
		}
		t.ab_xz[i - MIN_AB] = i32(v)
	}
}

// sRGB->XYZ (D65), divided by the white point, x 4096: rows X, Y, Z; columns R, G, B.
@(private = "file")
RGB2LAB_C :: [9]i32{1777, 1541, 778, 871, 2929, 296, 73, 448, 3575}
// XYZ->sRGB times the white point, x 4096: rows R, G, B; columns X, Y, Z.
@(private = "file")
LAB2RGB_C :: [9]i32{12615, -6296, -2223, -3773, 7684, 185, 217, -836, 4715}

rgb_to_lab8 :: proc(r8, g8, b8: u8) -> [3]u8 {
	sync.once_do(&lab_once, build_lab_tables)
	C := RGB2LAB_C
	R, G, B := i32(r8) * 8, i32(g8) * 8, i32(b8) * 8 // linear "gamma" table: v << 3
	tab := &lab_tables.cbrt
	fX := i32(tab[descale(R * C[0] + G * C[1] + B * C[2], LAB_SHIFT)])
	fY := i32(tab[descale(R * C[3] + G * C[4] + B * C[5], LAB_SHIFT)])
	fZ := i32(tab[descale(R * C[6] + G * C[7] + B * C[8], LAB_SHIFT)])
	LSCALE :: (116 * 255 + 50) / 100
	LSHIFT :: -((16 * 255 * (1 << LAB_SHIFT2) + 50) / 100)
	L := descale(LSCALE * fY + LSHIFT, LAB_SHIFT2)
	a := descale(500 * (fX - fY) + 128 * (1 << LAB_SHIFT2), LAB_SHIFT2)
	b := descale(200 * (fY - fZ) + 128 * (1 << LAB_SHIFT2), LAB_SHIFT2)
	return {u8(clamp(L, 0, 255)), u8(clamp(a, 0, 255)), u8(clamp(b, 0, 255))}
}

lab8_to_rgb :: proc(l8, a8, b8: u8) -> [3]u8 {
	sync.once_do(&lab_once, build_lab_tables)
	BASE :: 1 << 14
	SHIFT :: LAB_SHIFT + (14 - 12) // lab_shift + (base_shift - inv_gamma_shift)
	t := &lab_tables
	y := i32(t.l_to_yf[int(l8) * 2])
	ify := i32(t.l_to_yf[int(l8) * 2 + 1])
	aa, bb := i32(a8), i32(b8)
	adiv := ((5 * aa * 53687 + (1 << 7)) >> 13) - 128 * BASE / 500
	bdiv := ((bb * 41943 + (1 << 4)) >> 9) - 128 * BASE / 200 + 1
	x := t.ab_xz[ify + adiv - MIN_AB]
	z := t.ab_xz[ify - bdiv - MIN_AB]
	C := LAB2RGB_C
	out: [3]u8
	for k in 0 ..< 3 {
		v := descale(C[k * 3] * x + C[k * 3 + 1] * y + C[k * 3 + 2] * z, SHIFT)
		v = clamp(v, 0, 4095)
		out[k] = u8(clamp(((v << 8) - v) >> 12, 0, 255)) // v * 255 / 4096
	}
	return out
}

// ---------------------------------------------------------------------------
// fastNlMeansDenoisingColored (OpenCV FastNlMeansDenoisingInvoker, DistSquared)
// ---------------------------------------------------------------------------

NLM_TEMPLATE :: 7
NLM_SEARCH :: 21
@(private = "file")
NLM_TR :: NLM_TEMPLATE / 2
@(private = "file")
NLM_SR :: NLM_SEARCH / 2
@(private = "file")
NLM_PAD :: NLM_TR + NLM_SR
@(private = "file")
NLM_BAND :: 32

// Denoises in Lab: L with strength h, a/b together with strength h_color,
// exactly as OpenCV does, then converts back to RGB.
nlmeans_colored :: proc(src: Image, h, h_color: f32, progress: ^Descreen_Progress = nil, prog_lo := 0, prog_hi := 1000, allocator := context.allocator) -> (out: Image, ok: bool) {
	w, ht := src.w, src.h
	n := w * ht
	lab := make([]u8, n * 3)
	defer delete(lab)
	L, A, B := lab[:n], lab[n:2 * n], lab[2 * n:]
	{
		Ctx :: struct {
			src:     Image,
			L, A, B: []u8,
		}
		ctx := Ctx{src, L, A, B}
		parallel_rows(ht, &ctx, proc(data: rawptr, y0, y1: int) {
			c := (^Ctx)(data)
			for i in y0 * c.src.w ..< y1 * c.src.w {
				v := rgb_to_lab8(c.src.pix[i * 4], c.src.pix[i * 4 + 1], c.src.pix[i * 4 + 2])
				c.L[i], c.A[i], c.B[i] = v[0], v[1], v[2]
			}
		})
	}
	dl := make([]u8, n * 3)
	defer delete(dl)
	DL, DA, DB := dl[:n], dl[n:2 * n], dl[2 * n:]

	// Progress split: the 2-channel pass costs a little more than the 1-channel pass.
	mid := prog_lo + (prog_hi - prog_lo) * 2 / 5
	if !nlmeans_planes({L}, {DL}, w, ht, h, progress, prog_lo, mid) do return {}, false
	if !nlmeans_planes({A, B}, {DA, DB}, w, ht, h_color, progress, mid, prog_hi) do return {}, false

	out = image_make(w, ht, allocator)
	{
		Ctx :: struct {
			src, dst: Image,
			L, A, B:  []u8,
		}
		ctx := Ctx{src, out, DL, DA, DB}
		parallel_rows(ht, &ctx, proc(data: rawptr, y0, y1: int) {
			c := (^Ctx)(data)
			for i in y0 * c.src.w ..< y1 * c.src.w {
				v := lab8_to_rgb(c.L[i], c.A[i], c.B[i])
				c.dst.pix[i * 4], c.dst.pix[i * 4 + 1], c.dst.pix[i * 4 + 2] = v[0], v[1], v[2]
				c.dst.pix[i * 4 + 3] = c.src.pix[i * 4 + 3]
			}
		})
	}
	return out, true
}

// Non-local means over 1 or 2 planes that share one weight per candidate.
// Weights come from the mean squared template difference (summed over the
// planes) through OpenCV's fixed-point lookup table.
nlmeans_planes :: proc(src, dst: [][]u8, w, h: int, strength: f32, progress: ^Descreen_Progress, prog_lo, prog_hi: int) -> bool {
	cn := len(src)
	assert(cn == 1 || cn == 2)
	pw, ph := w + 2 * NLM_PAD, h + 2 * NLM_PAD

	// Reflect-101 padded copies.
	padded := make([][]u8, cn)
	defer {
		for p in padded do delete(p)
		delete(padded)
	}
	for c in 0 ..< cn {
		padded[c] = make([]u8, pw * ph)
		for y in 0 ..< ph {
			sy := reflect101(y - NLM_PAD, h)
			for x in 0 ..< pw do padded[c][y * pw + x] = src[c][sy * w + reflect101(x - NLM_PAD, w)]
		}
	}

	// Weight table, as OpenCV builds it: the template sum is divided by 64
	// (the power of two nearest above 49) instead of 49, then corrected.
	TSQ :: NLM_TEMPLATE * NLM_TEMPLATE
	shift := 0
	for (1 << uint(shift)) < TSQ do shift += 1
	almost_to_dist := f64(int(1) << uint(shift)) / f64(TSQ)
	fixed_mult := i32(max(i32) / i32(NLM_SEARCH * NLM_SEARCH * 255))
	lut := make([dynamic]i32)
	defer delete(lut)
	for d := 0;; d += 1 {
		dist := f64(d) * almost_to_dist
		wgt := math.exp(-dist / (f64(strength) * f64(strength) * f64(cn)))
		iw := i32(math.round(f64(fixed_mult) * wgt))
		if f64(iw) < 0.001 * f64(fixed_mult) do iw = 0
		append(&lut, iw)
		if iw == 0 do break // every larger distance also weighs 0
	}

	Ctx :: struct {
		padded:    [][]u8,
		dst:       [][]u8,
		w, h, pw:  int,
		cn:        int,
		shift:     uint,
		lut:       []i32,
		progress:  ^Descreen_Progress,
		prog_lo:   int,
		prog_span: int,
		bands:     int,
		done:      int, // atomic
	}
	ctx := Ctx {
		padded    = padded,
		dst       = dst,
		w         = w,
		h         = h,
		pw        = pw,
		cn        = cn,
		shift     = uint(shift),
		lut       = lut[:],
		progress  = progress,
		prog_lo   = prog_lo,
		prog_span = prog_hi - prog_lo,
		bands     = (h + NLM_BAND - 1) / NLM_BAND,
	}
	parallel_rows(ctx.bands, &ctx, proc(data: rawptr, b0, b1: int) {
		c := (^Ctx)(data)
		for band in b0 ..< b1 {
			if cancelled(c.progress) do return
			nlm_band(c.padded, c.dst, c.w, c.h, c.pw, c.cn, c.shift, c.lut, band * NLM_BAND, min((band + 1) * NLM_BAND, c.h))
			done := sync.atomic_add(&c.done, 1) + 1
			progress_set(c.progress, c.prog_lo + c.prog_span * done / c.bands)
		}
	})
	return !cancelled(progress)
}

// Processes output rows [y0, y1) for every search offset, keeping a 7-row ring
// of squared differences and running column sums so each offset costs O(1)
// per pixel.
// Hot loop: all indices are bounded by the NLM_PAD reflection padding, so bounds
// checks are off here.
@(private = "file")
nlm_band :: proc(padded, dst: [][]u8, w, h, pw, cn: int, shift: uint, lut: []i32, y0, y1: int) #no_bounds_check {
	bh := y1 - y0
	dw := w + 2 * NLM_TR // difference row covers x in [-3, w+3)
	// Heap, not the temp allocator: this also runs on the caller's thread.
	ring := make([]i32, NLM_TEMPLATE * dw)
	colsum := make([]i32, dw)
	est := make([]i32, bh * w * cn)
	wsum := make([]i32, bh * w)
	wrow_buf := make([]i32, w) // weights for one output row
	defer {
		delete(ring); delete(colsum); delete(est); delete(wsum); delete(wrow_buf)
	}
	last := i32(len(lut) - 1)

	// Squared difference row for output row r and offset (dy, dx), over the
	// template's x range. Padded coordinates are output + NLM_PAD.
	diff_row :: #force_inline proc(out: []i32, padded: [][]u8, pw, cn, r, dy, dx, dw: int) #no_bounds_check {
		base := (r + NLM_PAD) * pw + NLM_SR // x = -3 -> padded x = NLM_PAD - 3 = NLM_SR
		off := dy * pw + dx
		if cn == 1 {
			p := padded[0]
			for i in 0 ..< dw {
				d := i32(p[base + i]) - i32(p[base + i + off])
				out[i] = d * d
			}
		} else {
			p0, p1 := padded[0], padded[1]
			for i in 0 ..< dw {
				d0 := i32(p0[base + i]) - i32(p0[base + i + off])
				d1 := i32(p1[base + i]) - i32(p1[base + i + off])
				out[i] = d0 * d0 + d1 * d1
			}
		}
	}

	for dy in -NLM_SR ..= NLM_SR {
		for dx in -NLM_SR ..= NLM_SR {
			// Prime the ring with rows y0-3 .. y0+3.
			for &v in colsum do v = 0
			for k in 0 ..< NLM_TEMPLATE {
				row := ring[k * dw:][:dw]
				diff_row(row, padded, pw, cn, y0 - NLM_TR + k, dy, dx, dw)
				for i in 0 ..< dw do colsum[i] += row[i]
			}
			for y in y0 ..< y1 {
				ly := y - y0
				// Candidate pixel row (the center of the shifted template).
				cand := (y + NLM_PAD + dy) * pw + NLM_PAD + dx
				// Template sums along the row (sliding 7-wide window), then weights.
				s: i32 = 0
				for i in 0 ..< NLM_TEMPLATE do s += colsum[i]
				wts := wrow_buf
				for x in 0 ..< w - 1 {
					wts[x] = lut[min(s >> shift, last)]
					s += colsum[x + NLM_TEMPLATE] - colsum[x]
				}
				wts[w - 1] = lut[min(s >> shift, last)]
				erow := est[ly * w * cn:]
				wrow := wsum[ly * w:]
				if cn == 1 {
					p := padded[0][cand:]
					for x in 0 ..< w {
						erow[x] += wts[x] * i32(p[x])
						wrow[x] += wts[x]
					}
				} else {
					p0, p1 := padded[0][cand:], padded[1][cand:]
					for x in 0 ..< w {
						erow[x * 2] += wts[x] * i32(p0[x])
						erow[x * 2 + 1] += wts[x] * i32(p1[x])
						wrow[x] += wts[x]
					}
				}
				// Slide the template window down one row.
				if y + 1 < y1 {
					slot := (y - y0) % NLM_TEMPLATE // holds row y-3, which leaves the window
					row := ring[slot * dw:][:dw]
					for i in 0 ..< dw do colsum[i] -= row[i]
					diff_row(row, padded, pw, cn, y + NLM_TR + 1, dy, dx, dw)
					for i in 0 ..< dw do colsum[i] += row[i]
				}
			}
		}
	}

	for ly in 0 ..< bh {
		for x in 0 ..< w {
			ws := wsum[ly * w + x]
			for c in 0 ..< cn {
				e := est[(ly * w + x) * cn + c]
				// Unsigned like OpenCV: a fully uniform window reaches 441 * 19096 * 255,
				// right at the signed 32-bit limit, so adding ws/2 must not wrap.
				dst[c][(y0 + ly) * w + x] = u8(min((u32(e) + u32(ws / 2)) / u32(ws), 255))
			}
		}
	}
}

// ---------------------------------------------------------------------------
// bilateralFilter (OpenCV 8UC3: L1 colour distance, circular window)
// ---------------------------------------------------------------------------

bilateral_cv :: proc(src: Image, d: int, sigma_color, sigma_space: f64, allocator := context.allocator) -> Image {
	radius := d / 2
	pad := radius
	pw, ph := src.w + 2 * pad, src.h + 2 * pad
	padded := make([]u8, pw * ph * 4)
	defer delete(padded)
	for y in 0 ..< ph {
		sy := reflect101(y - pad, src.h)
		for x in 0 ..< pw {
			sx := reflect101(x - pad, src.w)
			copy(padded[(y * pw + x) * 4:][:4], src.pix[(sy * src.w + sx) * 4:][:4])
		}
	}
	Ctx :: struct {
		padded:       []u8,
		pw:           int,
		dst:          Image,
		src:          Image,
		ofs:          [dynamic]int, // byte offsets of the window taps
		space_w:      [dynamic]f32,
		color_w:      [256 * 3]f32,
		pad:          int,
	}
	ctx := new(Ctx)
	defer {
		delete(ctx.ofs); delete(ctx.space_w); free(ctx)
	}
	ctx.padded = padded
	ctx.pw = pw
	ctx.src = src
	ctx.dst = image_make(src.w, src.h, allocator)
	ctx.pad = pad
	ctx.ofs = make([dynamic]int)
	ctx.space_w = make([dynamic]f32)
	gs := -0.5 / (sigma_space * sigma_space)
	gc := -0.5 / (sigma_color * sigma_color)
	for i in -radius ..= radius {
		for j in -radius ..= radius {
			r := math.sqrt(f64(i * i + j * j))
			if r > f64(radius) do continue
			append(&ctx.space_w, f32(math.exp(r * r * gs)))
			append(&ctx.ofs, (i * pw + j) * 4)
		}
	}
	for i in 0 ..< len(ctx.color_w) do ctx.color_w[i] = f32(math.exp(f64(i * i) * gc))

	parallel_rows(src.h, ctx, proc(data: rawptr, y0, y1: int) {
		c := (^Ctx)(data)
		for y in y0 ..< y1 {
			for x in 0 ..< c.src.w {
				center := ((y + c.pad) * c.pw + x + c.pad) * 4
				r0, g0, b0 := i32(c.padded[center]), i32(c.padded[center + 1]), i32(c.padded[center + 2])
				sr, sg, sb, sw: f32
				for k in 0 ..< len(c.ofs) {
					p := center + c.ofs[k]
					r, g, b := i32(c.padded[p]), i32(c.padded[p + 1]), i32(c.padded[p + 2])
					wt := c.space_w[k] * c.color_w[abs(r - r0) + abs(g - g0) + abs(b - b0)]
					sr += f32(r) * wt
					sg += f32(g) * wt
					sb += f32(b) * wt
					sw += wt
				}
				inv := 1 / sw
				o := (y * c.src.w + x) * 4
				c.dst.pix[o] = u8(clamp(math.round(sr * inv), 0, 255))
				c.dst.pix[o + 1] = u8(clamp(math.round(sg * inv), 0, 255))
				c.dst.pix[o + 2] = u8(clamp(math.round(sb * inv), 0, 255))
				c.dst.pix[o + 3] = c.src.pix[o + 3]
			}
		}
	})
	return ctx.dst
}

// ---------------------------------------------------------------------------
// resize INTER_AREA for downscaling (OpenCV computeResizeAreaTab)
// ---------------------------------------------------------------------------

@(private)
Area_Tap :: struct {
	src:    int,
	weight: f32,
}

@(private)
area_taps :: proc(src_len, dst_len: int, allocator := context.allocator) -> (taps: [dynamic]Area_Tap, first: []int) {
	scale := f64(src_len) / f64(dst_len)
	taps = make([dynamic]Area_Tap, allocator)
	first = make([]int, dst_len + 1, allocator)
	for d in 0 ..< dst_len {
		first[d] = len(taps)
		fs1 := f64(d) * scale
		fs2 := fs1 + scale
		cell := min(scale, f64(src_len) - fs1)
		s1 := int(math.ceil(fs1))
		s2 := min(int(math.floor(fs2)), src_len - 1)
		s1 = min(s1, s2)
		if f64(s1) - fs1 > 1e-3 do append(&taps, Area_Tap{s1 - 1, f32((f64(s1) - fs1) / cell)})
		for s in s1 ..< s2 do append(&taps, Area_Tap{s, f32(1 / cell)})
		if fs2 - f64(s2) > 1e-3 do append(&taps, Area_Tap{s2, f32(min(min(fs2 - f64(s2), 1), cell) / cell)})
	}
	first[dst_len] = len(taps)
	return
}

resize_area_cv :: proc(src: Image, dw, dh: int, allocator := context.allocator) -> Image {
	Ctx :: struct {
		src, dst: Image,
		tmp:      []f32, // dw x src.h x 4
		tx, ty:   []Area_Tap,
		fx, fy:   []int,
	}
	tx, fx := area_taps(src.w, dw)
	ty, fy := area_taps(src.h, dh)
	ctx := Ctx{src, image_make(dw, dh, allocator), make([]f32, dw * src.h * 4), tx[:], ty[:], fx, fy}
	defer {
		delete(ctx.tmp); delete(tx); delete(ty); delete(fx); delete(fy)
	}
	parallel_rows(src.h, &ctx, proc(data: rawptr, y0, y1: int) {
		c := (^Ctx)(data)
		for y in y0 ..< y1 {
			srow := c.src.pix[y * c.src.w * 4:]
			trow := c.tmp[y * c.dst.w * 4:]
			for x in 0 ..< c.dst.w {
				acc: [4]f32
				for t in c.tx[c.fx[x]:c.fx[x + 1]] {
					for ch in 0 ..< 4 do acc[ch] += f32(srow[t.src * 4 + ch]) * t.weight
				}
				for ch in 0 ..< 4 do trow[x * 4 + ch] = acc[ch]
			}
		}
	})
	parallel_rows(dh, &ctx, proc(data: rawptr, y0, y1: int) {
		c := (^Ctx)(data)
		dw := c.dst.w
		for y in y0 ..< y1 {
			drow := c.dst.pix[y * dw * 4:]
			for i in 0 ..< dw * 4 {
				acc: f32
				for t in c.ty[c.fy[y]:c.fy[y + 1]] do acc += c.tmp[t.src * dw * 4 + i] * t.weight
				drow[i] = u8(clamp(math.round(acc), 0, 255))
			}
		}
	})
	return ctx.dst
}

// ---------------------------------------------------------------------------
// Unsharp mask in float32, as the original Python does:
//   f = img / 255; blur = GaussianBlur(f, sigma); s = clip(f*(1+a) - blur*a, 0, 1)
//   out = uint8(s * 255)          (truncation, like numpy's astype)
// ---------------------------------------------------------------------------

unsharp_cv :: proc(src: Image, sigma, amount: f32, allocator := context.allocator) -> Image {
	// GaussianBlur with ksize (0,0) on float32: ksize = round(sigma*8 + 1) | 1.
	ks := int(math.round(f64(sigma) * 8 + 1)) | 1
	kr := ks / 2
	kernel := make([]f32, ks)
	defer delete(kernel)
	{
		sum := 0.0
		k64 := make([]f64, ks)
		defer delete(k64)
		for i in 0 ..< ks {
			x := f64(i) - f64(ks - 1) * 0.5
			k64[i] = math.exp(-0.5 / (f64(sigma) * f64(sigma)) * x * x)
			sum += k64[i]
		}
		for i in 0 ..< ks do kernel[i] = f32(k64[i] / sum)
	}
	w, h := src.w, src.h
	Ctx :: struct {
		src, dst: Image,
		tmp:      []f32, // horizontally blurred, w x h x 3
		kernel:   []f32,
		kr:       int,
		amount:   f32,
	}
	ctx := Ctx{src, image_make(w, h, allocator), make([]f32, w * h * 3), kernel, kr, amount}
	defer delete(ctx.tmp)
	parallel_rows(h, &ctx, proc(data: rawptr, y0, y1: int) {
		c := (^Ctx)(data)
		w := c.src.w
		for y in y0 ..< y1 {
			for x in 0 ..< w {
				acc: [3]f32
				for k in 0 ..< len(c.kernel) {
					sx := reflect101(x + k - c.kr, w)
					p := c.src.pix[(y * w + sx) * 4:]
					for ch in 0 ..< 3 do acc[ch] += (f32(p[ch]) / 255) * c.kernel[k]
				}
				for ch in 0 ..< 3 do c.tmp[(y * w + x) * 3 + ch] = acc[ch]
			}
		}
	})
	parallel_rows(h, &ctx, proc(data: rawptr, y0, y1: int) {
		c := (^Ctx)(data)
		w, h := c.src.w, c.src.h
		alpha := 1 + c.amount
		beta := -c.amount
		for y in y0 ..< y1 {
			for x in 0 ..< w {
				blur: [3]f32
				for k in 0 ..< len(c.kernel) {
					sy := reflect101(y + k - c.kr, h)
					for ch in 0 ..< 3 do blur[ch] += c.tmp[(sy * w + x) * 3 + ch] * c.kernel[k]
				}
				o := (y * w + x) * 4
				for ch in 0 ..< 3 {
					f := f32(c.src.pix[o + ch]) / 255
					s := clamp(f * alpha + blur[ch] * beta, 0, 1)
					c.dst.pix[o + ch] = u8(s * 255) // truncates, like numpy astype(uint8)
				}
				c.dst.pix[o + 3] = c.src.pix[o + 3]
			}
		}
	})
	return ctx.dst
}
