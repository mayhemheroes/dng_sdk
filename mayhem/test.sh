#!/usr/bin/env bash
#
# mayhem/test.sh — behavioral oracle for the DNG SDK.
#
# Upstream (Adobe DNG SDK 1.4, as vendored in AOSP external/dng_sdk) ships NO unit/functional
# test suite — only the `dng_validate` command-line tool (Android.bp cc_binary "dng_validate",
# built with qDNGValidateTarget), which parses + linearizes + interpolates + validates a DNG and
# prints "Validation complete" on success / a diagnostic + nonzero exit on a malformed file.
# There is therefore tests_found=0; this is an AUTHORED known-answer oracle built directly on that
# real tool, exercising the full parse/render pipeline (not a thin process-exit check):
#   ACCEPT: the known-good seed original.dng must validate ("Validation complete", exit 0).
#   REJECT: a truncated copy of it must NOT validate (no "Validation complete" / nonzero exit).
# A sabotage patch that neuters the pipeline to exit(0) breaks the REJECT case (a truncated DNG
# then "passes") AND the ACCEPT assertion (no completion banner) — so this fails, as required.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

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

VALIDATE=/mayhem/dng_validate
SEED="$SRC/fuzzer/seeds/CVE_2020_9589/original.dng"

if [ ! -x "$VALIDATE" ]; then
  echo "test.sh: $VALIDATE missing — build.sh did not produce the oracle" >&2
  emit_ctrf "dng_validate-oracle" 0 1; exit 1
fi
if [ ! -f "$SEED" ]; then
  echo "test.sh: seed $SEED missing" >&2
  emit_ctrf "dng_validate-oracle" 0 1; exit 1
fi

passed=0; failed=0

# --- Test 1 (ACCEPT): the known-good DNG validates cleanly ---
out1="$("$VALIDATE" -v "$SEED" 2>&1)"; rc1=$?
if [ "$rc1" -eq 0 ] && printf '%s' "$out1" | grep -q "Validation complete"; then
  echo "PASS accept: original.dng validated (Validation complete, exit 0)"; passed=$((passed+1))
else
  echo "FAIL accept: original.dng did NOT validate (rc=$rc1)"; printf '%s\n' "$out1" | tail -5; failed=$((failed+1))
fi

# --- Test 2 (REJECT): a truncated DNG must NOT validate cleanly ---
TRUNC="$(mktemp /tmp/dng_trunc.XXXXXX.dng)"
head -c 5000 "$SEED" > "$TRUNC"
out2="$("$VALIDATE" -v "$TRUNC" 2>&1)"; rc2=$?
if [ "$rc2" -ne 0 ] || ! printf '%s' "$out2" | grep -q "Validation complete"; then
  echo "PASS reject: truncated DNG rejected (rc=$rc2, no completion banner)"; passed=$((passed+1))
else
  echo "FAIL reject: truncated DNG wrongly validated (rc=$rc2)"; failed=$((failed+1))
fi
rm -f "$TRUNC"

emit_ctrf "dng_validate-oracle" "$passed" "$failed"
