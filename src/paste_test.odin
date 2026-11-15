package main

import "core:testing"

@(test)
test_clipboard_paths_formats :: proc(t: ^testing.T) {
	// Plain path (GNOME Files' text/plain), URI list, and x-special/gnome-copied-files.
	cases := [?]struct {
		text: string,
		want: string,
	} {
		{"/home/me/Scans/scan 1.png", "/home/me/Scans/scan 1.png"},
		{"file:///home/me/Scans/scan%201.png\r\n", "/home/me/Scans/scan 1.png"},
		{"copy\nfile:///home/me/Scans/scan%201.png", "/home/me/Scans/scan 1.png"},
		{"file://localhost/tmp/a.png", "/tmp/a.png"},
		{"# comment\nfile:///tmp/%E2%82%AC.png", "/tmp/€.png"},
	}
	for c in cases {
		got := clipboard_paths(c.text, context.temp_allocator)
		if !testing.expectf(t, len(got) >= 1, "no path from %q", c.text) do continue
		testing.expect_value(t, got[0], c.want)
	}
}

@(test)
test_clipboard_paths_ignores_non_paths :: proc(t: ^testing.T) {
	testing.expect_value(t, len(clipboard_paths("hello world", context.temp_allocator)), 0)
	testing.expect_value(t, len(clipboard_paths("https://example.com/x.png", context.temp_allocator)), 0)
	testing.expect_value(t, len(clipboard_paths("file://otherhost/x.png", context.temp_allocator)), 0)
	two := clipboard_paths("/a.png\n/b.png\n", context.temp_allocator)
	testing.expect_value(t, len(two), 2)
}
