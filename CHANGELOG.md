# Changelog

All notable changes to Codeg for iOS are recorded here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Add changes under `## [Unreleased]` as you land them. When you cut a release,
`scripts/release.sh` moves that section under a new version heading and reuses
the text as the git tag message and the GitHub Release notes.

## [Unreleased]

### Added

- Activity lists older sessions on demand (1.3.6). Sessions not touched in
  the last 24 hours no longer simply vanish: an "Earlier" card at the old end
  of the feed (the top with the newest at the bottom) lists them 20 at a time.
- Opened sessions are kept on the iPhone (1.3.6). Opening one again draws its
  saved copy at once, pictures included, and then fetches only what changed;
  if the server can't be reached, the saved copy stays on screen. The cache
  lives in the Caches folder, is capped at 256 MB (least recently opened go
  first) and is cleared for a server whose address or token changes. Sessions
  in Activity that finish a turn are refreshed into it in the background (on
  Wi-Fi for ones never opened).

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

- Long sessions open with their latest 120 turns (1.3.6), and earlier ones load
  as you scroll up, instead of downloading the whole transcript each time:
  8.7 MB became 1.0 MB for a 1,700-turn session with pictures. Refreshes after
  a turn, on returning to the app and on reopening fetch only the turns that
  changed, and reload from the end if the server rewrote the history.
- Pictures in a transcript are decoded off the main thread and scaled to the
  screen (1.3.6), so scrolling onto a large screenshot no longer stutters.
- A notification or a link opens its session on the tab you are on (1.3.6),
  so Back returns to Activity (or the list you were in) rather than to Chats;
  from Settings it opens on Activity. The app reopens on the tab you left.
- A Chats folder's full list opens as a screen of its own (1.3.6), so Back from
  a session opened there returns to it.
- The ✕ on the Camera Control pill (1.3.3) only hides the pill now: it folds
  into the mic's badge at once (or hides a pause or failure report until the
  status changes) and the mode stays on. The toolbar button turns it off.
- The recording strip has two rows (1.3.2): the dot, a timer that never
  wraps, the level meter and cancel on top; the chips below, wrapping onto
  another line at large text sizes. While recording, the mic button is the
  one control that ends it (a paper plane when it sends, a check mark when
  it goes into the message bar), and Send or the agent's Stop is dimmed and
  inactive, so a reach for "stop" can't stop the agent.
- The "after transcribing" chip on the recording strip is the setting
  (1.3.2): picking "To English" there keeps every later dictation in English
  until it is changed again, and the chip is filled while clean-up or
  translation is on. The language chip stays for one message.
- The "Hold the Camera Control to talk" pill shows for 4 seconds when the
  mode turns on or a session opens with it on, then folds into a small
  shutter badge on the mic (1.3.2). It opens in full again while the camera
  is paused or failed, with the reason.
- Every audio session activation goes through one owner (1.3.2): a
  recording that starts while the Camera Control's microphone stands by
  records from it without activating again, and a failed activation is
  retried once after a clean deactivate.
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

- Turning a Plus or Pro Max iPhone to landscape left the open session, closed
  and reopened its connection, and switched the app to the iPad's three-column
  layout (1.3.6). The iPhone now keeps its tabs in every orientation, and the
  session keeps its place, its draft, its running reply and its connection.
  Lists keep their scroll position and filter.
- Pictures a tool returned never showed (1.3.5): the drawings an agent
  rendered and read back, the screenshots it took. The transcript, the live
  stream and a reattach's snapshot all carry them (`images` on a tool
  result or tool call); each now shows right after its tool's card, and a
  live reply keeps showing them through later updates and into the
  transcript.
- A session opened while its turn ran could hide part of its history (1.3.5).
  The live turn rebuilt from the snapshot stands in for the persisted copy
  of the running reply; it now does so only while it holds every tool call
  and picture of that copy, so a trimmed snapshot, or a prompt not yet in the
  transcript, never hides a reply (the previous one included). The 50-turn
  window counts back from the running reply's prompt, so a long running
  reply no longer pushes the rest of the history out of reach, and "Show
  earlier messages" at the top loads older turns when the screen is too
  short to scroll.
- The event socket now tells the server it takes 64 MiB frames
  (`codeg-max-frame`), so the server stops shrinking frames for it (1.3.5).
  A frame an older server did shrink (`frame_cut`) makes the session reload
  its transcript instead of keeping the incomplete copy, and an image sent
  by reference (`data_ref`) loads from the server.
- "Network error: The operation couldn't be completed. Message too long" on
  send (1.3.4). The event socket kept `URLSessionWebSocketTask`'s 1 MiB frame
  limit, and codeg sends bigger frames (a background-activity update re-sends
  a whole growing turn; an attach snapshot carries a long turn's output). A
  frame over the limit killed the socket while a send was attaching, and the
  send was rolled back into the composer with that error. Both sockets now
  accept 64 MiB frames, and a socket that drops during a send's attach is
  opened again (three tries); if it still won't attach, the prompt goes
  anyway and the stream recovers once the turn runs. A dropped socket never
  fails a send.
- A prompt or a message into the running turn whose response was lost (a
  timeout, a dropped LTE connection) was reported as failed and handed back,
  even when the server had it (1.3.4). The app now asks the server first: a
  prompt counts when the stream echoed its client message id or the
  connection's snapshot runs it; a message into the turn counts when the
  snapshot lists it. Messages into the turn wait up to 90 seconds (was 30).
- Sending while a turn the screen didn't know about was running gave "A turn
  is already running" and handed the message back (1.3.4). It is queued now,
  and the screen attaches to that turn so the message goes when it ends.
- A session could show "Working" when opened while the session list said
  idle (1.3.4). Output the agent produced after its turn ended (woken by a
  background task) was read as a running turn. A turn runs only while the
  connection is prompting or a card waits, as on the list, the server and the
  codeg web client.
- A turn that ended while the event socket was down stayed "working" for
  good, with queued messages stuck behind it (1.3.4). A reconnect that finds
  no turn running now settles it and sends the queue.
- A socket that dropped before the first snapshot of a session opened while
  its turn ran left the screen unattached (1.3.4); the attach is retried.
- "Couldn't start the microphone: Session activation failed" stayed above a
  recording that worked (1.3.2). Microphone and audio errors now say what is
  wrong with Apple's code ("a call or another app is using the audio
  (!pri)"), the log records the domain and code, and a recording that starts
  fine clears the old error.
- After a call or route change interrupted a recording made from the Camera
  Control's standby, standby never restarted and later recordings heard
  nothing (1.3.2).
- The recording strip broke at larger text sizes (1.3.2): the timer wrapped,
  the level meter ran over the language chip and Send became a tall pill.
- Filled chips on the recording strip used white text, which disappeared on
  the light accent in dark mode (1.3.2).
- The queued-messages box was wider than the message bar (1.3.2); it now
  lines up with it.
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
