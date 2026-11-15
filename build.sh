#!/bin/sh
# Build Scan Tool on Linux or macOS using only the Odin toolchain.
#   ./build.sh                  optimized build  -> build/scan_tool
#   ./build.sh debug            debug build with bounds checks and symbols
#   ./build.sh test             run the imaging unit tests
#   ./build.sh replay           replay tests/replay/*.rec and compare with *.expected/
#   ./build.sh replay --update  (re)write the expected results from the current build
set -e
cd "$(dirname "$0")"
mkdir -p build
case "$1" in
  debug) odin build src -out:build/scan_tool -debug -vet -strict-style ;;
  test)  odin test src/imaging -vet -strict-style ;;
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
  *)     odin build src -out:build/scan_tool -o:speed -vet -strict-style ;;
esac
