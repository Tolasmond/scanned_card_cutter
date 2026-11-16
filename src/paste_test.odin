package main

import "core:testing"

@(private = "file")
Paste_Case :: struct {
	text: string,
	want: string,
}

// clipboard_paths accepts each platform's own paths, so the cases differ:
// POSIX paths on Linux and macOS, drive-letter and UNC paths on Windows.
when ODIN_OS == .Windows {
	@(private = "file")
	PASTE_CASES := [?]Paste_Case {
		{`C:\Users\me\Scans\scan 1.png`, `C:\Users\me\Scans\scan 1.png`},
		{`\\server\share\scan 1.png`, `\\server\share\scan 1.png`},
		{"file:///C:/Users/me/Scans/scan%201.png\r\n", "C:/Users/me/Scans/scan 1.png"},
		{"copy\nfile:///C:/Users/me/Scans/scan%201.png", "C:/Users/me/Scans/scan 1.png"},
		{"file://localhost/C:/tmp/a.png", "C:/tmp/a.png"},
		{"# comment\nfile:///C:/tmp/%E2%82%AC.png", "C:/tmp/€.png"},
	}
	@(private = "file")
	TWO_PATHS :: "C:\\a.png\nC:\\b.png\n"
} else {
	// Plain path (GNOME Files' text/plain), URI list, and x-special/gnome-copied-files.
	@(private = "file")
	PASTE_CASES := [?]Paste_Case {
		{"/home/me/Scans/scan 1.png", "/home/me/Scans/scan 1.png"},
		{"file:///home/me/Scans/scan%201.png\r\n", "/home/me/Scans/scan 1.png"},
		{"copy\nfile:///home/me/Scans/scan%201.png", "/home/me/Scans/scan 1.png"},
		{"file://localhost/tmp/a.png", "/tmp/a.png"},
		{"# comment\nfile:///tmp/%E2%82%AC.png", "/tmp/€.png"},
	}
	@(private = "file")
	TWO_PATHS :: "/a.png\n/b.png\n"
}

@(test)
test_clipboard_paths_formats :: proc(t: ^testing.T) {
	for c in PASTE_CASES {
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
	two := clipboard_paths(TWO_PATHS, context.temp_allocator)
	testing.expect_value(t, len(two), 2)
}
