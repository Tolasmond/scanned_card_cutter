// Scanning straight into the app with a user-configured command.
//
// Each profile in scanners.ini (in the user's config folder) names a command
// that writes a PNG to {out}. The Scan button runs the chosen profile in the
// background, opens the PNG as the scan and deletes the file. Any program that
// can write a PNG works, so another scanner, driver or platform is a new
// profile, not new code. The command is the user's own: nothing ships with the
// app or depends on it.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "core:time/timezone"

SCANNERS_FILE :: "scanners.ini"
SCAN_OUTPUT_KEEP :: 4096 // bytes of the command's output kept for error messages

SCANNERS_EXAMPLE :: `# Scanner profiles for Scan Tool.
#
# Each [section] is one profile. The Scan button runs the chosen profile's
# command, which must write a PNG to {out}; the app opens it and deletes it.
# The command is split into arguments at spaces. Put "..." or '...' around an
# argument that contains spaces. It runs directly, not through a shell, so to
# use pipes or several steps, point it at a script.
#
# Scan at 300 dpi: card detection is tuned for it.
#
# Remove the # in front of an example to use it.

# Linux, macOS: SANE (any scanner scanimage supports, including AirScan/eSCL
# network scanners through the sane-airscan backend).
# [Flatbed 300 dpi]
# command = scanimage --source Flatbed --mode Color --resolution 300 --format=png -o {out}

# Windows: NAPS2 (naps2.com). Set up a profile named "Scan Tool" in NAPS2 first.
# [NAPS2]
# command = "C:\Program Files\NAPS2\NAPS2.Console.exe" --profile "Scan Tool" -o {out}
`

Scanner_Profile :: struct {
	name:    string,
	command: string,
}

Scan_Job :: struct {
	name:      string, // profile name
	args:      []string,
	out_dir:   string, // temporary folder, removed when the job is done
	out_path:  string,
	cancel:    bool, // atomic: set by the UI thread
	finished:  bool, // atomic: set by the worker
	cancelled: bool,
	start_err: os.Error,
	wait_err:  os.Error,
	exit_code: int,
	output:    [dynamic]u8, // the last SCAN_OUTPUT_KEEP bytes of stdout and stderr
	thread:    ^thread.Thread,
}

scanners_path :: proc(allocator := context.allocator) -> (string, bool) {
	dir, err := os.user_config_dir(context.temp_allocator)
	if err != nil || dir == "" do return "", false
	p, jerr := os.join_path({dir, "scan_tool", SCANNERS_FILE}, allocator)
	return p, jerr == nil
}

// Parses scanners.ini. Returns the profiles and, for the first line it could
// not use, a description of the problem.
parse_scanners :: proc(text: string, allocator := context.allocator) -> (profiles: [dynamic]Scanner_Profile, problem: string) {
	profiles = make([dynamic]Scanner_Profile, allocator)
	rest := text
	line_no := 0
	current := -1
	for raw in strings.split_lines_iterator(&rest) {
		line_no += 1
		line := strings.trim_space(raw)
		if line == "" || line[0] == '#' || line[0] == ';' do continue
		if line[0] == '[' {
			if line[len(line) - 1] != ']' || len(line) < 3 {
				if problem == "" do problem = fmt.aprintf("line %d: a profile name goes in [brackets]", line_no, allocator = allocator)
				current = -1
				continue
			}
			append(&profiles, Scanner_Profile{name = strings.clone(strings.trim_space(line[1:len(line) - 1]), allocator)})
			current = len(profiles) - 1
			continue
		}
		eq := strings.index_byte(line, '=')
		if eq < 0 || current < 0 {
			if problem == "" do problem = fmt.aprintf("line %d: expected [Profile name] or command = ...", line_no, allocator = allocator)
			continue
		}
		key := strings.trim_space(line[:eq])
		value := strings.trim_space(line[eq + 1:])
		if key == "command" {
			delete(profiles[current].command, allocator)
			profiles[current].command = strings.clone(value, allocator)
		} else if problem == "" {
			problem = fmt.aprintf("line %d: unknown setting %q", line_no, key, allocator = allocator)
		}
	}
	// A profile without a command can't scan; drop it and say so.
	for i := len(profiles) - 1; i >= 0; i -= 1 {
		if profiles[i].command != "" do continue
		if problem == "" do problem = fmt.aprintf("profile [%s] has no command", profiles[i].name, allocator = allocator)
		delete(profiles[i].name, allocator)
		ordered_remove(&profiles, i)
	}
	return
}

delete_scanners :: proc(profiles: ^[dynamic]Scanner_Profile) {
	for p in profiles {
		delete(p.name)
		delete(p.command)
	}
	clear(profiles)
}

