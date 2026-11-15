// Synthetic flatbed scans of printed cards, with exact ground truth.
//
//   ./build.sh synth OUTDIR [--clean] [--only PRESET] [--scale S]
//
// Writes OUTDIR/<preset>-<split>-<n>.png, optionally the matching
// "-clean.png" (the same scan printed without halftone and without sensor
// noise: the target for moiré removal), and OUTDIR/annotations.json in the
// format tools/detect_bench reads.
//
// The scans are simulated physically rather than drawn:
//   * card art is procedural (no third-party images), rendered as continuous
//     tone and converted to CMYK;
//   * printing: each ink is an AM halftone at its usual screen angle
//     (C 15, M 75, Y 0, K 45 degrees, ~150 lpi), with dot gain; overlapping
//     inks multiply;
//   * the scanner integrates 4x4 samples per 300 dpi pixel: this resampling
//     of the halftone is what produces real moiré;
//   * scanner bed and lid texture, lamp shadow beside card edges and on
//     overlapped cards, an optional dark lid strip, optical blur, sensor and
//     line noise, slight colour cast;
//   * layouts cover separated, tightly packed, touching, overlapping,
//     rotated, low-contrast and border-clipped cards.
//
// Everything is deterministic: the same preset and seed give the same image
// on every run (the generator carries its own PRNG and noise).
package synth

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import im "../../src/imaging"
import rl "vendor:raylib"

Vec2 :: [2]f64
RGB :: [3]f64

// ---------------------------------------------------------------------------
// Deterministic randomness
// ---------------------------------------------------------------------------

Rng :: struct {
	s: u64,
}

next_u64 :: proc(r: ^Rng) -> u64 {
	// splitmix64
	r.s += 0x9E3779B97F4A7C15
	z := r.s
	z = (z ~ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ~ (z >> 27)) * 0x94D049BB133111EB
	return z ~ (z >> 31)
}

rf :: proc(r: ^Rng) -> f64 {return f64(next_u64(r) >> 11) / f64(u64(1) << 53)}
rrange :: proc(r: ^Rng, a, b: f64) -> f64 {return a + (b - a) * rf(r)}
rint :: proc(r: ^Rng, a, b: int) -> int {return a + int(next_u64(r) % u64(b - a + 1))}
rnorm :: proc(r: ^Rng) -> f64 {
	u := max(rf(r), 1e-12)
	return math.sqrt(-2 * math.ln(u)) * math.cos(2 * math.PI * rf(r))
}

hash2 :: #force_inline proc(x, y: i64, seed: u64) -> f64 {
	h := u64(x) * 0x8DA6B343 ~ u64(y) * 0xD8163841 ~ seed * 0xCB1AB31F
	h = (h ~ (h >> 33)) * 0xFF51AFD7ED558CCD
	h = (h ~ (h >> 33)) * 0xC4CEB9FE1A85EC53
	h ~= h >> 33
	return f64(h >> 11) / f64(u64(1) << 53)
}

// Smooth value noise in [0, 1].
value_noise :: proc(x, y: f64, seed: u64) -> f64 {
	ix, iy := math.floor(x), math.floor(y)
	fx, fy := x - ix, y - iy
	sx, sy := fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)
	a := hash2(i64(ix), i64(iy), seed)
	b := hash2(i64(ix) + 1, i64(iy), seed)
	c := hash2(i64(ix), i64(iy) + 1, seed)
	d := hash2(i64(ix) + 1, i64(iy) + 1, seed)
	return math.lerp(math.lerp(a, b, sx), math.lerp(c, d, sx), sy)
}

fbm :: proc(x, y: f64, seed: u64, octaves := 4) -> f64 {
	sum, amp, norm := 0.0, 0.5, 0.0
	fx, fy := x, y
	for o in 0 ..< octaves {
		sum += amp * value_noise(fx, fy, seed + u64(o) * 7919)
		norm += amp
		amp *= 0.5
		fx *= 2.03
		fy *= 2.03
	}
	return sum / norm
}

// ---------------------------------------------------------------------------
// Cards
// ---------------------------------------------------------------------------

Border_Style :: enum {
	Marble, // light grey marbled frame (low contrast against a white bed)
	White, // white frame: the hardest case against a white lid
	Dark, // dark frame
}

ART_DPI :: 600.0

