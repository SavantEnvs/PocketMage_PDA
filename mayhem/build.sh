#!/usr/bin/env bash
# mayhem/build.sh — build the PocketMage_PDA fuzz harnesses and the functional tests.
#
# PocketMageOS is ESP32-S3 firmware with no host build. The harnesses compile the host-portable
# parsers directly:
#   - Code/PocketMageOS/src/elf_app_manifest.cpp            (in this repo)
#   - the elf_overlay submodule (loader + relink tool)        (pinned in the image under
#     /opt/toolchains/deps/elf_overlay-<sha7>/src by mayhem/Dockerfile, because CI cannot check out
#     the firmware's submodules: esp-iot-solution is not publicly fetchable)
# Everything sanitized goes to mayhem/build/ (gitignored by mayhem/.gitignore); fuzzers land in /mayhem.
set -euo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SRC:=/mayhem}"
: "${ELFO_SRC:=/opt/toolchains/deps/elf_overlay-18bd0b4/src}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
OS="$SRC/Code/PocketMageOS"
H="$SRC/mayhem/harnesses"
B="$SRC/mayhem/build"
[ -f "$ELFO_SRC/src/core/loader.c" ] || { echo "elf_overlay source missing at $ELFO_SRC" >&2; exit 1; }
# The manifest harness mirrors elf_runner.cpp's size cap; fail loudly if upstream changes it.
grep -q 'ELF_APP_PROPERTIES_MAX_BYTES = 1024;' "$OS/include/elf_runner.h" \
  || { echo "ELF_APP_PROPERTIES_MAX_BYTES changed upstream; update mayhem/harnesses/elf_runner_limits.h" >&2; exit 1; }

rm -rf "$B"
mkdir -p "$B/fuzz" "$B/test"

FZ="$SANITIZER_FLAGS $DEBUG_FLAGS"
# SanitizerCoverage on every fuzzed object (the project code, not just the harness); only when a
# fuzzing engine is configured, so an engine-less build still links.
FZC="$FZ"
[ -n "$LIB_FUZZING_ENGINE" ] && FZC="$FZ -fsanitize=fuzzer-no-link"
# UBSan shift-base relaxed on the ISA patchers only: xtensa_l32r_literal() computes `delta << 2` on a
# negative int32 for every backward L32R literal (any real Xtensa .text), which would abort every
# valid input. ASan and every other UBSan check stay on and halting.
ISA_RELAX="-fno-sanitize=shift-base"
ELFO_CORE="src/isa/isa.c src/isa/xtensa/patch.c src/isa/riscv/patch.c src/core/blob.c src/core/loader.c src/port/port.c"
ELFO_RELINK="tools/relink/main.c tools/common/elf_read.c tools/common/reloc.c tools/common/blob_pack.c"
ELFO_INC="-I$ELFO_SRC/include -I$ELFO_SRC/tools/common"

# ---- 1) sanitized objects (project code instrumented, DWARF 3) ----
$CC $FZ -c "$STANDALONE_FUZZ_MAIN" -o "$B/fuzz/standalone_main.o"
$CXX $FZ -c mayhem/lsan_off.cc -o "$B/fuzz/lsan_off.o"
$CXX $FZC -std=gnu++17 -I"$OS/include" -c "$OS/src/elf_app_manifest.cpp" -o "$B/fuzz/elf_app_manifest.o"
core_objs=()
for s in $ELFO_CORE; do
  o="$B/fuzz/eo_$(echo "$s" | tr '/.' '__').o"
  relax=""; case "$s" in src/isa/*/patch.c) relax="$ISA_RELAX" ;; esac
  $CC $FZC $relax -std=c11 -D_POSIX_C_SOURCE=200809L $ELFO_INC -c "$ELFO_SRC/$s" -o "$o"
  core_objs+=("$o")
done
relink_objs=()
for s in $ELFO_RELINK; do
  o="$B/fuzz/eo_$(echo "$s" | tr '/.' '__').o"
  extra=""; [ "$s" = tools/relink/main.c ] && extra="-Dmain=relink_main"
  $CC $FZC -std=c11 -D_POSIX_C_SOURCE=200809L $extra $ELFO_INC -c "$ELFO_SRC/$s" -o "$o"
  relink_objs+=("$o")
done

# ---- 2) harnesses: libFuzzer binary + standalone reproducer each ----
link() { # name compiler harness-src extra-flags objs...
  local name="$1" comp="$2" src="$3" fl="$4"; shift 4
  $comp $FZC $fl -c "$src" -o "$B/fuzz/$name.o"
  $CXX $FZ $LIB_FUZZING_ENGINE "$B/fuzz/$name.o" "$@" "$B/fuzz/lsan_off.o" -o "$SRC/$name"
  $CXX $FZ "$B/fuzz/standalone_main.o" "$B/fuzz/$name.o" "$@" "$B/fuzz/lsan_off.o" -o "$SRC/$name-standalone"
}
link fuzz_elf_manifest "$CXX" "$H/fuzz_elf_manifest.cpp" "-std=gnu++17 -I$OS/include -I$H" "$B/fuzz/elf_app_manifest.o"
link fuzz_elfo_load "$CC" "$H/fuzz_elfo_load.c" "-std=c11 -D_POSIX_C_SOURCE=200809L $ELFO_INC" "${core_objs[@]}"
link fuzz_elf_relink "$CC" "$H/fuzz_elf_relink.c" "-std=c11 -D_POSIX_C_SOURCE=200809L $ELFO_INC" "${relink_objs[@]}" "${core_objs[@]}"

# ---- 3) functional tests, NORMAL flags (no sanitizers), into mayhem/build/test ----
T="$B/test"
$CXX -O1 -std=gnu++17 $COVERAGE_FLAGS -I"$OS/include" mayhem/tests/manifest_test.cpp "$OS/src/elf_app_manifest.cpp" -o "$T/manifest_test"
tcore=()
for s in $ELFO_CORE; do tcore+=("$ELFO_SRC/$s"); done
tc() { local out="$1"; shift; $CC -O1 -std=c11 -D_POSIX_C_SOURCE=200809L $COVERAGE_FLAGS $ELFO_INC "$@" "${tcore[@]}" -o "$T/$out"; }
tc test_isa "$ELFO_SRC/tests/unit/test_isa.c"
tc test_blob "$ELFO_SRC/tests/unit/test_blob.c"
tc test_l32r "$ELFO_SRC/tests/unit/test_l32r.c"
tc test_load "$ELFO_SRC/tests/host/test_load.c"
tc test_fixture "$ELFO_SRC/tests/host/test_fixture.c"
tc test_redirect "$ELFO_SRC/tests/unit/test_redirect.c" "$ELFO_SRC/tools/common/blob_pack.c"
tc test_hostref "$ELFO_SRC/tests/unit/test_hostref.c" "$ELFO_SRC/tools/common/blob_pack.c"
tc elf_overlay_relink "$ELFO_SRC/tools/relink/main.c" "$ELFO_SRC/tools/common/elf_read.c" "$ELFO_SRC/tools/common/reloc.c" "$ELFO_SRC/tools/common/blob_pack.c"
echo "build.sh: done"
