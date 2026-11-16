#+build !windows
package main

// The scan worker runs real commands through sh, so these tests only build
// where sh exists. They live in their own file so that their imports are not
// left unused (and rejected by -vet) on Windows.

import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

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
	dir, err := os.make_directory_temp("", "scanned_card_cutter_test-*", context.temp_allocator)
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
	job = run_job({"scanned_card_cutter_no_such_program_xyz", "{out}"})
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
