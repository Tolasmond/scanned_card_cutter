// Moiré removal for the whole scan, run once per scan in the background.
//
// The cleaned copy feeds only the extracted cards (previews and exports).
// Everything that locates cards (the canvas you place corners on, and card
// detection) uses the original scan: the filter softens the card edges and
// the scanner background, which makes edge finding much worse. The filter
// keeps the image size and alignment, so corners found on the original apply
// to the cleaned pixels unchanged.
package main

import "core:sync"
import "core:thread"
import im "imaging"
import rl "vendor:raylib"

Clean_Job :: struct {
	src:      im.Image, // borrowed: the scan stays loaded until the job is joined
	progress: im.Descreen_Progress,
	result:   im.Image,
	ok:       bool,
	finished: bool, // atomic
	started:  f64,
	thread:   ^thread.Thread,
}

@(private = "file")
clean_worker :: proc(job: ^Clean_Job) {
	job.result, job.ok = im.descreen_soft(job.src, &job.progress)
	sync.atomic_store(&job.finished, true)
}

// The pixels previews and exports read. Never use this to locate cards; read
// app.scan_px for that.
extract_source :: proc(app: ^App) -> im.Image {
	if app.moire && app.cleaned.pix != nil do return app.cleaned
	return app.scan_px
}

// True while the filter is on but its result is not ready yet.
moire_pending :: proc(app: ^App) -> bool {
	return app.moire && has_scan(app) && app.cleaned.pix == nil
}

moire_percent :: proc(app: ^App) -> int {
	if app.clean_job == nil do return 0
	return sync.atomic_load(&app.clean_job.progress.permille) / 10
}

set_moire :: proc(app: ^App, on: bool) {
	if app.moire == on do return
	app.moire = on
	mark_preview_dirty(app)
	if !on {
		set_status(app, false, "Moiré removal off.")
		return
	}
	if !has_scan(app) do return
	if app.cleaned.pix != nil {
		set_status(app, false, "Moiré removal on.")
		return
	}
	start_cleaning(app)
}

start_cleaning :: proc(app: ^App) {
	if app.clean_job != nil || app.cleaned.pix != nil || !has_scan(app) do return
	if app.sync_jobs {
		// Record/replay: run inline so the result never depends on timing.
		out, _ := im.descreen_soft(app.scan_px)
		accept_cleaned(app, out)
		set_status(app, false, "Moiré removed.")
		return
	}
	job := new(Clean_Job)
	job.src = app.scan_px
	job.started = rl.GetTime()
	// nil init_context: the worker gets its own default context and temp allocator.
	job.thread = thread.create_and_start_with_poly_data(job, clean_worker)
	app.clean_job = job
	set_status(app, false, "Removing moiré pattern (once per scan)...")
}

@(private = "file")
accept_cleaned :: proc(app: ^App, img: im.Image) {
	app.cleaned = img
	mark_preview_dirty(app)
}

// Once per frame: picks up a finished job.
poll_cleaning :: proc(app: ^App) {
	job := app.clean_job
	if job == nil || !sync.atomic_load(&job.finished) do return
	thread.join(job.thread)
	thread.destroy(job.thread)
	if job.ok {
		accept_cleaned(app, job.result)
		set_status(app, false, "Moiré removed in %.1f s.", rl.GetTime() - job.started)
	}
	free(job)
	app.clean_job = nil
}

// Stops a running job (waits for the current band, a fraction of a second)
// and frees the cleaned copy. Called before the scan goes away.
discard_cleaning :: proc(app: ^App) {
	if job := app.clean_job; job != nil {
		sync.atomic_store(&job.progress.cancel, true)
		thread.join(job.thread)
		thread.destroy(job.thread)
		if job.ok do im.image_destroy(&job.result)
		free(job)
		app.clean_job = nil
	}
	if app.cleaned.pix != nil do im.image_destroy(&app.cleaned)
}
