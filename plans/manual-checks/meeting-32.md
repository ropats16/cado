# Manual checks: meeting detection, hotkey, mascot, consent, max length (#32)

What the tests can't reach: a real meeting app on the real mic (Core Audio
`IsRunningInput`), real notification buttons, the real event tap, real
right-clicks on the panel, the consent alert. Decisions:
[../meeting-detection-32.md](../meeting-detection-32.md).

Already verified without a human:
- `MeetingDetectorTests` (fake feed and time): ask after 4 s, not on a brief
  use, Not Now / timeout settle the call, a new call asks again, waits while
  dictating or busy, one ask at a time, off asks nothing, recorded calls never
  asked again, stop asked once the recorded call ends (15 s), withdrawn when
  the app is back on the mic or the recording stops; helper attribution
  (Chrome helper, FaceTime's avconferenced, never Cado).
- `MeetingAssistantTests`: the question goes to notification, menu and mascot
  together; any answer withdraws it everywhere; never records or stops by
  itself; hotkey records the asked call / the one app / opens the menu /
  explains; detection off reads nothing; notification buttons carry their
  question.
- `MascotMeetingTests`, `MascotOverlayPanelTests`: asking mascot, click
  records, click on meeting mascot stops, right-click starts/stops, plain
  click and drag unchanged.
- `MeetingToggleTests` (incl. consent once), `MeetingHotkeyTests`,
  `MeetingLimitTests`, `MeetingSessionTests` (max length read at start, Off
  stops at 24 h, the note says so), `SettingsMeetingsTests`.
- Measured here: one Core Audio scan of 32 clients takes ~2 ms (poll every 3 s).

## Setup

```sh
make package
pkill -x Cado
open dist/Cado.app
```

Owner steps first (Cado never changes these itself): Microphone and
Accessibility granted; Screen & System Audio Recording allowed when macOS
asks; Cado's notifications allowed, style **Alerts** for the button checks.
macOS 14.4 or later. Watch the log: `log stream --predicate 'process == "Cado"'`.

## Checks

1. **Consent, once.** Fresh config (or `"meetingConsentShown": false`).
   Click Record Meeting → the reminder alert. Cancel → nothing records. Press
   ⌃⌥M → it shows again; Record → recording starts. Stop; start again from
   the menu → no reminder. Quit, relaunch, start → still none.
2. **Record?** Join a Zoom (or FaceTime) call. Within ~5 s: notification
   "Record this meeting? Zoom is using the microphone." with Record / Not Now,
   the menu bar shows "Record?", the menu shows "Record Meeting (Zoom)" +
   "Not Now", and the mascot appears with a red record badge even with
   Always show the mascot off. Click **Record** on the notification → records
   Zoom; badge, "Record?" and notification go.
3. **Not now.** New call, Not Now (from the menu this time). Stay in the call
   5 min → not asked again. Mute/unmute → not asked. Leave, wait 20 s, join
   again → asked again.
4. **Mascot answers.** New call, click the badged mascot → records. Click the
   mascot while recording → stops. Right-click the resting mascot (Always
   show on) with Zoom running → starts; right-click again → stops. Drag the
   mascot in each state → it moves, nothing starts or stops.
5. **Notifications off.** Turn Cado's notifications off in System Settings.
   Join a call → still "Record?" in the menu bar, menu and mascot.
6. **Stop?** While recording a Zoom call, leave the call (or quit Zoom).
   ~15 s later: "Stop recording? Zoom stopped using the microphone…" with Stop
   Recording / Keep Recording; menu bar "12:34 Stop?". Nothing stops by
   itself. Keep Recording → asked no more; Stop Recording (another run) →
   note saved. Note whether muting in your meeting app drops the mic (it would
   ask "Stop?" after 15 s muted; Keep Recording settles it).
7. **Browser.** Open meet.google.com in Chrome (and Safari, Arc) and join a
   test call → asked about "Google Chrome" etc. A site using the mic briefly
   (< 4 s) → not asked.
8. **Dictation.** While a call is ringing in, hold ⌃⇧ and dictate for 10 s →
   no question until the dictation is done; then it asks.
9. **Hotkey.** ⌃⌥M with Zoom on a call → records Zoom (consent once). ⌃⌥M →
   stops. With Zoom and Chrome running, neither on a call → the avocado menu
   opens. Nothing running → "Meeting not started" notification. During
   "Transcribing Meeting…" → "still writing down the last meeting".
   Rebind in Settings › Hotkeys › Record meeting to ⇧⌘R → works at once;
   rebind to ⌃⇧ → the clash warning; Reset to Default → ⌃⌥M.
10. **Detection off.** Settings › Meetings › Ask to record meetings off →
    join a call: nothing asked; ⌃⌥M and the menu still work.
11. **Max length.** Hand-edit `"maxMeetingMinutes": 1`, relaunch, record →
    after 1 minute: "Meeting recording stopped — Meetings are recorded for up
    to 1 minute. You can change this in Settings › Meetings…" and a normal
    note ending "Recording stopped at the 1-minute limit." Settings shows
    "1 min (custom)". Set Off → a 3-minute recording isn't stopped.
12. **Energy.** Activity Monitor › Energy with detection on and no call for a
    few minutes: Cado's impact stays near zero.
