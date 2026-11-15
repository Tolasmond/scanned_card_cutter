// UI scaling for high-density monitors.
//
// Every layout size is written for 1x and multiplied by `ui_scale`; the fonts
// are re-rasterized at the matching pixel size (see fonts.odin).
package main

import "core:math"
import rl "vendor:raylib"

UI_SCALE_STEP :: 0.25
UI_SCALE_MIN :: 1.0
UI_SCALE_MAX :: 4.0

// Current scale and the sizes derived from it. Read everywhere; written only by ui_apply_scale.
ui_scale: f32 = 1
panel_w: f32 = 380
status_h: f32 = 32
pad: f32 = 12
row_h: f32 = 30

Ui_Scale_State :: struct {
	fixed:   bool, // record/replay: the layout must not depend on the monitor
	manual:  f32, // 0 = follow the monitor
	monitor: i32, // monitor the auto scale was computed for
	checked: int, // frame counter for the monitor check
	// raygui's per-control 1x values, so every scale is computed from the same base.
	base_padding: [rl.GuiControl]i32,
	base_border:  [rl.GuiControl]i32,
}

// Scales a 1x layout size.
S :: #force_inline proc(v: f32) -> f32 {
	return v * ui_scale
}

// Scales a 1x font size.
fs :: #force_inline proc(base: i32) -> i32 {
	return i32(math.round(f32(base) * ui_scale))
}

@(private = "file")
snap_scale :: proc(v: f32) -> f32 {
	return clamp(math.round(v / UI_SCALE_STEP) * UI_SCALE_STEP, UI_SCALE_MIN, UI_SCALE_MAX)
}

// Picks a scale for the monitor the window is on.
detect_ui_scale :: proc() -> f32 {
	when ODIN_OS == .Darwin {
		return 1 // macOS lays windows out in points and scales them itself
	} else {
		os_scale := rl.GetWindowScaleDPI().x
		when ODIN_OS == .Windows {
			return snap_scale(os_scale) // the user's display setting is authoritative
		} else {
			if os_scale > 1.01 do return snap_scale(os_scale) // e.g. Xft.dpi is set
			// No OS hint (typical under XWayland): use the monitor's pixel density,
			// in whole steps: ~96-150 dpi -> 1x, ~150-250 dpi -> 2x, and so on.
			m := rl.GetCurrentMonitor()
			px, mm := rl.GetMonitorWidth(m), rl.GetMonitorPhysicalWidth(m)
			if px <= 0 || mm <= 0 do return 1
			dpi := f32(px) * 25.4 / f32(mm)
			if dpi < 50 || dpi > 600 do return 1 // implausible size data from the monitor
			return clamp(math.floor(dpi / 96 + 0.4), UI_SCALE_MIN, UI_SCALE_MAX)
		}
	}
}

ui_scale_init :: proc(st: ^Ui_Scale_State, fixed: bool) {
	st.fixed = fixed
	for c in rl.GuiControl {
		st.base_padding[c] = rl.GuiGetStyle(c, i32(rl.GuiControlProperty.TEXT_PADDING))
		st.base_border[c] = rl.GuiGetStyle(c, i32(rl.GuiControlProperty.BORDER_WIDTH))
	}
	st.monitor = rl.GetCurrentMonitor()
	ui_apply_scale(st, 1 if fixed else detect_ui_scale())
}

ui_apply_scale :: proc(st: ^Ui_Scale_State, s: f32) {
	ui_scale = s
	panel_w = S(380)
	status_h = S(32)
	pad = S(12)
	row_h = S(30)
	for c in rl.GuiControl {
		rl.GuiSetStyle(c, i32(rl.GuiControlProperty.TEXT_PADDING), i32(math.round(f32(st.base_padding[c]) * s)))
		rl.GuiSetStyle(c, i32(rl.GuiControlProperty.BORDER_WIDTH), i32(math.round(f32(st.base_border[c]) * s)))
	}
	rl.GuiSetIconScale(max(1, i32(s)))
	fonts_update()
}

// The scale the user picked, or the monitor's.
ui_target_scale :: proc(st: ^Ui_Scale_State) -> f32 {
	if st.manual > 0 do return st.manual
	return 1 if st.fixed else detect_ui_scale()
}

// Once per frame: follow the window to another monitor. Returns true when the scale changed.
ui_scale_update :: proc(st: ^Ui_Scale_State) -> bool {
	if st.fixed || st.manual > 0 do return false
	st.checked += 1
	if st.checked % 30 != 0 do return false // querying monitors is not free on X11
	m := rl.GetCurrentMonitor()
	if m == st.monitor do return false
	st.monitor = m
	s := detect_ui_scale()
	if s == ui_scale do return false
	ui_apply_scale(st, s)
	return true
}

// Ctrl+= / Ctrl+- step the scale; Ctrl+0 returns to following the monitor.
// Returns true when the scale changed.
ui_scale_keys :: proc(st: ^Ui_Scale_State, ctrl: bool) -> bool {
	if !ctrl do return false
	s := ui_scale
	switch {
	case rl.IsKeyPressed(.EQUAL) || rl.IsKeyPressed(.KP_ADD):
		st.manual = min(ui_scale + UI_SCALE_STEP, UI_SCALE_MAX)
	case rl.IsKeyPressed(.MINUS) || rl.IsKeyPressed(.KP_SUBTRACT):
		st.manual = max(ui_scale - UI_SCALE_STEP, UI_SCALE_MIN)
	case rl.IsKeyPressed(.ZERO) || rl.IsKeyPressed(.KP_0):
		st.manual = 0
	case:
		return false
	}
	target := ui_target_scale(st)
	if target != s do ui_apply_scale(st, target)
	return true
}

// Sizes a resizable window for the scale, within the monitor it is on.
ui_size_window :: proc(base_w, base_h: f32) {
	m := rl.GetCurrentMonitor()
	mw, mh := f32(rl.GetMonitorWidth(m)), f32(rl.GetMonitorHeight(m))
	w, h := S(base_w), S(base_h)
	if mw > 0 && mh > 0 {
		w = min(w, mw * 0.9)
		h = min(h, mh * 0.9)
	}
	rl.SetWindowSize(i32(w), i32(h))
	rl.SetWindowMinSize(i32(min(S(900), w)), i32(min(S(650), h)))
	if mw > 0 && mh > 0 {
		pos := rl.GetMonitorPosition(m)
		rl.SetWindowPosition(i32(pos.x + (mw - w) / 2), i32(pos.y + (mh - h) / 2))
	}
}

// A dialog frame drawn at the current scale (raygui's window box has a fixed
// 24 px title bar). Returns the content area; `closed` is set when the title
// bar's close button is clicked.
dialog_frame :: proc(r: rl.Rectangle, title: cstring) -> (content: rl.Rectangle, closed: bool) {
	bar := S(36)
	rl.DrawRectangleRec(r, rl.GetColor(u32(rl.GuiGetStyle(.DEFAULT, i32(rl.GuiDefaultProperty.BACKGROUND_COLOR)))))
	rl.GuiStatusBar({r.x, r.y, r.width, bar}, title)
	rl.DrawRectangleLinesEx(r, max(1, S(1)), rl.GetColor(u32(rl.GuiGetStyle(.DEFAULT, i32(rl.GuiControlProperty.BORDER_COLOR_NORMAL)))))
	b := bar - S(8)
	closed = rl.GuiButton({r.x + r.width - b - S(4), r.y + S(4), b, b}, "x")
	return {r.x, r.y + bar, r.width, r.height - bar}, closed
}
