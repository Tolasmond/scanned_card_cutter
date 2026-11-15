package main

import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

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

when ODIN_OS != .Windows {
	@(private = "file")
	run_job :: proc(args: []string, cancel_after: time.Duration = 0) -> ^Scan_Job {
		job := new(Scan_Job)
		job.args = args
		if cancel_after > 0 {
			// The worker checks the flag between waits, so setting it up front
			// still lets the process start; it must then be killed.
			sync.atomic_store(&job.cancel, true)
		}
		scan_worker(job)
		return job
	}

	@(test)
	test_scan_worker :: proc(t: ^testing.T) {
		dir, err := os.make_directory_temp("", "scan_tool_test-*", context.temp_allocator)
		testing.expect(t, err == nil)
		defer os.remove_all(dir)
		out, _ := os.join_path({dir, "scan.png"}, context.temp_allocator)

		// Success: the command writes the file.
		job := run_job({"sh", "-c", strings.concatenate({"printf PNG > '", out, "'"}, context.temp_allocator)})
		testing.expect_value(t, job.start_err, nil)
		testing.expect_value(t, job.exit_code, 0)
		testing.expect(t, wrote_file_test(out))
		delete(job.output)
		free(job)

		// Failure: exit code and the last line of its error output.
		job = run_job({"sh", "-c", "echo warming up; echo 'scanimage: no SANE devices found' >&2; exit 3"})
		testing.expect_value(t, job.exit_code, 3)
		testing.expect_value(t, last_output_line(job), "scanimage: no SANE devices found")
		delete(job.output)
		free(job)

		// A program that doesn't exist.
		job = run_job({"scan_tool_no_such_program_xyz", "{out}"})
		testing.expect(t, job.start_err != nil)
		free(job)

		// Cancel kills a running command promptly.
		start := time.now()
		job = run_job({"sleep", "30"}, cancel_after = 1)
		testing.expect(t, job.cancelled)
		testing.expect(t, time.since(start) < 5 * time.Second)
		delete(job.output)
		free(job)
	}

	@(private = "file")
	wrote_file_test :: proc(path: string) -> bool {
		data, err := os.read_entire_file(path, context.temp_allocator)
		return err == nil && string(data) == "PNG"
	}
}
