package main

import "core:testing"
import rl "vendor:raylib"

@(test)
test_pan_to_show :: proc(t: ^testing.T) {
	rect := rl.Rectangle{0, 0, 1000, 800}
	// Zoom 2, scan pixel (0, 0) at screen (100, 100).
	v := View{zoom = 2, offset = {100, 100}}
	// Comfortably inside: the view stays put.
	testing.expect(t, !pan_to_show(&v, {200, 150}, rect, 40))
	testing.expect_value(t, v.offset, rl.Vector2{100, 100})
	// Off-screen to the right (screen x 1300): centered.
	testing.expect(t, pan_to_show(&v, {600, 150}, rect, 40))
	testing.expect_value(t, to_screen(v, {600, 150}), rl.Vector2{500, 400})
	testing.expect_value(t, v.zoom, f32(2))
	// Visible but inside the margin (screen y 790 of 800): centered too.
	v = View{zoom = 1, offset = {0, 0}}
	testing.expect(t, pan_to_show(&v, {300, 790}, rect, 40))
	testing.expect_value(t, to_screen(v, {300, 790}), rl.Vector2{500, 400})
}
