#!/usr/bin/env bash
#
# scripts/build-sherpa-onnx.sh: build sherpa-onnx's C API as a static
# XCFramework (SherpaOnnxC.xcframework) for Packages/SherpaOnnx.
#
# The libraries are compiled against the ONNX Runtime 1.30.0 that BlueTTSKit
# already links (the official CocoaPods C archive, the `onnxruntime` binary
# target in Packages/BlueTTSKit/Package.swift). Nothing of ONNX Runtime is
# bundled here: the archives only reference its C API (OrtGetApiBase and the
# Core ML provider factory), which the app resolves against BlueTTSKit's copy,
# so the app links exactly one runtime.
#
# TTS and speaker diarization are off (no espeak-ng, piper or clustering code;
# BlueTTSEspeak stays the only espeak-ng in the app). Only the C API, the
# recognizers and their feature/decoder libraries are built.
#
# Usage:
#   scripts/build-sherpa-onnx.sh [all]          every slice, then assemble
#   scripts/build-sherpa-onnx.sh slice NAME     one slice: ios-arm64,
#                                               ios-sim-arm64, ios-sim-x86_64
#                                               or macos-arm64
#   scripts/build-sherpa-onnx.sh assemble       merge built slices into the
#                                               XCFramework zip
#   scripts/build-sherpa-onnx.sh names          the release tag and zip name
#
# Output (in $OUT, default build/sherpa-onnx):
#   SherpaOnnxC.xcframework                 ios-arm64, ios-arm64_x86_64-simulator
#                                           and macos-arm64 (for `swift test`
#                                           and the macOS tools)
#   sherpa-onnx-<ver>-ort<ort>-xcframework.zip, its sha256 in checksum.txt
#   BUILD-INFO.txt                          versions, flags, member libraries
#   symbols.txt                             the symbol check below
#
# The symbol check fails the build when any slice defines an ONNX Runtime C
# API symbol (_Ort...), anything in the onnxruntime:: namespace, or an
# espeak/piper symbol, or when a slice does not reference _OrtGetApiBase
# (that is, did not get linked against an external runtime).
#
# Needs Xcode (xcodebuild, lipo, libtool, nm), CMake and git. Runs on the
# GitHub-hosted macOS runners (.github/workflows/sherpa-onnx.yml).

set -euo pipefail

SHERPA_VERSION="2.0.1"
SHERPA_TAG="v${SHERPA_VERSION}"
SHERPA_COMMIT="af2d8d81dbfa61c4cea4c568da78f3982edca005"
SHERPA_REPO="https://github.com/k2-fsa/sherpa-onnx.git"

ORT_VERSION="1.30.0"
ORT_URL="https://download.onnxruntime.ai/pod-archive-onnxruntime-c-${ORT_VERSION}.zip"
# The same archive and checksum as the `onnxruntime` binary target in
# Packages/BlueTTSKit/Package.swift. Keep the two in step.
ORT_SHA256="e6f1670c14406fd9f082bb400ab197a9b0a9646058ca6366e440642e2b54a2ea"

IOS_DEPLOYMENT_TARGET="16.0"
MACOS_DEPLOYMENT_TARGET="13.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT="${OUT:-$ROOT/build/sherpa-onnx}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
# Bump when the build changes without a new sherpa-onnx or ONNX Runtime
# version, so the release tag (and the zip Packages/SherpaOnnx pins) is new.
BUILD_REVISION=1
RELEASE_TAG="sherpa-onnx-${SHERPA_VERSION}-ort${ORT_VERSION%.*}"
[[ "$BUILD_REVISION" -gt 1 ]] && RELEASE_TAG+="-r${BUILD_REVISION}"
ZIP_NAME="sherpa-onnx-${SHERPA_VERSION}-ort${ORT_VERSION}-xcframework.zip"
SLICES=(ios-arm64 ios-sim-arm64 ios-sim-x86_64 macos-arm64)

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }

fetch_sources() {
  local src="$OUT/src/sherpa-onnx"
  if [[ ! -d "$src/.git" ]]; then
    info "Cloning sherpa-onnx $SHERPA_TAG"
    mkdir -p "$OUT/src"
    git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$SHERPA_TAG" "$SHERPA_REPO" "$src"
  fi
  local head
  head="$(git -C "$src" rev-parse HEAD)"
  [[ "$head" == "$SHERPA_COMMIT" ]] || die "sherpa-onnx $SHERPA_TAG is $head, expected $SHERPA_COMMIT"

  local ort="$OUT/src/onnxruntime"
  if [[ ! -d "$ort/onnxruntime.xcframework" ]]; then
    info "Fetching ONNX Runtime $ORT_VERSION"
    mkdir -p "$ort"
    curl -fsSL --retry 3 -o "$ort/ort.zip" "$ORT_URL"
    local sum
    sum="$(shasum -a 256 "$ort/ort.zip" | awk '{print $1}')"
    [[ "$sum" == "$ORT_SHA256" ]] || die "ONNX Runtime archive sha256 is $sum, expected $ORT_SHA256"
    (cd "$ort" && unzip -q ort.zip && rm ort.zip)
  fi
}

