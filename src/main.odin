// Scan Tool: extract straightened, rounded-corner card images from a flatbed scan.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import im "imaging"
import rl "vendor:raylib"

CORNER_HIT :: 16 // grab radius around a corner, screen px at 1x

main :: proc() {
	opts, ok := parse_args(os.args[1:])
	if !ok {
		fmt.eprint(USAGE)
		os.exit(2)
	}
	h: Harness
	if !harness_init(&h, opts) do os.exit(2)
	defer harness_destroy(&h)

	rl.SetConfigFlags(harness_window_flags(&h, opts.fast))
	win_w, win_h := harness_window_size(&h)
	rl.InitWindow(win_w, win_h, "Scan Tool")
	rl.SetWindowMinSize(900, 650)
	rl.SetExitKey(.KEY_NULL)
	rl.SetTargetFPS(0 if opts.fast else 60)

	app := App {
		selected       = -1,
		focused_corner = -1,
		out_w          = 750,
		out_h          = 1050,
		radius         = 36,
	}
	app.sync_jobs = h.mode != .Off
	// Record/replay keep a 1x layout: recorded clicks are window pixels.
	ui_scale_init(&app.ui, h.mode != .Off)
	if h.mode == .Off && ui_scale != 1 do ui_size_window(f32(win_w), f32(win_h))
	set_status(&app, false, "Open a scan (or drop a PNG on the window) to begin.")
	scan := h.scan if h.mode != .Off else opts.scan
	if scan != "" do load_scan(&app, scan)
	out := h.out if h.mode != .Off else opts.out
	if out != "" do buf_set(app.out_dir[:], out)
	harness_start(&h)

	for !rl.WindowShouldClose() && !app.quit {
		free_all(context.temp_allocator)
		if !harness_frame(&h, &app) do break
		poll_export(&app)
		poll_cleaning(&app)
		poll_detection(&app)
		handle_drops(&app)
		if ui_scale_update(&app.ui) do on_ui_scale_changed(&app)
		if rl.IsWindowResized() {
			if !app.view_touched do fit_view(&app)
			if app.big_tex.id != 0 do fit_view_to(&app.big_view, canvas_rect(), f32(app.big_tex.width), f32(app.big_tex.height), 1)
		}
		modal := app.browser.active || app.confirm_count > 0
		if !modal {
			if app.big_open do handle_big_preview_input(&app)
			else do handle_canvas_input(&app)
			if !handle_focus_keys(&app) do handle_keys(&app)
		}
		update_previews(&app)

		rl.BeginDrawing()
		rl.ClearBackground({40, 42, 48, 255})
		if app.big_open do draw_big_preview(&app)
		else do draw_canvas(&app)
		app.typing = false
		if modal do rl.GuiLock()
		draw_panel(&app)
		rl.GuiUnlock()
		draw_status(&app, modal)
		focus_end_frame(&app)
		draw_confirm(&app)
		browser_update_draw(&app.browser, &app.typing)
		take_browser_result(&app)
		rl.EndDrawing()
	}
	if app.job != nil do export_destroy(app.job) // waits for the worker
	harness_finish(&h, &app)
	unload_scan(&app)
	fonts_unload()
	rl.CloseWindow()
	if h.exit_code != 0 do os.exit(h.exit_code)
}

on_ui_scale_changed :: proc(app: ^App) {
	if !app.view_touched do fit_view(app)
	mark_preview_dirty(app)
	if app.big_tex.id != 0 do fit_view_to(&app.big_view, canvas_rect(), f32(app.big_tex.width), f32(app.big_tex.height), 1)
	mode := "manual" if app.ui.manual > 0 else "auto"
	set_status(app, false, "Interface scale %.1fx (%s). Ctrl+= / Ctrl+- to change, Ctrl+0 for auto.", ui_scale, mode)
}

take_browser_result :: proc(app: ^App) {
	if !app.browser.has_result do return
	app.browser.has_result = false
	defer delete(app.browser.result)
	switch app.browser_purpose {
	case .Scan:
		load_scan(app, app.browser.result)
	case .Folder:
		buf_set(app.out_dir[:], app.browser.result)
		set_status(app, false, "Output folder: %s", app.browser.result)
	}
}

