package main

import "core:os"
import "core:testing"

// load_scan checks the PNG signature before reading a whole file.
@(test)
test_png_signature :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("", "scan_tool_test-*", context.temp_allocator)
	if !testing.expect_value(t, err, nil) do return
	defer os.remove_all(dir)
	file :: proc(dir, name: string, data: []u8) -> string {
		path, _ := os.join_path({dir, name}, context.temp_allocator)
		_ = os.write_entire_file(path, data)
		return path
	}
	png := []u8{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n', 0, 0, 0, 13}
	testing.expect_value(t, png_signature(file(dir, "a.png", png)), Png_Check.PNG)
	testing.expect_value(t, png_signature(file(dir, "b.png", png[:7])), Png_Check.Not_PNG)
	testing.expect_value(t, png_signature(file(dir, "c.png", transmute([]u8)string("\xff\xd8\xff\xe0 a JPEG"))), Png_Check.Not_PNG)
	testing.expect_value(t, png_signature(file(dir, "empty.png", nil)), Png_Check.Not_PNG)
	missing, _ := os.join_path({dir, "missing.png"}, context.temp_allocator)
	testing.expect_value(t, png_signature(missing), Png_Check.Unreadable)
}
