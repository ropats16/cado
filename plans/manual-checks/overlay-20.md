# Manual checks: draggable mascot + always-visible mini mode (#20)

Run on the packaged app (`make install`), mic + Accessibility granted. Dictate
into a text field (TextEdit, a browser, Terminal) unless the step says
otherwise. Settings › Mascot has the two toggles; positions live in
`config.json` under `mascotPositions`.

Display rule: the mascot picks a display only when it comes on screen from
hidden (the one under the mouse, at that display's saved spot). While on
screen (resting or active) it stays on its display; a Space switch, wake or
display change puts it back at that display's spot, re-clamped. So with
"always visible" on, a dictation started anywhere plays on the display where
the mascot rests.

## Drag

- [ ] Drag while resting (always visible on): follows the mouse, stays where dropped.
- [ ] Drag while listening (toggle mode, keep talking): follows, dictation
      continues, text still pastes into the field.
- [ ] Drag while thinking: follows; done/fade still play where it was dropped.
- [ ] A tiny jiggle (< ~4 pt) while clicking counts as a click, not a drag.
- [ ] Drag past each screen edge (and under the menu bar / onto the Dock):
      snaps back fully inside the visible area.
- [ ] Position restored after quitting and relaunching Cado (resting at
      launch with always visible on; else on the next dictation).
- [ ] Two displays: drag to a different spot on each; dictate with the mouse
      on each (always visible off): each shows at its own spot.
- [ ] Drag from one display onto the other: saved on the destination.
- [ ] Unplug the display the mascot is on (resting), then replug: it moves
      onto the remaining display at its spot, and back to its own spot on the
      next show from hidden after replug.
- [ ] Move the Dock (left / bottom / right) and resize it: mascot stays
      inside the visible area (after the next show or a Space switch).
- [ ] Change resolution: mascot clamped on screen, not off it.

## Click

- [ ] Always visible on: click the resting mascot: dictation starts (listening).
- [ ] Click the listening mascot: dictation stops, text pastes.
- [ ] Click during thinking: ignored (no new dictation, no cancel).
- [ ] Click during the done celebration / fade-out: ignored.
- [ ] Clicks on the transparent margin round the avocado (halo, the empty
      space above/right of the mini one) reach the app underneath: click a
      button, a text field, a Finder icon placed just next to the body.
- [ ] Hovering the margin doesn't block scrolling or the app's own hover.
- [ ] Focus never stolen: with a text field focused, drag the mascot, then
      click it to start, speak, click to stop: text pastes into that field,
      Cado never becomes the active app (menu bar keeps the other app's name).
- [ ] Same with the app underneath fullscreen.

## Always visible

- [ ] Default (fresh config): nothing on screen while idle.
- [ ] Settings › Mascot › **Always show Cado** on: resting mini mascot appears at once.
- [ ] Toggle off: it fades out at once; still shows while dictating.
- [ ] Resting idle CPU ~0 (Activity Monitor, a minute idle, mouse still).
      With the mouse moving, Cado stays low (it watches pointer moves).
- [ ] Resting through Spaces switches, entering/leaving a fullscreen app,
      Mission Control, sleep/wake (lid and display sleep): still there, same
      spot, still clickable and draggable.

## Screen shares

- [ ] Default: mascot absent from a QuickTime screen recording, a Zoom /
      Meet / FaceTime screen share, and a screenshot (⌘⇧3, ⌘⇧5) — while
      resting and while listening.
- [ ] Settings › Mascot › **Show Cado in screen shares** on: present in all of the
      above, applied live (no relaunch).
- [ ] Toggle back off mid-share: disappears from the share.
- [ ] Note per capture tool if it still shows the mascot with the setting
      off: exclusion is `NSWindow.sharingType = .none`, which macOS 15+
      ScreenCaptureKit-based capture is reported to not always honour.