handle_drops :: proc(app: ^App) {
	if !rl.IsFileDropped() do return
	files := rl.LoadDroppedFiles()
	defer rl.UnloadDroppedFiles(files)
	if files.count == 0 do return
	path := string(files.paths[0])
	if os.is_dir(path) {
		buf_set(app.out_dir[:], path)
		set_status(app, false, "Output folder: %s", path)
	} else {
		load_scan(app, path)
	}
}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

handle_keys :: proc(app: ^App) {
	if app.typing || app.edit_field != .None do return
	shift := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
	ctrl := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL) || rl.IsKeyDown(.LEFT_SUPER)

	if ui_scale_keys(&app.ui, ctrl) do on_ui_scale_changed(app)
	if ctrl && rl.IsKeyPressed(.Q) do app.quit = true
	if ctrl && rl.IsKeyPressed(.V) do paste_from_clipboard(app)
	if ctrl && rl.IsKeyPressed(.O) do open_scan_dialog(app)
	if ctrl && rl.IsKeyPressed(.E) do request_export(app)
	if !has_scan(app) do return

	if rl.IsKeyPressed(.ESCAPE) {
		if app.big_open do app.big_open = false
		else if app.placing {
			app.placing = false
			clear(&app.place_pts)
			set_status(app, false, "Add card cancelled.")
		} else if app.focused_corner >= 0 do app.focused_corner = -1
		else do select_region(app, -1)
	}
	if rl.IsKeyPressed(.P) || rl.IsKeyPressed(.SPACE) do toggle_big_preview(app)
	if app.big_open do return

	if rl.IsKeyPressed(.A) || rl.IsKeyPressed(.N) do start_placing(app)
	if rl.IsKeyPressed(.M) do set_moire(app, !app.moire)
	if rl.IsKeyPressed(.D) do start_detection(app)
	if rl.IsKeyPressed(.F) do fit_view(app)
	if app.selected < 0 do return

	if rl.IsKeyPressed(.DELETE) || rl.IsKeyPressed(.BACKSPACE) {
		delete_selected(app)
		return
	}
	if rl.IsKeyPressed(.R) {
		rotate_region(&app.regions[app.selected], -1 if shift else 1)
		app.regions[app.selected].review = false
		mark_preview_dirty(app)
	}
	if rl.IsKeyPressed(.C) && !ctrl {
		// Cycle the nudge target: whole card -> corner 1..4 -> whole card
		// Values run -1 (whole card), 0..3 (corners); Shift+C goes backwards.
		app.focused_corner = (app.focused_corner + 1 + (4 if shift else 1)) % 5 - 1
	}
	step := 10.0 if shift else 1.0
	delta: im.Vec2
	if rl.IsKeyPressed(.LEFT) || rl.IsKeyPressedRepeat(.LEFT) do delta.x -= step
	if rl.IsKeyPressed(.RIGHT) || rl.IsKeyPressedRepeat(.RIGHT) do delta.x += step
	if rl.IsKeyPressed(.UP) || rl.IsKeyPressedRepeat(.UP) do delta.y -= step
	if rl.IsKeyPressed(.DOWN) || rl.IsKeyPressedRepeat(.DOWN) do delta.y += step
	if delta != {} do move_region(app, app.selected, app.focused_corner, delta)
}

start_placing :: proc(app: ^App) {
	if !has_scan(app) do return
	app.placing = true
	clear(&app.place_pts)
	set_status(app, false, "Click the card's 4 corners (any order). Esc cancels.")
}

open_scan_dialog :: proc(app: ^App) {
	if app.job != nil do return
	app.browser_purpose = .Scan
	browser_open(&app.browser, .Open_File, "Open scan (PNG)", os.dir(app.scan_path) if app.scan_path != "" else "")
}

open_folder_dialog :: proc(app: ^App) {
	app.browser_purpose = .Folder
	browser_open(&app.browser, .Pick_Folder, "Choose output folder", buf_string(app.out_dir[:]))
}

toggle_big_preview :: proc(app: ^App) {
	if app.big_open {
		app.big_open = false
		return
	}
	if app.selected < 0 {
		set_status(app, true, "Select a card to preview.")
		return
	}
	app.big_open = true
	app.big_dirty = true
	if app.big_tex.id != 0 do rl.UnloadTexture(app.big_tex)
	app.big_tex = {}
}

