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

# Runs the suites build.sh built (normal flags) in mayhem/build/test: the app.properties
# known-answer tests (mayhem/tests/manifest_test.cpp) and elf_overlay's own C test suite, whose
# assert()s check loader/ISA/blob/pack results; the integration tests compare output values.
T="$SRC/mayhem/build/test"
: "${ELFO_SRC:=/opt/toolchains/deps/elf_overlay-18bd0b4/src}"
[ -x "$T/manifest_test" ] || { echo "test binaries missing in $T (run mayhem/build.sh)" >&2; emit_ctrf "manifest+elf_overlay-tests" 0 1; exit 1; }
passed=0; failed=0
run() { # name expected-stdout-regex cmd...
  local name="$1" want="$2"; shift 2
  local out; out="$("$@" 2>&1)"; local rc=$?
  if [ $rc -eq 0 ] && printf '%s\n' "$out" | grep -Eq "$want"; then
    passed=$((passed+1)); echo "PASS $name"
  else
    failed=$((failed+1)); echo "FAIL $name (rc=$rc)"; printf '%s\n' "$out" | tail -5
  fi
}
# manifest: every case must print PASS and none FAIL
mout="$("$T/manifest_test" 2>&1)"; mrc=$?
printf '%s\n' "$mout"
mp=$(printf '%s\n' "$mout" | grep -c '^PASS ' || true)
mf=$(printf '%s\n' "$mout" | grep -c '^FAIL ' || true)
if [ $mrc -ne 0 ] || [ "$mp" -ne 14 ]; then mf=$((mf + 1)); fi
passed=$((passed+mp)); failed=$((failed+mf))
run elfo_isa       'passed|PASS|ok|OK'     "$T/test_isa"
run elfo_blob      'passed|PASS|ok|OK'     "$T/test_blob"
run elfo_l32r      'passed|PASS|ok|OK'     "$T/test_l32r"
run elfo_load      'host load test passed' "$T/test_load" "$ELFO_SRC/tests/integration/fixtures/minimal.elfo"
run elfo_fixture   'passed|PASS|ok|OK'     "$T/test_fixture" "$ELFO_SRC/examples/host_pipeline/fixture.elfo"
run elfo_redirect  'passed|PASS|ok|OK'     "$T/test_redirect"
run elfo_hostref   'passed|PASS|ok|OK'     "$T/test_hostref"
# relink golden test: relinking upstream's fixture ELF must reproduce upstream's fixture.relk byte for
# byte. (Upstream's test_plt_hostrefs is not run: it needs the xtensa-esp32s3-elf-as cross assembler.)
scratch="$(mktemp -d "${TMPDIR:-/tmp}/pm_test.XXXXXX")"
run elfo_relink_golden 'wrote 254 bytes' "$T/elf_overlay_relink" "$ELFO_SRC/examples/host_pipeline/fixture.elf" "$scratch/out.relk"
if cmp -s "$scratch/out.relk" "$ELFO_SRC/examples/host_pipeline/fixture.relk"; then
  passed=$((passed+1)); echo "PASS elfo_relink_golden_bytes"
else
  failed=$((failed+1)); echo "FAIL elfo_relink_golden_bytes (output differs from fixture.relk)"
fi
rm -rf "$scratch"
emit_ctrf "manifest+elf_overlay-tests" "$passed" "$failed"
