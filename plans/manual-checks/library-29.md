# Manual checks: Library window (#29)

Run on the packaged app (`make install`). Put a few `.md` notes in the notes
folder (default `~/Documents/Cado`; front matter optional).

- [ ] Menu bar > **Library…** (also Cmd-L in the menu) opens "Cado Library"; no Dock icon beforehand
- [ ] Dock icon appears while it's open; closing it (red button) removes the icon
- [ ] With Settings open too: close Library, Settings stays; Settings alone never shows a Dock icon
- [ ] Reopen from the menu: same window, same size/position (move + resize, quit, relaunch)
- [ ] List: newest first; each row shows title, date, kind and duration (meetings), preview line
- [ ] Click a row: Markdown renders (headings, bold, lists, quote, links); text selectable
- [ ] Up/Down arrows move the selection
- [ ] Cmd-F focuses search; typing filters by title and body; clear (x) restores; nonsense shows "No results"
- [ ] Return on a selected row renames inline; Return commits, Esc cancels; list re-sorts, note stays selected
- [ ] Rename to an existing note's title: both notes kept (file gets " 2"), no alert
- [ ] Context menu: Rename, Show in Finder, Open in Default App, Delete…
- [ ] Delete key / Delete…: confirmation says it goes to the Trash; Cancel keeps it; confirm trashes it (check the Trash) and selects the next note
- [ ] Empty folder: "No notes yet — Notes from meetings will appear here."
- [ ] While open, edit a note's text in another editor (Obsidian/TextEdit): detail updates within a second or two
- [ ] Add a file in Finder: appears in the list. Delete the selected file in Finder: selection clears with a quiet line, no crash
- [ ] Rename the selected file in Finder: list updates, selection clears (new filename = new note)
- [ ] Make the folder read-only (`chmod a-w`), try rename: quiet inline message under the list, no alert
- [ ] Change the notes folder in Settings, reopen Library: shows the new folder's notes
- [ ] Light and dark appearance both read as a stock Mac window