Card :: struct {
	w, h:        f64, // inches
	radius:      f64, // corner radius, inches
	center:      Vec2, // scan pixels (continuous: pixel i covers [i, i+1))
	angle:       f64, // radians
	ca, sa:      f64,
	style:       Border_Style,
	edge_white:  bool, // light cut edge
	seed:        u64,
	// Contone CMYK raster at ART_DPI, covering the whole card.
	rw, rh:      int,
	cmyk:        []u8,
	bbox:        [4]f64, // scan-pixel bounds (x0, y0, x1, y1)
}

// Scan pixel -> card inches (origin at the card's top-left).
to_card :: #force_inline proc(c: ^Card, p: Vec2, dpi: f64) -> Vec2 {
	d := (p - c.center) / dpi
	return {d.x * c.ca + d.y * c.sa + c.w / 2, -d.x * c.sa + d.y * c.ca + c.h / 2}
}

in_rounded :: #force_inline proc(u, v, w, h, r: f64) -> bool {
	if u < 0 || v < 0 || u > w || v > h do return false
	cx := clamp(u, r, w - r)
	cy := clamp(v, r, h - r)
	return (u - cx) * (u - cx) + (v - cy) * (v - cy) <= r * r
}

// Distance from inside a rounded rect to its outline (inches, >= 0 inside).
rounded_depth :: #force_inline proc(u, v, w, h, r: f64) -> f64 {
	cx := clamp(u, r, w - r)
	cy := clamp(v, r, h - r)
	dc := math.sqrt((u - cx) * (u - cx) + (v - cy) * (v - cy))
	if (u < r || u > w - r) && (v < r || v > h - r) do return r - dc
	return min(u, v, w - u, h - v)
}

card_corners :: proc(c: ^Card, dpi: f64) -> [4]Vec2 {
	hw, hh := c.w / 2 * dpi, c.h / 2 * dpi
	local := [4]Vec2{{-hw, -hh}, {hw, -hh}, {hw, hh}, {-hw, hh}}
	out: [4]Vec2
	for p, i in local do out[i] = c.center + {p.x * c.ca - p.y * c.sa, p.x * c.sa + p.y * c.ca}
	return out
}

hsv :: proc(h, s, v: f64) -> RGB {
	i := math.floor(h * 6)
	f := h * 6 - i
	p, q, t := v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
	switch int(i) % 6 {
	case 0: return {v, t, p}
	case 1: return {q, v, p}
	case 2: return {p, v, t}
	case 3: return {p, q, v}
	case 4: return {t, p, v}
	}
	return {v, p, q}
}

mix :: #force_inline proc(a, b: RGB, t: f64) -> RGB {return a + (b - a) * clamp(t, 0, 1)}

// The card as intended (before printing): appearance in [0, 1] RGB.
Art :: struct {
	sky0, sky1, ground, accent, blob, panel, ink: RGB,
	horizon, wave, wave_f, phase:                 f64,
	gems:                                         [6][4]f64, // u, v, r, hue
	gem_count:                                    int,
	blob_c:                                       Vec2,
	blob_r:                                       Vec2,
	text_top:                                     bool,
	badge:                                        Vec2,
}

make_art :: proc(r: ^Rng) -> Art {
	a: Art
	h := rf(r)
	a.sky0 = hsv(h, rrange(r, 0.2, 0.6), rrange(r, 0.75, 0.98))
	a.sky1 = hsv(math.mod(h + rrange(r, 0.05, 0.2), 1), rrange(r, 0.3, 0.8), rrange(r, 0.5, 0.9))
	a.ground = hsv(math.mod(h + rrange(r, 0.25, 0.6), 1), rrange(r, 0.4, 0.9), rrange(r, 0.3, 0.75))
	a.accent = hsv(rf(r), rrange(r, 0.6, 1), rrange(r, 0.6, 1))
	a.blob = hsv(rf(r), rrange(r, 0.2, 0.7), rrange(r, 0.2, 0.6))
	a.panel = hsv(rf(r), rrange(r, 0.0, 0.15), rrange(r, 0.85, 0.97))
	a.ink = hsv(rf(r), rrange(r, 0.3, 0.8), rrange(r, 0.1, 0.35))
	a.horizon = rrange(r, 0.35, 0.7)
	a.wave = rrange(r, 0.02, 0.08)
	a.wave_f = rrange(r, 1.5, 5)
	a.phase = rrange(r, 0, 6.28)
	a.gem_count = rint(r, 3, 6)
	for i in 0 ..< a.gem_count do a.gems[i] = {rrange(r, 0.12, 0.88), rrange(r, 0.15, 0.9), rrange(r, 0.03, 0.07), rf(r)}
	a.blob_c = {rrange(r, 0.3, 0.7), rrange(r, 0.35, 0.65)}
	a.blob_r = {rrange(r, 0.15, 0.3), rrange(r, 0.2, 0.35)}
	a.text_top = rf(r) < 0.5
	a.badge = {rrange(r, 0.3, 0.7), 0.82 if a.text_top else 0.18}
	return a
}

