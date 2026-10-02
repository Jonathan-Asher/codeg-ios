#!/usr/bin/env bash
#
# scripts/release.sh — cut a new Codeg for iOS release.
#
# One command bumps the version, files the release notes, tags, pushes, and
# creates a GitHub Release. With --archive it also builds and (if an App Store
# Connect API key is configured) uploads to App Store Connect — the archive and
# upload run *before* anything is published, so a signing/upload failure never
# leaves a public release without a build.
#
# The version is single-sourced from project.yml's MARKETING_VERSION (the
# displayed X.Y.Z) and CURRENT_PROJECT_VERSION (the build number). The release
# notes come from the CHANGELOG.md [Unreleased] section (or --notes).
#
# See the "Releasing" section of README.md for the full workflow.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

PROJECT_YML="$ROOT/project.yml"
CHANGELOG="$ROOT/CHANGELOG.md"

# ---- pretty output -----------------------------------------------------------
if [[ -t 1 ]]; then
  DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RST=$'\033[0m'
else
  DIM=""; RED=""; GRN=""; YEL=""; RST=""
fi
info() { printf '%s==>%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%swarn:%s %s\n' "$YEL" "$RST" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: scripts/release.sh <patch|minor|major|X.Y.Z> [options]

Bump the version, file the release notes, tag, push, and create a GitHub Release.

Version argument:
  patch|minor|major   Increment the marketing version by that semver level.
  X.Y.Z               Set the marketing version explicitly.
  (the build number CURRENT_PROJECT_VERSION always increments by 1)

Options:
  --notes "text"   Use this text as the release notes (overrides CHANGELOG,
                   and is written into the promoted CHANGELOG section too).
  --archive        Archive + export an .ipa (and upload to App Store Connect if
                   ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH are set) BEFORE the
                   tag/release are published.
  --yes, -y        Don't prompt for confirmation before pushing / publishing.
  --dry-run        Print every action; change, commit, or push nothing.
  -h, --help       Show this help.

Signing environment:
  CODEG_DEVELOPMENT_TEAM   Optional Apple Developer Team ID for --archive.
                           Overrides Config/Signing.local.xcconfig.
  ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH
                           Optional App Store Connect upload credentials.

Examples:
  scripts/release.sh patch
  scripts/release.sh 1.2.0 --notes "First public TestFlight build"
  scripts/release.sh minor --archive --yes
EOF
}

# ---- args --------------------------------------------------------------------
BUMP=""; NOTES=""; HAVE_NOTES=0; ARCHIVE=0; ASSUME_YES=0; DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    patch|minor|major)     BUMP="$1"; shift ;;
    [0-9]*.[0-9]*.[0-9]*)  BUMP="$1"; shift ;;
    --notes)               [[ $# -ge 2 ]] || { usage; die "--notes requires a value"; }
                           NOTES="$2"; HAVE_NOTES=1; shift 2 ;;
    --archive)             ARCHIVE=1; shift ;;
    --yes|-y)              ASSUME_YES=1; shift ;;
    --dry-run)             DRY_RUN=1; shift ;;
    -h|--help)             usage; exit 0 ;;
    *)                     usage; die "unknown argument: $1" ;;
  esac
done
if [[ -z "$BUMP" ]]; then usage; die "missing version argument (patch|minor|major|X.Y.Z)"; fi

# Run a side-effecting command, or just print it (quoted) under --dry-run.
run() {
  if [[ "$DRY_RUN" == 1 ]]; then
    local q="" a
    for a in "$@"; do q+=" $(printf '%q' "$a")"; done
    printf '%s[dry-run]%s%s\n' "$DIM" "$RST" "$q"
  else
    "$@"
  fi
}

# ---- preconditions -----------------------------------------------------------
command -v xcodegen >/dev/null 2>&1 || die "xcodegen not found (brew install xcodegen)"
command -v gh       >/dev/null 2>&1 || die "gh not found (brew install gh)"
gh auth status >/dev/null 2>&1        || die "gh is not logged in (run: gh auth login)"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1 \
  || die "branch '$BRANCH' has no upstream — set one with: git push -u origin $BRANCH"

if [[ -n "$(git status --porcelain)" ]]; then
  die "working tree is not clean — commit or stash first so the release commit stays focused"
fi

# ---- current version ---------------------------------------------------------
read_yml() { grep -E "^[[:space:]]*$1:" "$PROJECT_YML" | head -1 | sed -E 's/.*"([^"]+)".*/\1/'; }
OLD_VERSION="$(read_yml MARKETING_VERSION)"
OLD_BUILD="$(read_yml CURRENT_PROJECT_VERSION)"
[[ "$OLD_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "can't parse MARKETING_VERSION (got '$OLD_VERSION')"
[[ "$OLD_BUILD"   =~ ^[0-9]+$ ]]                 || die "can't parse CURRENT_PROJECT_VERSION (got '$OLD_BUILD')"

# ---- compute new version -----------------------------------------------------
IFS=. read -r MA MI PA <<<"$OLD_VERSION"
case "$BUMP" in
  patch) NEW_VERSION="$MA.$MI.$((PA + 1))" ;;
  minor) NEW_VERSION="$MA.$((MI + 1)).0" ;;
  major) NEW_VERSION="$((MA + 1)).0.0" ;;
  *)     NEW_VERSION="$BUMP" ;;
