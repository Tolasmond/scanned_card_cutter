// Right-hand control panel.
package main

import "core:fmt"
import "core:os"
import im "imaging"
import rl "vendor:raylib"

FIELD_W :: 1
FIELD_H :: 2
FIELD_RADIUS :: 3
FIELD_TRIM :: 4
FIELD_DIR :: 5
FIELD_PREFIX :: 6

@(private = "file")
section :: proc(x, y: ^f32, w: f32, title: cstring) {
	y^ += 6
	rl.GuiLine({x^, y^, w, 20}, title)
	y^ += 26
}

// Value box with label; tracks which box is being edited in app.edit_field.
@(private = "file")
value_field :: proc(app: ^App, id: int, r: rl.Rectangle, label: cstring, value: ^i32, lo, hi: i32) {
	lw := f32(rl.MeasureText(label, 20)) + 8
	rl.GuiLabel({r.x, r.y, lw, r.height}, label)
	before := value^
	if rl.GuiValueBox({r.x + lw, r.y, r.width - lw, r.height}, nil, value, lo, hi, app.edit_field == id) != 0 {
		app.edit_field = 0 if app.edit_field == id else id
	}
	if value^ != before do mark_preview_dirty(app)
}

@(private = "file")
text_field :: proc(app: ^App, id: int, r: rl.Rectangle, buf: []u8) {
	if rl.GuiTextBox(r, cstring(raw_data(buf)), i32(len(buf)), app.edit_field == id) {
		app.edit_field = 0 if app.edit_field == id else id
	}
	if app.edit_field == id do app.typing = true
}

