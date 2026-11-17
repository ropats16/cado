# Manual checks: Settings tabs, menu, About, mascot menu (#45)

Packaged app (`make install`). Before/after renders: `plans/screenshots/45/`.

## Settings
- [ ] Menu > Settings…: toolbar tabs General, Dictation, Speech Model, Meetings; the current one highlights; switching is instant.
- [ ] Resize the window taller, move it, close, reopen, quit and relaunch: position and height are remembered; width can't change.
- [ ] Meetings tab: a long notes path (e.g. inside an Obsidian vault) shows on its own line, middle-truncated, full path on hover.
- [ ] Dictation > Hotkeys: button says "Change…"; clicking shows "Press the new keys (Esc to cancel)"; Esc cancels; a new chord saves.
- [ ] Pickers (Engine, Model, Microphone, Keep model loaded) show their full names.
- [ ] Light and dark; Increase Contrast; Tab key reaches every control in each tab.
- [ ] VoiceOver: tabs read as "General, tab" etc.; "Change Hold to talk hotkey" button.

## Menu
- [ ] Both permissions granted: no Microphone/Accessibility rows. Revoke one (owner step, in System Settings): its "Not granted" row appears, clickable.
- [ ] Separators group: status / meeting / hotkeys / Recent, Library / Set Up, Settings, Advanced / Updates, About / Quit.
- [ ] Advanced submenu opens the config file and the models folder.
- [ ] About Cado: version matches the DMG's; credits scroll; links open.
- [ ] With the Dock icon showing (Library open), the app menu has About Cado and Settings… (⌘,).

## Mascot
- [ ] Right-click (and Control-click) the mascot body: Hide Mascot, Settings…. Hide turns off "Always show the mascot" and the mascot disappears; Settings… opens Settings. Right-click off the body goes to the app underneath.
- [ ] VoiceOver on the mascot: "Cado mascot, button"; VO-Space starts/stops dictating; actions rotor lists Hide Mascot and Settings….
