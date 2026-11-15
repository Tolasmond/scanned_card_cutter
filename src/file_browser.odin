// Built-in modal file/folder browser drawn with raylib + raygui. Works on every
// platform with no external dialog dependencies.
package main

import "core:os"
import "core:slice"
import "core:strings"
import rl "vendor:raylib"

Browser_Mode :: enum {
	Open_File, // pick a .png file
	Pick_Folder, // pick a directory
}

Browser_Entry :: struct {
	name:   string,
	label:  cstring,
	is_dir: bool,
}

Browser :: struct {
	active:       bool,
	mode:         Browser_Mode,
	title:        cstring,
	dir:          string,
	entries:      [dynamic]Browser_Entry,
	selected:     int,
	scroll:       f32,
	last_click:   f64,
	last_index:   int,
	path_buf:     [1024]u8,
	path_edit:    bool,
	error:        string,
	// Set when the user confirms; the caller takes ownership and clears it.
	result:       string,
	has_result:   bool,
}

BROWSER_ROW :: 28

browser_open :: proc(b: ^Browser, mode: Browser_Mode, title: cstring, start_dir: string) {
	b.active = true
	b.mode = mode
	b.title = title
	b.has_result = false
	dir := start_dir
	if dir == "" || !os.is_dir(dir) {
		home, err := os.user_home_dir(context.temp_allocator)
		dir = home if err == nil else "."
	}
	browser_navigate(b, dir)
}

browser_close :: proc(b: ^Browser) {
	b.active = false
	b.path_edit = false
}

@(private = "file")
browser_clear_entries :: proc(b: ^Browser) {
	for e in b.entries {
		delete(e.name)
		delete(e.label)
	}
	clear(&b.entries)
}

@(private = "file")
set_path_buf :: proc(b: ^Browser, s: string) {
	n := min(len(s), len(b.path_buf) - 1)
	copy(b.path_buf[:n], s[:n])
	b.path_buf[n] = 0
}

browser_navigate :: proc(b: ^Browser, path: string) {
	abs_path, err := os.get_absolute_path(path, context.temp_allocator)
	if err != nil || !os.is_dir(abs_path) {
		b.error = "Not a folder."
		set_path_buf(b, b.dir)
		return
	}
	infos, rerr := os.read_all_directory_by_path(abs_path, context.temp_allocator)
	if rerr != nil {
		b.error = "Cannot read that folder."
		set_path_buf(b, b.dir)
		return
	}
	b.error = ""
	delete(b.dir)
	b.dir = strings.clone(abs_path)
	set_path_buf(b, b.dir)
	browser_clear_entries(b)
	for fi in infos {
		if strings.has_prefix(fi.name, ".") do continue
		is_dir := fi.type == .Directory || (fi.type == .Symlink && os.is_dir(fi.fullpath))
		if !is_dir {
			if b.mode == .Pick_Folder do continue
			if !strings.equal_fold(os.ext(fi.name), ".png") do continue
		}
		label := strings.concatenate({fi.name, "/" if is_dir else ""}, context.temp_allocator)
		append(&b.entries, Browser_Entry{name = strings.clone(fi.name), label = strings.clone_to_cstring(label), is_dir = is_dir})
	}
	slice.sort_by(b.entries[:], proc(a, c: Browser_Entry) -> bool {
		if a.is_dir != c.is_dir do return a.is_dir
		return strings.to_lower(a.name, context.temp_allocator) < strings.to_lower(c.name, context.temp_allocator)
	})
	b.selected = -1
	b.scroll = 0
}

@(private = "file")
browser_up :: proc(b: ^Browser) {
	parent := os.dir(b.dir)
	if parent != "" && parent != b.dir do browser_navigate(b, parent)
}

@(private = "file")
browser_finish :: proc(b: ^Browser, path: string) {
	b.result = strings.clone(path)
	b.has_result = true
	browser_close(b)
}

@(private = "file")
browser_activate :: proc(b: ^Browser, index: int) {
	if index < 0 || index >= len(b.entries) do return
	e := b.entries[index]
	full, _ := os.join_path({b.dir, e.name}, context.temp_allocator)
	if e.is_dir do browser_navigate(b, full)
	else do browser_finish(b, full)
}

