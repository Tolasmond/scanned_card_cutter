// Scores moiré removal on synthetic scans that have a clean reference.
//
//   ./build.sh moire-bench CORPUS_DIR [development|holdout]
//
// CORPUS_DIR must come from `./build.sh synth DIR --clean`: each scan has a
// "-clean.png" twin printed without halftone and without sensor noise. The
// score is PSNR against that clean twin over the card interiors (each card's
// quad shrunk away from its edges, where geometry rather than moiré differs),
// for the raw scan and for the Soft filter's output. Higher is better; the
// gain is what the filter buys.
package moire_bench

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:time"
import im "../../src/imaging"
import rl "vendor:raylib"

Scan :: struct {
	id:      string,
	split:   string,
	preset:  string,
	image:   string,
	clean:   string,
	regions: [][4][2]f64,
}

Annotations :: struct {
	scans: []Scan,
}

load :: proc(dir, name: string) -> (im.Image, rl.Image, bool) {
	path, _ := os.join_path({dir, name}, context.temp_allocator)
	img := rl.LoadImage(fmt.ctprintf("%s", path))
	if img.data == nil do return {}, img, false
	rl.ImageFormat(&img, .UNCOMPRESSED_R8G8B8A8)
	return im.Image{int(img.width), int(img.height), ([^]u8)(img.data)[:img.width * img.height * 4]}, img, true
}

// Card interiors: inside each quad and at least `inset` pixels from its sides.
interior_mask :: proc(w, h: int, regions: [][4][2]f64, inset: f64) -> []bool {
	mask := make([]bool, w * h)
	for r in regions {
		q: [4]im.Vec2
		for k in 0 ..< 4 do q[k] = {r[k][0], r[k][1]}
		lo, hi := q[0], q[0]
		for p in q {lo = {min(lo.x, p.x), min(lo.y, p.y)}; hi = {max(hi.x, p.x), max(hi.y, p.y)}}
		for y in max(0, int(lo.y)) ..< min(h, int(hi.y) + 1) {
			for x in max(0, int(lo.x)) ..< min(w, int(hi.x) + 1) {
				p := im.Vec2{f64(x), f64(y)}
				inside := true
				for k in 0 ..< 4 {
					a, b := q[k], q[(k + 1) % 4]
					d := b - a
					// Signed distance to the side; corners are clockwise on screen (y down).
					dist := ((p.x - a.x) * d.y - (p.y - a.y) * d.x) / math.sqrt(d.x * d.x + d.y * d.y)
					if -dist < inset {inside = false; break}
				}
				if inside do mask[y * w + x] = true
			}
		}
	}
	return mask
}

psnr :: proc(a, b: im.Image, mask: []bool) -> f64 {
	sq, n := 0.0, 0.0
	for i in 0 ..< a.w * a.h {
		if !mask[i] do continue
		for c in 0 ..< 3 {
			d := f64(a.pix[i * 4 + c]) - f64(b.pix[i * 4 + c])
			sq += d * d
			n += 1
		}
	}
	if n == 0 do return 0
	return 10 * math.log10(255 * 255 / max(sq / n, 1e-9))
}

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: moire_bench CORPUS_DIR [split]")
		os.exit(2)
	}
	dir := os.args[1]
	only := os.args[2] if len(os.args) > 2 else ""
	path, _ := os.join_path({dir, "annotations.json"}, context.temp_allocator)
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintln("cannot read", path)
		os.exit(2)
	}
	ann: Annotations
	if jerr := json.unmarshal(data, &ann); jerr != nil {
		fmt.eprintln("bad annotation file:", jerr)
		os.exit(2)
	}
	rl.SetTraceLogLevel(.WARNING)
	sum_raw, sum_filt, n := 0.0, 0.0, 0
	for s in ann.scans {
		if only != "" && s.split != only do continue
		if s.clean == "" do continue
		scan, rs, ok1 := load(dir, s.image)
		clean, rc, ok2 := load(dir, s.clean)
		if !ok1 || !ok2 {
			fmt.eprintln("missing image for", s.id)
			continue
		}
		mask := interior_mask(scan.w, scan.h, s.regions, 12)
		t := time.now()
		filtered, _ := im.descreen_soft(scan)
		ms := time.duration_milliseconds(time.since(t))
		raw_db, filt_db := psnr(scan, clean, mask), psnr(filtered, clean, mask)
		fmt.printfln("  %-28s raw %5.2f dB  filtered %5.2f dB  gain %+5.2f dB  (%.0f ms)", s.id, raw_db, filt_db, filt_db - raw_db, ms)
		sum_raw += raw_db
		sum_filt += filt_db
		n += 1
		im.image_destroy(&filtered)
		delete(mask)
		rl.UnloadImage(rs)
		rl.UnloadImage(rc)
		free_all(context.temp_allocator)
	}
	if n > 0 do fmt.printfln("mean over %d scans: raw %.2f dB  filtered %.2f dB  gain %+.2f dB", n, sum_raw / f64(n), sum_filt / f64(n), (sum_filt - sum_raw) / f64(n))
}
