// Automatic card detection, run on demand in the background. Detected cards
// become ordinary editable cards; uncertain ones are flagged for review.
//
// Detection always reads the original scan (app.scan_px), never the
// moiré-filtered copy, which softens the edges it looks for.
package main

import "core:sync"
import "core:thread"
import im "imaging"
import rl "vendor:raylib"

Detect_Job :: struct {
	src:      im.Image, // borrowed: the scan stays loaded until the job is joined
	result:   []im.Card_Candidate,
	finished: bool, // atomic
	started:  f64,
	thread:   ^thread.Thread,
}

@(private = "file")
detect_worker :: proc(job: ^Detect_Job) {
	job.result = im.detect_cards(job.src)
	sync.atomic_store(&job.finished, true)
}

start_detection :: proc(app: ^App) {
	if !has_scan(app) || app.detect_job != nil do return
	if app.sync_jobs {
		// Record/replay: run inline so the result never depends on timing.
		cands := im.detect_cards(app.scan_px)
		apply_detections(app, cands)
		delete(cands)
		return
	}
	job := new(Detect_Job)
	job.src = app.scan_px
	job.started = rl.GetTime()
	job.thread = thread.create_and_start_with_poly_data(job, detect_worker)
	app.detect_job = job
	set_status(app, false, "Detecting cards...")
}

poll_detection :: proc(app: ^App) {
	job := app.detect_job
	if job == nil || !sync.atomic_load(&job.finished) do return
	thread.join(job.thread)
	thread.destroy(job.thread)
	apply_detections(app, job.result)
	delete(job.result)
	free(job)
	app.detect_job = nil
}

// Waits for a running detection (a fraction of a second) and drops its result.
discard_detection :: proc(app: ^App) {
	job := app.detect_job
	if job == nil do return
	thread.join(job.thread)
	thread.destroy(job.thread)
	delete(job.result)
	free(job)
	app.detect_job = nil
}

// Overlap of a with b as a fraction of a's area.
@(private = "file")
overlap :: proc(a, b: [4]im.Vec2) -> f64 {
	a, b := a, b
	area := im.polygon_area(a[:])
	if area <= 0 do return 0
	return im.convex_intersection_area(a[:], b[:]) / area
}

apply_detections :: proc(app: ^App, cands: []im.Card_Candidate) {
	added, review, skipped := 0, 0, 0
	first := len(app.regions)
	outer: for c in cands {
		for r in app.regions {
			if overlap(c.corners, r.corners) >= 0.5 || overlap(r.corners, c.corners) >= 0.5 {
				skipped += 1
				continue outer
			}
		}
		reg := Region{corners = c.corners, review = c.source != .Full_Resolution_Edges}
		orient_for_output(app, &reg)
		append(&app.regions, reg)
		added += 1
		if reg.review do review += 1
	}
	if added == 0 {
		if skipped > 0 do set_status(app, false, "Detection found no new cards (%d already marked).", skipped)
		else do set_status(app, true, "No cards detected. Add them by hand with A.")
		return
	}
	select_region(app, first)
	if review > 0 {
		set_status(app, false, "Detected %d card(s); %d marked for review (pink): check their edges.", added, review)
	} else {
		set_status(app, false, "Detected %d card(s). Check each preview, then export.", added)
	}
}
