# Changelog

All notable changes to Codeg for iOS are recorded here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Add changes under `## [Unreleased]` as you land them. When you cut a release,
`scripts/release.sh` moves that section under a new version heading and reuses
the text as the git tag message and the GitHub Release notes.

## [Unreleased]

### Added

- Activity can list the most recent session at the bottom of the screen and
  open scrolled there (Settings › Appearance › "Newest at the bottom", on by
  default). It stays on the newest session as sessions update, unless you have
  scrolled up.

- Voice typing: a mic in the message bar (tap to start and stop, or hold to
  talk) with a live level meter and timer. Speech is transcribed on the iPhone
  with whisper.cpp and ivrit.ai's Hebrew large-v3-turbo (q8_0), trimmed with
  Silero VAD, and inserted at the cursor; an optional switch sends the message
  right after. Hebrew (default), English, or detect automatically with the
  stock multilingual model. The session's folder and title bias the spelling.
  The models download on demand from Settings › Voice (875 MB, resumable,
  checksummed) from this repository's `models-v1` release.
- Push notifications from every saved codeg server: permission asked after a
  server is added (or from Settings), the device token registered with each
  server, Acknowledge / Snooze / Approve / Open actions, taps that open the
  session, no banner for the session on screen, and phone presence reported to
  the server while a session is open.
- Settings › Notifications: this iPhone's preferences on each server (turn
  finished, needs you, critical alerts, errors) and "Send test push".
- What each session is doing — Working, Needs you, Idle, Interrupted, idle with
  background tasks, paused on the usage limit — on session rows and in the
  session title.
- Insert a message into the running turn (native steering), queue messages for
  when the turn ends, and deliver at once while only background work holds the
  turn.
- A Continue chip after an agent reply, and "Continued" dividers for continue,
  resume-after-restart and limit-reset turns.
- Session Details shows the session's model, effort and mode.
- Read aloud: agent replies read on device with BlueTTS (Hebrew + English),
  a one-time 575 MB model download in the background, playback with the screen
  locked and Now Playing controls; the system voice reads until the model is
  there. Settings › Voice manages the model, voice, speed and what is read.
- Unit tests (`CodegiOSTests`) and a CI job that runs them.
- Codeg Plus fork identity: bundle id `io.ashurov.codeg`, display name
  "Codeg Plus", URL scheme `codegplus`, all set in `Config/Identity.xcconfig`.
- Push notification entitlements (`aps-environment`, time-sensitive).
- CI: a simulator build on every push and pull request, plus a manual
  TestFlight upload job (off until its secrets exist).

### Changed

- Session lists are easier to read: each session is its own card (inset rows
  inside the Chats folder cards) with the title on up to two lines, the agent,
  the folder, the time and a status tag, and a press highlight. A row in a
  Chats folder card opens that session instead of the whole card. The session
  you came from is outlined. VoiceOver reads each row as one element.
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