// Art inside the window, s/t in [0, 1] across it (t down).
art_color :: proc(a: ^Art, s, t: f64, seed: u64) -> RGB {
	n := fbm(s * 6, t * 6, seed)
	horizon := a.horizon + a.wave * math.sin(s * a.wave_f * 2 * math.PI + a.phase) + (n - 0.5) * 0.05
	col: RGB
	if t < horizon {
		col = mix(a.sky0, a.sky1, t / horizon + (n - 0.5) * 0.3)
	} else {
		g := fbm(s * 22, t * 22, seed + 3)
		col = mix(a.ground, a.ground * 0.55, g)
	}
	// A large soft character blob with shading.
	d := Vec2{(s - a.blob_c.x) / a.blob_r.x, (t - a.blob_c.y) / a.blob_r.y}
	dd := d.x * d.x + d.y * d.y + (fbm(s * 9, t * 9, seed + 5) - 0.5) * 0.4
	if dd < 1 do col = mix(a.blob * (1.3 - 0.5 * dd), a.blob * 0.4, fbm(s * 40, t * 40, seed + 9) * 0.6)
	// Gems: saturated shaded circles with a highlight.
	for gi in 0 ..< a.gem_count {
		g := a.gems[gi]
		gd := math.sqrt((s - g[0]) * (s - g[0]) + (t - g[1]) * (t - g[1]) * 0.6) / g[2]
		if gd < 1 {
			base := hsv(g[3], 0.85, 0.95)
			col = mix(base, base * 0.45, gd * gd)
			if (s - g[0]) < -0.2 * g[2] && (t - g[1]) < -0.2 * g[2] && gd < 0.5 do col = mix(col, {1, 1, 1}, 0.6)
		}
	}
	// A text band: light panel with rows of short dark bars.
	band0, band1 := 0.84, 0.96
	if a.text_top do band0, band1 = 0.04, 0.16
	if t > band0 && t < band1 && s > 0.06 && s < 0.94 {
		col = a.panel
		row := (t - band0) / (band1 - band0) * 3
		fr := row - math.floor(row)
		word := math.floor(s * 14 + math.floor(row) * 3.7)
		if fr > 0.3 && fr < 0.7 && hash2(i64(word), i64(row), seed) > 0.25 && math.mod(s * 14, 1) < 0.85 do col = a.ink
	}
	// A number badge: white rounded square with a dark outline.
	bd := max(abs(s - a.badge.x) / 0.09, abs(t - a.badge.y) / 0.06)
	if bd < 1 do col = {0.97, 0.97, 0.98} if bd < 0.85 else a.ink
	// Fine paper-print texture.
	f := (hash2(i64(s * 900), i64(t * 1300), seed + 11) - 0.5) * 0.04
	return {clamp(col.r + f, 0, 1), clamp(col.g + f, 0, 1), clamp(col.b + f, 0, 1)}
}

border_color :: proc(style: Border_Style, u, v: f64, seed: u64) -> RGB {
	switch style {
	case .Marble:
		// Mid-tone tinted stone, like many printed card frames.
		n := fbm(u * 3, v * 3, seed + 21, 5)
		vein := abs(math.sin((u * 4 + v * 2.5 + n * 6) * 1.7))
		tint := hsv(f64(seed % 1000) / 1000, 0.18, 1)
		base := 0.58 + f64(seed % 7) * 0.025 + (n - 0.5) * 0.16 - (0.12 if vein < 0.08 else 0)
		return tint * base
	case .White:
		n := fbm(u * 8, v * 8, seed + 23) - 0.5
		return {0.95 + n * 0.02, 0.95 + n * 0.02, 0.94 + n * 0.02}
	case .Dark:
		n := fbm(u * 5, v * 5, seed + 25) - 0.5
		return {0.12 + n * 0.05, 0.13 + n * 0.05, 0.20 + n * 0.06}
	}
	return {}
}

// Undercolour removal: intended RGB -> CMYK ink coverage.
to_cmyk :: proc(c: RGB) -> [4]f64 {
	cy, mg, yl := 1 - c.r, 1 - c.g, 1 - c.b
	k := min(cy, mg, yl) * 0.8
	if k >= 0.999 do return {0, 0, 0, 1}
	return {(cy - k) / (1 - k), (mg - k) / (1 - k), (yl - k) / (1 - k), k}
}

