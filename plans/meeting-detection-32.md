# Meeting detection (#32): decisions

## Browser-based meetings: in

Browsers (Chrome, Edge, Brave, Arc, Firefox, Safari) count as meeting apps for
"Record this meeting?". Meet, Teams on the web, Whereby and most ad-hoc calls
run in a browser, so leaving them out would miss a large share of real
meetings, which is the point of the feature. The cost is false positives: Core
Audio only says that a browser (or its audio helper) is recording from the
mic, not which tab or site, so a voice search, a web dictation tool or a mic
test also asks. That cost is small because nothing records by itself: the
question is one notification / menu-bar "Record?" / mascot badge, a few
seconds of mic use are ignored (`startDelay`), "Not Now" (or two minutes
without an answer) settles that whole stretch of mic use, and Settings ›
Meetings › Ask to record meetings turns it off. Safari's mic runs in WebKit's
shared GPU process, so another WebKit app using the mic while Safari is open
is credited to Safari (same known limitation as its audio tap). Reversible:
filtering browsers out is one check in `MicUsers.meetingApps`.

## Other defaults picked

- **Mechanism:** poll Core Audio process objects every 3 s
  (`kAudioProcessPropertyIsRunningInput`, macOS 14.4+; ~2 ms per scan of ~30
  clients, measured) and attribute helpers with `AudioProcessMatcher`.
  Polling over property listeners: whether `IsRunningInput` sends change
  notifications is undocumented, and a missed one would silently break
  detection. Below 14.4 nothing is detected; manual start still works.
- **Timing** (`MeetingDetector.Timing`): ask after 4 s of mic use; a call ends
  after 15 s without the mic (survives a mute that drops the mic); an
  unanswered "Record?" is withdrawn after 2 min.
- **Meeting hotkey ⌃⌥M:** same modifiers as the toggle (⌃⌥Space), M for
  meeting; not a macOS default nor used by Zoom/Teams/Meet/Slack; types
  nothing. Letter names are US-layout positions.
- **Mascot:** plain click keeps its dictation meaning when resting/listening;
  on the meeting mascot it stops the meeting; on the asking mascot it records.
  Right-click / Control-click starts or stops a meeting (same rules as the
  hotkey). Drag unchanged.
- **Consent reminder:** an alert (Record / Cancel) before the first recording
  from any entry point; saved only on Record (cancel shows it next time).
- **Max meeting length:** 30 min, 1, 2 (default, as before), 3, 4 h, Off; Off
  still stops at 24 h as a disk-safety backstop.
- **Hotkey with several apps or none known:** opens the avocado menu to pick;
  nothing running at all: a notification says so.
