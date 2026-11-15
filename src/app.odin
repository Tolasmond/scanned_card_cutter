// Application state and editing operations (no drawing).
package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import im "imaging"
import rl "vendor:raylib"

MAX_TEXTURE_DIM :: 8192
PREVIEW_MAX_H :: 420 // at 1x; the panel width limits the other side

View :: struct {
	zoom:   f32, // screen pixels per image pixel
	offset: rl.Vector2, // screen position of image pixel (0, 0)
}

Region :: struct {
	corners: [4]im.Vec2, // TL, TR, BR, BL of the *output* card, in source pixels
	review:  bool, // detected with medium confidence; cleared once the user edits it
}

Drag_Kind :: enum {
	None,
	Pan,
	Corner,
	Body,
}

Browser_Purpose :: enum {
	Scan,
	Folder,
}

App :: struct {
	// Scan
	scan:            rl.Image, // full resolution, RGBA8
	scan_px:         im.Image, // view of scan.data
	moire:           bool, // remove the moiré (halftone) pattern before extracting
	cleaned:         im.Image, // moiré-free copy of the scan, for extraction only
	clean_job:       ^Clean_Job,
	sync_jobs:       bool, // record/replay: run background jobs inline
	detect_job:      ^Detect_Job,
	scan_path:       string,
	tex:             rl.Texture2D, // possibly downscaled for the GPU
	tex_filter:      rl.TextureFilter,
	view:            View,
	view_touched:    bool, // user zoomed/panned; otherwise refit on window resize

	// Cards
	regions:         [dynamic]Region,
	selected:        int, // -1 = none
	focused_corner:  int, // -1 = whole region
	placing:         bool,
	place_pts:       [dynamic]im.Vec2,

	// Mouse drag
	drag:            Drag_Kind,
	drag_corner:     int,
	drag_grab:       im.Vec2, // corner - mouse (source px) at grab time
	drag_last:       im.Vec2, // last mouse position (source px) for body drag

	// Output settings
	out_w, out_h:    i32,
	radius, trim:    i32,
	edit_field:      int, // which value box is in edit mode (0 = none)
	panel_scroll:    f32, // side panel scroll offset when the window is too short
	out_dir:         [1024]u8,
	prefix:          [256]u8,

	// Preview
	preview:         rl.Texture2D,
	preview_dirty:   bool,
	preview_time:    f64,
	big_open:        bool, // full-size preview overlay
	big_tex:         rl.Texture2D,
	big_dirty:       bool,
	big_view:        View,
	big_panning:     bool,

	// Dialogs / jobs
	browser:         Browser,
	browser_purpose: Browser_Purpose,
	job:             ^Export_Job,
	confirm_count:   int, // > 0 while asking to overwrite this many files
	typing:          bool, // a text box has keyboard focus this frame
	quit:            bool, // Exit button or Ctrl+Q
	ui:              Ui_Scale_State,

	status:          [512]u8,
	status_len:      int,
	status_error:    bool,
}

set_status :: proc(app: ^App, is_error: bool, format: string, args: ..any) {
	s := fmt.bprintf(app.status[:], format, ..args)
	app.status_len = len(s)
	app.status_error = is_error
}

status_text :: proc(app: ^App) -> string {
	return string(app.status[:app.status_len])
}

buf_string :: proc(buf: []u8) -> string {
	return string(cstring(raw_data(buf)))
}

buf_set :: proc(buf: []u8, s: string) {
	n := min(len(s), len(buf) - 1)
	copy(buf[:n], s[:n])
	buf[n] = 0
}

has_scan :: proc(app: ^App) -> bool {
	return app.scan.data != nil
}

settings_of :: proc(app: ^App) -> im.Extract_Settings {
	return {width = int(app.out_w), height = int(app.out_h), corner_radius = int(app.radius), edge_trim = int(app.trim)}
}

mark_preview_dirty :: proc(app: ^App) {
	app.preview_dirty = true
	app.big_dirty = true
}

// ---------------------------------------------------------------------------
// Scan loading
// ---------------------------------------------------------------------------

