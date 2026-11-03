#!/usr/bin/env bash
#
# scripts/ci-mac-runner.sh: what .github/workflows/ios.yml does only on
# Jonathan's Mac, the self-hosted runner m4-ios (label codeg-m4-ios).
#
# Usage: scripts/ci-mac-runner.sh prepare|simulator|shutdown
#
#   prepare    Fails clearly if the Metal toolchain is missing, puts pinned
#              XcodeGen and xcbeautify builds on PATH (downloaded once into
#              $HOME/tools, checksums verified), keeps DerivedData in
#              $HOME/dd/codeg-ios under 10 GB, makes sure 20 GB are free, and
#              exports DERIVED_DATA and XCODEBUILD_EXTRA for the later steps.
#   simulator  Erases the dedicated "Codeg CI iPhone 17 Pro Max" simulator on
#              the newest iOS runtime (creating it the first time) and exports
#              SIM_UDID.
#   shutdown   Shuts that one simulator down and erases it, so its data
#              (about 2 GB after a test run) doesn't sit on the Mac's disk
#              between runs. Never `simctl shutdown all`: the Mac's other
#              simulators are Jonathan's.
#
# Nothing is installed into Homebrew or Xcode. On the runner, HOME is
# ~/actions-runner/_home/ios, so the tools and DerivedData stay in the runner
# folder.

set -euo pipefail

XCODEGEN_VERSION=2.46.0
XCODEGEN_SHA256=4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806
XCBEAUTIFY_VERSION=3.2.1
XCBEAUTIFY_SHA256=ed32972e41bc3aa19588f8b0f4a0209ef70c663ad60bbf4ad84a2de73355d637
DD="$HOME/dd/codeg-ios"
DD_CAP_GB=10
MIN_FREE_GB=20
SIM_NAME="Codeg CI iPhone 17 Pro Max"
SIM_TYPE=com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max

err() { echo "::error::$*"; exit 1; }
: "${GITHUB_ENV:?run this from a GitHub Actions job}"

# fetch NAME VERSION URL SHA256: unpack a release zip into $HOME/tools/NAME-VERSION once.
fetch() {
  local dir="$HOME/tools/$1-$2" tmp
  [[ -f "$dir/.complete" ]] && return 0
  tmp="$(mktemp -d)"
  curl -fsSL --retry 3 -o "$tmp/download.zip" "$3"
  echo "$4  $tmp/download.zip" | shasum -a 256 -c - >/dev/null || err "$1 $2: checksum mismatch for $3"
  rm -rf "$dir"
  mkdir -p "$dir"
  ditto -x -k "$tmp/download.zip" "$dir"
  touch "$dir/.complete"
  rm -rf "$tmp"
  echo "Installed $1 $2 into $dir"
}

free_gb() { df -g "$HOME" | awk 'NR == 2 { print $4 }'; }
dd_gb() { if [[ -d "$DD" ]]; then echo $(( $(du -sk "$DD" | cut -f1) / 1048576 )); else echo 0; fi; }

