// Right-hand control panel.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import im "imaging"
import rl "vendor:raylib"

@(private = "file")
section :: proc(x, y: ^f32, w: f32, title: cstring) {
	y^ += S(6)
	rl.GuiLine({x^, y^, w, S(20)}, title)
	y^ += S(26)
}

// A box toggled its edit mode (clicked, or Enter/click outside while editing).
@(private = "file")
toggle_edit :: proc(app: ^App, id: Focus) {
	if app.edit_field == id {
		if !app.edit_fresh do app.edit_field = .None
	} else {
		app.edit_field = id
	}
}

// Value box with label; tracks which box is being edited in app.edit_field.
@(private = "file")
value_field :: proc(app: ^App, id: Focus, r: rl.Rectangle, label: cstring, value: ^i32, lo, hi: i32) {
	lw := measure_text(label) + S(8)
	rl.GuiLabel({r.x, r.y, lw, r.height}, label)
	before := value^
	box := rl.Rectangle{r.x + lw, r.y, r.width - lw, r.height}
	if rl.GuiValueBox(box, nil, value, lo, hi, app.edit_field == id) != 0 do toggle_edit(app, id)
	// raygui clamps only when Enter or a click ends the edit, not when Tab does.
	if app.edit_field != id do value^ = clamp(value^, lo, hi)
	if app.edit_field == id do app.focus = id
	focus_control(app, id, box)
	if value^ != before do mark_preview_dirty(app)
}

@(private = "file")
text_field :: proc(app: ^App, id: Focus, r: rl.Rectangle, buf: []u8) {
	if rl.GuiTextBox(r, cstring(raw_data(buf)), i32(len(buf)), app.edit_field == id) do toggle_edit(app, id)
	if app.edit_field == id {
		app.typing = true
		app.focus = id
	}
	focus_control(app, id, r)
}