// Renders the card's contone CMYK raster (border, window outline, art).
render_card_raster :: proc(c: ^Card, r: ^Rng) {
	c.rw = int(math.ceil(c.w * ART_DPI))
	c.rh = int(math.ceil(c.h * ART_DPI))
	c.cmyk = make([]u8, c.rw * c.rh * 4)
	art := make_art(r)
	Ctx :: struct {
		c:   ^Card,
		art: ^Art,
	}
	ctx := Ctx{c, &art}
	im.parallel_rows(c.rh, &ctx, proc(data: rawptr, y0, y1: int) {
		x := (^Ctx)(data)
		c := x.c
		border := 0.11 + f64(c.seed % 5) * 0.01 // frame width, inches
		wr := max(c.radius - border * 0.5, 0.04)
		for py in y0 ..< y1 {
			for px in 0 ..< c.rw {
				u := (f64(px) + 0.5) / ART_DPI
				v := (f64(py) + 0.5) / ART_DPI
				// Art window: inset rounded rect with a thin dark outline.
				wu, wv := u - border, v - border
				ww, wh := c.w - 2 * border, c.h - 2 * border
				col: RGB
				if in_rounded(wu, wv, ww, wh, wr) {
					depth := rounded_depth(wu, wv, ww, wh, wr)
					if depth < 0.012 {
						col = {0.18, 0.15, 0.12}
					} else {
						col = art_color(x.art, wu / ww, wv / wh, c.seed)
					}
				} else {
					col = border_color(c.style, u, v, c.seed)
				}
				k := to_cmyk(col)
				o := (py * c.rw + px) * 4
				for ch in 0 ..< 4 do c.cmyk[o + ch] = u8(clamp(k[ch] * 255 + 0.5, 0, 255))
			}
		}
	})
}

// ---------------------------------------------------------------------------
// Scene and scanner
// ---------------------------------------------------------------------------

Scene :: struct {
	w, h:        int,
	dpi:         f64,
	cards:       [dynamic]Card, // bottom to top
	bed:         RGB, // linear reflectance of the lid
	lid_top:     f64, // dark scanner strip widths, pixels (0 = none)
	lid_left:    f64,
	shadow:      Vec2, // lamp shadow offset, pixels
	shadow_dark: f64,
	lpi:         f64,
	dot_gain:    f64,
	blur_sigma:  f64,
	noise_sd:    f64,
	line_sd:     f64,
	tint:        RGB, // colour cast
	seed:        u64,
}

PAPER :: RGB{0.88, 0.87, 0.83}
INK_RGB := [4]RGB {
	{0.12, 0.55, 0.85}, // cyan
	{0.85, 0.12, 0.45}, // magenta
	{0.95, 0.88, 0.10}, // yellow
	{0.04, 0.04, 0.05}, // black
}
SCREEN_DEG :: [4]f64{15, 75, 0, 45}

// Topmost card covering scan point p, or -1.
card_at :: #force_inline proc(s: ^Scene, p: Vec2) -> (int, Vec2) {
	#reverse for &c, i in s.cards {
		if p.x < c.bbox[0] || p.y < c.bbox[1] || p.x > c.bbox[2] || p.y > c.bbox[3] do continue
		uv := to_card(&c, p, s.dpi)
		if in_rounded(uv.x, uv.y, c.w, c.h, c.radius) do return i, uv
	}
	return -1, {}
}

// Linear reflectance of the printed card at card point uv.
print_reflectance :: #force_inline proc(s: ^Scene, c: ^Card, uv: Vec2, halftone: bool, screens: ^[4][2]f64) -> RGB {
	px := clamp(int(uv.x * ART_DPI), 0, c.rw - 1)
	py := clamp(int(uv.y * ART_DPI), 0, c.rh - 1)
	o := (py * c.rw + px) * 4
	refl := PAPER
	for k in 0 ..< 4 {
		cov := f64(c.cmyk[o + k]) / 255
		if cov <= 0 do continue
		cov = clamp(cov + s.dot_gain * 4 * cov * (1 - cov) * 0.5, 0, 1)
		ink := INK_RGB[k]
		if !halftone {
			refl *= RGB{1, 1, 1} - (RGB{1, 1, 1} - ink) * cov
			continue
		}
		// AM halftone cell coordinates for this ink's screen.
		cs, sn := screens[k][0], screens[k][1]
		a := (uv.x * cs + uv.y * sn) * s.lpi
		b := (-uv.x * sn + uv.y * cs) * s.lpi
		fa := a - math.floor(a) - 0.5
		fb := b - math.floor(b) - 0.5
		// Ink spreads unevenly along paper fibres: jitter the dot threshold.
		jit := 1 + 0.35 * (value_noise(uv.x * 900, uv.y * 900, c.seed + u64(k)) - 0.5)
		on: bool
		if cov <= 0.5 {
			on = fa * fa + fb * fb < cov / math.PI * jit
		} else {
			ca, cb := 0.5 - abs(fa), 0.5 - abs(fb)
			on = ca * ca + cb * cb >= (1 - cov) / math.PI / jit
		}
		if on do refl *= ink
	}
	// The cut edge: a thin light core on some cards, a slight dark rim on others.
	depth := rounded_depth(uv.x, uv.y, c.w, c.h, c.radius)
	if depth < 0.004 {
		if c.edge_white do refl = mix(refl, PAPER, 0.7)
		else do refl *= 0.75
	}
	return refl
}

