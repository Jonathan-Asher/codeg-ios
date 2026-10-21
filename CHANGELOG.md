# Changelog

All notable changes to Codeg for iOS are recorded here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Add changes under `## [Unreleased]` as you land them. When you cut a release,
`scripts/release.sh` moves that section under a new version heading and reuses
the text as the git tag message and the GitHub Release notes.

## [Unreleased]

### Added

- Crash reports to your own codeg server (1.3.17), with nothing sent
  anywhere else. When the app crashes, hangs, uses too much CPU or disk,
  launches slowly, or catches an audio error it would have died of, a report
  goes to every saved server: MetricKit's diagnostics (delivered on the next
  launch), the name, reason and stack of an uncaught Objective-C exception
  (written down just before the app ends and sent on the next launch), and
  each exception the new audio guard caught. A report carries the app
  version and build, the device and iOS version, the call stack, the
  binary's UUID and load address for symbolication, and the last 100 app
  events: screens opened, dictation and the microphone starting and
  stopping, Camera Control's mode, read aloud, media playing, audio route
  changes and interruptions, and network changes; never message text, file
  names, paths, URLs or tokens. They wait on the phone until a server takes
  them (at most 50, for three weeks). On by default; Settings › About ›
  "Send Crash Reports to Your Server" turns it off and drops what is
  waiting. The codeg desktop lists them in Settings › Logs › iPhone crash
  reports.

