// Input record/replay harness for regression tests, built on raylib's
// automation events.
//
//   scan_tool --record session.rec [--out DIR] scan.png
//       Use the app normally; closing the window saves the recording.
//   scan_tool --replay session.rec [--out DIR] [--dump state.txt] [--fast]
//       Re-runs the recorded input frame by frame, waits for previews and any
//       export to finish, writes the state dump, then exits.
//
// Both modes use a fixed-size window: mouse positions are recorded in window
// pixels, so a replay only means anything at the size it was recorded at.
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import rl "vendor:raylib"

REPLAY_MAGIC :: "scan_tool-replay 1"
HARNESS_W :: 1500
HARNESS_H :: 950
REPLAY_SETTLE_FRAMES :: 3 // idle frames after the last event before the dump
REPLAY_TIMEOUT_FRAMES :: 60 * 120 // give up if previews/export never settle

// raylib's AutomationEventType values (rcore.c). Only these are recorded:
// gestures and touch events are derived from the mouse and would only repeat it.
EV_KEY_UP :: 1
EV_KEY_DOWN :: 2
EV_MOUSE_BUTTON_UP :: 5
EV_MOUSE_BUTTON_DOWN :: 6
EV_MOUSE_POSITION :: 7
EV_MOUSE_WHEEL :: 8

Harness_Mode :: enum {
	Off,
	Record,
	Replay,
}

Options :: struct {
	scan:   string,
	out:    string,
	record: string,
	replay: string,
	dump:   string,
	fast:   bool,
}

Harness :: struct {
	mode:      Harness_Mode,
	path:      string, // the recording file
	dump_path: string,
	scan:      string, // scan the recording starts from
	out:       string, // output folder the recording starts with
	size:      [2]i32, // window size the recording was made at
	frame:     int,
	events:    [dynamic]rl.AutomationEvent, // .frame is the loop iteration that sees the event
	exit_code: int,

	// Record
	list:      rl.AutomationEventList, // raylib's buffer, drained every frame
	recording: bool,

	// Replay
	next:      int,
	mouse:     [2]i32,
	has_mouse: bool,
	settled:   int,
}

USAGE :: `usage:
  scan_tool [scan.png]
  scan_tool --record FILE [--out DIR] [scan.png]
  scan_tool --replay FILE [--out DIR] [--dump FILE] [--fast]

  --record FILE  record input until the window closes, then save it to FILE
  --replay FILE  replay FILE, write the --dump state file, and exit
  --out DIR      start with DIR as the output folder
  --dump FILE    after a replay, write the cards and settings to FILE
  --fast         replay without the 60 fps cap
`

parse_args :: proc(args: []string) -> (o: Options, ok: bool) {
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		value :: proc(args: []string, i: ^int) -> (string, bool) {
			if i^ + 1 >= len(args) do return "", false
			i^ += 1
			return args[i^], true
		}
		switch a {
		case "--record":
			o.record = value(args, &i) or_return
		case "--replay":
			o.replay = value(args, &i) or_return
		case "--out":
			o.out = value(args, &i) or_return
		case "--dump":
			o.dump = value(args, &i) or_return
		case "--fast":
			o.fast = true
		case "-h", "--help":
			return o, false
		case:
			if strings.has_prefix(a, "--") || o.scan != "" do return o, false
			o.scan = a
		}
	}
	if o.record != "" && o.replay != "" do return o, false
	if o.replay != "" && o.scan != "" do return o, false // the recording names its scan
	if (o.dump != "" || o.fast) && o.replay == "" do return o, false
	return o, true
}

// Sets up the harness before the window opens. Returns false (after printing
// why) when a replay file cannot be used.
harness_init :: proc(h: ^Harness, o: Options) -> bool {
	switch {
	case o.record != "":
		h.mode = .Record
		h.path = o.record
		h.scan = o.scan
		h.out = o.out
	case o.replay != "":
		h.mode = .Replay
		h.path = o.replay
		h.dump_path = o.dump
		if !load_recording(h) do return false
		if o.out != "" {
			delete(h.out)
			h.out = strings.clone(o.out) // harness_destroy frees what a replay owns
		}
	}
	return true
}

harness_window_flags :: proc(h: ^Harness, fast: bool) -> rl.ConfigFlags {
	if h.mode == .Off do return {.WINDOW_RESIZABLE, .MSAA_4X_HINT, .VSYNC_HINT}
	// Fixed size: tiling window managers float a window that cannot be resized.
	if fast do return {.MSAA_4X_HINT}
	return {.MSAA_4X_HINT, .VSYNC_HINT}
}

harness_window_size :: proc(h: ^Harness) -> (i32, i32) {
	if h.mode == .Replay do return h.size.x, h.size.y
	return HARNESS_W, HARNESS_H
}

