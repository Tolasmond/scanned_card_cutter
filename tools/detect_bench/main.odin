// Scores card detection against hand-corrected corners.
//
//   ./build.sh bench ANNOTATIONS.json IMAGE_DIR [development|holdout]
//
// Annotation file format:
//   {"scans": [{"id": "...", "split": "development" | "holdout",
//               "image": "file.png",       (relative to IMAGE_DIR)
//               "regions": [[[x, y], [x, y], [x, y], [x, y]], ...]}]}
// Regions are each card's corners, clockwise from the top-left, at the
// intersections of its outer straight edges.
//
// A detection matches a card when their IoU is at least 0.35 (greedy, best
// first). Corner error is the distance between corresponding corners.
package detect_bench

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:time"
import im "../../src/imaging"
import rl "vendor:raylib"

Scan :: struct {
	id:      string,
	split:   string,
	image:   string,
	regions: [][4][2]f64,
}

Annotations :: struct {
	scans: []Scan,
}

iou :: proc(a, b: im.Quad) -> f64 {
	a, b := a, b
	inter := im.convex_intersection_area(a[:], b[:])
	u := im.polygon_area(a[:]) + im.polygon_area(b[:]) - inter
	return inter / u if u > 0 else 0
}

percentile :: proc(v: []f64, p: f64) -> f64 {
	if len(v) == 0 do return 0
	s := slice.clone(v, context.temp_allocator)
	slice.sort(s)
	// numpy's default linear interpolation
	pos := p / 100 * f64(len(s) - 1)
	lo := int(math.floor(pos))
	hi := min(lo + 1, len(s) - 1)
	return s[lo] + (s[hi] - s[lo]) * (pos - f64(lo))
}

main :: proc() {
	if len(os.args) < 3 {
		fmt.eprintln("usage: detect_bench ANNOTATIONS.json IMAGE_DIR [split]")
		os.exit(2)
	}
	data, err := os.read_entire_file(os.args[1], context.allocator)
	if err != nil {
		fmt.eprintln("cannot read", os.args[1])
		os.exit(2)
	}
	ann: Annotations
	if jerr := json.unmarshal(data, &ann); jerr != nil {
		fmt.eprintln("bad annotation file:", jerr)
		os.exit(2)
	}
	only := os.args[3] if len(os.args) > 3 else ""
	rl.SetTraceLogLevel(.WARNING)

	for split in ([]string{"development", "holdout"}) {
		if only != "" && only != split do continue
		errs := make([dynamic]f64)
		found, total, false_pos, scans := 0, 0, 0, 0
		ms_total := 0.0
		for s in ann.scans {
			if s.split != split do continue
			path, _ := os.join_path({os.args[2], s.image}, context.temp_allocator)
			img := rl.LoadImage(fmt.ctprintf("%s", path))
			if img.data == nil {
				fmt.eprintln("missing image:", path)
				continue
			}
			rl.ImageFormat(&img, .UNCOMPRESSED_R8G8B8A8)
			src := im.Image{int(img.width), int(img.height), ([^]u8)(img.data)[:img.width * img.height * 4]}
			t := time.now()
			cands := im.detect_cards(src)
			ms_total += time.duration_milliseconds(time.since(t))
			scans += 1

			truth := make([]im.Quad, len(s.regions), context.temp_allocator)
			for r, i in s.regions do for k in 0 ..< 4 do truth[i][k] = {r[k][0], r[k][1]}
			Pair :: struct {
				v:    f64,
				p, t: int,
			}
			pairs := make([dynamic]Pair, context.temp_allocator)
			for c, pi in cands do for q, ti in truth do append(&pairs, Pair{iou(c.corners, q), pi, ti})
			slice.sort_by(pairs[:], proc(a, b: Pair) -> bool {return a.v > b.v})
			used_p := make([]bool, len(cands), context.temp_allocator)
			used_t := make([]bool, len(truth), context.temp_allocator)
			matched := 0
			for pr in pairs {
				if pr.v < 0.35 || used_p[pr.p] || used_t[pr.t] do continue
				used_p[pr.p], used_t[pr.t] = true, true
				matched += 1
				for k in 0 ..< 4 {
					d := cands[pr.p].corners[k] - truth[pr.t][k]
					append(&errs, math.sqrt(d.x * d.x + d.y * d.y))
				}
			}
			found += matched
			total += len(truth)
			false_pos += len(cands) - matched
			fmt.printfln("  %-16s %d/%d found, %d false", s.id, matched, len(truth), len(cands) - matched)
			delete(cands)
			rl.UnloadImage(img)
			free_all(context.temp_allocator)
		}
		if scans == 0 do continue
		fmt.printfln("%-12s recall %d/%d  false %d  corner error median %.2f  p95 %.2f  max %.2f px  (%.0f ms/scan)",
			split, found, total, false_pos, percentile(errs[:], 50), percentile(errs[:], 95), percentile(errs[:], 100), ms_total / f64(scans))
		delete(errs)
	}
}