unload_scan :: proc(app: ^App) {
	discard_detection(app)
	discard_cleaning(app)
	if has_scan(app) {
		rl.UnloadTexture(app.tex)
		rl.UnloadImage(app.scan)
	}
	app.scan = {}
	app.scan_px = {}
	clear(&app.regions)
	clear(&app.place_pts)
	app.selected = -1
	app.focused_corner = -1
	app.placing = false
	app.big_open = false
	mark_preview_dirty(app)
}

load_scan :: proc(app: ^App, path: string) -> bool {
	if app.job != nil {
		set_status(app, true, "Wait for the export to finish before opening another scan.")
		return false
	}
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		set_status(app, true, "Could not read %s", path)
		return false
	}
	defer delete(data)
	img := rl.LoadImageFromMemory(".png", raw_data(data), i32(len(data)))
	if img.data == nil || img.width <= 0 || img.height <= 0 {
		set_status(app, true, "%s is not a readable PNG.", os.base(path))
		return false
	}
	rl.ImageFormat(&img, .UNCOMPRESSED_R8G8B8A8)

	unload_scan(app)
	app.scan = img
	app.scan_px = im.Image{w = int(img.width), h = int(img.height), pix = ([^]u8)(img.data)[:img.width * img.height * 4]}

	app.tex = make_display_texture(img)
	app.tex_filter = .TRILINEAR
	rl.SetTextureFilter(app.tex, app.tex_filter)

	delete(app.scan_path)
	app.scan_path = strings.clone(path)
	buf_set(app.prefix[:], os.stem(path))
	if buf_string(app.out_dir[:]) == "" do buf_set(app.out_dir[:], os.dir(path))
	fit_view(app)
	set_status(app, false, "Opened %s (%d x %d). Press A to add a card, then click its 4 corners.", os.base(path), img.width, img.height)
	if app.moire do start_cleaning(app)
	return true
}

// GPUs cap texture size; display a reduced copy for very large scans.
// All processing still reads the full-resolution pixels.
make_display_texture :: proc(img: rl.Image) -> rl.Texture2D {
	tex: rl.Texture2D
	if max(img.width, img.height) > MAX_TEXTURE_DIM {
		s := f32(MAX_TEXTURE_DIM) / f32(max(img.width, img.height))
		small := rl.ImageCopy(img)
		rl.ImageResize(&small, i32(f32(img.width) * s), i32(f32(img.height) * s))
		tex = rl.LoadTextureFromImage(small)
		rl.UnloadImage(small)
	} else {
		tex = rl.LoadTextureFromImage(img)
	}
	rl.GenTextureMipmaps(&tex)
	return tex
}

// ---------------------------------------------------------------------------
// View transforms
// ---------------------------------------------------------------------------

canvas_rect :: proc() -> rl.Rectangle {
	return {0, 0, f32(rl.GetScreenWidth()) - panel_w, f32(rl.GetScreenHeight()) - status_h}
}

fit_view_to :: proc(v: ^View, rect: rl.Rectangle, w, h: f32, max_zoom: f32 = 64) {
	v.zoom = min(min(rect.width / w, rect.height / h) * 0.95, max_zoom)
	v.offset = {rect.x + (rect.width - w * v.zoom) / 2, rect.y + (rect.height - h * v.zoom) / 2}
}

fit_view :: proc(app: ^App) {
	if has_scan(app) do fit_view_to(&app.view, canvas_rect(), f32(app.scan.width), f32(app.scan.height))
	app.view_touched = false
}

to_screen :: proc(v: View, p: im.Vec2) -> rl.Vector2 {
	return v.offset + rl.Vector2{f32(p.x), f32(p.y)} * v.zoom
}

to_source :: proc(v: View, s: rl.Vector2) -> im.Vec2 {
	p := (s - v.offset) / v.zoom
	return {f64(p.x), f64(p.y)}
}

zoom_at :: proc(v: ^View, anchor: rl.Vector2, factor: f32, min_zoom: f32 = 0.02, max_zoom: f32 = 64) {
	nz := clamp(v.zoom * factor, min_zoom, max_zoom)
	v.offset = anchor - (anchor - v.offset) * (nz / v.zoom)
	v.zoom = nz
}