handle_canvas_input :: proc(app: ^App) {
	if !has_scan(app) do return
	canvas := canvas_rect()
	mouse := rl.GetMousePosition()
	over := rl.CheckCollisionPointRec(mouse, canvas)
	msrc := to_source(app.view, mouse)

	if over {
		if wheel := rl.GetMouseWheelMove(); wheel != 0 {
			zoom_at(&app.view, mouse, 1.0 + 0.15 * wheel if wheel > 0 else 1.0 / (1.0 - 0.15 * wheel))
			app.view_touched = true
		}
	}
	// Pan with right/middle drag anywhere, or left drag on empty canvas.
	if over && (rl.IsMouseButtonPressed(.RIGHT) || rl.IsMouseButtonPressed(.MIDDLE)) do app.drag = .Pan
	if app.drag == .Pan {
		app.view.offset += rl.GetMouseDelta()
		if rl.GetMouseDelta() != {} do app.view_touched = true
		if !rl.IsMouseButtonDown(.LEFT) && !rl.IsMouseButtonDown(.RIGHT) && !rl.IsMouseButtonDown(.MIDDLE) do app.drag = .None
		return
	}

	if app.placing {
		if over && rl.IsMouseButtonPressed(.LEFT) {
			append(&app.place_pts, clamp_to_scan(app, msrc))
			if len(app.place_pts) == 4 do finish_placing(app)
		}
		return
	}

	switch app.drag {
	case .Corner:
		set_corner(app, app.selected, app.drag_corner, msrc + app.drag_grab)
		if !rl.IsMouseButtonDown(.LEFT) do app.drag = .None
		return
	case .Body:
		move_region(app, app.selected, -1, msrc - app.drag_last)
		app.drag_last = msrc
		if !rl.IsMouseButtonDown(.LEFT) do app.drag = .None
		return
	case .None, .Pan:
	}

	if !over || !rl.IsMouseButtonPressed(.LEFT) do return

	// Corner hit: prefer the selected card, then any card.
	hit_region, hit_corner := -1, -1
	best := S(CORNER_HIT)
	try_region :: proc(app: ^App, i: int, mouse: rl.Vector2, best: ^f32, hr, hc: ^int) {
		for c in 0 ..< 4 {
			d := rl.Vector2Distance(to_screen(app.view, app.regions[i].corners[c]), mouse)
			if d < best^ {
				best^ = d
				hr^ = i
				hc^ = c
			}
		}
	}
	if app.selected >= 0 do try_region(app, app.selected, mouse, &best, &hit_region, &hit_corner)
	if hit_region < 0 do for _, i in app.regions do try_region(app, i, mouse, &best, &hit_region, &hit_corner)
	if hit_region >= 0 {
		select_region(app, hit_region)
		app.focused_corner = hit_corner
		app.drag = .Corner
		app.drag_corner = hit_corner
		app.drag_grab = app.regions[hit_region].corners[hit_corner] - msrc
		return
	}
	// Body hit: selected card first so overlapping cards stay grabbable.
	if app.selected >= 0 && point_in_quad(app.regions[app.selected].corners, msrc) {
		app.focused_corner = -1
		app.drag = .Body
		app.drag_last = msrc
		return
	}
	#reverse for r, i in app.regions {
		if point_in_quad(r.corners, msrc) {
			select_region(app, i)
			app.drag = .Body
			app.drag_last = msrc
			return
		}
	}
	select_region(app, -1)
	app.drag = .Pan
}

