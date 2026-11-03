#!/usr/bin/env bash
#
#  build-engine.sh — the engine's Metal kernels and its baked resources, for iOS.
#
#  Usage:
#      ios/Tools/build-engine.sh bundle      # kernels + resources (what a build needs)
#      ios/Tools/build-engine.sh metallib    # kernels only
#      ios/Tools/build-engine.sh resources    # baked resources only
#
#  Two things happen here, and both matter.
#
#  1. **The kernels are compiled for iOS, not for macOS.** `xcrun -sdk iphoneos
#     metal` compiles the `.metal` sources against the iOS SDK and the iOS GPU
#     family's capabilities. A macOS-built metallib will load on iOS but will
#     be missing what the iOS compiler drops, and the engine's kernels are
#     written against the whole set.
#
#  2. **Safe math is not optional.** The engine probes the metallib at startup
#     and refuses to run if it detects fast-math drift -- a 1.1e-5 difference
#     in `exp` and fma contraction, which is past the float32 bar the engine
#     holds itself to (RFC-014 §5.1 trap 1). Xcode's `MTL_FAST_MATH` applies to
#     the *app's* shader, not to these, because these do not go through Xcode
#     at all -- they are compiled here, by the Metal compiler, with the flags
#     below.
#
#  The resources are copied into `ios/SpektraLab/Resources/engine`, which the
#  Xcode project carries as a folder reference, so they land in the app bundle
#  at `Resources/engine` -- and the engine resolves every asset relative to
#  that directory.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
engine="$root/engine"
app="$root/ios/SpektraLab"

# The iOS deployment target. It must match the Xcode project's
# IPHONEOS_DEPLOYMENT_TARGET, or the metallib and the app disagree about what
# the GPU supports.
IOS_MIN="16.0"

# The engine's own safety flags. Do not remove `-fmetal-math-mode=safe`: the
# engine's `check_math_mode` probe rejects a fast-math metallib outright, and
# the app will not start.
MATH_FLAGS=(-fmetal-math-mode=safe -fmetal-math-fp32-functions=precise)
TARGET_FLAGS=(-mios-version-min="$IOS_MIN")

build_metallib() {
  local src="$engine/src/shaders"
  local out="$engine/build/ios"
  local air_dir="$out/air"
  mkdir -p "$air_dir"

  echo "==> compiling Metal kernels for iOS ($IOS_MIN)"
  local airs=()
  for m in "$src"/*.metal; do
    local name
    name="$(basename "$m" .metal)"
    echo "    $(basename "$m")"
    xcrun -sdk iphoneos metal "${MATH_FLAGS[@]}" "${TARGET_FLAGS[@]}" \
      -Werror -c "$m" -o "$air_dir/$name.air"
    airs+=("$air_dir/$name.air")
  done

  echo "==> linking spektrafilm.metallib"
  xcrun -sdk iphoneos metallib "${airs[@]}" -o "$out/spektrafilm.metallib"

  # `build_resources` packs this into the app's single resource archive, so
  # nothing is copied into the bundle from here.
  echo "    -> $out/spektrafilm.metallib"
}

build_resources() {
  local src="$engine/resources"
  local product="$engine/resources_product"
  local out="$engine/build/ios"
  local staging="$engine/build/assets"
  local dst="$app/Resources"

  echo "==> staging the engine's baked resources"
  rm -rf "$staging"
  mkdir -p "$staging/profiles" "$staging/io"

  # The baked constants: 9.4 MB of measured tables. The engine reads this by
  # name out of the resources directory.
  cp "$src/spektrafilm_constants.bin" "$staging/"
  cp "$src/print_luts.json" "$staging/"
  cp "$src/neutral_print_filters.json" "$staging/"

  # The kernels, when `build_metallib` has already run.
  if [ -f "$out/spektrafilm.metallib" ]; then
    cp "$out/spektrafilm.metallib" "$staging/"
  fi

  # The stock profiles. The engine resolves a stock by name against
  # `<resources>/profiles/<stock>.json`, so both directories' profiles are
  # merged into the one the engine looks in.
  cp "$src/profiles/"*.json "$staging/profiles/"
  if [ -d "$product/profiles" ]; then
    cp "$product/profiles/"*.json "$staging/profiles/"
  fi

  # The colour profile the export embeds.
  cp "$src/io/sRGB.icc" "$staging/io/"

  # The product's own extras: the paper grades and the neutral filters.
  if [ -f "$product/paper_grades.json" ]; then
    cp "$product/paper_grades.json" "$staging/"
  fi
  if [ -f "$product/neutral_print_filters.json" ]; then
    cp "$product/neutral_print_filters.json" "$staging/product_neutral_print_filters.json"
  fi

  local count
  count="$(find "$staging/profiles" -name '*.json' | wc -l | tr -d ' ')"
  echo "    $count profiles staged"

  # One archive instead of 33 loose files. A sideloading installer unpacks the
  # IPA into its own staging directory and copies the .app to a fixed name;
  # with this many entries that copy fails on iOS 27, and the only thing it
  # reports is "Failed to get bundle ID ... /Payload/App.app", which names
  # nothing useful. A six-entry test bundle installed fine on the same device.
  echo "==> packing them into one file"
  mkdir -p "$dst"
  rm -rf "$dst/engine"
  rm -f "$dst/engine-assets.bin"
  python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pack-engine-assets.py" \
    "$staging" "$dst/engine-assets.bin"
}

check_resources() {
  local dst="$app/Resources/engine-assets.bin"
  if [ ! -f "$dst" ]; then
    echo "MISSING: $dst"
    echo "run ios/Tools/build-engine.sh bundle before building the app"
    exit 1
  fi
  echo "the engine's resources are in place ($(du -h "$dst" | cut -f1) archive)"
}

case "${1:-bundle}" in
  metallib)  build_metallib ;;
  resources) build_resources ;;
  bundle)    build_metallib; build_resources ;;
  check)     check_resources ;;
  *) echo "usage: $0 {bundle|metallib|resources|check}" >&2; exit 2 ;;
esac
