# Manual checks: mascot overlay (#19)

Run on the packaged app (`make install`), mic + Accessibility granted. Dictate
into a text field (TextEdit, a browser, Terminal) unless the step says
otherwise. The avocado sits in the bottom-left corner of the screen under the
mouse. (Since #20 it's draggable and only its body takes clicks; placement and
click checks: [overlay-20.md](overlay-20.md).)

## Animations

- [ ] Listening: rings and body pulse with your voice; still when silent.
- [ ] Thinking: avocado wobbles while transcribing.
- [ ] Done on paste: hop + flip when text lands, then fades out.
- [ ] Done on copy (no text field focused): same celebration.
- [ ] No celebration, just a fade, on: Esc cancel, short tap, silence (empty
      result), failed transcription.
- [ ] Re-dictate right as it fades out: stays visible and goes straight to
      listening; never vanishes mid-dictation.

## Window server

- [ ] Sleep/wake: close the lid (and separately, let the display sleep), wake,
      dictate: overlay shows.
- [ ] Display sleeps and wakes mid-dictation (toggle mode, mascot on screen):
      overlay still there after wake.
- [ ] Switch Spaces mid-dictation with the mouse on another display: note
      whether the overlay jumps displays (it re-pins to the mouse's screen).
- [ ] Switch Spaces mid-dictation: overlay follows to the new Space.
- [ ] Switch Spaces between dictations, then dictate: overlay shows.
- [ ] Over a fullscreen app: overlay shows on top.
- [ ] Enter and leave fullscreen mid-dictation: overlay stays.
- [ ] Plug in / unplug a display, then dictate: overlay shows, on screen.
- [ ] Change resolution, then dictate: overlay in the corner, not off screen.
- [ ] Mouse on another display, dictate: overlay on that display.

## Look and behaviour

- [ ] Light and dark mode: art and shadow read on both.
- [ ] Reduce Motion on (System Settings › Accessibility › Display): poses
      change, no looping motion.
- [ ] Never steals focus: the text field keeps focus and the paste lands.
- [ ] Clicks pass through to whatever is under the avocado.
- [ ] Idle CPU ~0 when hidden (Activity Monitor, a minute after a dictation).
