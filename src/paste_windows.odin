#+build windows
package main

// Explorer's Copy puts files on the clipboard as CF_HDROP, a file list with no
// text form, so raylib's GetClipboardText sees nothing. Read the list itself.
//
// The clipboard functions are looked up at run time rather than called through
// core:sys/windows: linking User32.lib next to raylib's static library makes
// the linker warn that both define CloseWindow.

import win "core:sys/windows"

@(private = "file")
Clipboard_Api :: struct {
	is_format_available: proc "system" (format: win.UINT) -> win.BOOL,
	open:                proc "system" (owner: win.HWND) -> win.BOOL,
	close:               proc "system" () -> win.BOOL,
	get_data:            proc "system" (format: win.UINT) -> win.HANDLE,
	drag_query_file:     proc "system" (drop: win.HDROP, index: win.UINT, file: win.LPWSTR, cch: win.UINT) -> win.UINT,
}

@(private = "file")
load_clipboard_api :: proc() -> (api: Clipboard_Api, ok: bool) {
	user32 := win.LoadLibraryW(win.L("user32.dll"))
	shell32 := win.LoadLibraryW(win.L("shell32.dll"))
	if user32 == nil || shell32 == nil do return
	api.is_format_available = auto_cast win.GetProcAddress(user32, "IsClipboardFormatAvailable")
	api.open = auto_cast win.GetProcAddress(user32, "OpenClipboard")
	api.close = auto_cast win.GetProcAddress(user32, "CloseClipboard")
	api.get_data = auto_cast win.GetProcAddress(user32, "GetClipboardData")
	api.drag_query_file = auto_cast win.GetProcAddress(shell32, "DragQueryFileW")
	// Both DLLs ship with every Windows version, so a missing entry is a bug.
	assert(api.is_format_available != nil && api.open != nil && api.close != nil && api.get_data != nil && api.drag_query_file != nil)
	return api, true
}

// Paths of files copied in Explorer, in order; empty when the clipboard holds
// no file list.
clipboard_file_list :: proc(allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	api, ok := load_clipboard_api()
	if !ok do return out[:]
	if !api.is_format_available(win.CF_HDROP) do return out[:]
	if !api.open(nil) do return out[:]
	defer api.close()
	drop := win.HDROP(api.get_data(win.CF_HDROP))
	if drop == nil do return out[:]
	count := api.drag_query_file(drop, 0xFFFFFFFF, nil, 0)
	for i in 0 ..< count {
		n := api.drag_query_file(drop, i, nil, 0)
		buf := make([]u16, n + 1, context.temp_allocator)
		api.drag_query_file(drop, i, raw_data(buf), n + 1)
		path, err := win.utf16_to_utf8(buf[:n], allocator)
		if err == nil do append(&out, path)
	}
	return out[:]
}