draw_panel :: proc(app: ^App) {
	sw, sh := f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())
	px := sw - PANEL_W
	rl.DrawRectangleRec({px, 0, PANEL_W, sh - STATUS_H}, {245, 245, 245, 255})
	rl.DrawLineEx({px, 0}, {px, sh - STATUS_H}, 1, rl.GRAY)
	x := px + PAD
	w := f32(PANEL_W - PAD * 2)
	half := (w - 8) / 2
	y := f32(PAD)
	busy := app.job != nil

	// --- Scan ---------------------------------------------------------------
	if busy do rl.GuiDisable()
	if rl.GuiButton({x, y, w, ROW + 4}, "#1#Open scan...  (Ctrl+O)") do open_scan_dialog(app)
	rl.GuiEnable()
	y += ROW + 10
	if has_scan(app) {
		name := fmt.ctprintf("%s  (%d x %d)", os.base(app.scan_path), app.scan.width, app.scan.height)
		rl.GuiLabel({x, y, w, 22}, name)
		y += 24
	}

	// --- Output size ----------------------------------------------------------
	section(&x, &y, w, "Card output (pixels)")
	value_field(app, FIELD_W, {x, y, half, ROW}, "Width", &app.out_w, 1, 20000)
	value_field(app, FIELD_H, {x + half + 8, y, half, ROW}, "Height", &app.out_h, 1, 20000)
	y += ROW + 6
	value_field(app, FIELD_RADIUS, {x, y, half, ROW}, "Radius", &app.radius, 0, 10000)
	value_field(app, FIELD_TRIM, {x + half + 8, y, half, ROW}, "Trim", &app.trim, 0, 1000)
	y += ROW + 6
	app.radius = clamp(app.radius, 0, min(app.out_w, app.out_h) / 2)
	if app.selected < 0 do rl.GuiDisable()
	if rl.GuiButton({x, y, w, ROW}, "Use selected card's scanned size") && app.selected >= 0 {
		nw, nh := im.quad_native_size(app.regions[app.selected].corners)
		app.out_w = i32(nw - 2 * int(app.trim))
		app.out_h = i32(nh - 2 * int(app.trim))
		mark_preview_dirty(app)
	}
	rl.GuiEnable()
	y += ROW + 4

	// --- Cards ----------------------------------------------------------------
	section(&x, &y, w, fmt.ctprintf("Cards (%d)", len(app.regions)))
	if !has_scan(app) do rl.GuiDisable()
	if app.placing {
		if rl.GuiButton({x, y, half, ROW}, "Cancel add (Esc)") {
			app.placing = false
			clear(&app.place_pts)
		}
	} else if rl.GuiButton({x, y, half, ROW}, "Add card (A)") do start_placing(app)
	if app.selected < 0 do rl.GuiDisable()
	if rl.GuiButton({x + half + 8, y, half, ROW}, "Delete (Del)") do delete_selected(app)
	y += ROW + 6
	if rl.GuiButton({x, y, half, ROW}, "Rotate (R)") && app.selected >= 0 {
		rotate_region(&app.regions[app.selected], 1)
		mark_preview_dirty(app)
	}
	if rl.GuiButton({x + half + 8, y, half, ROW}, "Full preview (P)") do toggle_big_preview(app)
	rl.GuiEnable()
	y += ROW + 8

	// Card list
	list_h := f32(4 * 26)
	list := rl.Rectangle{x, y, w, list_h}
	rl.DrawRectangleRec(list, rl.WHITE)
	rl.DrawRectangleLinesEx(list, 1, rl.LIGHTGRAY)
	@(static) list_scroll: f32
	mouse := rl.GetMousePosition()
	if rl.CheckCollisionPointRec(mouse, list) do list_scroll -= rl.GetMouseWheelMove() * 26
	list_scroll = clamp(list_scroll, 0, max(0, f32(len(app.regions)) * 26 - list_h))
	rl.BeginScissorMode(i32(list.x), i32(list.y), i32(list.width), i32(list.height))
	for r, i in app.regions {
		ry := list.y + f32(i) * 26 - list_scroll
		row := rl.Rectangle{list.x + 1, ry, list.width - 2, 26}
		if i == app.selected do rl.DrawRectangleRec(row, {255, 236, 150, 255})
		nw, nh := im.quad_native_size(r.corners)
		rl.DrawText(fmt.ctprintf("%2d   scanned %d x %d", i + 1, nw, nh), i32(row.x + 8), i32(ry + 3), 20, rl.DARKGRAY)
		if !rl.GuiIsLocked() && rl.CheckCollisionPointRec(mouse, row) && rl.CheckCollisionPointRec(mouse, list) && rl.IsMouseButtonPressed(.LEFT) {
			select_region(app, i)
		}
	}
	rl.EndScissorMode()
	y += list_h + 8

	// --- Preview (fills the space between the card list and the export block) ---
	EXPORT_BLOCK_H :: ROW * 5 + 46
	export_y := sh - STATUS_H - PAD - EXPORT_BLOCK_H
	if export_y - y >= 32 + 80 {
		section(&x, &y, w, "Preview")
		avail := rl.Rectangle{x, y, w, export_y - y - 8}
		if app.preview.id != 0 {
			pw, ph := f32(app.preview.width), f32(app.preview.height)
			s := min(avail.width / pw, avail.height / ph, 1)
			dst := rl.Rectangle{x + (w - pw * s) / 2, y, pw * s, ph * s}
			draw_checker(dst)
			rl.DrawTexturePro(app.preview, {0, 0, pw, ph}, dst, {}, 0, rl.WHITE)
		} else {
			msg: cstring = "Select a card" if app.selected < 0 else "Invalid card shape"
			rl.DrawText(msg, i32(x + 8), i32(y + 8), 20, rl.GRAY)
		}
	} else {
		// Window too short for an inline preview; Full preview (P) still works.
		export_y = y
	}

	// --- Export (pinned to the bottom) -------------------------------------------
	y = export_y
	section(&x, &y, w, "Export")
	rl.GuiLabel({x, y, w, 22}, "Folder")
	y += 24
	text_field(app, FIELD_DIR, {x, y, w - 98, ROW}, app.out_dir[:])
	if rl.GuiButton({x + w - 90, y, 90, ROW}, "Browse") do open_folder_dialog(app)
	y += ROW + 6
	rl.GuiLabel({x, y, 120, ROW}, "File prefix")
	text_field(app, FIELD_PREFIX, {x + 110, y, w - 110, ROW}, app.prefix[:])
	y += ROW + 4
	prefix := buf_string(app.prefix[:])
	example := fmt.ctprintf("Files: %s_01.png, %s_02.png ...", prefix if prefix != "" else "card", prefix if prefix != "" else "card")
	rl.DrawText(example, i32(x), i32(y + 2), 20, rl.GRAY)
	y += 26
	if busy {
		done, total, _ := export_progress(app.job)
		v := f32(done)
		rl.GuiProgressBar({x, y, w, ROW + 4}, nil, nil, &v, 0, f32(max(total, 1)))
		rl.DrawText(fmt.ctprintf("Exporting %d / %d", done, total), i32(x + 10), i32(y + 7), 20, rl.BLACK)
	} else {
		if len(app.regions) == 0 do rl.GuiDisable()
		if rl.GuiButton({x, y, w, ROW + 4}, fmt.ctprintf("Export %d card(s)  (Ctrl+E)", len(app.regions))) do request_export(app)
		rl.GuiEnable()
	}
}
