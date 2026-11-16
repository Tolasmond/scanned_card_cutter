// Ctrl+V: open a file copied in a file manager.
//
// File managers put a copied file on the clipboard as a plain path, a
// file:// URI list, or GNOME's "copy\nfile://..." form; raylib reads the text
// form. Windows Explorer puts a file list instead (CF_HDROP, read in
// paste_windows.odin); a copied text path still works there too. This is also
// the reliable way in where drag and drop does not arrive, such as Wayland
// file managers dropping onto this XWayland window on Hyprland.
package main

import "core:os"
import "core:strings"
import rl "vendor:raylib"

// Paths named in clipboard text, in order. URIs are decoded; lines that are
// not local paths are skipped.
clipboard_paths :: proc(text: string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_space(line)
		if l == "" || l == "copy" || l == "cut" || strings.has_prefix(l, "#") do continue
		if strings.has_prefix(l, "file://") {
			l = l[len("file://"):]
			// file://host/path: only the local host (empty or "localhost") is usable.
			if strings.has_prefix(l, "localhost/") do l = l[len("localhost"):]
			if !strings.has_prefix(l, "/") do continue
			when ODIN_OS == .Windows {
				// file:///C:/path -> C:/path
				if len(l) >= 3 && l[2] == ':' do l = l[1:]
			}
			append(&out, percent_decode(l, allocator))
			continue
		}
		when ODIN_OS == .Windows {
			// C:\path or \\server\share
			if (len(l) >= 3 && l[1] == ':') || strings.has_prefix(l, "\\\\") do append(&out, strings.clone(l, allocator))
		} else {
			if strings.has_prefix(l, "/") do append(&out, strings.clone(l, allocator))
		}
	}
	return out[:]
}

percent_decode :: proc(s: string, allocator := context.allocator) -> string {
	hex :: proc(c: u8) -> int {
		switch c {
		case '0' ..= '9': return int(c - '0')
		case 'a' ..= 'f': return int(c - 'a' + 10)
		case 'A' ..= 'F': return int(c - 'A' + 10)
		}
		return -1
	}
	b := make([dynamic]u8, 0, len(s), allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '%' && i + 2 < len(s) {
			hi, lo := hex(s[i + 1]), hex(s[i + 2])
			if hi >= 0 && lo >= 0 {
				append(&b, u8(hi * 16 + lo))
				i += 2
				continue
			}
		}
		append(&b, s[i])
	}
	return string(b[:])
}

paste_from_clipboard :: proc(app: ^App) {
	paths := clipboard_file_list(context.temp_allocator)
	if len(paths) == 0 do paths = clipboard_paths(string(rl.GetClipboardText()), context.temp_allocator)
	for p in paths {
		if os.is_dir(p) {
			buf_set(app.out_dir[:], p)
			set_status(app, false, "Output folder: %s", p)
			return
		}
		if os.exists(p) {
			load_scan(app, p)
			return
		}
	}
	if len(paths) > 0 {
		set_status(app, true, "Pasted path does not exist: %s", paths[0])
	} else {
		set_status(app, true, "Nothing to paste: copy a PNG (or a folder) in your file manager, then press Ctrl+V.")
	}
}
