#!/usr/bin/env bash
#
# mayhem/build.sh — build the Adobe DNG SDK + its five libFuzzer harnesses (instrumented),
# their standalone reproducers, and the dng_validate CLI used as the functional test oracle.
#
# Air-gapped and re-runnable: no network access, no source mutation of tracked files
# (the dng_validate munge for the validate harnesses is done on a private copy under /tmp).
# The org base (ghcr.io/mayhemheroes/base) exports the build contract (CC/CXX/
# LIB_FUZZING_ENGINE/SANITIZER_FLAGS/DEBUG_FLAGS/STANDALONE_FUZZ_MAIN/SRC).
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

cd "$SRC"

OUT=/mayhem
BUILD="$SRC/.mayhem-build"
rm -rf "$BUILD"; mkdir -p "$BUILD/obj-san" "$BUILD/obj-oracle"

# DNG SDK compile defines: LibJPEG on, XMP off (no XMP toolkit), thread-safe.
DNG_DEFS="-DqDNGUseLibJPEG=1 -DqDNGUseXMP=0 -DqDNGThreadSafe=1"
INC="-I$SRC/source"
# The SDK triggers a lot of benign C++ warnings; silence them so -w keeps logs readable.
WARN="-w"

# XMP glue is not built (no XMP toolkit available); collect the buildable source set.
mapfile -t SRCS < <(cd "$SRC/source" && ls *.cpp | grep -v '^dng_xmp' | grep -v '^dng_validate\.cpp$')

compile_lib() {   # <outdir> <extra-flags...>
  local outdir="$1"; shift
  printf '%s\n' "${SRCS[@]}" | xargs -P"$MAYHEM_JOBS" -I{} \
    "$CXX" "$@" $DNG_DEFS $INC $WARN -std=c++14 -c "$SRC/source/{}" -o "$outdir/{}.o"
  ( cd "$outdir" && ar cr libdng_sdk.a *.o )
}

# ---------------------------------------------------------------------------
# 1) Instrumented DNG SDK library (ASan+UBSan + DWARF<4) for the fuzz harnesses.
# ---------------------------------------------------------------------------
echo ">> building instrumented libdng_sdk.a"
compile_lib "$BUILD/obj-san" $SANITIZER_FLAGS $DEBUG_FLAGS
LIB_SAN="$BUILD/obj-san/libdng_sdk.a"

CXXF="$SANITIZER_FLAGS $DEBUG_FLAGS $DNG_DEFS $INC $WARN -std=c++14"

# StandaloneFuzzTargetMain.c compiled as C so its LLVMFuzzerTestOneInput ref keeps C linkage.
STANDALONE_OBJ="$BUILD/standalone_main.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$STANDALONE_OBJ"

# ---------------------------------------------------------------------------
# 2) Simple harnesses (parser / stage / camera_profile): fuzzer + standalone.
# ---------------------------------------------------------------------------
build_simple() {   # <target-name> <harness.cpp>
  local name="$1" src="$2"
  echo ">> harness $name"
  $CXX $CXXF $LIB_FUZZING_ENGINE "$src" "$LIB_SAN" -ljpeg -lz -o "$OUT/$name"
  $CXX $CXXF "$src" "$STANDALONE_OBJ" "$LIB_SAN" -ljpeg -lz -o "$OUT/$name-standalone"
}

build_simple dng_parser_fuzzer         "$SRC/fuzzer/dng_parser_fuzzer.cpp"
build_simple dng_stage_fuzzer          "$SRC/mayhem/dng_stage_fuzzer.cpp"
build_simple dng_camera_profile_fuzzer "$SRC/mayhem/dng_camera_profile_fuzzer.cpp"

# ---------------------------------------------------------------------------
# 3) Validate harnesses: they call dng_validate() and the g* validation globals,
#    both provided by source/dng_validate.cpp + source/dng_globals.cpp built with
#    qDNGValidateTarget. Munge a PRIVATE copy of dng_validate.cpp (rename its CLI
#    main, un-static dng_validate(), drop the per-file "Validation complete"
#    printf) — the tracked upstream source is never modified.
# ---------------------------------------------------------------------------
VDIR="$BUILD/validate"; mkdir -p "$VDIR"
sed -e 's/^int main (/int dng_validate_cli_main (/' \
    -e 's/^static dng_error_code dng_validate/dng_error_code dng_validate/' \
    -e 's/printf ("Validation complete/\/\/ &/' \
    "$SRC/source/dng_validate.cpp" > "$VDIR/dng_validate_impl.cpp"

VFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS $DNG_DEFS -DqDNGValidateTarget=1 $INC $WARN -std=c++14"

build_validate() {   # <target-name> <harness.cpp>
  local name="$1" src="$2"
  echo ">> validate harness $name"
  local combined="$VDIR/${name}_combined.cpp"
  cat "$VDIR/dng_validate_impl.cpp" "$src" > "$combined"
  $CXX $VFLAGS $LIB_FUZZING_ENGINE "$SRC/source/dng_globals.cpp" "$combined" \
       "$LIB_SAN" -ljpeg -lz -o "$OUT/$name"
  $CXX $VFLAGS "$SRC/source/dng_globals.cpp" "$combined" "$STANDALONE_OBJ" \
       "$LIB_SAN" -ljpeg -lz -o "$OUT/$name-standalone"
}

build_validate dng_validate_fuzzer       "$SRC/mayhem/dng_validate_fuzzer.cpp"
build_validate dng_fixed_validate_fuzzer  "$SRC/mayhem/dng_fixed_validate_fuzzer.cpp"

# ---------------------------------------------------------------------------
# 4) Functional-test oracle: the real dng_validate CLI (parses + renders a DNG),
#    built with NORMAL flags (clean, independent of the sanitized fuzz build) so
#    mayhem/test.sh only RUNS it. Left at a fixed path for test.sh.
# ---------------------------------------------------------------------------
echo ">> building dng_validate CLI (test oracle)"
compile_lib "$BUILD/obj-oracle" -O1 $DNG_DEFS
$CXX -O1 $DNG_DEFS -DqDNGValidateTarget=1 $INC $WARN -std=c++14 \
     "$SRC/source/dng_validate.cpp" "$SRC/source/dng_globals.cpp" \
     "$BUILD/obj-oracle/libdng_sdk.a" -ljpeg -lz -o "$OUT/dng_validate"

echo ">> build.sh complete; artifacts in $OUT:"
ls -1 "$OUT"/dng_*fuzzer "$OUT"/dng_validate 2>/dev/null