handle_big_preview_input :: proc(app: ^App) {
	canvas := canvas_rect()
	mouse := rl.GetMousePosition()
	if rl.CheckCollisionPointRec(mouse, canvas) {
		if wheel := rl.GetMouseWheelMove(); wheel != 0 do zoom_at(&app.big_view, mouse, 1.0 + 0.15 * wheel if wheel > 0 else 1.0 / (1.0 - 0.15 * wheel), 0.05, 16)
		if rl.IsMouseButtonPressed(.LEFT) || rl.IsMouseButtonPressed(.RIGHT) || rl.IsMouseButtonPressed(.MIDDLE) do app.big_panning = true
	}
	if app.big_panning {
		app.big_view.offset += rl.GetMouseDelta()
		if !rl.IsMouseButtonDown(.LEFT) && !rl.IsMouseButtonDown(.RIGHT) && !rl.IsMouseButtonDown(.MIDDLE) do app.big_panning = false
	}
	if rl.IsKeyPressed(.ONE) && app.big_tex.id != 0 {
		app.big_view.zoom = 1
		app.big_view.offset = {canvas.x + (canvas.width - f32(app.big_tex.width)) / 2, canvas.y + (canvas.height - f32(app.big_tex.height)) / 2}
	}
	if rl.IsKeyPressed(.F) && app.big_tex.id != 0 do fit_view_to(&app.big_view, canvas, f32(app.big_tex.width), f32(app.big_tex.height), 1)
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

COLOR_REGION :: rl.Color{80, 200, 255, 255}
COLOR_SELECTED :: rl.Color{255, 220, 60, 255}
COLOR_TOP :: rl.Color{255, 120, 40, 255}
COLOR_REVIEW :: rl.Color{255, 90, 200, 255} // detected with medium confidence

draw_scene :: proc(app: ^App, v: View) {
	dest := rl.Rectangle{v.offset.x, v.offset.y, f32(app.scan.width) * v.zoom, f32(app.scan.height) * v.zoom}
	// Always the original scan: corners are placed on unfiltered pixels.
	rl.DrawTexturePro(app.tex, {0, 0, f32(app.tex.width), f32(app.tex.height)}, dest, {}, 0, rl.WHITE)

	for r, i in app.regions {
		sel := i == app.selected
		col := COLOR_SELECTED if sel else (COLOR_REVIEW if r.review else COLOR_REGION)
		pts: [4]rl.Vector2
		for c in 0 ..< 4 do pts[c] = to_screen(v, r.corners[c])
		for c in 1 ..< 4 do rl.DrawLineEx(pts[c], pts[(c + 1) % 4], S(2), col)
		rl.DrawLineEx(pts[0], pts[1], S(4) if sel else S(3), COLOR_TOP) // card's top edge
		for c in 0 ..< 4 {
			focused := sel && c == app.focused_corner
			s := S(13) if focused else S(9)
			rl.DrawRectangleV(pts[c] - s / 2, {s, s}, rl.WHITE if focused else col)
			rl.DrawRectangleLinesEx({pts[c].x - s / 2, pts[c].y - s / 2, s, s}, max(1, S(1)), rl.BLACK)
		}
		// Card number at the centre.
		center := (pts[0] + pts[1] + pts[2] + pts[3]) / 4
		label := fmt.ctprintf("%d", i + 1)
		tw := measure_big_text(label)
		rl.DrawRectangleRounded({center.x - tw / 2 - S(10), center.y - S(26), tw + S(20), S(52)}, 0.3, 6, {0, 0, 0, 160})
		// Inter's digits span 0.24-0.97 em below the line top; center that band.
		draw_big_text(label, i32(center.x - tw / 2), i32(center.y - 0.605 * f32(fonts.big_size)), col)
	}
	// Points placed so far for a new card, with a rubber band to the mouse.
	if app.placing {
		mouse := rl.GetMousePosition()
		for p, i in app.place_pts {
			sp := to_screen(v, p)
			next := to_screen(v, app.place_pts[i + 1]) if i + 1 < len(app.place_pts) else mouse
			rl.DrawLineEx(sp, next, S(2), COLOR_SELECTED)
			rl.DrawCircleV(sp, S(5), COLOR_SELECTED)
		}
	}
}

draw_canvas :: proc(app: ^App) {
	canvas := canvas_rect()
	if !has_scan(app) {
		msg: cstring = "Open a scan PNG (Ctrl+O), or copy one in your file manager and press Ctrl+V"
		w := i32(measure_text(msg))
		draw_text(msg, i32(canvas.width / 2) - w / 2, i32(canvas.height / 2 - S(10)), rl.LIGHTGRAY)
		return
	}
	// Show individual pixels when zoomed in for precise corner placement.
	want: rl.TextureFilter = .POINT if app.view.zoom >= 3 else .TRILINEAR
	if want != app.tex_filter {
		app.tex_filter = want
		rl.SetTextureFilter(app.tex, want)
	}
	rl.BeginScissorMode(i32(canvas.x), i32(canvas.y), i32(canvas.width), i32(canvas.height))
	draw_scene(app, app.view)
	rl.EndScissorMode()
}

draw_checker :: proc(r: rl.Rectangle) {
	rl.BeginScissorMode(i32(r.x), i32(r.y), i32(r.width), i32(r.height))
	rl.DrawRectangleRec(r, {205, 205, 205, 255})
	cell := i32(S(12))
	for y: i32 = 0; f32(y * cell) < r.height; y += 1 {
		for x := (y & 1); f32(x * cell) < r.width; x += 2 {
			rl.DrawRectangle(i32(r.x) + x * cell, i32(r.y) + y * cell, cell, cell, {245, 245, 245, 255})
		}
	}
	rl.EndScissorMode()
}

draw_big_preview :: proc(app: ^App) {
	canvas := canvas_rect()
	draw_checker(canvas)
	if app.big_tex.id == 0 {
		draw_text("Rendering...", i32(canvas.x + S(20)), i32(canvas.y + S(20)), rl.DARKGRAY)
		return
	}
	v := app.big_view
	rl.SetTextureFilter(app.big_tex, .POINT if v.zoom >= 2 else .BILINEAR)
	rl.BeginScissorMode(i32(canvas.x), i32(canvas.y), i32(canvas.width), i32(canvas.height))
	rl.DrawTexturePro(app.big_tex, {0, 0, f32(app.big_tex.width), f32(app.big_tex.height)}, {v.offset.x, v.offset.y, f32(app.big_tex.width) * v.zoom, f32(app.big_tex.height) * v.zoom}, {}, 0, rl.WHITE)
	rl.EndScissorMode()
	info := rl.TextFormat("Card %d at export size %d × %d, zoom %.0f%%. Wheel zooms, drag pans, 1 = 100%%, F = fit, P/Esc closes.", app.selected + 1, app.big_tex.width, app.big_tex.height, v.zoom * 100)
	rl.DrawRectangle(0, 0, i32(canvas.width), i32(S(32)), {0, 0, 0, 170})
	draw_text(info, i32(S(10)), i32(S(6)), rl.WHITE)
}

draw_status :: proc(app: ^App, modal: bool) {
	sh, sw := f32(rl.GetScreenHeight()), f32(rl.GetScreenWidth())
	rl.DrawRectangleRec({0, sh - status_h, sw, status_h}, {28, 29, 33, 255})

	// Exit button: tiling window managers often show no title bar to close from.
	label: cstring = "Exit (Ctrl+Q)"
	bw := measure_text(label) + S(24)
	button := rl.Rectangle{sw - bw - S(4), sh - status_h + S(3), bw, status_h - S(6)}
	if modal do rl.GuiLock()
	if focus_button(app, .Exit, button, label, in_panel = false) do app.quit = true
	rl.GuiUnlock()

	text := strings.clone_to_cstring(status_text(app), context.temp_allocator)
	rl.BeginScissorMode(0, i32(sh - status_h), i32(button.x - S(8)), i32(status_h))
	draw_text(text, i32(pad), i32(sh - status_h + S(6)), rl.Color{255, 120, 110, 255} if app.status_error else rl.Color{220, 220, 220, 255})
	rl.EndScissorMode()
}

draw_confirm :: proc(app: ^App) {
	if app.confirm_count <= 0 do return
	sw, sh := f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())
	rl.DrawRectangle(0, 0, i32(sw), i32(sh), {0, 0, 0, 140})
	w, h := S(520), S(190)
	content, closed := dialog_frame({(sw - w) / 2, (sh - h) / 2, w, h}, "Replace files?")
	x, y := content.x + S(16), content.y + S(14)
	text_col := rl.GetColor(u32(rl.GuiGetStyle(.LABEL, i32(rl.GuiControlProperty.TEXT_COLOR_NORMAL))))
	draw_text(rl.TextFormat("%d file(s) with these names already exist", app.confirm_count), i32(x), i32(y), text_col)
	draw_text("in the output folder. Replace them?", i32(x), i32(y + S(26)), text_col)
	bw, bh := S(140), S(36)
	by := content.y + content.height - bh - S(14)
	replace := rl.GuiButton({content.x + content.width - S(16) - bw, by, bw, bh}, "Replace")
	cancel := rl.GuiButton({content.x + content.width - S(16) - bw * 2 - S(10), by, bw, bh}, "Cancel")
	if replace {
		app.confirm_count = 0
		start_export(app)
	} else if cancel || closed || rl.IsKeyPressed(.ESCAPE) {
		app.confirm_count = 0
	}
}