// Draws the browser over the whole window and handles its input.
// Returns true while it is open (callers should ignore other input then).
browser_update_draw :: proc(b: ^Browser, typing: ^bool) -> bool {
	if !b.active do return false
	sw, sh := f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())
	rl.DrawRectangle(0, 0, i32(sw), i32(sh), {0, 0, 0, 140})

	w := min(sw - 40, 900)
	h := min(sh - 40, 700)
	box := rl.Rectangle{(sw - w) / 2, (sh - h) / 2, w, h}
	if rl.GuiWindowBox(box, b.title) != 0 {
		browser_close(b)
		return true
	}
	x := box.x + 12
	y := box.y + 36
	inner_w := box.width - 24

	// Path row: [Up] [Home] [path text box]
	if rl.GuiButton({x, y, 70, 30}, "Up") do browser_up(b)
	if rl.GuiButton({x + 78, y, 80, 30}, "Home") {
		if home, err := os.user_home_dir(context.temp_allocator); err == nil do browser_navigate(b, home)
	}
	if rl.GuiTextBox({x + 166, y, inner_w - 166, 30}, cstring(&b.path_buf[0]), i32(len(b.path_buf)), b.path_edit) {
		b.path_edit = !b.path_edit
		if !b.path_edit {
			typed := string(cstring(&b.path_buf[0]))
			if os.is_dir(typed) do browser_navigate(b, typed)
			else if b.mode == .Open_File && os.exists(typed) do browser_finish(b, typed)
			else do browser_navigate(b, typed)
			if !b.active do return true
		}
	}
	typing^ = typing^ || b.path_edit
	y += 40

	// File list
	footer := f32(46)
	list := rl.Rectangle{x, y, inner_w, box.y + box.height - footer - y - 8}
	rl.DrawRectangleRec(list, rl.RAYWHITE)
	rl.DrawRectangleLinesEx(list, 1, rl.GRAY)
	mouse := rl.GetMousePosition()
	content_h := f32(len(b.entries)) * BROWSER_ROW
	if rl.CheckCollisionPointRec(mouse, list) do b.scroll -= rl.GetMouseWheelMove() * BROWSER_ROW * 3
	b.scroll = clamp(b.scroll, 0, max(0, content_h - list.height))

	rl.BeginScissorMode(i32(list.x), i32(list.y), i32(list.width), i32(list.height))
	first := int(b.scroll / BROWSER_ROW)
	for i := first; i < len(b.entries); i += 1 {
		ry := list.y + f32(i) * BROWSER_ROW - b.scroll
		if ry > list.y + list.height do break
		row := rl.Rectangle{list.x + 1, ry, list.width - 2, BROWSER_ROW}
		hover := rl.CheckCollisionPointRec(mouse, row) && rl.CheckCollisionPointRec(mouse, list)
		if i == b.selected do rl.DrawRectangleRec(row, {151, 232, 255, 255})
		else if hover do rl.DrawRectangleRec(row, {230, 240, 250, 255})
		e := b.entries[i]
		icon := rl.GuiIconName.ICON_FOLDER if e.is_dir else rl.GuiIconName.ICON_FILE
		rl.GuiDrawIcon(icon, i32(row.x + 6), i32(ry + 6), 1, rl.DARKGRAY)
		rl.DrawText(e.label, i32(row.x + 30), i32(ry + 4), 20, rl.BLACK)
		if hover && rl.IsMouseButtonPressed(.LEFT) && !b.path_edit {
			now := rl.GetTime()
			if i == b.last_index && now - b.last_click < 0.4 {
				b.last_click = 0
				rl.EndScissorMode()
				browser_activate(b, i)
				return true
			}
			b.selected = i
			b.last_index = i
			b.last_click = now
		}
	}
	rl.EndScissorMode()
	if len(b.entries) == 0 {
		msg: cstring = "No PNG files here." if b.mode == .Open_File else "No subfolders."
		rl.DrawText(msg, i32(list.x + 12), i32(list.y + 10), 20, rl.GRAY)
	}

	// Footer
	fy := box.y + box.height - footer
	if b.error != "" do rl.DrawText(strings.clone_to_cstring(b.error, context.temp_allocator), i32(x), i32(fy + 8), 20, rl.RED)
	ok_label: cstring = "Open" if b.mode == .Open_File else "Use this folder"
	ok_w := f32(170)
	if rl.GuiButton({x + inner_w - ok_w, fy, ok_w, 34}, ok_label) {
		if b.mode == .Pick_Folder {
			if b.selected >= 0 && b.entries[b.selected].is_dir {
				full, _ := os.join_path({b.dir, b.entries[b.selected].name}, context.temp_allocator)
				browser_finish(b, full)
			} else {
				browser_finish(b, b.dir)
			}
		} else {
			browser_activate(b, b.selected)
		}
		return true
	}
	if rl.GuiButton({x + inner_w - ok_w - 110, fy, 100, 34}, "Cancel") {
		browser_close(b)
		return true
	}

	// Keyboard
	if !b.path_edit {
		if rl.IsKeyPressed(.ESCAPE) do browser_close(b)
		else if rl.IsKeyPressed(.BACKSPACE) do browser_up(b)
		else if rl.IsKeyPressed(.ENTER) && b.selected >= 0 do browser_activate(b, b.selected)
		else {
			moved := false
			if rl.IsKeyPressedRepeat(.DOWN) || rl.IsKeyPressed(.DOWN) {
				b.selected = min(b.selected + 1, len(b.entries) - 1)
				moved = true
			} else if rl.IsKeyPressedRepeat(.UP) || rl.IsKeyPressed(.UP) {
				b.selected = max(b.selected - 1, 0)
				moved = true
			}
			if moved && b.selected >= 0 { 	// keep the selection visible
				top := f32(b.selected) * BROWSER_ROW
				if top < b.scroll do b.scroll = top
				if top + BROWSER_ROW > b.scroll + list.height do b.scroll = top + BROWSER_ROW - list.height
			}
		}
	}
	return true
}