# The ONNX Runtime slice whose headers and (static) binary a slice compiles
# against. Only the headers are used: the static libraries record the
# dependency but don't contain it.
ort_slice_dir() {
  case "$1" in
    ios-arm64) echo "$OUT/src/onnxruntime/onnxruntime.xcframework/ios-arm64" ;;
    ios-sim-arm64|ios-sim-x86_64) echo "$OUT/src/onnxruntime/onnxruntime.xcframework/ios-arm64_x86_64-simulator" ;;
    macos-arm64) echo "$OUT/src/onnxruntime/onnxruntime.xcframework/macos-arm64_x86_64" ;;
    *) die "unknown slice: $1" ;;
  esac
}

build_slice() {
  local name="$1"
  fetch_sources
  local src="$OUT/src/sherpa-onnx"
  local bdir="$OUT/build/$name"
  local ort
  ort="$(ort_slice_dir "$name")"
  [[ -f "$ort/onnxruntime.framework/Headers/onnxruntime_cxx_api.h" ]] || die "no ONNX Runtime headers in $ort"

  local common=(
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_POLICY_VERSION_MINIMUM=3.10
    -DBUILD_SHARED_LIBS=OFF
    -DSHERPA_ONNX_ENABLE_C_API=ON
    -DSHERPA_ONNX_ENABLE_TTS=OFF
    -DSHERPA_ONNX_ENABLE_SPEAKER_DIARIZATION=OFF
    -DSHERPA_ONNX_ENABLE_PYTHON=OFF
    -DSHERPA_ONNX_ENABLE_BINARY=OFF
    -DSHERPA_ONNX_BUILD_C_API_EXAMPLES=OFF
    -DSHERPA_ONNX_ENABLE_TESTS=OFF
    -DSHERPA_ONNX_ENABLE_CHECK=OFF
    -DSHERPA_ONNX_ENABLE_PORTAUDIO=OFF
    -DSHERPA_ONNX_ENABLE_JNI=OFF
    -DSHERPA_ONNX_ENABLE_WEBSOCKET=OFF
    -DSHERPA_ONNX_ENABLE_GPU=OFF
    -DCMAKE_INSTALL_PREFIX="$bdir/install"
  )
  local platform=()
  case "$name" in
    ios-arm64) platform=(-DCMAKE_TOOLCHAIN_FILE="$src/toolchains/ios.toolchain.cmake" -DPLATFORM=OS64) ;;
    ios-sim-arm64) platform=(-DCMAKE_TOOLCHAIN_FILE="$src/toolchains/ios.toolchain.cmake" -DPLATFORM=SIMULATORARM64) ;;
    ios-sim-x86_64) platform=(-DCMAKE_TOOLCHAIN_FILE="$src/toolchains/ios.toolchain.cmake" -DPLATFORM=SIMULATOR64) ;;
    macos-arm64)
      platform=(
        -DCMAKE_OSX_ARCHITECTURES=arm64
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_DEPLOYMENT_TARGET"
        -DCMAKE_C_VISIBILITY_PRESET=hidden
        -DCMAKE_CXX_VISIBILITY_PRESET=hidden
        -DCMAKE_VISIBILITY_INLINES_HIDDEN=ON
      )
      ;;
  esac
  if [[ "$name" == ios-* ]]; then
    # As upstream's build-ios.sh: ARC on (it links NSLog otherwise
    # unresolved), hidden visibility, no bitcode.
    platform+=(-DENABLE_BITCODE=0 -DENABLE_ARC=1 -DENABLE_VISIBILITY=0 -DDEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET")
  fi

  info "Configuring $name (ONNX Runtime from $ort)"
  rm -rf "$bdir"
  mkdir -p "$OUT/build"
  SHERPA_ONNXRUNTIME_LIB_DIR="$ort" \
  SHERPA_ONNXRUNTIME_INCLUDE_DIR="$ort/onnxruntime.framework/Headers" \
    cmake -S "$src" -B "$bdir" "${common[@]}" "${platform[@]}" | tee "$bdir.configure.log" >/dev/null \
    || { tail -50 "$bdir.configure.log"; die "cmake configure failed for $name"; }
  grep -E 'TTS is|speaker diarization is|location_onnxruntime|Use static lib' "$bdir.configure.log" || true
  if grep -q 'Downloading pre-compiled onnxruntime' "$bdir.configure.log"; then
    die "$name: CMake fell back to downloading its own ONNX Runtime"
  fi

  info "Building $name with $JOBS jobs"
  cmake --build "$bdir" -j "$JOBS"
  cmake --install "$bdir" >/dev/null

  # One archive per slice: everything the C API needs, without the C++ API
  # wrapper (unused) and without ONNX Runtime (external).
  local libs=()
  local f
  for f in "$bdir"/lib/*.a; do
    case "$(basename "$f")" in
      libsherpa-onnx-cxx-api.a) continue ;;
      *onnxruntime*) die "$name: an ONNX Runtime library was built or copied: $f" ;;
      *espeak*|*piper*|*ucd*) die "$name: a TTS phonemizer library was built: $f" ;;
    esac
    libs+=("$f")
  done
  [[ ${#libs[@]} -gt 0 ]] || die "$name: no libraries in $bdir/lib"
  mkdir -p "$OUT/slices/$name"
  libtool -static -no_warning_for_no_symbols -o "$OUT/slices/$name/libsherpa-onnx.a" "${libs[@]}"
  printf '%s\n' "${libs[@]##*/}" >"$OUT/slices/$name/members.txt"
  rm -rf "$OUT/slices/$name/include"
  cp -R "$bdir/install/include" "$OUT/slices/$name/include"
  info "$name: $(du -h "$OUT/slices/$name/libsherpa-onnx.a" | awk '{print $1}') from ${#libs[@]} libraries"
  check_symbols "$name" "$OUT/slices/$name/libsherpa-onnx.a" | tee "$OUT/slices/$name/symbols.txt"
}