harness_start :: proc(h: ^Harness) {
	if h.mode != .Record do return
	h.size = {rl.GetScreenWidth(), rl.GetScreenHeight()}
	h.list = rl.LoadAutomationEventList(nil)
	rl.SetAutomationEventList(&h.list)
	rl.SetAutomationEventBaseFrame(0)
	rl.StartAutomationEventRecording()
	h.recording = true
	// The cursor's starting place is not an event until it moves; record it so
	// a key that acts at the cursor replays at the same spot.
	m := rl.GetMousePosition()
	append(&h.events, rl.AutomationEvent{frame = 0, type = EV_MOUSE_POSITION, params = {i32(m.x), i32(m.y), 0, 0}})
}

// Runs at the top of every loop iteration, before the app reads input.
// Returns false when a replay is done and the loop should end.
harness_frame :: proc(h: ^Harness, app: ^App) -> bool {
	defer h.frame += 1
	size := [2]i32{rl.GetScreenWidth(), rl.GetScreenHeight()}
	switch h.mode {
	case .Off:
	case .Record:
		if !h.recording do return true
		// raylib recorded these during the previous EndDrawing; this iteration is
		// the first to see them, so that is the frame they replay on.
		for ev in h.list.events[:h.list.count] {
			switch ev.type {
			case EV_KEY_UP, EV_KEY_DOWN, EV_MOUSE_BUTTON_UP, EV_MOUSE_BUTTON_DOWN, EV_MOUSE_POSITION, EV_MOUSE_WHEEL:
				e := ev
				e.frame = u32(h.frame)
				append(&h.events, e)
			}
		}
		h.list.count = 0
		if size != h.size {
			rl.StopAutomationEventRecording()
			h.recording = false
			set_status(app, true, "Recording stopped: the window was resized, which a replay cannot reproduce.")
			fmt.eprintfln("scan_tool: recording stopped at frame %d: window resized from %v to %v", h.frame, h.size, size)
		}
	case .Replay:
		if size != h.size {
			fmt.eprintfln("scan_tool: replay window is %d x %d but %s was recorded at %d x %d", size.x, size.y, h.path, h.size.x, h.size.y)
			h.exit_code = 3
			return false
		}
		for h.next < len(h.events) && int(h.events[h.next].frame) <= h.frame {
			ev := h.events[h.next]
			rl.PlayAutomationEvent(ev)
			if ev.type == EV_MOUSE_POSITION {
				h.mouse = {ev.params[0], ev.params[1]}
				h.has_mouse = true
			}
			h.next += 1
		}
		// Put the replayed cursor back when a real pointer wandering over the
		// window has moved it, so it cannot steer the replay.
		if h.has_mouse && rl.GetMousePosition() != {f32(h.mouse.x), f32(h.mouse.y)} {
			rl.PlayAutomationEvent({type = EV_MOUSE_POSITION, params = {h.mouse.x, h.mouse.y, 0, 0}})
		}

		if h.next < len(h.events) do return true
		idle := app.job == nil && app.clean_job == nil && !app.preview_dirty && !(app.big_open && app.big_dirty)
		h.settled = h.settled + 1 if idle else 0
		if h.settled >= REPLAY_SETTLE_FRAMES do return false
		last := int(h.events[len(h.events) - 1].frame) if len(h.events) > 0 else 0
		if h.frame - last > REPLAY_TIMEOUT_FRAMES {
			fmt.eprintln("scan_tool: replay timed out waiting for previews/export to finish")
			h.exit_code = 4
			return false
		}
	}
	return true
}

// Runs after the loop: saves a recording, or writes a replay's state dump.
harness_finish :: proc(h: ^Harness, app: ^App) {
	switch h.mode {
	case .Off:
	case .Record:
		if h.recording do rl.StopAutomationEventRecording()
		if err := save_recording(h); err != nil {
			fmt.eprintfln("scan_tool: could not write %s: %v", h.path, err)
			h.exit_code = 1
		} else {
			fmt.printfln("scan_tool: recorded %d events over %d frames to %s", len(h.events), h.frame, h.path)
		}
		rl.UnloadAutomationEventList(h.list)
	case .Replay:
		if h.exit_code != 0 || h.dump_path == "" do return
		if err := os.write_entire_file(h.dump_path, transmute([]u8)state_dump(app)); err != nil {
			fmt.eprintfln("scan_tool: could not write %s: %v", h.dump_path, err)
			h.exit_code = 1
		}
	}
}

harness_destroy :: proc(h: ^Harness) {
	if h.mode == .Replay {
		delete(h.scan)
		delete(h.out)
	}
	delete(h.events)
}