bed_reflectance :: #force_inline proc(s: ^Scene, p: Vec2) -> RGB {
	n := fbm(p.x / 180, p.y / 180, s.seed + 101, 3) - 0.5
	fine := hash2(i64(p.x * 2), i64(p.y * 2), s.seed + 103) - 0.5
	vx := (p.x / f64(s.w) - 0.5)
	vy := (p.y / f64(s.h) - 0.5)
	vig := 1 - 0.06 * (vx * vx + vy * vy) * 4
	return s.bed * (vig + n * 0.02 + fine * 0.01)
}

// Renders the scan (linear RGB, 3 floats per pixel) by 4x4 supersampling.
render_scan :: proc(s: ^Scene, halftone: bool) -> []f32 {
	out := make([]f32, s.w * s.h * 3)
	screens: [4][2]f64
	deg := SCREEN_DEG
	for k in 0 ..< 4 do screens[k] = {math.cos(deg[k] * math.PI / 180), math.sin(deg[k] * math.PI / 180)}
	Ctx :: struct {
		s:        ^Scene,
		out:      []f32,
		halftone: bool,
		screens:  [4][2]f64,
	}
	ctx := Ctx{s, out, halftone, screens}
	im.parallel_rows(s.h, &ctx, proc(data: rawptr, y0, y1: int) {
		x := (^Ctx)(data)
		s := x.s
		SS :: 4
		for py in y0 ..< y1 {
			for px in 0 ..< s.w {
				acc: RGB
				for sy in 0 ..< SS {
					for sx in 0 ..< SS {
						p := Vec2{f64(px) + (f64(sx) + 0.5) / SS, f64(py) + (f64(sy) + 0.5) / SS}
						ci, uv := card_at(s, p)
						refl: RGB
						if ci >= 0 {
							refl = print_reflectance(s, &s.cards[ci], uv, x.halftone, &x.screens)
							// Shadow cast by a higher card onto this one.
							if ci < len(s.cards) - 1 {
								above, _ := card_at(s, p - s.shadow)
								if above > ci do refl *= 1 - s.shadow_dark * 0.8
							}
						} else {
							refl = bed_reflectance(s, p)
							// Lamp shadow beside card edges (two-step penumbra).
							if a, _ := card_at(s, p - s.shadow); a >= 0 {
								refl *= 1 - s.shadow_dark
							} else if b, _ := card_at(s, p - s.shadow * 2); b >= 0 {
								refl *= 1 - s.shadow_dark * 0.45
							}
						}
						// Dark lid strip along the top/left frame of the scanner.
						if p.y < s.lid_top || p.x < s.lid_left {
							d := 0.04 + 0.03 * (hash2(i64(p.x), i64(p.y), s.seed + 7) - 0.5)
							refl = {d, d, d * 1.1}
						}
						acc += refl
					}
				}
				acc /= SS * SS
				o := (py * s.w + px) * 3
				x.out[o], x.out[o + 1], x.out[o + 2] = f32(acc.r), f32(acc.g), f32(acc.b)
			}
		}
	})
	return out
}

