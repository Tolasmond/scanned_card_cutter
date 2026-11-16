#+build !windows
package main

// Linux and macOS file managers put copied files on the clipboard as text,
// which clipboard_paths parses; only Windows needs a separate file list.
clipboard_file_list :: proc(allocator := context.allocator) -> []string {
	return nil
}