prepare() {
  # SwiftTerm ships a Metal shader. Xcode 26+ installs the Metal compiler as a
  # separate component, which a job must not download onto Jonathan's Mac.
  if ! xcrun metal --version >/dev/null 2>&1; then
    err "The Metal toolchain is missing on this Mac, and SwiftTerm's shader needs it. Install it once on the Mac with: xcodebuild -downloadComponent MetalToolchain"
  fi

  fetch xcodegen "$XCODEGEN_VERSION" \
    "https://github.com/yonaskolb/XcodeGen/releases/download/$XCODEGEN_VERSION/xcodegen.zip" "$XCODEGEN_SHA256"
  fetch xcbeautify "$XCBEAUTIFY_VERSION" \
    "https://github.com/cpisciotta/xcbeautify/releases/download/$XCBEAUTIFY_VERSION/xcbeautify-$XCBEAUTIFY_VERSION-arm64-apple-macosx.zip" "$XCBEAUTIFY_SHA256"
  chmod +x "$HOME/tools/xcodegen-$XCODEGEN_VERSION/xcodegen/bin/xcodegen" "$HOME/tools/xcbeautify-$XCBEAUTIFY_VERSION/xcbeautify"
  {
    echo "$HOME/tools/xcodegen-$XCODEGEN_VERSION/xcodegen/bin"
    echo "$HOME/tools/xcbeautify-$XCBEAUTIFY_VERSION"
  } >>"$GITHUB_PATH"
  echo "XcodeGen $("$HOME/tools/xcodegen-$XCODEGEN_VERSION/xcodegen/bin/xcodegen" --version 2>&1 | tail -1), xcbeautify $("$HOME/tools/xcbeautify-$XCBEAUTIFY_VERSION/xcbeautify" --version 2>&1 | tail -1)"

  # DerivedData stays between runs, so a push only rebuilds what changed.
  # Logs and result bundles are not build inputs (result bundles go to
  # RUNNER_TEMP, which the runner empties after each job).
  mkdir -p "$DD"
  rm -rf "$DD/Logs"
  local size free
  size="$(dd_gb)"
  if (( size >= DD_CAP_GB )); then
    echo "DerivedData is $size GB, over the $DD_CAP_GB GB cap: starting it afresh."
    rm -rf "$DD"
    mkdir -p "$DD"
  fi
  free="$(free_gb)"
  if (( free < MIN_FREE_GB )) && [[ -n "$(ls -A "$DD")" ]]; then
    echo "Only $free GB free: dropping this runner's DerivedData."
    rm -rf "$DD"
    mkdir -p "$DD"
    free="$(free_gb)"
  fi
  if (( free < MIN_FREE_GB )); then
    err "Only $free GB free on the Mac; an iPhone job needs $MIN_FREE_GB GB. The runner guard moves iPhone jobs to GitHub's runners below 25 GB; run this job again once it has."
  fi
  echo "DerivedData $DD: $(dd_gb) GB. Free on the Mac: $free GB."

  {
    echo "DERIVED_DATA=$DD"
    echo "XCODEBUILD_EXTRA=COMPILER_INDEX_STORE_ENABLE=NO -resultBundlePath $RUNNER_TEMP/result.xcresult"
  } >>"$GITHUB_ENV"
}

simulator() {
  local runtime udid stale
  # The newest general iOS runtime: not one made for a single new device
  # model, such as com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4.
  runtime="$(xcrun simctl list runtimes available -j | python3 -c '
import json, re, sys
runtimes = [r for r in json.load(sys.stdin)["runtimes"]
            if r.get("isAvailable") and re.search(r"\.iOS-[0-9]+-[0-9]+$", r["identifier"])]
runtimes.sort(key=lambda r: tuple(int(x) for x in r["version"].split(".")))
print(runtimes[-1]["identifier"] if runtimes else "")
')"
  [[ -n "$runtime" ]] || err "No iOS simulator runtime on this Mac. Install one once on the Mac with: xcodebuild -downloadPlatform iOS"

  # [udid of the CI simulator on that runtime] then every other copy of it
  # (an older runtime's, or one whose runtime is gone).
  read -r udid stale < <(xcrun simctl list devices -j | python3 -c '
import json, sys
name, runtime = sys.argv[1], sys.argv[2]
keep, stale = "", []
for rt, devices in json.load(sys.stdin)["devices"].items():
    for d in devices:
        if d["name"] != name:
            continue
        if rt == runtime and d.get("isAvailable") and not keep:
            keep = d["udid"]
        else:
            stale.append(d["udid"])
print(keep or "-", ",".join(stale))
' "$SIM_NAME" "$runtime") || true
  for old in ${stale//,/ }; do
    echo "Deleting an old \"$SIM_NAME\": $old"
    xcrun simctl delete "$old" || true
  done
  if [[ -z "$udid" || "$udid" == "-" ]]; then
    udid="$(xcrun simctl create "$SIM_NAME" "$SIM_TYPE" "$runtime")"
    echo "Created \"$SIM_NAME\" ($udid) on $runtime"
  fi
  xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
  local i
  for i in 1 2 3; do
    xcrun simctl erase "$udid" && break
    (( i < 3 )) || err "could not erase the simulator $udid"
    sleep 5
  done
  echo "SIM_UDID=$udid" >>"$GITHUB_ENV"
  xcrun simctl list devices | grep "$udid" || true
}

shutdown_simulator() {
  if [[ -n "${SIM_UDID:-}" ]]; then
    xcrun simctl shutdown "$SIM_UDID" 2>/dev/null || true
    xcrun simctl erase "$SIM_UDID" || true
    xcrun simctl list devices | grep "$SIM_UDID" || true
  fi
}

case "${1:-}" in
  prepare)   prepare ;;
  simulator) simulator ;;
  shutdown)  shutdown_simulator ;;
  *)         sed -n '2,23p' "$0"; exit 2 ;;
esac