// Separable Gaussian blur of a 3-channel float image (scanner optics).
blur3 :: proc(img: []f32, w, h: int, sigma: f64) {
	if sigma <= 0 do return
	r := int(math.ceil(sigma * 3))
	k := make([]f32, 2 * r + 1)
	defer delete(k)
	sum := 0.0
	for i in -r ..= r {
		v := math.exp(-f64(i * i) / (2 * sigma * sigma))
		k[i + r] = f32(v)
		sum += v
	}
	for &v in k do v /= f32(sum)
	tmp := make([]f32, len(img))
	defer delete(tmp)
	for y in 0 ..< h do for x in 0 ..< w do for c in 0 ..< 3 {
		acc: f32
		for i in -r ..= r do acc += img[(y * w + clamp(x + i, 0, w - 1)) * 3 + c] * k[i + r]
		tmp[(y * w + x) * 3 + c] = acc
	}
	for y in 0 ..< h do for x in 0 ..< w do for c in 0 ..< 3 {
		acc: f32
		for i in -r ..= r do acc += tmp[(clamp(y + i, 0, h - 1) * w + x) * 3 + c] * k[i + r]
		img[(y * w + x) * 3 + c] = acc
	}
}

srgb_encode :: #force_inline proc(lin: f64) -> f64 {
	v := clamp(lin, 0, 1)
	return v * 12.92 if v <= 0.0031308 else 1.055 * math.pow(v, 1 / 2.4) - 0.055
}

// Linear float image -> 8-bit sRGB with colour cast and sensor noise.
to_rgba8 :: proc(s: ^Scene, lin: []f32, noisy: bool) -> im.Image {
	img := im.image_make(s.w, s.h)
	r := Rng{s.seed ~ 0xABCDEF}
	for y in 0 ..< s.h {
		line := rnorm(&r) * s.line_sd if noisy else 0
		for x in 0 ..< s.w {
			o := (y * s.w + x)
			for c in 0 ..< 3 {
				v := srgb_encode(f64(lin[o * 3 + c]) * s.tint[c]) * 255
				if noisy do v += line + rnorm(&r) * s.noise_sd
				img.pix[o * 4 + c] = u8(clamp(v + 0.5, 0, 255))
			}
			img.pix[o * 4 + 3] = 255
		}
	}
	return img
}

// ---------------------------------------------------------------------------
// Presets
// ---------------------------------------------------------------------------

Preset :: struct {
	name:            string,
	rows, cols:      int,
	card_w, card_h:  f64, // inches
	radius:          f64,
	gap_min:         f64, // pixels between neighbours (negative = overlap)
	gap_max:         f64,
	touch_chance:    f64, // chance a gap is exactly zero
	rot_deg:         f64, // max rotation, degrees
	lid_strip:       bool,
	clip_right:      bool, // push the grid against the right edge so cards are cut
	styles:          bit_set[Border_Style],
	page_w, page_h:  f64, // inches; 0 = 8.5 x 11.69 (the scanner bed)
	dpi:             f64, // 0 = 300
	small:           bool, // a compact scene for committed replay tests, not part of the benchmark corpus
}

PRESETS := [?]Preset {
	{"separated", 2, 3, 2.72, 4.77, 0.12, 25, 70, 0, 1.5, false, false, {.Marble, .Dark}, 0, 0, 0, false},
	{"packed", 2, 3, 2.72, 4.77, 0.12, 0, 8, 0.3, 0.7, true, true, {.Marble}, 0, 0, 0, false},
	{"overlap", 2, 3, 2.72, 4.77, 0.12, -12, 4, 0.1, 0.7, true, false, {.Marble, .Dark}, 0, 0, 0, false},
	{"rotated", 2, 2, 2.5, 3.5, 0.12, 120, 220, 0, 10, false, false, {.Marble, .Dark}, 0, 0, 0, false},
	{"pale", 3, 3, 2.5, 3.5, 0.12, 8, 40, 0, 1.2, false, false, {.White}, 0, 0, 0, false},
	{"poker_packed", 3, 3, 2.5, 3.5, 0.12, 0, 6, 0.25, 0.6, true, false, {.Dark, .Marble}, 0, 0, 0, false},
	// Three poker cards on a small page at 150 dpi: the halftone still aliases
	// into moiré, and the PNG stays small enough to commit.
	{"replay_small", 1, 3, 1.6, 2.24, 0.08, 0, 30, 0.5, 1.0, false, false, {.Marble, .Dark}, 5.4, 2.8, 150, true},
}

pick_style :: proc(r: ^Rng, styles: bit_set[Border_Style]) -> Border_Style {
	list := make([dynamic]Border_Style, context.temp_allocator)
	for st in Border_Style do if st in styles do append(&list, st)
	return list[rint(r, 0, len(list) - 1)]
}

