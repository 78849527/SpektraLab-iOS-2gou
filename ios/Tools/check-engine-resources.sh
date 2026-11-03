#!/usr/bin/env bash
#
#  check-engine-resources.sh — is the engine's data in the app?
#
#  A pre-build *check*, not a build step. It reports rather than bakes: the
#  kernels and the baked resources are produced by `ios/Tools/build-engine.sh`,
#  which needs the Metal compiler and therefore a machine that has one.
#
#  Why it matters: without the metallib the engine starts and then fails when
#  it cannot load its library, and without `spektrafilm_constants.bin` it
#  fails at the first read. Both failures surface as an engine error at
#  runtime, on a phone, where the cause is a build step nobody ran. This
#  script turns them into one line at build time.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dst="$here/../SpektraLab/Resources/engine"

missing=0
note_missing() {
  echo "error: the engine's resources are incomplete: $1 is missing."
  echo "       run ios/Tools/build-engine.sh bundle before building the app."
  missing=1
}

if [ ! -f "$dst/spektrafilm_constants.bin" ]; then
  note_missing "$dst/spektrafilm_constants.bin"
fi
if [ ! -f "$dst/spektrafilm.metallib" ]; then
  note_missing "$dst/spektrafilm.metallib"
fi
if [ ! -f "$dst/print_luts.json" ]; then
  note_missing "$dst/print_luts.json"
fi
if [ ! -d "$dst/profiles" ]; then
  note_missing "$dst/profiles/"
else
  count="$(find "$dst/profiles" -name '*.json' | wc -l | tr -d ' ')"
  if [ "$count" -lt 20 ]; then
    echo "error: only $count stock profiles in $dst/profiles (expected 28+)."
    missing=1
  fi
fi

if [ "$missing" -ne 0 ]; then
  exit 1
fi

echo "the engine's resources are in place ($(find "$dst/profiles" -name '*.json' | wc -l | tr -d ' ') profiles)"
