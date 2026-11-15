package main

import "core:testing"

@(test)
test_next_focus :: proc(t: ^testing.T) {
	avail := Focus_Set{.Open, .Width, .Export, .Exit}
	// Forward from the canvas starts at the first control, and skips unavailable ones.
	testing.expect_value(t, next_focus(.None, avail, false), Focus.Open)
	testing.expect_value(t, next_focus(.Width, avail, false), Focus.Export)
	// Wraps around past the last control, and never lands on .None.
	testing.expect_value(t, next_focus(.Exit, avail, false), Focus.Open)
	// Backwards.
	testing.expect_value(t, next_focus(.None, avail, true), Focus.Exit)
	testing.expect_value(t, next_focus(.Open, avail, true), Focus.Exit)
	testing.expect_value(t, next_focus(.Export, avail, true), Focus.Width)
	// From a control that has become unavailable (e.g. Delete after the last card went).
	testing.expect_value(t, next_focus(.Delete, avail, false), Focus.Export)
	testing.expect_value(t, next_focus(.Delete, avail, true), Focus.Width)
	// Nothing to focus.
	testing.expect_value(t, next_focus(.Open, {}, false), Focus.None)
}
