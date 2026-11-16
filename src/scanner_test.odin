package main

import "core:testing"

@(test)
test_parse_scanners :: proc(t: ^testing.T) {
	text := `# comment
; also a comment

[Flatbed 300 dpi]
command = scanimage --resolution 300 -o {out}
[ Second ]
command=b {out}
[Empty]
`
	profiles, problem := parse_scanners(text, context.temp_allocator)
	testing.expect_value(t, len(profiles), 2)
	testing.expect_value(t, profiles[0].name, "Flatbed 300 dpi")
	testing.expect_value(t, profiles[0].command, "scanimage --resolution 300 -o {out}")
	testing.expect_value(t, profiles[1].name, "Second")
	testing.expect_value(t, profiles[1].command, "b {out}")
	testing.expect_value(t, problem, "profile [Empty] has no command")

	_, problem = parse_scanners("command = x {out}\n", context.temp_allocator)
	testing.expect_value(t, problem, "line 1: expected [Profile name] or command = ...")
	_, problem = parse_scanners("[A]\ncommand = x {out}\ndpi = 300\n", context.temp_allocator)
	testing.expect_value(t, problem, `line 3: unknown setting "dpi"`)

	// The shipped example parses, and every profile in it is commented out.
	profiles, problem = parse_scanners(SCANNERS_EXAMPLE, context.temp_allocator)
	testing.expect_value(t, len(profiles), 0)
	testing.expect_value(t, problem, "")
}

@(test)
test_split_command :: proc(t: ^testing.T) {
	args, ok := split_command(`"C:\Program Files\NAPS2\NAPS2.Console.exe"  --profile 'Scan Tool' -o {out}`, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, len(args), 5)
	if len(args) == 5 {
		testing.expect_value(t, args[0], `C:\Program Files\NAPS2\NAPS2.Console.exe`)
		testing.expect_value(t, args[2], "Scan Tool")
		testing.expect_value(t, args[4], "{out}")
	}
	// Quotes inside an argument join with it; an empty quoted argument is kept.
	args, ok = split_command(`a --name="x y" ""`, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, len(args), 3)
	if len(args) == 3 {
		testing.expect_value(t, args[1], "--name=x y")
		testing.expect_value(t, args[2], "")
	}
	_, ok = split_command(`a "b`, context.temp_allocator)
	testing.expect(t, !ok)

	out, has := expand_out({"scanimage", "--output-file={out}"}, "/tmp/a b.png", context.temp_allocator)
	testing.expect(t, has)
	testing.expect_value(t, out[1], "--output-file=/tmp/a b.png")
	_, has = expand_out({"scanimage", "-o", "scan.png"}, "/tmp/x.png", context.temp_allocator)
	testing.expect(t, !has)
	// Every result is its own allocation, with or without {out}: the job frees
	// them all (the test runner's tracking allocator reports a bad free).
	owned, _ := expand_out({"scanimage", "-o", "{out}"}, "/tmp/x.png")
	for a in owned do delete(a)
	delete(owned)
}
