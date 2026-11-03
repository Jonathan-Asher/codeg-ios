#!/usr/bin/env bash
#
# scripts/check-app-identity.sh: check that a built Codeg.app carries the
# fork's identity (Config/Identity.xcconfig) and embeds the notification
# service extension.
#
# Usage: scripts/check-app-identity.sh path/to/Codeg.app
#
# The `build` job of .github/workflows/ios.yml runs it on the simulator build,
# and scripts/archive.sh on the archived Release app before anything is
# exported or uploaded.

set -euo pipefail

app="${1:?usage: $0 path/to/Codeg.app}"
plist="$app/Info.plist"

err() {
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then echo "::error::$*"; else echo "error: $*" >&2; fi
  exit 1
}

[[ -f "$plist" ]] || err "no Info.plist in $app"

plutil -p "$plist" | grep -E 'CFBundleIdentifier|CFBundleDisplayName|CFBundleURLSchemes|CodegURLScheme|ITSAppUsesNonExemptEncryption' -A2 || true

check() {
  local got
  got="$(/usr/libexec/PlistBuddy -c "Print :$1" "$plist" 2>/dev/null || true)"
  [[ "$got" == "$2" ]] || err "$1 is '$got' in $plist, expected '$2'"
}

check CFBundleIdentifier io.ashurov.codeg
check CFBundleDisplayName "Codeg Plus"
check CFBundleURLTypes:0:CFBundleURLSchemes:0 codegplus
check CodegURLScheme codegplus
check ITSAppUsesNonExemptEncryption false

# The notification service extension (answer buttons on question pushes).
plist="$app/PlugIns/NotificationService.appex/Info.plist"
[[ -f "$plist" ]] || err "the notification service extension is not embedded in $app"
check CFBundleIdentifier io.ashurov.codeg.NotificationService
check NSExtension:NSExtensionPointIdentifier com.apple.usernotifications.service

echo "App identity OK: $app"
