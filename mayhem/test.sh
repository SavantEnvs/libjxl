#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

CJXL="$SRC/build-tests/tools/cjxl"
DJXL="$SRC/build-tests/tools/djxl"
JXLINFO="$SRC/build-tests/tools/jxlinfo"
for b in "$CJXL" "$DJXL" "$JXLINFO"; do
  [ -x "$b" ] || { echo "missing $b: mayhem/build.sh must build it" >&2; emit_ctrf cjxl-djxl-oracle 0 1 0; exit 1; }
done

W="$(mktemp -d "${TMPDIR:-/tmp}/jxl-oracle.XXXXXX")"
trap 'rm -rf "$W"' EXIT
passed=0 ; failed=0
ok()   { passed=$((passed+1)); echo "PASS $1"; }
bad()  { failed=$((failed+1)); echo "FAIL $1"; }

# Deterministic synthetic images (netpbm), written by python so the oracle needs no image library.
python3 - "$W" <<'PY'
import sys, struct
w = sys.argv[1]
W, H = 64, 48
def px(x, y, c): return (x * 4 + y * 3 + c * 61 + ((x * y) % 7) * 9) & 255
open(f"{w}/rgb8.ppm", "wb").write(b"P6\n%d %d\n255\n" % (W, H) + bytes(px(x, y, c) for y in range(H) for x in range(W) for c in range(3)))
open(f"{w}/gray8.pgm", "wb").write(b"P5\n%d %d\n255\n" % (W, H) + bytes(px(x, y, 0) for y in range(H) for x in range(W)))
d16 = b"".join(struct.pack(">H", (px(x, y, c) * 257 + x * y) & 65535) for y in range(H) for x in range(W) for c in range(3))
open(f"{w}/rgb16.ppm", "wb").write(b"P6\n%d %d\n65535\n" % (W, H) + d16)
open(f"{w}/rgba8.pam", "wb").write(b"P7\nWIDTH %d\nHEIGHT %d\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n" % (W, H) + bytes(px(x, y, c) for y in range(H) for x in range(W) for c in range(4)))
PY

# Lossless round trips must be bit-exact: encode, decode, compare against the original bytes.
roundtrip() {  # name input ext cjxl-options...
  local name="$1" in="$2" ext="$3"; shift 3
  rm -f "$W/$name.jxl" "$W/$name.out.$ext"
  if "$CJXL" "$W/$in" "$W/$name.jxl" -d 0 "$@" >"$W/$name.enc.log" 2>&1 \
     && "$DJXL" "$W/$name.jxl" "$W/$name.out.$ext" >"$W/$name.dec.log" 2>&1 \
     && cmp -s "$W/$in" "$W/$name.out.$ext"; then ok "$name"; else bad "$name"; cat "$W/$name".*.log 2>/dev/null | tail -5; fi
}
roundtrip rgb8_e3     rgb8.ppm  ppm -e 3
roundtrip rgb8_e7     rgb8.ppm  ppm -e 7
roundtrip rgb8_modular rgb8.ppm ppm -e 5 -m 1
roundtrip gray8       gray8.pgm pgm -e 5
roundtrip rgb16       rgb16.ppm ppm -e 5
roundtrip rgba8       rgba8.pam pam -e 5

# Known answer: a committed .jxl must decode to pixels with the committed digest.
KAT_DIR="$SRC/mayhem/test"
for kat in "$KAT_DIR"/*.jxl; do
  name="$(basename "$kat" .jxl)"
  want="$(cut -d' ' -f1 "${kat%.jxl}.sha256")"
  rm -f "$W/kat.ppm"
  "$DJXL" "$kat" "$W/kat.ppm" >/dev/null 2>&1
  got="$(sha256sum "$W/kat.ppm" 2>/dev/null | cut -d' ' -f1)"
  if [ -n "$got" ] && [ "$got" = "$want" ]; then ok "kat-$name"; else bad "kat-$name (got '${got}' want '${want}')"; fi
done

# jxlinfo must report the known image size of the encoded file.
if "$JXLINFO" "$W/rgb8_e7.jxl" 2>&1 | grep -q 'JPEG XL image, 64x48'; then ok jxlinfo-size; else bad jxlinfo-size; fi

emit_ctrf cjxl-djxl-oracle "$passed" "$failed" 0
