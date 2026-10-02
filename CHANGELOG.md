# Changelog

All notable changes to Codeg for iOS are recorded here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Add changes under `## [Unreleased]` as you land them. When you cut a release,
`scripts/release.sh` moves that section under a new version heading and reuses
the text as the git tag message and the GitHub Release notes.

## [Unreleased]

### Added

- Codeg Plus fork identity: bundle id `io.ashurov.codeg`, display name
  "Codeg Plus", URL scheme `codegplus`, all set in `Config/Identity.xcconfig`.
- Push notification entitlements (`aps-environment`, time-sensitive) and an
  APNs device-token registration stub.
- CI: a simulator build on every push and pull request, plus a manual
  TestFlight upload job (off until its secrets exist).

### Changed

- The fork's Apple Developer team is committed in `Config/Signing.xcconfig`;
  `Config/Signing.local.xcconfig` can still override it.
- Archive, export and upload moved into `scripts/archive.sh`, shared by
  `scripts/release.sh --archive` and CI.

### Fixed

- Unknown and custom agent types no longer decode as Claude (upstream #4).
- The live stream recovers after a drop or backgrounding, and the session
  resyncs when the app returns to the foreground (upstream #10, #17).
- Expert Skills use endpoints that exist on codeg-server (upstream #15).
- The transcript keeps its bottom pin across keyboard and layout changes
  (upstream #16).
- The event WebSocket keeps the server URL's base path (upstream #19).

## [1.0.1] - 2026-07-07

### Added

- **New agent types** — CodeBuddy, Kimi Code, and Pi.
- One-command release automation: `scripts/release.sh` bumps the version, files
  the release notes, tags, pushes, and creates a GitHub Release (with an
  optional `--archive` App Store Connect upload leg).
- This `CHANGELOG.md` as the home for version notes.

### Changed

- The app version is now single-sourced from `MARKETING_VERSION` /
  `CURRENT_PROJECT_VERSION` in `project.yml`.

### Fixed

- Streaming no longer rebuilds the entire transcript on every token, keeping
  long sessions smooth.
- The pending approval card is restored after a mid-turn stream reconnect.
- `Info.plist` no longer hardcodes `CFBundleShortVersionString`, which had
  silently overridden `MARKETING_VERSION` so version bumps didn't take effect.

## [1.0.0] - 2026-06-07

### Added

- Initial Codeg for iOS release.
