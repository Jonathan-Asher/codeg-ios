#!/usr/bin/env bash
#
# scripts/archive.sh — archive, export and (optionally) upload an App Store
# Connect build. Shared by `scripts/release.sh --archive` and the `testflight`
# job in .github/workflows/ios.yml.
#
# Usage: scripts/archive.sh [--tag NAME] [--build-number N]
#
#   --tag NAME          Names the outputs: build/CodegiOS-NAME.xcarchive and
#                       build/export-NAME/. Default: "local".
#   --build-number N    Override CURRENT_PROJECT_VERSION for this archive only
#                       (CI uses the run number so every upload is unique).
#
# Environment:
#   CODEG_DEVELOPMENT_TEAM   Optional team override (default: Config/Signing.xcconfig).
#   ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH
#                            App Store Connect API key. When all three are set,
#                            signing is cloud-managed (-allowProvisioningUpdates
#                            with the key) and the .ipa is uploaded with altool.
#                            Without them the archive uses the local Xcode
#                            account and the .ipa is only exported.
#   DRY_RUN=1                Print the commands instead of running them.
#
# Run `xcodegen generate` first (release.sh and CI do).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

EXPORT_OPTS="$SCRIPT_DIR/ExportOptions.plist"
TAG="local"
BUILD_NUMBER=""
DRY_RUN="${DRY_RUN:-0}"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)          [[ $# -ge 2 ]] || die "--tag requires a value"; TAG="$2"; shift 2 ;;
    --build-number) [[ $# -ge 2 ]] || die "--build-number requires a value"; BUILD_NUMBER="$2"; shift 2 ;;
    -h|--help)      sed -n '2,25p' "$0"; exit 0 ;;
    *)              die "unknown argument: $1" ;;
  esac
done
if [[ -n "$BUILD_NUMBER" && ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  die "--build-number must be a positive integer (got '$BUILD_NUMBER')"
fi

run() {
  if [[ "$DRY_RUN" == 1 ]]; then
    local q="" a
    for a in "$@"; do q+=" $(printf '%q' "$a")"; done
    printf '[dry-run]%s\n' "$q"
  else
    "$@"
  fi
}

[[ "$DRY_RUN" == 1 || -d CodegiOS.xcodeproj ]] || die "CodegiOS.xcodeproj missing — run xcodegen generate first"

ARCHIVE_PATH="build/CodegiOS-$TAG.xcarchive"
EXPORT_PATH="build/export-$TAG"
run mkdir -p build

AUTH_ARGS=()
if [[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" && -n "${ASC_KEY_PATH:-}" ]]; then
  if [[ "$DRY_RUN" != 1 && ! -f "$ASC_KEY_PATH" ]]; then die "ASC_KEY_PATH not found: $ASC_KEY_PATH"; fi
  AUTH_ARGS=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

BUILD_ARGS=()
if [[ -n "${CODEG_DEVELOPMENT_TEAM:-}" ]]; then
  BUILD_ARGS+=(CODEG_DEVELOPMENT_TEAM="$CODEG_DEVELOPMENT_TEAM")
fi
if [[ -n "$BUILD_NUMBER" ]]; then
  BUILD_ARGS+=(CURRENT_PROJECT_VERSION="$BUILD_NUMBER")
fi

info "Archiving $ARCHIVE_PATH"
run xcodebuild -project CodegiOS.xcodeproj -scheme CodegiOS -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$ARCHIVE_PATH" \
    ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"} \
    ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} \
    -skipMacroValidation -allowProvisioningUpdates clean archive

# Static frameworks (ONNX Runtime ships its iOS binary as a static archive) are
# linked into the app binary, but Xcode still copies the .framework into
# Codeg.app/Frameworks (with or without its binary). App Store Connect rejects
# such a bundle (ITMS-90208), so drop every embedded framework the app binary
# does not load before export re-signs the app.
APP_DIR="$ARCHIVE_PATH/Products/Applications/Codeg.app"
if [[ "$DRY_RUN" != 1 ]]; then
  for fw in "$APP_DIR"/Frameworks/*.framework; do
    [[ -e "$fw" ]] || continue
    name="$(basename "$fw")"
    if ! otool -L "$APP_DIR/Codeg" | grep -qF "@rpath/$name/"; then
      info "Removing unused framework from the bundle: $name"
      rm -rf "$fw"
    fi
  done
fi

info "Exporting to $EXPORT_PATH"
run xcodebuild -exportArchive -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" -exportOptionsPlist "$EXPORT_OPTS" \
    ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} -allowProvisioningUpdates

if [[ ${#AUTH_ARGS[@]} -gt 0 ]]; then
  # altool locates the key by id under ~/.appstoreconnect/private_keys/AuthKey_<ID>.p8
  KEYDIR="$HOME/.appstoreconnect/private_keys"
  run mkdir -p "$KEYDIR"
  if [[ "$ASC_KEY_PATH" != "$KEYDIR/AuthKey_${ASC_KEY_ID}.p8" ]]; then
    run cp "$ASC_KEY_PATH" "$KEYDIR/AuthKey_${ASC_KEY_ID}.p8"
  fi
  if [[ "$DRY_RUN" == 1 ]]; then
    printf '[dry-run] xcrun altool --upload-app -f %s/*.ipa -t ios --apiKey %s --apiIssuer %s\n' \
      "$EXPORT_PATH" "$ASC_KEY_ID" "$ASC_ISSUER_ID"
  else
    IPA="$(ls "$EXPORT_PATH"/*.ipa 2>/dev/null | head -1 || true)"
    [[ -n "$IPA" ]] || die "no .ipa produced in $EXPORT_PATH"
    # Refuse to upload a bundle App Store Connect would reject for an embedded
    # framework the app never loads.
    CHECK_DIR="$(mktemp -d)"
    unzip -q "$IPA" -d "$CHECK_DIR"
    for fw in "$CHECK_DIR"/Payload/*.app/Frameworks/*.framework; do
      [[ -e "$fw" ]] || continue
      name="$(basename "$fw")"
      if ! otool -L "$CHECK_DIR"/Payload/*.app/Codeg | grep -qF "@rpath/$name/"; then
        die "the .ipa embeds a framework the app does not load: $name"
      fi
    done
    rm -rf "$CHECK_DIR"
    xcrun altool --upload-app -f "$IPA" -t ios --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
    info "Uploaded $IPA to App Store Connect."
  fi
else
  printf 'warn: ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH not all set — skipping upload.\n' >&2
  printf 'warn: the exported .ipa is in %s; upload it via Transporter.app or set those vars and re-run.\n' "$EXPORT_PATH" >&2
fi
