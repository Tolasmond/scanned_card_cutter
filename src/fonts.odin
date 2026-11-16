// UI fonts: Inter (SIL Open Font License 1.1, see assets/fonts/Inter-LICENSE.txt),
// compiled into the executable so there is nothing to install or find at runtime.
//
// raylib rasterizes a TrueType font at one pixel size, so the fonts are
// reloaded at the exact size whenever the interface scale changes.
package main

import "core:math"
import "core:strconv"
import rl "vendor:raylib"

@(private = "file")
INTER_REGULAR := #load("../assets/fonts/Inter-Regular.ttf")
@(private = "file")
INTER_SEMIBOLD := #load("../assets/fonts/Inter-SemiBold.ttf")

UI_TEXT_SIZE :: 20 // body text at 1x
BIG_TEXT_SIZE :: 40 // card numbers on the canvas at 1x

Fonts :: struct {
	ui:       rl.Font, // Inter Regular at fs(UI_TEXT_SIZE)
	ui_size:  i32,
	big:      rl.Font, // Inter SemiBold at fs(BIG_TEXT_SIZE)
	big_size: i32,
}

fonts: Fonts

// ASCII, Latin-1 (accented letters, ×, °) and common typographic punctuation,
// enough for file names in most Western languages. Anything else draws as '?'.
@(private = "file")
font_codepoints :: proc() -> []rune {
	@(static) cps: [95 + 96 + 12]rune
	@(static) n: int
	if n == 0 {
		for r in rune(32) ..= 126 {cps[n] = r; n += 1}
		for r in rune(160) ..= 255 {cps[n] = r; n += 1}
		for r in ([]rune{'…', '–', '—', '‘', '’', '“', '”', '•', '→', '←', '↑', '↓'}) {cps[n] = r; n += 1}
	}
	return cps[:n]
}

@(private = "file")
load_font :: proc(data: []u8, size: i32) -> rl.Font {
	cps := font_codepoints()
	f := rl.LoadFontFromMemory(".ttf", raw_data(data), i32(len(data)), size, raw_data(cps), i32(len(cps)))
	rl.SetTextureFilter(f.texture, .BILINEAR)
	return f
}

// (Re)loads the fonts for the current ui_scale and hands the UI font to raygui.
fonts_update :: proc() {
	if s := fs(UI_TEXT_SIZE); s != fonts.ui_size {
		if fonts.ui_size != 0 do rl.UnloadFont(fonts.ui)
		fonts.ui = load_font(INTER_REGULAR, s)
		fonts.ui_size = s
	}
	if s := fs(BIG_TEXT_SIZE); s != fonts.big_size {
		if fonts.big_size != 0 do rl.UnloadFont(fonts.big)
		fonts.big = load_font(INTER_SEMIBOLD, s)
		fonts.big_size = s
	}
	rl.GuiSetFont(fonts.ui)
	rl.GuiSetStyle(.DEFAULT, i32(rl.GuiDefaultProperty.TEXT_SIZE), fonts.ui_size)
	rl.GuiSetStyle(.DEFAULT, i32(rl.GuiDefaultProperty.TEXT_SPACING), 0)
}

fonts_unload :: proc() {
	if fonts.ui_size != 0 do rl.UnloadFont(fonts.ui)
	if fonts.big_size != 0 do rl.UnloadFont(fonts.big)
	fonts = {}
}

// Body text at integer pixel positions (keeps the glyphs sharp).
draw_text :: proc(text: cstring, x, y: i32, color: rl.Color) {
	rl.DrawTextEx(fonts.ui, text, {f32(x), f32(y)}, f32(fonts.ui_size), 0, color)
}

measure_text :: proc(text: cstring) -> f32 {
	return rl.MeasureTextEx(fonts.ui, text, f32(fonts.ui_size), 0).x
}

// Draws n right-aligned at right_x with every digit centred in a cell as wide
// as the widest digit, so numbers line up in a column. Inter's digits are
// proportional ("1" is narrow), and raylib can't turn on its tabular figures.
draw_number_right :: proc(n: int, right_x, y: i32, color: rl.Color) {
	digits: [20]u8
	s := strconv.write_int(digits[:], i64(n), 10)
	cell: f32 = 0
	for d in u8('0') ..= u8('9') {
		one := [2]u8{d, 0}
		cell = max(cell, measure_text(cstring(&one[0])))
	}
	x := f32(right_x) - cell * f32(len(s))
	for i in 0 ..< len(s) {
		one := [2]u8{s[i], 0}
		c := cstring(&one[0])
		draw_text(c, i32(math.round(x + (cell - measure_text(c)) / 2)), y, color)
		x += cell
	}
}

draw_big_text :: proc(text: cstring, x, y: i32, color: rl.Color) {
	rl.DrawTextEx(fonts.big, text, {f32(x), f32(y)}, f32(fonts.big_size), 0, color)
}

measure_big_text :: proc(text: cstring) -> f32 {
	return rl.MeasureTextEx(fonts.big, text, f32(fonts.big_size), 0).x
}