- Edit your own messages (1.3.16), as on the desktop. Long-press a message
  you sent: Copy, and Edit Message. The editor opens with the message as you
  sent it, its pictures beside it (they are sent again with the edit), and
  says what saving does: "Saving continues this conversation from here with
  the edited message, in place of the original", or, with Settings › General
  › "Keep the original as a separate conversation when editing" on, "Saving
  starts a new branch from here" (the original stays in the lists as "…
  (before edit)"). Save & send forks the session at the reply right before
  the message, loads the forked history in its place and sends the edited
  text there; the conversation continues from it. Editing the first message
  starts a new conversation with it on the same agent and folder, and Back
  returns to the original. A Hebrew or Arabic message edits right to left.
  Edit Message is greyed out with the reason while a turn runs ("Can't edit
  while a turn is running"), while messages wait in the queue, or while the
  reply before it is still being written; it is offered for Claude Code,
  Codex and DeepSeek sessions (the agents whose fork lands exactly on a
  chosen reply), and not at all against a codeg server without edit forks.
- Mark a session critical from the phone (1.3.16), as on the desktop: Mark
  as Critical and Unmark Critical in the long press on a session (Activity,
  Chats, a folder's list, Search) and in the session's ⋯ menu. A critical
  session has a red flag on its row and beside its title, and Session
  Details has the desktop's "Critical session" switches: Mark as critical,
  and, while it is, "Alert when a turn may be stuck". codeg then alerts
  when the session sits idle, as it already did for sessions marked on the
  desktop. The mark shows at once and is put back, with the reason, if the
  server refuses it. Against a codeg server without critical sessions there
  is no such item.
- Sessions open where you left them (1.3.16). Leaving a session scrolled up
  (Back, another tab, the app going to the background, even a relaunch) and
  coming back shows the same message at the same place, instead of the
  latest one. A session you left at its latest message opens there and keeps
  following new replies, and one opened from a notification or a link opens
  at its latest message. A reply that arrived meanwhile doesn't move the
  view: the button above the message bar says "New messages".

- Attach videos (1.3.14). The "+" menu's Photo Library offers videos as well
  as photos, the Camera records video, and Files takes movies. A video from
  iCloud downloads first, with its progress on the chip; one in HEVC, in
  another codec or over the codeg server's 20 MB attachment limit is
  compressed to H.264 MP4 (720p, or 540p, 480p or about 360p when it must be
  smaller to fit), then uploaded to the server with its progress, the way
  codeg web uploads a file that isn't a picture, and the message links to
  it. The message can be sent once the upload is done; a video that didn't
  upload says why on its chip and tries again on a tap. In your message the
  video shows as a card that plays from the server. A video too long to fit
  even at the smallest size says so and asks you to trim it.
- Pictures, videos and audio from a session (1.3.13). A file the agent
  links or names in a reply, one its tools wrote (Write, Edit, apply_patch)
  or a command made, and a file attached to your message show as cards under
  the message. A picture is a thumbnail that opens full screen: pinch or
  double-tap to zoom, Share, Save to Photos. A video is a poster with its
  length that plays full screen in the system player, with seeking, AirPlay
  and Picture in Picture. An audio file plays in the conversation (play,
  pause, scrub, its time and length) and keeps playing with the screen
  locked, from the lock screen's controls too. PDFs and office documents open
  in Quick Look, SVGs in a viewer. Videos stream from the codeg server as
  they play, so a seek fetches from the new point instead of downloading the
  file; pictures are fetched once and kept. A tapped link to such a file
  opens it the same way, and so do pictures already in the transcript and
  media files in a folder's Files tab. A clip pauses when read aloud or
  dictation starts, and read aloud stops when a clip plays. A file that is
  gone, refused or in a format the iPhone can't play says so on its card.
  codeg streams only video, so audio is downloaded before it plays (up to
  200 MB); against a server without streaming, a video's card says it needs
  a newer codeg server.
- Fork a session (1.3.11), as on the desktop. Every finished reply has Fork
  beside Copy and Read (and in a long press on its footer): the session
  continues from that reply in a session titled "[Fork] …", which opens with
  the original under it, so Back returns to the original. Fork Session in the
  session's ⋯ menu, and in a long press on a session in Activity, Chats, a
  folder's list or Search, forks the whole session: a duplicate that
  continues on its own. From a list the fork opens on top of the list. Between
  turns it is taken as codeg web takes it: the session moves to the fork and
  a new row keeps the original, under the original title. While a turn runs,
  a Claude Code session forks a finished reply (Fork Session: the latest)
  into a new session and the turn carries on; other agents fork only between
  turns, and the
  item is greyed out with "This agent can only fork between turns". A
  session with no agent running is resumed for the fork. The long press on a
  session also has Open, Pin or Unpin, Copy Title and Archive Folder. Against
  a codeg server without forking the replies have no Fork, and Fork Session
  is greyed out with "Needs a newer codeg server".
- Sessions with background work show as running (1.3.10). A session whose
  turn has ended while its sub-agents, background shells or monitors keep
  going now sits in Activity's "Running" section and counts in the Folders
  badges, and its row reads "Background · 2" instead of nothing. When that
  work wakes the agent and it runs a turn of its own, the row says "Working"
  until the agent is done; a turn held open only for background work reads
  as background rather than "Working". It follows codeg's new live
  background status on the session list. Against a codeg server without it
  the app behaves exactly as 1.3.9.
- Hebrew and Arabic messages read right to left (1.3.9), as on the desktop.
  Every paragraph, heading, list, list item, quote and table of a reply, and
  every run of lines of your own message, takes the direction of its own
  words: right-aligned, list markers and the quote bar on the right, and
  punctuation, parentheses and English terms inside a Hebrew sentence where
  they belong. A Hebrew sentence that opens with an English term, a path or
  a code span stays right to left; an English sentence quoting a few Hebrew
  words stays left to right. Code blocks, commands and JSON stay left to
  right. The agent's questions and their options, plan and task entries,
  and the prompts in a permission card follow their text too. English
  messages look as before.
- Archived folders (1.3.8), following codeg's new sidebar Archive. A folder
  archived on the desktop or from the phone (long-press a folder in the
  Folders tab: Archive Folder, Unarchive Folder, or the same for its desktop
  folder group) moves to an "Archived" group at the bottom of the Folders and
  Chats lists, closed until tapped, and its sessions leave Activity's "Last
  24 Hours" and "Earlier". Nothing about the sessions changes: they open
  normally, a running one stays in "Running" and still notifies, and a search
  still finds them. Against a codeg server without archiving the app behaves
  exactly as 1.3.7 and offers no Archive action.
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

- Older messages come in without moving the view (1.3.16). They are brought
  in a screen and a half before the top, as soon as the scroll comes to
  rest, and the server's older pages are fetched ahead while there are still
  messages to read; the message you are reading stays exactly where it is on
  screen while they go in above it. Pictures and
  videos keep the height they will have while they load, so one landing
  doesn't push the text either.

- A message's media takes less room (1.3.14). One picture or video shows
  inline, at most 180 points tall; several files fold into one row with tiny
  thumbnails ("3 images · 1 PDF · 1 video") that opens into a list of them:
  a picture opens full screen, a video plays, an audio file plays in the
  list, a document opens in Quick Look. Hebrew lays the row out right to
  left. A file attached to your message shows inside your message, in place
  of its link.
- The mode and every agent option can be changed while the agent works
  (1.3.7), as on the desktop: switch from Plan or Manual to Bypass
  permissions mid-turn, also while a permission card waits, or change the
  model or effort. The pick applies to the running turn at once; a change
  the server or the agent refuses goes back to what the session is on, with
  a message saying why. Only the branch stays locked while the agent
  responds. A permission card raised before the switch still needs an
  answer (the desktop does the same) and says so.
- The options sheet follows the session live (1.3.7): when the agent leaves
  plan mode after an approved plan, or the mode or model is changed on the
  desktop, the phone shows it at once.
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

- The app no longer crashes when the Camera Control's standby microphone
  starts (1.3.17). Every crash TestFlight reported from 1.3.2 to 1.3.14 was
  this one: `installTap` on the microphone raised an Objective-C exception
  (SIGABRT) right after the session was activated for standby, because the
  one audio engine the recorder kept for the app's lifetime still held the
  input formats of the route it last ran on, and read aloud, a video or
  AirPods switching profile had changed the route since. Every cold start
  of the microphone now builds a fresh engine, checks its input formats
  against each other before installing the tap, and runs every AVFAudio call
  that can raise through a guard that turns the exception into an error: the
  standby retries, and a recording shows "Couldn't start the microphone: the
  audio system refused the request, try again." instead of the app ending.

- Read aloud no longer risks the same crash when a route change stops its
  engine mid-reply (AirPods put in or taken out): it starts the engine again
  before scheduling or playing audio, keeps playing after the change, or
  stops cleanly.

- A message is never lost before the server has it (1.3.19). A send that
  fails (no network, a timeout, a server error or restart) waits at the
  front of the queue above the message bar, marked "Not sent" with the
  reason, instead of going back into the message bar, where it was lost when
  another message was already being written. It goes again by itself once
  the server answers, under the same client id, so a send whose answer was
  lost is not delivered twice (the codeg server answers the repeat as a
  duplicate). The queue and the messages on their way are kept on disk per
  server and conversation: closing the screen, a killed app or a restart
  brings them back when the session opens again. A message the server
  refuses waits for Send now. Inserts into a running turn are kept the same
  way.

- The transcript jumped (1.3.16). Each page of older messages pushed the
  view down by its own height, so the message being read went off screen and
  more pages followed, and opening a session, coming back to it (also from
  another tab or from a fork opened over it), the app returning to the
  foreground and a reconnect to a running turn all scrolled to the latest
  message, even for someone reading higher up.

- Media cards for files that were never there (1.3.14). A reply whose
  commands worked in another folder showed a column of cards that said "The
  file is no longer there", some for names that aren't files at all
  (`f.png`, `-short.png`, `l.pdf`). Names were taken from the commands'
  own code (Python f-strings, `$f.png` in a shell loop, sed expressions,
  dictionary keys) and bare names were looked for in the session's folder
  instead of the folder the command had moved to. Now a card shows only for
  a file the agent wrote (Write, Edit, apply_patch), linked, named in full
  (`/…` or `~/…`) or that a tool printed it saved; a relative name is
  resolved only against the `cd` its own command starts with. Before a card
  shows, the server is asked whether the file is there (one listing per
  folder) and a file that isn't doesn't show; only a file the reply itself
  wrote and that has since been deleted is listed, as deleted.
- A message sent into a running turn stayed above the message bar (1.3.12).
  One delivered into a turn held open for background work, or with "Insert
  into current turn", sat in a strip there until the turn ended, while the
  agent's answer to it streamed into the conversation above it. A Camera
  Control recording is sent the way Send sends, so one made while background
  work held the turn ended up there too. Once the agent has the message, it is
  now in the conversation, inside the reply where the agent took it, marked
  "Sent during the turn", with the answer after it, as on the desktop; when the
  turn ends the server's copy takes its place, so it shows once. Only a
  message still on its way, or one waiting for an agent that reads its notes
  through its feedback tool, stays above the bar. A message sent into the turn
  from the desktop shows too, and a reconnect or a return to the app keeps
  each message where it was.
- Coming back to the app after a reply that failed or was cancelled could
  show your message twice (1.3.12): the reply was dropped but its message
  stayed beside the server's copy. Both are now kept until the server's copy
  replaces them.
- A mode or option change that failed during a turn (from the phone or the
  desktop) ended the reply on the phone as an error (1.3.7). Such errors
  (`set_mode_failed`, `set_config_option_failed` and the other per-action
  ones) are now a notice and the turn goes on, as on the web client.
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