build_scene :: proc(p: Preset, seed: u64, scale: f64) -> Scene {
	r := Rng{seed}
	s := Scene {
		dpi         = (p.dpi if p.dpi > 0 else 300) * scale,
		seed        = seed,
		bed         = RGB{0.95, 0.955, 0.96} + RGB{rrange(&r, -0.02, 0.02), rrange(&r, -0.01, 0.01), rrange(&r, -0.02, 0.02)},
		shadow      = {rrange(&r, -0.6, 0.6), rrange(&r, 1.5, 2.8)} * scale,
		shadow_dark = rrange(&r, 0.15, 0.3),
		lpi         = rrange(&r, 133, 175),
		dot_gain    = rrange(&r, 0.08, 0.18),
		blur_sigma  = rrange(&r, 0.7, 1.05) * scale,
		noise_sd    = rrange(&r, 0.8, 1.8),
		line_sd     = rrange(&r, 0.2, 0.7),
		tint        = {1 + rrange(&r, -0.02, 0.02), 1, 1 + rrange(&r, -0.02, 0.02)},
	}
	s.w = int(math.round((p.page_w if p.page_w > 0 else 8.5) * s.dpi))
	s.h = int(math.round((p.page_h if p.page_h > 0 else 11.69) * s.dpi))
	if p.lid_strip {
		s.lid_top = rrange(&r, 4, 14) * scale
		s.lid_left = rrange(&r, 3, 12) * scale
	}
	cw, ch := p.card_w * s.dpi, p.card_h * s.dpi
	// Column x positions and row y positions with per-gap randomness.
	gap :: proc(r: ^Rng, p: Preset, scale: f64) -> f64 {
		if rf(r) < p.touch_chance do return 0
		return rrange(r, p.gap_min, p.gap_max) * scale
	}
	xs := make([]f64, p.cols, context.temp_allocator)
	ys := make([]f64, p.rows, context.temp_allocator)
	total_w := cw * f64(p.cols)
	for i in 1 ..< p.cols do xs[i] = xs[i - 1] + cw + gap(&r, p, scale)
	total_w = xs[p.cols - 1] + cw
	for i in 1 ..< p.rows do ys[i] = ys[i - 1] + ch + gap(&r, p, scale)
	total_h := ys[p.rows - 1] + ch
	ox := max(s.lid_left, rrange(&r, 0.02, 0.5) * s.dpi)
	if p.clip_right do ox = f64(s.w) - total_w + rrange(&r, 0.03, 0.12) * s.dpi // last column runs off the edge
	oy := max(s.lid_top, rrange(&r, 0.0, 0.6) * s.dpi)
	if total_h + oy > f64(s.h) do oy = max(0, f64(s.h) - total_h - 4)
	_ = total_w
	for row in 0 ..< p.rows {
		for col in 0 ..< p.cols {
			c := Card {
				w          = p.card_w,
				h          = p.card_h,
				radius     = p.radius,
				angle      = rrange(&r, -p.rot_deg, p.rot_deg) * math.PI / 180,
				style      = pick_style(&r, p.styles),
				edge_white = rf(&r) < 0.5,
				seed       = next_u64(&r),
			}
			c.ca, c.sa = math.cos(c.angle), math.sin(c.angle)
			c.center = {ox + xs[col] + cw / 2 + rrange(&r, -2, 2) * scale, oy + ys[row] + ch / 2 + rrange(&r, -2, 2) * scale}
			corners := card_corners(&c, s.dpi)
			c.bbox = {math.INF_F64, math.INF_F64, -math.INF_F64, -math.INF_F64}
			for q in corners {
				c.bbox = {min(c.bbox[0], q.x), min(c.bbox[1], q.y), max(c.bbox[2], q.x), max(c.bbox[3], q.y)}
			}
			append(&s.cards, c)
		}
	}
	// Overlaps stack in a random order.
	for i := len(s.cards) - 1; i > 0; i -= 1 {
		j := rint(&r, 0, i)
		if p.gap_min < 0 do s.cards[i], s.cards[j] = s.cards[j], s.cards[i]
	}
	for &c in s.cards {
		cr := Rng{c.seed}
		render_card_raster(&c, &cr)
	}
	return s
}

