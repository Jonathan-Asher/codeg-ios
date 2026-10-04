# Changelog

All notable changes to Codeg for iOS are recorded here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Add changes under `## [Unreleased]` as you land them. When you cut a release,
`scripts/release.sh` moves that section under a new version heading and reuses
the text as the git tag message and the GitHub Release notes.

## [Unreleased]

### Added

- Hebrew or English dictation (1.3.1): the new default Language, "Hebrew or
  English (automatic)", tells the two apart on the iPhone with whisper tiny
  (44 MB, downloaded with the speech model) and then transcribes with the
  ivrit.ai model in that language, leaning to Hebrew. An install that already
  has the model fetches only the new file. A language chip on the recording
  strip (Auto, עב, EN) sets it for one message. Hebrew, English and "Detect
  automatically" are still in Settings, and a Hebrew left over from 1.3.0
  moves to the new default once.
- Camera Control "Catch the first words" (1.3.1, on by default): while the
  mode runs, the microphone stands by with the last 1.5 seconds in memory, so
  a press starts with what was said as it went down. Settings › Voice ›
  Camera Control explains the orange dot. It uses the iPhone's microphone so
  AirPods keep playing in full quality, and it steps aside while a reply is
  read aloud.

- Camera Control to talk (1.3.0): with a session open and the mode on, hold
  the Camera Control, speak and let go; the message is transcribed on the
  iPhone, cleaned up if that is on, and sent to the session's agent like the
  Send button (queued or inserted into a running turn). A switch in the
  session's toolbar, remembered across launches; an indicator above the
  message bar while the camera runs for it; an explanation in Settings ›
  Voice. The volume buttons work as talk keys too.
- Dictation clean-up and translation through the codeg server (1.3.0):
  Settings › Voice › Voice Typing › After transcribing (insert as spoken,
  clean up, or clean up and translate to English), a chip on the recording
  strip for one message, and "Translating…" on the strip during the call.
  Only the transcript text goes to the server. Any failure or a 12-second
  timeout inserts the words as spoken, with a short notice.
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
- A dictation cut short by a call or Siri goes into the message bar without
  being sent, even with "Send right after transcribing" on.
- Haptics play while the microphone records.
- The fork's Apple Developer team is committed in `Config/Signing.xcconfig`;
  `Config/Signing.local.xcconfig` can still override it.
- Archive, export and upload moved into `scripts/archive.sh`, shared by
  `scripts/release.sh --archive` and CI.

### Fixed

- English dictation came out in Hebrew (1.3.1), because the only Hebrew
  setting forced Hebrew.
- Camera Control messages lost their first words (1.3.1): the recording now
  starts from the pre-roll, the VAD trim keeps 300 ms before the first speech,
  and the log shows the time from the press to the first live audio.
- A queued message's "⋯" menu often didn't open (1.3.1): its button is now a
  44-point target, the menu lists the same items while the turn streams ("Send
  now" is disabled instead of hidden), and the rows only redraw when the queue
  changes. Each row also has an ✕ to remove it in one tap, and a long press
  opens the same menu.
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
