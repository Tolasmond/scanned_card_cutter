// Keyboard focus for the panel's controls: Tab / Shift+Tab move between them,
// Enter or Space presses the focused button, Esc hands the keys back to the canvas.
package main

import rl "vendor:raylib"

// Panel controls in Tab order. .None means the canvas has the keys.
Focus :: enum {
	None,
	Open,
	Scan,
	Scanner,
	Width,
	Height,
	Radius,
	Trim,
	Use_Size,
	Moire,
	Add,
	Delete,
	Rotate,
	Full_Preview,
	Detect,
	Cards,
	Folder,
	Browse,
	Prefix,
	Export,
	Exit,
}

Focus_Set :: bit_set[Focus]

// Text and number boxes: focusing one starts editing it.
FOCUS_FIELDS :: Focus_Set{.Width, .Height, .Radius, .Trim, .Folder, .Prefix}

COLOR_FOCUS :: rl.Color{30, 110, 230, 255}

// The control after (or before) cur among the available ones, wrapping around.
next_focus :: proc(cur: Focus, avail: Focus_Set, back: bool) -> Focus {
	n := len(Focus)
	i := int(cur)
	for _ in 0 ..< n {
		i = (i + (n - 1 if back else 1)) % n
		if Focus(i) in avail do return Focus(i)
	}
	return .None
}

// Handles the focus keys before the canvas sees any key. Returns true when the
// frame's keys were used here, so the canvas shortcuts must not run.
handle_focus_keys :: proc(app: ^App) -> bool {
	app.focus_activate = false
	// A click moves focus away from the panel; a clicked text box takes it back.
	if rl.IsMouseButtonPressed(.LEFT) do app.focus = .None
	shift := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)

	if rl.IsKeyPressed(.TAB) {
		app.edit_field = .None
		app.focus = next_focus(app.focus, app.focus_avail, shift)
		app.focus_moved = true
		if app.focus in FOCUS_FIELDS do app.edit_field = app.focus
		return true
	}
	if app.focus == .None do return false
	if app.edit_field != .None {
		// The box itself handles typing and Enter; Esc stops editing but keeps focus.
		if rl.IsKeyPressed(.ESCAPE) {
			app.edit_field = .None
			return true
		}
		return false
	}
	if rl.IsKeyPressed(.ESCAPE) {
		app.focus = .None
		return true
	}
	enter := rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER)
	if app.focus in FOCUS_FIELDS {
		// Enter edits the box again after Esc or Enter ended an edit. Space would
		// type itself into a text box, so it only starts editing via Enter.
		if enter {
			app.edit_field = app.focus
			app.edit_fresh = true // the box must not take this Enter as "done"
		}
		if enter || rl.IsKeyPressed(.SPACE) do return true
	} else if enter || rl.IsKeyPressed(.SPACE) {
		app.focus_activate = true
		return true
	}
	if app.focus == .Cards && len(app.regions) > 0 {
		n := len(app.regions)
		step := 0
		if rl.IsKeyPressed(.UP) || rl.IsKeyPressedRepeat(.UP) do step = -1
		if rl.IsKeyPressed(.DOWN) || rl.IsKeyPressedRepeat(.DOWN) do step = 1
		if step != 0 {
			i := (n - 1 if step < 0 else 0) if app.selected < 0 else clamp(app.selected + step, 0, n - 1)
			select_region(app, i)
			app.focus_moved = true
			return true
		}
	}
	return false
}

// Starts a frame's panel: controls drawn from here on register as focusable.
focus_begin_frame :: proc(app: ^App) {
	app.focus_avail = {}
}

focus_end_frame :: proc(app: ^App) {
	app.edit_fresh = false
	app.focus_moved = false
}

// Registers control id at r. Returns true when it has focus and can be used.
// in_panel scrolls the panel to show it when focus has just moved to it.
focus_control :: proc(app: ^App, id: Focus, r: rl.Rectangle, in_panel := true) -> bool {
	enabled := rl.GuiGetState() != i32(rl.GuiState.STATE_DISABLED) && !rl.GuiIsLocked()
	if enabled do app.focus_avail += {id}
	if app.focus != id do return false
	g := S(3)
	rl.DrawRectangleLinesEx({r.x - g, r.y - g, r.width + 2 * g, r.height + 2 * g}, max(2, S(2)), COLOR_FOCUS)
	if in_panel && app.focus_moved {
		top, bottom := pad, f32(rl.GetScreenHeight()) - status_h - pad
		if r.y - g < top do app.panel_scroll -= top - (r.y - g)
		else if r.y + r.height + g > bottom do app.panel_scroll += r.y + r.height + g - bottom
	}
	return enabled
}

// Takes this frame's Enter/Space press if id has focus.
focus_activated :: proc(app: ^App, focused: bool) -> bool {
	if !focused || !app.focus_activate do return false
	app.focus_activate = false
	return true
}

// A raygui button that Tab can reach.
focus_button :: proc(app: ^App, id: Focus, r: rl.Rectangle, text: cstring, in_panel := true) -> bool {
	clicked := rl.GuiButton(r, text)
	focused := focus_control(app, id, r, in_panel)
	return clicked || focus_activated(app, focused)
}