// Ground truth: each card's outer-edge corners in scan pixel indices
// (pixel centres), clamped to the image like the annotation tools do.
ground_truth :: proc(s: ^Scene, b: ^strings.Builder) {
	// Reading order: rows by centre y, then x.
	order := make([dynamic]int, context.temp_allocator)
	for _, i in s.cards do append(&order, i)
	ch := s.cards[0].h * s.dpi
	for i in 1 ..< len(order) {
		for j := i; j > 0; j -= 1 {
			a, c := s.cards[order[j - 1]].center, s.cards[order[j]].center
			same_row := abs(a.y - c.y) < ch * 0.35
			if (same_row && c.x < a.x) || (!same_row && c.y < a.y) {
				order[j - 1], order[j] = order[j], order[j - 1]
			} else do break
		}
	}
	fmt.sbprint(b, "[")
	for idx, n in order {
		corners := card_corners(&s.cards[idx], s.dpi)
		fmt.sbprintf(b, "%s[", "," if n > 0 else "")
		for q, k in corners {
			x := clamp(q.x - 0.5, 0, f64(s.w - 1))
			y := clamp(q.y - 0.5, 0, f64(s.h - 1))
			fmt.sbprintf(b, "%s[%.2f,%.2f]", "," if k > 0 else "", x, y)
		}
		fmt.sbprint(b, "]")
	}
	fmt.sbprint(b, "]")
}

save_png :: proc(path: string, img: im.Image) -> bool {
	return rl.ExportImage(rl.Image{raw_data(img.pix), i32(img.w), i32(img.h), 1, .UNCOMPRESSED_R8G8B8A8}, fmt.ctprintf("%s", path))
}

main :: proc() {
	args := os.args[1:]
	if len(args) < 1 {
		fmt.eprintln("usage: synth OUTDIR [--clean] [--only PRESET] [--scale S] [--count N]")
		os.exit(2)
	}
	out_dir := args[0]
	clean := false
	only := ""
	scale := 1.0
	count := 2 // scans per preset per split
	for i := 1; i < len(args); i += 1 {
		switch args[i] {
		case "--clean": clean = true
		case "--only": i += 1; only = args[i]
		case "--scale": i += 1; scale = f64(parse_f(args[i]))
		case "--count": i += 1; count = int(parse_f(args[i]))
		}
	}
	rl.SetTraceLogLevel(.WARNING)
	_ = os.make_directory_all(out_dir)
	b := strings.builder_make()
	fmt.sbprint(&b, "{\"generator\": \"tools/synth\", \"scans\": [")
	first := true
	for p, pi in PRESETS {
		if only != "" && only != p.name do continue
		if only == "" && p.small do continue
		for split, si in ([2]string{"development", "holdout"}) {
			for n in 0 ..< count {
				seed := u64(1000003 * (pi + 1) + 7919 * si + n)
				s := build_scene(p, seed, scale)
				name := fmt.tprintf("%s-%s-%d", p.name, split, n + 1)
				lin := render_scan(&s, true)
				blur3(lin, s.w, s.h, s.blur_sigma)
				img := to_rgba8(&s, lin, true)
				path, _ := os.join_path({out_dir, fmt.tprintf("%s.png", name)}, context.temp_allocator)
				save_png(path, img)
				im.image_destroy(&img)
				delete(lin)
				clean_name := ""
				if clean {
					cl := render_scan(&s, false)
					blur3(cl, s.w, s.h, s.blur_sigma)
					cimg := to_rgba8(&s, cl, false)
					clean_name = fmt.tprintf("%s-clean.png", name)
					cpath, _ := os.join_path({out_dir, clean_name}, context.temp_allocator)
					save_png(cpath, cimg)
					im.image_destroy(&cimg)
					delete(cl)
				}
				fmt.sbprintf(&b, "%s\n {{\"id\": \"%s\", \"split\": \"%s\", \"preset\": \"%s\", \"image\": \"%s.png\", \"clean\": \"%s\", \"width\": %d, \"height\": %d, \"regions\": ",
					"" if first else ",", name, split, p.name, name, clean_name, s.w, s.h)
				ground_truth(&s, &b)
				fmt.sbprint(&b, "}")
				first = false
				fmt.printfln("%s  %dx%d  %d cards", name, s.w, s.h, len(s.cards))
				for &c in s.cards do delete(c.cmyk)
				delete(s.cards)
				free_all(context.temp_allocator)
			}
		}
	}
	fmt.sbprint(&b, "\n]}\n")
	ann, _ := os.join_path({out_dir, "annotations.json"}, context.temp_allocator)
	_ = os.write_entire_file(ann, transmute([]u8)strings.to_string(b))
}

parse_f :: proc(s: string) -> f64 {
	v := 0.0
	frac := 0.0
	div := 1.0
	for ch in s {
		if ch == '.' {frac = 1; continue}
		if ch < '0' || ch > '9' do continue
		if frac > 0 {div *= 10; v += f64(ch - '0') / div} else do v = v * 10 + f64(ch - '0')
	}
	return v
}
