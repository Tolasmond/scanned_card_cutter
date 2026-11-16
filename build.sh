#!/bin/sh
# Build Scan Tool on Linux or macOS using only the Odin toolchain.
#   ./build.sh                  optimized build  -> build/scan_tool
#   ./build.sh debug            debug build with bounds checks and symbols
#   ./build.sh test             run the imaging, app and synthetic-scan unit tests
#   ./build.sh replay           replay tests/replay/*.rec and compare with *.expected/
#   ./build.sh replay --update  (re)write the expected results from the current build
#   ./build.sh synth DIR [opts] generate synthetic scans + DIR/annotations.json (tools/synth)
#   ./build.sh bench ANN DIR    score card detection: annotation file ANN, scans in DIR
#   ./build.sh moire-bench DIR  score moiré removal on a corpus made with `synth DIR --clean`
#   ./build.sh check            every check a change must pass: the debug and optimized
#                               builds, the tools, the unit tests and the replay tests
set -e
cd "$(dirname "$0")"
mkdir -p build
case "$1" in
  debug) odin build src -out:build/scan_tool -debug -vet -strict-style ;;
  test)  odin test src/imaging -vet -strict-style && odin test src -vet -strict-style && odin test tools/synth -vet -strict-style -o:speed ;;
  synth)
    [ -n "$2" ] || { echo "usage: ./build.sh synth OUTDIR [--clean] [--only PRESET] [--count N] [--scale S]"; exit 2; }
    odin build tools/synth -o:speed -vet -strict-style -out:build/synth
    shift; build/synth "$@" ;;
  moire-bench)
    [ -n "$2" ] || { echo "usage: ./build.sh moire-bench CORPUS_DIR [development|holdout]"; exit 2; }
    odin run tools/moire_bench -o:speed -vet -strict-style -out:build/moire_bench -- "$2" $3 ;;
  bench)
    [ -n "$3" ] || { echo "usage: ./build.sh bench ANNOTATIONS.json IMAGE_DIR [development|holdout]"; exit 2; }
    odin run tools/detect_bench -o:speed -vet -strict-style -out:build/detect_bench -- "$2" "$3" $4 $5 $6 ;;
  replay)
    odin build src -out:build/scan_tool -o:speed -vet -strict-style
    set -- tests/replay/*.rec "$2"
    if [ ! -e "$1" ]; then echo "No recordings in tests/replay/ (make one with: build/scan_tool --record tests/replay/NAME.rec SCAN.png)"; exit 0; fi
    update=""
    failed=0
    for arg in "$@"; do [ "$arg" = "--update" ] && update=1; done
    for rec in "$@"; do
      [ "$rec" = "--update" ] || [ -z "$rec" ] && continue
      expected="${rec%.rec}.expected"
      out=$(mktemp -d)
      code=0
      build/scan_tool --replay "$rec" --out "$out" --dump "$out/state.txt" --fast >"$out/log.txt" 2>&1 || code=$?
      if [ "$code" -ne 0 ]; then
        echo "FAIL  $rec (exit $code)"; grep "scan_tool:" "$out/log.txt" || true
        failed=$((failed + 1))
      elif [ -n "$update" ]; then
        rm -rf "$expected" && mkdir -p "$expected"
        rm "$out/log.txt" && cp "$out"/* "$expected"/
        echo "SAVED $expected"
      elif [ ! -d "$expected" ]; then
        echo "FAIL  $rec (no $expected; run ./build.sh replay --update)"
        failed=$((failed + 1))
      elif diff -r -x log.txt "$expected" "$out"; then
        echo "ok    $rec"
      else
        echo "FAIL  $rec (differs from $expected)"
        failed=$((failed + 1))
      fi
      rm -rf "$out"
    done
    [ "$failed" -eq 0 ] || { echo "$failed replay test(s) failed"; exit 1; }
    ;;
  check)
    odin build src -out:build/scan_tool -debug -vet -strict-style
    for tool in tools/synth tools/detect_bench tools/moire_bench; do odin check "$tool" -vet -strict-style; done
    sh ./build.sh test
    sh ./build.sh replay
    ;;
  *)     odin build src -out:build/scan_tool -o:speed -vet -strict-style ;;
esac
