#!/usr/bin/env bash
#
# mayhem/build.sh — build this repo's fuzz harness(es). EDIT per repo.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#                       (ASan + UBSan, both set to HALT — so Mayhem catches memory AND UB defects)
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF debug info — always on for fuzz/standalone builds,
#                       independent of the sanitizer off-switch; DWARF version must be < 4)
#   RUST_DEBUG_FLAGS    -C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3
#                       (thread through RUSTFLAGS on every cargo-fuzz build)
#   GO_DEBUG_FLAGS      -gcflags=all=-N -l
#                       (thread through go build / go-fuzz-build so the linked ELF keeps symbols)
#   SRC                 /mayhem (the repo source)
#
# Contract: build EVERYTHING here — one runnable binary per fuzz harness, AND the project's test
# suite (so mayhem/test.sh only has to RUN it, never compile). Keep it ADDITIVE (build upstream as
# upstream documents; don't edit upstream files). IMPORTANT: build the PROJECT ITSELF with
# $SANITIZER_FLAGS and $DEBUG_FLAGS (not just the harness) so the fuzzed code is instrumented
# AND carries DWARF < 4 symbols — otherwise ASan/UBSan only see the harness, not the library
# you're trying to find bugs in, and backtraces won't resolve project source lines. Build the TEST
# suite with the project's NORMAL flags (a clean, independent build) so test.sh stays an honest
# functional oracle and won't false-fail on benign UB. Leave the test binary/runner where test.sh
# expects it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

FUZZERS="cjxl_fuzzer color_encoding_fuzzer decode_basic_info_fuzzer djxl_fuzzer fields_fuzzer icc_codec_fuzzer rans_fuzzer set_from_bytes_fuzzer streaming_fuzzer transforms_fuzzer"

# Options shared by both builds. Everything third_party/* comes from the committed submodules
# (already in the image), so nothing is fetched at build time.
COMMON_ARGS=(
  -G Ninja
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX"
  -DBUILD_TESTING=OFF -DBUILD_SHARED_LIBS=OFF
  -DJPEGXL_ENABLE_TOOLS=ON -DJPEGXL_ENABLE_DEVTOOLS=OFF
  -DJPEGXL_ENABLE_BENCHMARK=OFF -DJPEGXL_ENABLE_EXAMPLES=OFF -DJPEGXL_ENABLE_MANPAGES=OFF
  -DJPEGXL_ENABLE_DOXYGEN=OFF -DJPEGXL_ENABLE_SJPEG=OFF -DJPEGXL_ENABLE_JNI=OFF
  -DJPEGXL_ENABLE_OPENEXR=OFF -DJPEGXL_ENABLE_PLUGINS=OFF -DJPEGXL_ENABLE_VIEWERS=OFF
  -DJPEGXL_ENABLE_TCMALLOC=OFF
)

# 1) The sanitized, coverage-instrumented project + the libFuzzer harnesses (same configuration as
#    upstream's OSS-Fuzz build: Release plus JXL_DASSERT, fuzzing-build mode).
# Both trees are configured from scratch: re-configuring an existing tree flips BUILD_TESTING on
# (via include(CTest)) and then fails on the missing libpng, so a re-run could not otherwise succeed.
rm -rf build build-tests
mkdir -p build
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o build/lsan_off.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o build/standalone_main.o
FUZZ_CXXFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION=1 -DJXL_IS_DEBUG_BUILD"
FUZZ_CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION=1"
cmake -S "$SRC" -B build "${COMMON_ARGS[@]}" \
  -DJPEGXL_ENABLE_FUZZERS=ON \
  -DJPEGXL_FUZZER_LINK_FLAGS="$LIB_FUZZING_ENGINE;$SRC/build/lsan_off.o" \
  -DCMAKE_C_FLAGS="$FUZZ_CFLAGS" -DCMAKE_CXX_FLAGS="$FUZZ_CXXFLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$SANITIZER_FLAGS"
ninja -C build -j"$MAYHEM_JOBS" $FUZZERS

# icc_codec_fuzzer.cc ends with memcmp(data, reconstructed.data(), size), whose second argument is NULL
# for the empty input (the first input libFuzzer tries), so halting UBSan aborts it before it fuzzes
# anything. Relax only nonnull-attribute, only for that one translation unit, and relink by hand
# (a later ninja run would see the hand-built object as dirty and rebuild it with the stock flags).
icc_compile="$(ninja -C build -t commands tools/icc_codec_fuzzer | grep -E -- ' -c [^ ]*tools/icc_codec_fuzzer\.cc' | tail -n 1)"
[ -n "$icc_compile" ] || { echo "could not find the icc_codec_fuzzer compile command" >&2; exit 1; }
(cd build && eval "$icc_compile -fno-sanitize=nonnull-attribute")
icc_link="$(ninja -C build -t commands tools/icc_codec_fuzzer | tail -n 1)"
(cd build && eval "$icc_link")

# 2) Each fuzzer binary, and its non-fuzzer standalone reproducer: the same link line with the
#    libFuzzer engine swapped for the run-once driver.
for f in $FUZZERS; do
  cp "build/tools/$f" "/mayhem/$f"
  cmd="$(ninja -C build -t commands "tools/$f" | tail -n 1)"
  standalone_cmd="$(printf '%s' "$cmd" | sed -E "s# -fsanitize=fuzzer( |\$)# $SRC/build/standalone_main.o #; s#-o tools/$f( |\$)#-o /mayhem/$f-standalone #")"
  [ "$standalone_cmd" != "$cmd" ] || { echo "could not derive standalone link for $f" >&2; exit 1; }
  (cd build && eval "$standalone_cmd")
done

# 3) The test build: cjxl/djxl/jxlinfo with the project's NORMAL flags, no sanitizers.
cmake -S "$SRC" -B build-tests "${COMMON_ARGS[@]}" \
  -DJPEGXL_ENABLE_FUZZERS=OFF \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" \
  -DCMAKE_EXE_LINKER_FLAGS="$COVERAGE_FLAGS"
ninja -C build-tests -j"$MAYHEM_JOBS" cjxl djxl jxlinfo