// ---------------------------------------------------------------------------
// Region editing
// ---------------------------------------------------------------------------

clamp_to_scan :: proc(app: ^App, p: im.Vec2) -> im.Vec2 {
	return {clamp(p.x, 0, f64(app.scan.width)), clamp(p.y, 0, f64(app.scan.height))}
}

point_in_quad :: proc(q: [4]im.Vec2, p: im.Vec2) -> bool {
	sign := 0.0
	for i in 0 ..< 4 {
		a, b := q[i], q[(i + 1) % 4]
		cr := (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
		if cr == 0 do continue
		if sign == 0 do sign = cr
		else if (cr > 0) != (sign > 0) do return false
	}
	return true
}

edge_len :: proc(a, b: im.Vec2) -> f64 {
	return math.sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y))
}

// Rotates which quad edge is the card's top: +1 = turn the output 90° clockwise.
rotate_region :: proc(r: ^Region, steps: int) {
	c := r.corners
	s := ((steps % 4) + 4) % 4
	for i in 0 ..< 4 do r.corners[i] = c[(i + 4 - s) % 4]
}

// For a new card (corners clockwise from the top-left on the scan): a portrait
// output gets the quad's short edge on top, a landscape output its long edge.
orient_for_output :: proc(app: ^App, r: ^Region) {
	q := r.corners
	top, side := edge_len(q[0], q[1]), edge_len(q[0], q[3])
	if (app.out_h > app.out_w) == (top > side) do rotate_region(r, -1)
}

finish_placing :: proc(app: ^App) {
	defer {
		clear(&app.place_pts)
		app.placing = false
	}
	q := im.order_corners({app.place_pts[0], app.place_pts[1], app.place_pts[2], app.place_pts[3]})
	if !im.quad_is_valid(q) {
		set_status(app, true, "Those 4 points don't form a card shape. Press A to try again.")
		return
	}
	r := Region{corners = q}
	orient_for_output(app, &r)
	append(&app.regions, r)
	select_region(app, len(app.regions) - 1)
	set_status(app, false, "Card %d added. Drag corners to adjust, R to rotate, A to add another.", len(app.regions))
}

select_region :: proc(app: ^App, index: int) {
	if app.selected != index do mark_preview_dirty(app)
	app.selected = index
	app.focused_corner = -1
}

delete_selected :: proc(app: ^App) {
	if app.selected < 0 do return
	ordered_remove(&app.regions, app.selected)
	app.selected = min(app.selected, len(app.regions) - 1)
	app.focused_corner = -1
	mark_preview_dirty(app)
}

// Moves one corner (or the whole region when corner < 0), keeping the quad
// convex and inside the scan. Returns false if the move was rejected.
move_region :: proc(app: ^App, index, corner: int, delta: im.Vec2) -> bool {
	r := &app.regions[index]
	q := r.corners
	if corner >= 0 {
		q[corner] = clamp_to_scan(app, q[corner] + delta)
	} else {
		lo, hi := q[0], q[0]
		for p in q {
			lo = {min(lo.x, p.x), min(lo.y, p.y)}
			hi = {max(hi.x, p.x), max(hi.y, p.y)}
		}
		d := im.Vec2{clamp(delta.x, -lo.x, f64(app.scan.width) - hi.x), clamp(delta.y, -lo.y, f64(app.scan.height) - hi.y)}
		for &p in q do p += d
	}
	if !im.quad_is_valid(q) do return false
	if q != r.corners {
		r.corners = q
		r.review = false // the user has looked at this card
		if index == app.selected do mark_preview_dirty(app)
	}
	return true
}

// Sets one corner to an absolute position (used while dragging).
set_corner :: proc(app: ^App, index, corner: int, p: im.Vec2) {
	move_region(app, index, corner, clamp_to_scan(app, p) - app.regions[index].corners[corner])
}

// ---------------------------------------------------------------------------
// Preview
// ---------------------------------------------------------------------------