draw_panel :: proc(app: ^App) {
	sw, sh := f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())
	px := sw - panel_w
	panel_h := sh - status_h
	rl.DrawRectangleRec({px, 0, panel_w, panel_h}, {245, 245, 245, 255})
	rl.DrawLineEx({px, 0}, {px, panel_h}, max(1, S(1)), rl.GRAY)
	x := px + pad
	w := panel_w - pad * 2
	gap := S(8)
	half := (w - gap) / 2
	// When the window is too short for everything, the panel scrolls.
	y := pad - app.panel_scroll
	rl.BeginScissorMode(i32(px), 0, i32(panel_w), i32(panel_h))
	defer rl.EndScissorMode()
	busy := app.job != nil
	ROW := row_h
	LINE := S(26) // one line of 20 px text in lists

	// --- Scan ---------------------------------------------------------------
	focus_begin_frame(app)
	// Open and Scan share a row, so the controls below stay where recordings click.
	scanning := app.scan_job != nil
	if busy || scanning do rl.GuiDisable()
	if focus_button(app, .Open, {x, y, half, ROW + S(4)}, "#1#Open...  (Ctrl+O)") do open_scan_dialog(app)
	rl.GuiEnable()
	if !app.scanning_allowed || busy do rl.GuiDisable()
	scan_label: cstring = "#113#Cancel scan" if scanning else "#183#Scan  (Ctrl+N)"
	if focus_button(app, .Scan, {x + half + gap, y, half, ROW + S(4)}, scan_label) {
		if scanning do cancel_scan(app)
		else do start_scan(app)
	}
	rl.GuiEnable()
	y += ROW + S(10)
	// Several scanner profiles: pick one (click or Enter cycles through them).
	if len(app.scanners) > 1 {
		names := make([dynamic]string, context.temp_allocator)
		for p in app.scanners {
			n, _ := strings.replace_all(p.name, ";", ",", context.temp_allocator) // raygui separates items with ;
			append(&names, n)
		}
		label_w := S(70)
		rl.GuiLabel({x, y, label_w, ROW}, "Scanner")
		box := rl.Rectangle{x + label_w, y, w - label_w, ROW}
		if scanning do rl.GuiDisable()
		active := i32(app.scanner_index)
		rl.GuiComboBox(box, strings.clone_to_cstring(strings.join(names[:], ";", context.temp_allocator), context.temp_allocator), &active)
		if focus_activated(app, focus_control(app, .Scanner, box)) do active = (active + 1) % i32(len(app.scanners))
		rl.GuiEnable()
		app.scanner_index = int(active)
		y += ROW + S(6)
	}
	if has_scan(app) {
		name := fmt.ctprintf("%s  (%d × %d)", os.base(app.scan_path), app.scan.width, app.scan.height)
		rl.GuiLabel({x, y, w, S(22)}, name)
		y += S(24)
	}

	// --- Output size ----------------------------------------------------------
	section(&x, &y, w, "Card output (pixels)")
	value_field(app, .Width, {x, y, half, ROW}, "Width", &app.out_w, 1, 20000)
	value_field(app, .Height, {x + half + gap, y, half, ROW}, "Height", &app.out_h, 1, 20000)
	y += ROW + S(6)
	value_field(app, .Radius, {x, y, half, ROW}, "Radius", &app.radius, 0, 10000)
	value_field(app, .Trim, {x + half + gap, y, half, ROW}, "Trim", &app.trim, 0, 1000)
	y += ROW + S(6)
	app.radius = clamp(app.radius, 0, min(app.out_w, app.out_h) / 2)
	if app.selected < 0 do rl.GuiDisable()
	if focus_button(app, .Use_Size, {x, y, half, ROW}, "Use card's size") && app.selected >= 0 {
		nw, nh := im.quad_native_size(app.regions[app.selected].corners)
		app.out_w = i32(nw - 2 * int(app.trim))
		app.out_h = i32(nh - 2 * int(app.trim))
		mark_preview_dirty(app)
	}
	rl.GuiEnable()
	// Moiré (halftone) removal, with progress while it runs.
	moire := app.moire
	box := S(20)
	moire_label := fmt.ctprintf("Remove moiré %d%%", moire_percent(app)) if app.moire && app.clean_job != nil else cstring("Remove moiré (M)")
	moire_box := rl.Rectangle{x + half + gap, y + (ROW - box) / 2, box, box}
	rl.GuiCheckBox(moire_box, moire_label, &moire)
	moire_focus := rl.Rectangle{moire_box.x, moire_box.y, box + S(6) + measure_text(moire_label), box}
	if focus_activated(app, focus_control(app, .Moire, moire_focus)) do moire = !moire
	if moire != app.moire do set_moire(app, moire)
	y += ROW + S(4)

	// --- Cards ----------------------------------------------------------------
	section(&x, &y, w, fmt.ctprintf("Cards (%d)", len(app.regions)))
	if !has_scan(app) do rl.GuiDisable()
	if app.placing {
		if focus_button(app, .Add, {x, y, half, ROW}, "Cancel add (Esc)") {
			app.placing = false
			clear(&app.place_pts)
		}
	} else if focus_button(app, .Add, {x, y, half, ROW}, "Add card (A)") do start_placing(app)
	if app.selected < 0 do rl.GuiDisable()
	if focus_button(app, .Delete, {x + half + gap, y, half, ROW}, "Delete (Del)") do delete_selected(app)
	y += ROW + S(6)
	if focus_button(app, .Rotate, {x, y, half, ROW}, "Rotate (R)") && app.selected >= 0 {
		rotate_region(&app.regions[app.selected], 1)
		app.regions[app.selected].review = false
		mark_preview_dirty(app)
	}
	if focus_button(app, .Full_Preview, {x + half + gap, y, half, ROW}, "Full preview (P)") do toggle_big_preview(app)
	rl.GuiEnable()
	y += ROW + S(6)
	if !has_scan(app) || app.detect_job != nil do rl.GuiDisable()
	if focus_button(app, .Detect, {x, y, w, ROW}, "Detecting..." if app.detect_job != nil else "Detect cards (D)") do start_detection(app)
	rl.GuiEnable()
	y += ROW + S(8)

	// Card list
	list_h := 4 * LINE
	list := rl.Rectangle{x, y, w, list_h}
	over_list := rl.CheckCollisionPointRec(rl.GetMousePosition(), list)
	rl.DrawRectangleRec(list, rl.WHITE)
	rl.DrawRectangleLinesEx(list, max(1, S(1)), rl.LIGHTGRAY)
	@(static) list_scroll: f32
	mouse := rl.GetMousePosition()
	if rl.CheckCollisionPointRec(mouse, list) do list_scroll -= rl.GetMouseWheelMove() * LINE
	if app.focus == .Cards && app.focus_moved && app.selected >= 0 {
		// Keep the card chosen with Up/Down in view.
		top := f32(app.selected) * LINE
		list_scroll = clamp(list_scroll, top + LINE - list_h, top)
	}
	list_scroll = clamp(list_scroll, 0, max(0, f32(len(app.regions)) * LINE - list_h))
	rl.BeginScissorMode(i32(list.x), i32(list.y), i32(list.width), i32(list.height))
	for r, i in app.regions {
		ry := list.y + f32(i) * LINE - list_scroll
		row := rl.Rectangle{list.x + 1, ry, list.width - 2, LINE}
		if i == app.selected do rl.DrawRectangleRec(row, {255, 236, 150, 255})
		nw, nh := im.quad_native_size(r.corners)
		num := fmt.ctprintf("%d", i + 1)
		draw_text(num, i32(row.x + S(32) - measure_text(num)), i32(ry + S(3)), rl.DARKGRAY)
		draw_text(fmt.ctprintf("scanned %d × %d", nw, nh), i32(row.x + S(44)), i32(ry + S(3)), rl.DARKGRAY)
		if r.review {
			tag: cstring = "review"
			draw_text(tag, i32(row.x + row.width - S(8) - measure_text(tag)), i32(ry + S(3)), {200, 40, 150, 255})
		}
		if !rl.GuiIsLocked() && rl.CheckCollisionPointRec(mouse, row) && rl.CheckCollisionPointRec(mouse, list) && rl.IsMouseButtonPressed(.LEFT) {
			select_region(app, i)
		}
	}
	rl.BeginScissorMode(i32(px), 0, i32(panel_w), i32(panel_h)) // back to the panel's clip
	if len(app.regions) > 0 do focus_control(app, .Cards, list)
	y += list_h + S(8)

	// --- Preview (fills the space between the card list and the export block) ---
	export_block_h := ROW * 5 + S(46)
	export_y := panel_h - pad - export_block_h
	if app.panel_scroll == 0 && export_y - y >= S(32 + 80) {
		section(&x, &y, w, "Preview")
		avail := rl.Rectangle{x, y, w, export_y - y - S(8)}
		if app.preview.id != 0 {
			pw, ph := f32(app.preview.width), f32(app.preview.height)
			s := min(avail.width / pw, avail.height / ph, 1)
			dst := rl.Rectangle{x + (w - pw * s) / 2, y, pw * s, ph * s}
			draw_checker(dst)
			rl.DrawTexturePro(app.preview, {0, 0, pw, ph}, dst, {}, 0, rl.WHITE)
		} else {
			msg: cstring = "Select a card" if app.selected < 0 else "Invalid card shape"
			draw_text(msg, i32(x + S(8)), i32(y + S(8)), rl.GRAY)
		}
	} else {
		// Window too short for an inline preview; Full preview (P) still works.
		export_y = y
	}

	// --- Export (pinned to the bottom) -------------------------------------------
	y = export_y
	section(&x, &y, w, "Export")
	rl.GuiLabel({x, y, w, S(22)}, "Folder")
	y += S(24)
	browse_w := S(90)
	text_field(app, .Folder, {x, y, w - browse_w - gap, ROW}, app.out_dir[:])
	if focus_button(app, .Browse, {x + w - browse_w, y, browse_w, ROW}, "Browse") do open_folder_dialog(app)
	y += ROW + S(6)
	label_w := S(110)
	rl.GuiLabel({x, y, S(120), ROW}, "File prefix")
	text_field(app, .Prefix, {x + label_w, y, w - label_w, ROW}, app.prefix[:])
	y += ROW + S(4)
	prefix := buf_string(app.prefix[:])
	if prefix == "" do prefix = "card"
	example := fmt.ctprintf("Files: %s_01.png, %s_02.png ...", prefix, prefix)
	if measure_text(example) > w do example = fmt.ctprintf("Files: %s_01.png ...", prefix)
	draw_text(example, i32(x), i32(y + S(2)), rl.GRAY)
	y += S(26)
	if busy {
		done, total, _ := export_progress(app.job)
		v := f32(done)
		rl.GuiProgressBar({x, y, w, ROW + S(4)}, nil, nil, &v, 0, f32(max(total, 1)))
		draw_text(fmt.ctprintf("Exporting %d / %d", done, total), i32(x + S(10)), i32(y + S(7)), rl.BLACK)
	} else {
		pending := moire_pending(app)
		if len(app.regions) == 0 || pending do rl.GuiDisable()
		export_label := fmt.ctprintf("Removing moiré... %d%%", moire_percent(app)) if pending else fmt.ctprintf("Export %d card(s)  (Ctrl+E)", len(app.regions))
		if focus_button(app, .Export, {x, y, w, ROW + S(4)}, export_label) do request_export(app)
		rl.GuiEnable()
	}

	// Scroll range: everything drawn above ends at y + one button row.
	content_h := y + ROW + S(4) + pad + app.panel_scroll
	max_scroll := max(0, content_h - panel_h)
	mouse_now := rl.GetMousePosition()
	if !rl.GuiIsLocked() && !over_list && rl.CheckCollisionPointRec(mouse_now, {px, 0, panel_w, panel_h}) {
		app.panel_scroll -= rl.GetMouseWheelMove() * S(40)
	}
	app.panel_scroll = clamp(app.panel_scroll, 0, max_scroll)
}