# Fails when the archive carries its own ONNX Runtime or any espeak/piper code.
check_symbols() {
  local name="$1" archive="$2"
  local defined undefined bad
  defined="$(nm -gU -A "$archive" 2>/dev/null || true)"
  undefined="$(nm -gu "$archive" 2>/dev/null || true)"
  echo "[$name] defined external symbols: $(grep -c ' [TDSBC] ' <<<"$defined" || true)"
  bad="$(grep -E ' _Ort[A-Z]| __ZN11onnxruntime|espeak|_piper' <<<"$defined" || true)"
  if [[ -n "$bad" ]]; then
    echo "$bad" | head -20
    die "$name: the archive defines ONNX Runtime or espeak/piper symbols (above)"
  fi
  if ! grep -qx '_OrtGetApiBase' <<<"$undefined"; then
    die "$name: the archive does not reference _OrtGetApiBase"
  fi
  echo "[$name] ONNX Runtime symbols it needs from the app: $(grep -E '^_Ort' <<<"$undefined" | tr '\n' ' ')"
  echo "[$name] no _Ort*, onnxruntime::, espeak or piper definitions: ok"
}

framework_plist() {
  local platform="$1" min_os="$2"
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>SherpaOnnxC</string>
  <key>CFBundleIdentifier</key>
  <string>com.k2-fsa.sherpa-onnx.c-api</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>SherpaOnnxC</string>
  <key>CFBundlePackageType</key>
  <string>FMWK</string>
  <key>CFBundleShortVersionString</key>
  <string>${SHERPA_VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${SHERPA_VERSION}</string>
  <key>CFBundleSupportedPlatforms</key>
  <array>
    <string>${platform}</string>
  </array>
  <key>MinimumOSVersion</key>
  <string>${min_os}</string>
</dict>
</plist>
EOF
}

module_map() {
  cat <<'EOF'
framework module SherpaOnnxC {
  header "sherpa-onnx/c-api/c-api.h"
  link "c++"
  export *
}
EOF
}

# A static framework around one slice's archive. iOS frameworks are flat;
# macOS frameworks need the versioned layout.
make_framework() {
  local archive="$1" include="$2" dest="$3" kind="$4"
  local fw="$dest/SherpaOnnxC.framework"
  rm -rf "$fw"
  if [[ "$kind" == macos ]]; then
    local v="$fw/Versions/A"
    mkdir -p "$v/Headers/sherpa-onnx/c-api" "$v/Modules" "$v/Resources"
    cp "$archive" "$v/SherpaOnnxC"
    cp "$include/sherpa-onnx/c-api/c-api.h" "$v/Headers/sherpa-onnx/c-api/"
    module_map >"$v/Modules/module.modulemap"
    framework_plist MacOSX "$MACOS_DEPLOYMENT_TARGET" >"$v/Resources/Info.plist"
    ln -s A "$fw/Versions/Current"
    ln -s Versions/Current/SherpaOnnxC "$fw/SherpaOnnxC"
    ln -s Versions/Current/Headers "$fw/Headers"
    ln -s Versions/Current/Modules "$fw/Modules"
    ln -s Versions/Current/Resources "$fw/Resources"
  else
    mkdir -p "$fw/Headers/sherpa-onnx/c-api" "$fw/Modules"
    cp "$archive" "$fw/SherpaOnnxC"
    cp "$include/sherpa-onnx/c-api/c-api.h" "$fw/Headers/sherpa-onnx/c-api/"
    module_map >"$fw/Modules/module.modulemap"
    local plat=iPhoneOS
    [[ "$kind" == ios-sim ]] && plat=iPhoneSimulator
    framework_plist "$plat" "$IOS_DEPLOYMENT_TARGET" >"$fw/Info.plist"
  fi
}

assemble() {
  local s
  for s in "${SLICES[@]}"; do
    [[ -f "$OUT/slices/$s/libsherpa-onnx.a" ]] || die "slice $s is not built ($OUT/slices/$s/libsherpa-onnx.a)"
  done
  local stage="$OUT/stage"
  rm -rf "$stage" "$OUT/SherpaOnnxC.xcframework"
  mkdir -p "$stage/ios" "$stage/ios-sim" "$stage/macos"

  info "Simulator slice: arm64 + x86_64"
  lipo -create "$OUT/slices/ios-sim-arm64/libsherpa-onnx.a" "$OUT/slices/ios-sim-x86_64/libsherpa-onnx.a" \
    -output "$stage/ios-sim/libsherpa-onnx.a"
  make_framework "$OUT/slices/ios-arm64/libsherpa-onnx.a" "$OUT/slices/ios-arm64/include" "$stage/ios" ios
  make_framework "$stage/ios-sim/libsherpa-onnx.a" "$OUT/slices/ios-arm64/include" "$stage/ios-sim" ios-sim
  make_framework "$OUT/slices/macos-arm64/libsherpa-onnx.a" "$OUT/slices/macos-arm64/include" "$stage/macos" macos

  info "Creating SherpaOnnxC.xcframework"
  xcodebuild -create-xcframework \
    -framework "$stage/ios/SherpaOnnxC.framework" \
    -framework "$stage/ios-sim/SherpaOnnxC.framework" \
    -framework "$stage/macos/SherpaOnnxC.framework" \
    -output "$OUT/SherpaOnnxC.xcframework"

  info "Checking every slice of the XCFramework"
  : >"$OUT/symbols.txt"
  local bin
  for bin in "$OUT"/SherpaOnnxC.xcframework/*/SherpaOnnxC.framework/SherpaOnnxC; do
    local slice
    slice="$(basename "$(dirname "$(dirname "$bin")")")"
    { echo "## $slice ($(lipo -archs "$bin"))"; check_symbols "$slice" "$bin"; echo; } | tee -a "$OUT/symbols.txt"
  done

  info "Zipping"
  rm -f "$OUT/$ZIP_NAME"
  (cd "$OUT" && zip -q -r -y -X "$ZIP_NAME" SherpaOnnxC.xcframework)
  local sum
  sum="$(shasum -a 256 "$OUT/$ZIP_NAME" | awk '{print $1}')"
  echo "$sum  $ZIP_NAME" >"$OUT/checksum.txt"

  {
    echo "sherpa-onnx ${SHERPA_TAG} (${SHERPA_COMMIT}), ${SHERPA_REPO}"
    echo "ONNX Runtime ${ORT_VERSION} headers from ${ORT_URL} (sha256 ${ORT_SHA256}); not bundled"
    echo "CMake: Release, static, C API on, TTS off, speaker diarization off, binaries/tests/Python/JNI/websocket/portaudio off"
    echo "Deployment targets: iOS ${IOS_DEPLOYMENT_TARGET}, macOS ${MACOS_DEPLOYMENT_TARGET}"
    echo "Built with: $(xcodebuild -version | tr '\n' ' '); $(cmake --version | head -1)"
    echo
    for s in "${SLICES[@]}"; do
      echo "$s: $(tr '\n' ' ' <"$OUT/slices/$s/members.txt")"
    done
    echo
    echo "sha256 ${sum}  ${ZIP_NAME}"
  } >"$OUT/BUILD-INFO.txt"
  cat "$OUT/BUILD-INFO.txt"
  info "Done: $OUT/$ZIP_NAME"
}

cmd="${1:-all}"
case "$cmd" in
  all)
    for s in "${SLICES[@]}"; do build_slice "$s"; done
    assemble
    ;;
  slice)
    [[ $# -ge 2 ]] || die "usage: $0 slice NAME"
    build_slice "$2"
    ;;
  assemble) assemble ;;
  names) printf 'tag=%s\nzip=%s\nversion=%s\nort=%s\n' "$RELEASE_TAG" "$ZIP_NAME" "$SHERPA_VERSION" "$ORT_VERSION" ;;
  -h|--help) sed -n '2,40p' "$0" ;;
  *) die "unknown command: $cmd" ;;
esac