// Splits a command line into arguments at spaces and tabs. "..." and '...'
// group an argument; there are no escapes, so Windows paths work unchanged.
// Returns false for an unterminated quote.
split_command :: proc(cmd: string, allocator := context.allocator) -> (args: [dynamic]string, ok: bool) {
	args = make([dynamic]string, allocator)
	b := strings.builder_make(context.temp_allocator)
	in_arg := false
	quote: u8 = 0
	for i in 0 ..< len(cmd) {
		c := cmd[i]
		switch {
		case quote != 0:
			if c == quote do quote = 0
			else do strings.write_byte(&b, c)
		case c == '"' || c == '\'':
			quote = c
			in_arg = true
		case c == ' ' || c == '\t':
			if in_arg do append(&args, strings.clone(strings.to_string(b), allocator))
			strings.builder_reset(&b)
			in_arg = false
		case:
			strings.write_byte(&b, c)
			in_arg = true
		}
	}
	if in_arg do append(&args, strings.clone(strings.to_string(b), allocator))
	return args, quote == 0
}

// Arguments with {out} replaced by out. Returns false when no argument names {out}.
expand_out :: proc(args: []string, out: string, allocator := context.allocator) -> (res: []string, ok: bool) {
	res = make([]string, len(args), allocator)
	for a, i in args {
		if strings.contains(a, "{out}") do ok = true
		// replace_all hands back a itself when there is nothing to replace;
		// every result is freed later, so always allocate.
		s, allocated := strings.replace_all(a, "{out}", out, allocator)
		res[i] = s if allocated else strings.clone(a, allocator)
	}
	return
}

// (Re)reads the profiles. Missing file: no profiles, no problem.
load_scanners :: proc(app: ^App) -> (problem: string) {
	delete_scanners(&app.scanners)
	path, ok := scanners_path(context.temp_allocator)
	if !ok do return ""
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return ""
	profiles, prob := parse_scanners(string(data), context.temp_allocator)
	for p in profiles do append(&app.scanners, Scanner_Profile{strings.clone(p.name), strings.clone(p.command)})
	app.scanner_index = clamp(app.scanner_index, 0, max(len(app.scanners) - 1, 0))
	return prob // temp allocator
}

// Writes the commented example file if there is none yet. Returns its path.
@(private = "file")
write_scanners_example :: proc() -> (path: string, ok: bool) {
	path = scanners_path(context.temp_allocator) or_return
	if os.exists(path) do return path, true
	if os.make_directory_all(os.dir(path)) != nil do return path, false
	return path, os.write_entire_file(path, SCANNERS_EXAMPLE) == nil
}

// A file name for the scan from the local time, so exports from scans made one
// after another get different names.
@(private = "file")
scan_file_name :: proc(allocator := context.allocator) -> string {
	now, _ := time.time_to_datetime(time.now())
	if tz, ok := timezone.region_load("local", context.temp_allocator); ok {
		if local, lok := timezone.datetime_to_tz(now, tz); lok do now = local
	}
	return fmt.aprintf("scan-%04d%02d%02d-%02d%02d%02d.png", now.year, now.month, now.day, now.hour, now.minute, now.second, allocator = allocator)
}

scan_available :: proc(app: ^App) -> bool {
	return app.scanning_allowed && app.job == nil && app.scan_job == nil
}

// Runs the chosen scanner profile (Scan button, Ctrl+N).
start_scan :: proc(app: ^App) {
	if !app.scanning_allowed || app.scan_job != nil do return
	if app.job != nil {
		set_status(app, true, "Wait for the export to finish before scanning.")
		return
	}
	if problem := load_scanners(app); problem != "" {
		path, _ := scanners_path(context.temp_allocator)
		set_status(app, true, "%s, %s", path, problem)
		if len(app.scanners) == 0 do return
	}
	if len(app.scanners) == 0 {
		path, ok := write_scanners_example()
		if ok do set_status(app, true, "No scanner set up yet. Add a profile to %s (it has examples).", path)
		else do set_status(app, true, "No scanner set up, and could not write an example file at %s.", path)
		return
	}
	prof := app.scanners[app.scanner_index]
	parts, ok := split_command(prof.command, context.temp_allocator)
	if !ok || len(parts) == 0 {
		set_status(app, true, "Scanner [%s]: the command has an unclosed quote.", prof.name)
		return
	}
	dir, derr := os.make_directory_temp("", "scan_tool-*", context.allocator)
	if derr != nil {
		set_status(app, true, "Could not make a temporary folder for the scan.")
		return
	}
	out, _ := os.join_path({dir, scan_file_name(context.temp_allocator)}, context.allocator)
	args, has_out := expand_out(parts[:], out)
	if !has_out {
		set_status(app, true, "Scanner [%s]: the command must contain %s, where the PNG goes.", prof.name, "{out}") // fmt reads {} itself
		for a in args do delete(a)
		delete(args)
		delete(out)
		_ = os.remove_all(dir)
		delete(dir)
		return
	}
	job := new(Scan_Job)
	job.name = strings.clone(prof.name)
	job.args = args
	job.out_dir = dir
	job.out_path = out
	job.thread = thread.create_and_start_with_poly_data(job, scan_worker)
	app.scan_job = job
	set_status(app, false, "Scanning with %s...", prof.name)
}

