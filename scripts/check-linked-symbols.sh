#!/usr/bin/env bash
#
# scripts/check-linked-symbols.sh: check that the linked app binary carries one
# ONNX Runtime and one espeak-ng.
#
# Usage: scripts/check-linked-symbols.sh path/to/Codeg.app/Codeg
#
# BlueTTSKit links ONNX Runtime 1.30.0 and espeak-ng (BlueTTSEspeak); the
# SherpaOnnx and SmartTurn packages must use that runtime, not bring their own
# (scripts/build-sherpa-onnx.sh builds sherpa-onnx without TTS, so without a
# second espeak-ng). A second static copy linked with hidden visibility would
# not clash at link time: it would show up as a second, local definition of
# the same name. So every defined C symbol named _Ort* (ONNX Runtime's C API)
# or _espeak* (espeak_* and espeak_ng_*) must appear exactly once,
# _OrtGetApiBase must be defined, and sherpa-onnx must be in the binary.
#
# Run on an unstripped build (xcodebuild build, not an exported archive).

set -euo pipefail

bin="${1:?usage: $0 path/to/binary}"
[[ -f "$bin" ]] || { echo "error: no binary at $bin" >&2; exit 1; }

fail=0
err() { echo "::error::$*"; fail=1; }

echo "Binary: $bin ($(lipo -archs "$bin"), $(du -h "$bin" | awk '{print $1}'))"
symbols="$(nm -m "$bin" | grep -v '(undefined)' || true)"
names() { awk '{print $NF}' <<<"$symbols" | grep -E "$1" || true; }

ort="$(names '^_Ort[A-Z]')"
espeak="$(names '^_espeak')"
sherpa="$(names '^_SherpaOnnx')"
echo "Defined _Ort* C API symbols: $(grep -c . <<<"$ort" || true)"
echo "Defined _espeak* symbols: $(grep -c . <<<"$espeak" || true)"
echo "Defined _SherpaOnnx* symbols: $(grep -c . <<<"$sherpa" || true)"

dupes="$(printf '%s\n%s\n' "$ort" "$espeak" | grep . | sort | uniq -d || true)"
if [[ -n "$dupes" ]]; then
  err "symbols defined more than once (a second ONNX Runtime or espeak-ng?):"
  echo "$dupes" | head -40
  grep -F -f <(echo "$dupes") <<<"$symbols" | head -40
fi

count="$(grep -cx '_OrtGetApiBase' <<<"$ort" || true)"
[[ "$count" == 1 ]] || err "_OrtGetApiBase is defined $count times, expected once"
[[ -n "$espeak" ]] || err "no _espeak* symbols: is BlueTTSEspeak still linked? (the check would prove nothing)"
grep -qx '_SherpaOnnxGetOnnxruntimeVersionStr' <<<"$sherpa" \
  || err "sherpa-onnx is not in the binary (_SherpaOnnxGetOnnxruntimeVersionStr missing)"

# For information: onnxruntime:: names that repeat. Functions with internal
# linkage can legitimately share a name across files, so this doesn't fail.
cxx="$(names '^__ZN11onnxruntime' | sort | uniq -d | grep -c . || true)"
echo "Repeated onnxruntime:: names (internal linkage, informational): $cxx"

if [[ "$fail" == 0 ]]; then
  echo "OK: one ONNX Runtime (_OrtGetApiBase defined once, no _Ort* symbol twice), one espeak-ng (no _espeak* symbol twice), sherpa-onnx linked."
fi
exit "$fail"