// Renders the selected card through the exact export pipeline at `scale`.
render_card_texture :: proc(app: ^App, tex: ^rl.Texture2D, scale: f64) -> bool {
	if tex.id != 0 do rl.UnloadTexture(tex^)
	tex^ = {}
	if app.selected < 0 || !has_scan(app) do return false
	s := settings_of(app)
	if s.width <= 0 || s.height <= 0 do return false
	ps := s
	ps.width = max(1, int(math.round(f64(s.width) * scale)))
	ps.height = max(1, int(math.round(f64(s.height) * scale)))
	ps.corner_radius = int(math.round(f64(s.corner_radius) * scale))
	out, ok := im.extract_card(extract_source(app), app.regions[app.selected].corners, ps)
	if !ok do return false
	defer im.image_destroy(&out)
	tex^ = rl.LoadTextureFromImage({data = raw_data(out.pix), width = i32(out.w), height = i32(out.h), mipmaps = 1, format = .UNCOMPRESSED_R8G8B8A8})
	rl.SetTextureFilter(tex^, .BILINEAR)
	return true
}

update_previews :: proc(app: ^App) {
	now := rl.GetTime()
	dragging := app.drag == .Corner || app.drag == .Body
	if app.preview_dirty && (!dragging || now - app.preview_time > 0.08) {
		scale := min(f64(panel_w - pad * 2) / f64(max(app.out_w, 1)), f64(S(PREVIEW_MAX_H)) / f64(max(app.out_h, 1)), 1)
		render_card_texture(app, &app.preview, scale)
		app.preview_dirty = false
		app.preview_time = now
	}
	if app.big_open && app.big_dirty && !dragging {
		first := app.big_tex.id == 0
		render_card_texture(app, &app.big_tex, 1)
		app.big_dirty = false
		if first && app.big_tex.id != 0 do fit_view_to(&app.big_view, canvas_rect(), f32(app.big_tex.width), f32(app.big_tex.height), 1)
	}
}

// ---------------------------------------------------------------------------
// Export
// ---------------------------------------------------------------------------

export_paths :: proc(app: ^App, allocator := context.allocator) -> []string {
	dir := buf_string(app.out_dir[:])
	prefix := buf_string(app.prefix[:])
	if prefix == "" do prefix = "card"
	paths := make([]string, len(app.regions), allocator)
	for _, i in app.regions {
		name := fmt.tprintf("%s_%02d.png", prefix, i + 1)
		paths[i], _ = os.join_path({dir, name}, allocator)
	}
	return paths
}

// Validates and, if needed, asks to confirm overwriting before starting.
request_export :: proc(app: ^App) {
	if app.job != nil || !has_scan(app) do return
	if len(app.regions) == 0 {
		set_status(app, true, "Add at least one card first.")
		return
	}
	if app.out_w <= 0 || app.out_h <= 0 {
		set_status(app, true, "Set the output width and height.")
		return
	}
	if moire_pending(app) {
		set_status(app, true, "Moiré removal is still running (%d%%). Export when it finishes.", moire_percent(app))
		return
	}
	dir := buf_string(app.out_dir[:])
	if dir == "" {
		set_status(app, true, "Choose an output folder.")
		return
	}
	if !os.is_dir(dir) {
		if err := os.make_directory_all(dir); err != nil {
			set_status(app, true, "Could not create folder %s", dir)
			return
		}
	}
	existing := 0
	for p in export_paths(app, context.temp_allocator) do if os.exists(p) do existing += 1
	if existing > 0 {
		app.confirm_count = existing
		return
	}
	start_export(app)
}

start_export :: proc(app: ^App) {
	paths := export_paths(app)
	defer delete(paths)
	items := make([]Export_Item, len(app.regions))
	for r, i in app.regions do items[i] = {corners = r.corners, path = paths[i]}
	app.job = export_start(extract_source(app), settings_of(app), items)
	set_status(app, false, "Exporting %d cards...", len(items))
}

poll_export :: proc(app: ^App) {
	if app.job == nil do return
	done, total, finished := export_progress(app.job)
	if !finished do return
	if len(app.job.errors) > 0 {
		set_status(app, true, "Exported %d of %d. First error: %s", total - len(app.job.errors), total, app.job.errors[0])
	} else {
		set_status(app, false, "Exported %d cards to %s", done, buf_string(app.out_dir[:]))
	}
	export_destroy(app.job)
	app.job = nil
}