esac
[[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "computed version '$NEW_VERSION' is not X.Y.Z"
NEW_BUILD="$((OLD_BUILD + 1))"
TAG="v$NEW_VERSION"
DATE="$(date +%Y-%m-%d)"

# Tag must not exist locally OR on the remote (a stale clone can miss a remote
# tag and otherwise commit + push the branch before failing on the tag push).
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1; then
  die "tag $TAG already exists locally"
fi
# Distinguish "tag absent" (ls-remote exit 2) from network/auth errors, so a
# failed lookup aborts instead of sailing on toward a release.
lsr_rc=0
git ls-remote --tags --exit-code origin "refs/tags/$TAG" >/dev/null 2>&1 || lsr_rc=$?
if [[ "$lsr_rc" -eq 0 ]]; then
  die "tag $TAG already exists on origin — fetch and pick a newer version"
elif [[ "$lsr_rc" -ne 2 ]]; then
  die "couldn't query origin for tag $TAG (git ls-remote exit $lsr_rc) — check network/remote access"
fi

# ---- resolve release notes ---------------------------------------------------
# Body of the CHANGELOG's "## [Unreleased]" section (up to the next "## [").
extract_unreleased() {
  awk '
    /^## \[Unreleased\]/ { cap = 1; next }
    /^## \[/            { if (cap) exit }
    cap                 { print }
  ' "$CHANGELOG"
}
CHANGELOG_BODY="$(extract_unreleased || true)"
# "Meaningful" = something other than blank lines and empty "### Section" headers.
CHANGELOG_MEANINGFUL="$(printf '%s\n' "$CHANGELOG_BODY" | grep -vE '^[[:space:]]*$' | grep -vE '^###[[:space:]]' || true)"

NOTES_FILE="$(mktemp -t codeg-release-notes)"
# Prints a rollback hint (only when set) if the script exits non-zero partway.
FAILED_HINT=""
cleanup() {
  local rc=$?
  rm -f "$NOTES_FILE"
  if [[ $rc -ne 0 && -n "$FAILED_HINT" ]]; then
    printf '%swarn:%s %s\n' "$YEL" "$RST" "$FAILED_HINT" >&2
  fi
}
trap cleanup EXIT

if [[ "$HAVE_NOTES" == 1 ]]; then
  printf '%s\n' "$NOTES" >"$NOTES_FILE"
elif [[ -n "$CHANGELOG_MEANINGFUL" ]]; then
  printf '%s\n' "$CHANGELOG_BODY" | sed -e '/./,$!d' >"$NOTES_FILE"   # drop leading blank lines
elif [[ "$DRY_RUN" == 1 ]]; then
  printf 'Release %s\n' "$NEW_VERSION" >"$NOTES_FILE"
  warn "[dry-run] CHANGELOG [Unreleased] is empty; would open \$EDITOR — using a placeholder"
else
  : "${EDITOR:=vi}"
  {
    printf '# Release notes for %s. Lines starting with # are ignored.\n' "$TAG"
    printf '# Tip: fill in CHANGELOG.md [Unreleased] next time and this opens pre-filled.\n'
  } >"$NOTES_FILE"
  "$EDITOR" "$NOTES_FILE"
  sed -i '' -e '/^#/d' "$NOTES_FILE"
fi
if [[ ! -s "$NOTES_FILE" || -z "$(grep -vE '^[[:space:]]*$' "$NOTES_FILE" || true)" ]]; then
  die "release notes are empty — add entries under CHANGELOG.md [Unreleased] or pass --notes"
fi

# ---- confirm -----------------------------------------------------------------
echo
info "Release plan"
printf '  version : %s  ->  %s\n' "$OLD_VERSION" "$NEW_VERSION"
printf '  build   : %s  ->  %s\n' "$OLD_BUILD" "$NEW_BUILD"
printf '  tag     : %s\n' "$TAG"
printf '  branch  : %s\n' "$BRANCH"
printf '  archive : %s\n' "$([[ "$ARCHIVE" == 1 ]] && echo yes || echo no)"
echo   '  notes   :'
sed 's/^/    | /' "$NOTES_FILE"
echo
if [[ "$ASSUME_YES" != 1 && "$DRY_RUN" != 1 ]]; then
  read -r -p "Proceed with this release? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || die "aborted"
fi

# ---- bump project.yml --------------------------------------------------------
set_yml() {  # key value — replaces the quoted value on the "key:" line
  sed -E -i '' "s/^([[:space:]]*$1:[[:space:]]*)\"[^\"]*\"/\1\"$2\"/" "$PROJECT_YML"
}
if [[ "$DRY_RUN" == 1 ]]; then
  printf '%s[dry-run]%s set MARKETING_VERSION="%s" and CURRENT_PROJECT_VERSION="%s" in project.yml\n' \
    "$DIM" "$RST" "$NEW_VERSION" "$NEW_BUILD"
else
  set_yml MARKETING_VERSION "$NEW_VERSION"
  set_yml CURRENT_PROJECT_VERSION "$NEW_BUILD"
  # git checkout HEAD -- <paths> restores both the index and the working tree,
  # so this discards the release edits whether or not `git add` has staged them.
  FAILED_HINT="release changes are local but not committed — discard with: git checkout HEAD -- project.yml CHANGELOG.md CodegiOS/Info.plist"
fi

# ---- promote CHANGELOG [Unreleased] -> [X.Y.Z] with the published notes -------
# The new version section always carries exactly the notes we publish (whether
# they came from [Unreleased], --notes, or the editor), so CHANGELOG and the
# GitHub Release never disagree.
if [[ "$DRY_RUN" == 1 ]]; then
  printf '%s[dry-run]%s promote CHANGELOG [Unreleased] -> ## [%s] - %s (fill with the notes, reset Unreleased)\n' \
    "$DIM" "$RST" "$NEW_VERSION" "$DATE"
else
  tmp="$(mktemp)"
  awk -v ver="$NEW_VERSION" -v date="$DATE" -v nf="$NOTES_FILE" '
    function emit_notes(  line) { while ((getline line < nf) > 0) print line; close(nf) }
    /^## \[Unreleased\]/ && !seen {
      seen = 1
      print "## [Unreleased]"; print "";
      print "### Added"; print "";
      print "### Changed"; print "";
      print "### Fixed"; print "";
      print "## [" ver "] - " date; print "";
      emit_notes(); print "";
      skip = 1        # drop the old [Unreleased] body; it is now in the notes
      next
    }
    skip && /^## \[/ { skip = 0 }   # reached the previous version — resume copying
    skip { next }
    { print }
  ' "$CHANGELOG" >"$tmp"
  mv "$tmp" "$CHANGELOG"
fi

run xcodegen generate

# ---- optional: archive + export + upload BEFORE publishing -------------------
# Runs from the (uncommitted) bumped working tree. If signing/export/upload
# fails, set -e aborts here — nothing is committed, tagged, pushed, or released,
# and FAILED_HINT tells you how to discard the bump.
if [[ "$ARCHIVE" == 1 ]]; then
  info "Archiving for App Store Connect (before publishing)"
  run mkdir -p build
  run cp "$NOTES_FILE" "build/release-notes-$TAG.txt"
  # Archive + export + optional upload live in scripts/archive.sh, shared with
  # the CI testflight job. It honors DRY_RUN and the ASC_* / team env vars.
  DRY_RUN="$DRY_RUN" "$SCRIPT_DIR/archive.sh" --tag "$TAG"
fi

# ---- commit, tag, push, release ---------------------------------------------
run git add "$PROJECT_YML" "$CHANGELOG" "$ROOT/CodegiOS/Info.plist"
run git commit -m "release: $TAG (build $NEW_BUILD)"
[[ "$DRY_RUN" == 1 ]] || FAILED_HINT="a local release commit exists but no tag was created — undo with: git reset --hard HEAD~1"
# --cleanup=verbatim: keep the notes exactly, incl. Markdown '### Header' lines
# that Git's default cleanup would strip as comments.
run git tag -a "$TAG" --cleanup=verbatim -F "$NOTES_FILE"
[[ "$DRY_RUN" == 1 ]] || FAILED_HINT="a local release commit + tag $TAG exist but nothing was pushed — undo with: git reset --hard HEAD~1 && git tag -d $TAG"
# Push branch and tag atomically: never leave origin/$BRANCH pushed without its tag.
run git push --atomic origin "$BRANCH" "$TAG"
[[ "$DRY_RUN" == 1 ]] || FAILED_HINT="branch + tag $TAG are pushed but the GitHub Release was not created — finish with: gh release create $TAG --title $TAG --target $BRANCH --notes-from-tag"
run gh release create "$TAG" --title "$TAG" --notes-file "$NOTES_FILE" --target "$BRANCH"
FAILED_HINT=""

if [[ "$ARCHIVE" == 1 ]]; then
  info "App Store 'What's New' text is in build/release-notes-$TAG.txt — altool can't set it; paste it into App Store Connect."
fi

echo
info "Done — $TAG released."
if [[ "$DRY_RUN" == 1 ]]; then warn "(dry-run — nothing was actually changed)"; fi
