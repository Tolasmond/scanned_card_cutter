package synth

import "core:math"
import "core:testing"

@(private = "file")
render_small :: proc(preset: Preset, seed: u64, halftone: bool) -> (Scene, []f32) {
	s := build_scene(preset, seed, 0.25)
	lin := render_scan(&s, halftone)
	return s, lin
}

@(private = "file")
free_scene :: proc(s: ^Scene) {
	for &c in s.cards do delete(c.cmyk)
	delete(s.cards)
}

@(private = "file")
preset_named :: proc(name: string) -> Preset {
	for p in PRESETS do if p.name == name do return p
	return PRESETS[0]
}

// The corpus must not drift: the same preset and seed give the same pixels.
@(test)
test_synth_is_deterministic :: proc(t: ^testing.T) {
	p := preset_named("packed")
	a, la := render_small(p, 42, true)
	defer {free_scene(&a); delete(la)}
	b, lb := render_small(p, 42, true)
	defer {free_scene(&b); delete(lb)}
	testing.expect_value(t, len(la), len(lb))
	same := true
	for v, i in la do if v != lb[i] {same = false; break}
	testing.expect(t, same, "same seed rendered different pixels")
	c, lc := render_small(p, 43, true)
	defer {free_scene(&c); delete(lc)}
	differs := false
	for v, i in la do if v != lc[i] {differs = true; break}
	testing.expect(t, differs, "a different seed rendered the same scan")
}

// Ground truth corners sit on the card: just inside each corner is card, just
// outside (away from the card) is bed.
@(test)
test_synth_ground_truth_matches_cards :: proc(t: ^testing.T) {
	p := preset_named("rotated")
	s := build_scene(p, 7, 0.5)
	defer free_scene(&s)
	for &c in s.cards {
		corners := card_corners(&c, s.dpi)
		center := c.center
		for q in corners {
			toward := center - q
			l := math.sqrt(toward.x * toward.x + toward.y * toward.y)
			dir := toward / l
			// Corners are rounded, so step well inside along the diagonal.
			inside, _ := card_at(&s, q + dir * (c.radius * s.dpi * 1.5))
			outside, _ := card_at(&s, q - dir * 3)
			testing.expect(t, inside >= 0, "point inside a card corner is not on a card")
			testing.expect(t, outside < 0, "point outside a card corner is on a card")
		}
	}
}

// Halftoning is what creates moiré: the halftoned render must carry far more
// high-frequency energy than the contone (clean) one.
@(test)
test_synth_halftone_adds_texture :: proc(t: ^testing.T) {
	p := preset_named("separated")
	s, ht := render_small(p, 11, true)
	defer {free_scene(&s); delete(ht)}
	s2, ct := render_small(p, 11, false)
	defer {free_scene(&s2); delete(ct)}
	hf :: proc(img: []f32, w, h: int) -> f64 {
		e := 0.0
		for y in 0 ..< h do for x in 1 ..< w {
			d := f64(img[(y * w + x) * 3 + 1] - img[(y * w + x - 1) * 3 + 1])
			e += d * d
		}
		return e
	}
	a, b := hf(ht, s.w, s.h), hf(ct, s.w, s.h)
	testing.expectf(t, a > b * 1.5, "halftone energy %.3f vs contone %.3f", a, b)
}