// File format, one record per line:
//   scan_tool-replay 1
//   size <width> <height>
//   scan <path>                      (optional)
//   out <path>                       (optional)
//   e <frame> <type> <p0> <p1> <p2> <p3>
save_recording :: proc(h: ^Harness) -> os.Error {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	fmt.sbprintln(&b, REPLAY_MAGIC)
	fmt.sbprintfln(&b, "size %d %d", h.size.x, h.size.y)
	if h.scan != "" do fmt.sbprintfln(&b, "scan %s", h.scan)
	if h.out != "" do fmt.sbprintfln(&b, "out %s", h.out)
	for e in h.events {
		fmt.sbprintfln(&b, "e %d %d %d %d %d %d", e.frame, e.type, e.params[0], e.params[1], e.params[2], e.params[3])
	}
	return os.write_entire_file(h.path, b.buf[:])
}

load_recording :: proc(h: ^Harness) -> bool {
	data, err := os.read_entire_file(h.path, context.allocator)
	if err != nil {
		fmt.eprintfln("scan_tool: could not read %s: %v", h.path, err)
		return false
	}
	defer delete(data)
	text := string(data)
	n := 0
	for raw in strings.split_lines_iterator(&text) {
		n += 1
		line := strings.trim_right(raw, "\r")
		if n == 1 {
			if line != REPLAY_MAGIC {
				fmt.eprintfln("scan_tool: %s is not a scan_tool recording", h.path)
				return false
			}
			continue
		}
		key, _, rest := strings.partition(line, " ")
		switch key {
		case "":
		case "size":
			f := strings.fields(rest, context.temp_allocator)
			if len(f) != 2 do return bad_line(h, n)
			w, ok1 := strconv.parse_int(f[0])
			hh, ok2 := strconv.parse_int(f[1])
			if !ok1 || !ok2 || w <= 0 || hh <= 0 do return bad_line(h, n)
			h.size = {i32(w), i32(hh)}
		case "scan":
			h.scan = resolve_beside(h.path, rest)
		case "out":
			h.out = strings.clone(rest)
		case "e":
			f := strings.fields(rest, context.temp_allocator)
			if len(f) != 6 do return bad_line(h, n)
			v: [6]int
			for s, i in f {
				ok: bool
				if v[i], ok = strconv.parse_int(s); !ok do return bad_line(h, n)
			}
			if v[0] < 0 do return bad_line(h, n)
			append(&h.events, rl.AutomationEvent{frame = u32(v[0]), type = u32(v[1]), params = {i32(v[2]), i32(v[3]), i32(v[4]), i32(v[5])}})
		case:
			return bad_line(h, n)
		}
	}
	if h.size == {} {
		fmt.eprintfln("scan_tool: %s has no size line", h.path)
		return false
	}
	return true
}

@(private = "file")
bad_line :: proc(h: ^Harness, n: int) -> bool {
	fmt.eprintfln("scan_tool: %s:%d: unreadable line", h.path, n)
	return false
}

// A relative scan path is taken from the working directory when it exists
// there, otherwise from the recording's folder, so a recording can sit next
// to its scan.
@(private = "file")
resolve_beside :: proc(rec_path, p: string) -> string {
	if os.is_absolute_path(p) || os.exists(p) do return strings.clone(p)
	beside, _ := os.join_path({os.dir(rec_path), p}, context.allocator)
	return beside
}

// The app state a replay is checked against. Paths are reduced to names and
// the output folder to "<out>", so the dump is the same wherever it runs.
state_dump :: proc(app: ^App) -> string {
	b := strings.builder_make(context.temp_allocator)
	if has_scan(app) {
		fmt.sbprintfln(&b, "scan %s %d x %d", os.base(app.scan_path), app.scan.width, app.scan.height)
	} else {
		fmt.sbprintln(&b, "scan none")
	}
	fmt.sbprintfln(&b, "output %d x %d radius %d trim %d prefix %q", app.out_w, app.out_h, app.radius, app.trim, buf_string(app.prefix[:]))
	fmt.sbprintfln(&b, "moire %s", "on" if app.moire else "off")
	fmt.sbprintfln(&b, "cards %d selected %d focused_corner %d", len(app.regions), app.selected + 1, app.focused_corner + 1)
	for r, i in app.regions {
		fmt.sbprintf(&b, "card %d", i + 1)
		for c in r.corners do fmt.sbprintf(&b, " (%.2f, %.2f)", c.x, c.y)
		fmt.sbprintln(&b)
	}
	fmt.sbprintfln(&b, "preview %s", "open" if app.big_open else "closed")
	status := status_text(app)
	if dir := buf_string(app.out_dir[:]); dir != "" do status, _ = strings.replace_all(status, dir, "<out>", context.temp_allocator)
	fmt.sbprintfln(&b, "status %s%s", "error: " if app.status_error else "", status)
	return strings.to_string(b)
}
