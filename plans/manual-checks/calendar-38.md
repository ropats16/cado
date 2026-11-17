# Manual checks: meeting titles from the calendar (#38)

What the tests can't reach: the real macOS Calendar prompt, EventKit, a
release build's entitlement. Nothing here was run by the agent that built it:
it never triggered the prompt or read the real calendar.

Already verified without a human (fake calendar, `CalendarNamingTests`):
matching rules and tie-breaks (in progress, starts within 5 min, all-day /
declined / cancelled / untitled ignored, attendees or video link first, closest
start, shorter, earlier, title); names only (no emails, no you, capped); the gate
(off, denied, not asked, restricted: no read, no prompt); note title, `event`
and `attendees` front matter (absent when none), safe file name and ` 2` on a
clash; `meeting.json` keeps the event for a recovered meeting and an older
file without it still opens; Settings switch (never asks on creation, asks on
turn-on, denied stays off with the how-to, revoked shows off); onboarding step
states; plain wording.

## Owner steps (need a real Mac and your calendar)

Use a dev build from `make package` (not `make install` over your real copy if
you want to keep its grants), signed so the prompt can show. First reset only
if you want to see the prompt again: that is a System Settings action for you
to do yourself (Privacy & Security › Calendars, remove Cado).

1. **Not asked at launch:** launch Cado fresh; open Settings › Meetings. No
   calendar prompt appeared. The Calendar card says what turning it on does.
2. **Turn on, allow:** switch on **Name meetings from my calendar**. macOS asks
   to let Cado access your calendar (text: "Cado reads your calendar to name a
   meeting note…"). Choose **Allow Full Access**. The switch stays on.
3. **Matching:** make a calendar event now-ish (start within 5 minutes or already
   running) with a guest, then **Record Meeting** for a few seconds of
   speech and stop. The note is named after the event; the Library row shows
   the event title; the file in the notes folder is `yyyy-MM-dd <title>.md`;
   its front matter has `event:` and `attendees:` with names (no emails).
4. **Edge cases:** an all-day event and a declined one are not used; two
   overlapping events pick the one with guests / a Zoom or Meet link; a title with
   `/` or `:` makes a sane file name; no event gives "Meeting with Zoom — date
   time" as before.
5. **Crash recovery:** start a meeting during an event, speak, Force Quit
   Cado, reopen. The recovered note has the event's title.
6. **Turn off:** switch off; the next meeting is named app and time. Old notes
   keep their titles.
7. **Denied:** in System Settings › Privacy & Security › Calendars turn Cado off
   (or choose Don't Allow at the prompt). Settings shows the switch off with
   the words on how to allow it and an **Open System Settings** button that
   opens that pane. After you allow it there and come back, switching it on
   works without a new prompt.
8. **Onboarding:** reopen onboarding from the menu; the optional Calendar step
   follows Notifications; **Use My Calendar** asks (once) and turns the
   setting on; the step never blocks Ready.
9. **Release build (Hardened Runtime):** a notarized build (`make release`) shows
   the prompt in step 2. If it doesn't, check the app is signed with
   `Resources/Cado.entitlements` (`codesign -d --entitlements - Cado.app` lists
   `com.apple.security.personal-information.calendars`).
10. **Privacy:** with Little Snitch or `nettop`, confirm no network traffic
    appears when a calendar-named meeting starts; summaries (if on) get the
    transcript only, not the event title or names.

Not decided for you (conservative defaults used): attendee **names are
written to the note** (no emails); the user is left out; max 20 names;
matching happens when the meeting starts, not when the note is written.
