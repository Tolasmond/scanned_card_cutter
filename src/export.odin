// Background export of every card to PNG files.
package main

import "core:fmt"
import "core:os"
import "core:sync"
import "core:thread"
import im "imaging"
import rl "vendor:raylib"

Export_Item :: struct {
	corners: [4]im.Vec2,
	path:    string,
}

Export_Job :: struct {
	src:      im.Image, // borrowed: the scan must stay loaded until the job finishes
	settings: im.Extract_Settings,
	items:    []Export_Item,
	done:     int, // atomic
	finished: bool, // atomic
	errors:   [dynamic]string, // written by the worker; read only after `finished`
	thread:   ^thread.Thread,
}

// Encodes RGBA pixels as PNG (raylib's bundled stb_image_write) and writes the file.
write_png :: proc(path: string, image: im.Image) -> bool {
	rimg := rl.Image {
		data    = raw_data(image.pix),
		width   = i32(image.w),
		height  = i32(image.h),
		mipmaps = 1,
		format  = .UNCOMPRESSED_R8G8B8A8,
	}
	size: i32
	data := rl.ExportImageToMemory(rimg, ".png", &size)
	if data == nil || size <= 0 do return false
	defer rl.MemFree(data)
	return os.write_entire_file(path, ([^]u8)(data)[:size]) == nil
}

@(private = "file")
export_worker :: proc(job: ^Export_Job) {
	for item in job.items {
		out, ok := im.extract_card(job.src, item.corners, job.settings)
		if !ok {
			append(&job.errors, fmt.aprintf("%s: card shape is invalid", os.base(item.path)))
		} else {
			if !write_png(item.path, out) do append(&job.errors, fmt.aprintf("%s: could not write file", os.base(item.path)))
			im.image_destroy(&out)
		}
		free_all(context.temp_allocator)
		sync.atomic_add(&job.done, 1)
	}
	sync.atomic_store(&job.finished, true)
}

export_start :: proc(src: im.Image, settings: im.Extract_Settings, items: []Export_Item) -> ^Export_Job {
	job := new(Export_Job)
	job.src = src
	job.settings = settings
	job.items = items
	// nil init_context: the worker gets its own default context and temp allocator.
	job.thread = thread.create_and_start_with_poly_data(job, export_worker)
	return job
}

export_progress :: proc(job: ^Export_Job) -> (done, total: int, finished: bool) {
	return sync.atomic_load(&job.done), len(job.items), sync.atomic_load(&job.finished)
}

export_destroy :: proc(job: ^Export_Job) {
	thread.join(job.thread)
	thread.destroy(job.thread)
	for it in job.items do delete(it.path)
	delete(job.items)
	for e in job.errors do delete(e)
	delete(job.errors)
	free(job)
}