cancel_scan :: proc(app: ^App) {
	if app.scan_job != nil do sync.atomic_store(&app.scan_job.cancel, true)
}

@(private = "file")
keep_output :: proc(job: ^Scan_Job, data: []u8) {
	append(&job.output, ..data)
	if over := len(job.output) - SCAN_OUTPUT_KEEP; over > 0 do remove_range(&job.output, 0, over)
}

// Reads whatever the command has written so far, without blocking.
@(private = "file")
drain :: proc(job: ^Scan_Job, r: ^os.File) {
	buf: [1024]u8
	for {
		has, err := os.pipe_has_data(r)
		if !has || err != nil do return
		n, rerr := os.read(r, buf[:])
		if n > 0 do keep_output(job, buf[:n])
		if rerr != nil || n == 0 do return
	}
}

// Worker thread: owns the process handle, so killing and waiting never race.
scan_worker :: proc(job: ^Scan_Job) {
	defer sync.atomic_store(&job.finished, true)
	r, w, perr := os.pipe()
	if perr != nil {
		job.start_err = perr
		return
	}
	defer os.close(r)
	p, err := os.process_start({command = job.args, stdout = w, stderr = w})
	os.close(w) // the child has its own copy; EOF arrives when it exits
	if err != nil {
		job.start_err = err
		return
	}
	for {
		drain(job, r)
		if sync.atomic_load(&job.cancel) {
			_ = os.process_kill(p)
			_, _ = os.process_wait(p)
			job.cancelled = true
			return
		}
		state, werr := os.process_wait(p, 50 * time.Millisecond)
		if werr == os.General_Error.Timeout do continue
		if werr != nil {
			job.wait_err = werr
			return
		}
		if state.exited {
			drain(job, r)
			job.exit_code = state.exit_code
			if !state.success && job.exit_code == 0 do job.exit_code = -1 // killed by a signal
			return
		}
	}
}

// The last non-empty line of the command's output, for the status line.
last_output_line :: proc(job: ^Scan_Job) -> string {
	text := strings.trim_space(string(job.output[:]))
	if i := strings.last_index_any(text, "\r\n"); i >= 0 do text = text[i + 1:]
	return text
}

@(private = "file")
wrote_file :: proc(path: string) -> bool {
	fi, err := os.stat(path, context.temp_allocator)
	return err == nil && fi.size > 0
}

@(private = "file")
destroy_scan_job :: proc(job: ^Scan_Job) {
	_ = os.remove_all(job.out_dir) // the scan and anything else the command left there
	delete(job.name)
	for a in job.args do delete(a)
	delete(job.args)
	delete(job.out_dir)
	delete(job.out_path)
	delete(job.output)
	free(job)
}

poll_scan :: proc(app: ^App) {
	job := app.scan_job
	if job == nil || !sync.atomic_load(&job.finished) do return
	// A new scan replaces the current one, which an export is still writing:
	// open it once the export is done.
	if app.job != nil do return
	thread.join(job.thread)
	thread.destroy(job.thread)
	app.scan_job = nil
	defer destroy_scan_job(job)

	switch {
	case job.cancelled:
		set_status(app, false, "Scan cancelled.")
	case job.start_err != nil:
		set_status(app, true, "Scanner [%s]: could not run %s (%v).", job.name, job.args[0], job.start_err)
	case job.wait_err != nil:
		set_status(app, true, "Scanner [%s]: lost track of the command (%v).", job.name, job.wait_err)
	case job.exit_code != 0:
		msg := last_output_line(job)
		if msg != "" do set_status(app, true, "Scan failed (exit %d): %s", job.exit_code, msg)
		else do set_status(app, true, "Scan failed: %s exited with code %d.", job.args[0], job.exit_code)
	case !wrote_file(job.out_path):
		set_status(app, true, "Scanner [%s]: the command finished but wrote no PNG to %s.", job.name, "{out}")
	case:
		if load_scan(app, job.out_path, temporary = true) {
			set_status(app, false, "Scanned with %s (%d x %d). Press D to detect the cards, or A to add one.", job.name, app.scan.width, app.scan.height)
		}
	}
}

// Stops a running scan and waits for the worker (app exit).
discard_scan :: proc(app: ^App) {
	job := app.scan_job
	if job == nil do return
	sync.atomic_store(&job.cancel, true)
	thread.join(job.thread)
	thread.destroy(job.thread)
	destroy_scan_job(job)
	app.scan_job = nil
}
