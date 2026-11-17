# Cado

Local, private, system-wide voice dictation for macOS. Hold a hotkey, speak,
and your words are transcribed **entirely on your Mac** with
[whisper.cpp](https://github.com/ggml-org/whisper.cpp) (GPU-accelerated) and
typed into whatever text field you're in — any browser, any app, the Terminal,
and the Claude Code CLI. No audio or text is ever sent to the internet; the
only network use is downloading models and a daily update check you can turn
off (see [Privacy](#privacy)).

> **Website:** <https://ropats16.github.io/cado/>
>
> **Install:** download the latest `Cado-<version>.dmg` from
> [Releases](https://github.com/ropats16/cado/releases/latest), open it and
> drag Cado to Applications. Or with Homebrew:
> `brew install --cask ropats16/tap/cado`
> (if Homebrew says the tap is untrusted, run `brew trust ropats16/tap` first).
>
> Requires macOS 14 or later (meeting notes need 14.2). You can also build it
> yourself (steps below). Models (whisper.cpp, WhisperKit, Parakeet) download
> from Settings › Speech Model (only when you click Download).

---

## What it does

- **Hold-to-talk:** hold **Control + Shift**, speak, release — your words appear
  at the cursor.
- **Toggle mode:** press **⌃⌥Space** to start, press again to stop — for longer
  dictation without holding a key. Press **Esc** while recording to cancel.
- **Cado on screen** while it works (bottom-left corner until you drag it
  elsewhere): the avocado pulses with your voice while it listens, wobbles
  while it transcribes and hops when your text lands, then gets out of the
  way. Drag it anywhere, even mid-dictation; each display remembers its own
  spot. It never takes focus, clicks next to it pass straight through, and
  it's hidden from screen shares and recordings (Settings › Dictation can show
  it).
- **Always-visible option** (Settings › Dictation › Always show the mascot, off by
  default): a small resting Cado stays on screen; click it to start
  dictating, click again to stop. Right-click it for **Hide Mascot** and **Settings…**.
- **Works everywhere** by pasting (and restoring your clipboard afterward), so it
  works in browsers, native apps, terminals, and CLIs alike.
- **Notifies you** on errors (mic unavailable, model missing, transcription
  failure) and when no text field is focused, instead of failing silently.
- **Menu-bar only** — a small avocado icon, no Dock icon, stays out of your way.
- **Meeting notes** (macOS 14.2+): **Record Meeting** in the avocado menu
  records you (the mic, "Me") and the meeting app (Zoom, Teams, Meet in a
  browser…, "Others") until you click **Stop Recording**, then writes a Markdown
  note with the conversation as Me/Others turns to your notes folder. See
  [Meeting notes](#meeting-notes).
- **Meeting summaries** (macOS 26 with Apple Intelligence): each meeting note
  gets a summary (key points, decisions, action items) written on your Mac.
  See [Summaries](#summaries).
- **100% private.** It only uses the internet to download models: the
  one-time setup download, and Settings › Speech Model's **Download** button, which
  fetches pinned files from `huggingface.co` only when you click it — plus a
  once-a-day update check on GitHub (Settings › General turns it off).

---

## Will it run on my Mac?

- **Apple Silicon Mac (M1, M2, M3, M4 — any model from 2020 on):** ✅ ideal.
  Metal (GPU) accelerated; the default model transcribes a sentence in about a
  second.
- **Intel Mac:** ✅ supported. Runs CPU-only (no Metal), so it's slower — the
  app automatically picks a smaller model to keep it responsive.
- **8 GB Macs (e.g. M1 8 GB):** ✅ first-class — they get a light quantized
  model, and the model is unloaded when idle to give the RAM back.
- **macOS 14 (Sonoma) or newer** required.
- **~1 GB free disk** for the default model.

**The app picks a model for your chip + RAM by itself** (and setup downloads
that one) — no input needed. You can still pick another in **Settings** (it
switches instantly, no restart) or with `make setup MODEL=…`. What it picks:

| Your Mac      | RAM      | Auto-picked model | Download |
|---------------|----------|-------------------|----------|
| Apple Silicon | ≥ 32 GB  | `medium.en-q8_0`  | 823 MB   |
| Apple Silicon | 16–31 GB | `medium.en-q5_0`  | 539 MB   |
| Apple Silicon | 8–15 GB  | `small.en-q5_1`   | 190 MB   |
| Apple Silicon | < 8 GB   | `base.en-q5_1`    | 60 MB    |
| Intel         | ≥ 16 GB  | `small.en-q5_1`   | 190 MB   |
| Intel         | 8–15 GB  | `base.en-q5_1`    | 60 MB    |
| Intel         | < 8 GB   | `tiny.en-q5_1`    | 32 MB    |

If you set a non-English `language`, it picks the multilingual model of the
same size (e.g. `small-q5_1`). If the picked model isn't downloaded, the app
uses the best one you do have.

<details>
<summary>All models (you can change the model later)</summary>

Every model comes in **English-only** (`.en`) and **multilingual** (no `.en`)
versions, each also **quantized** (`-q5_*` smallest, `-q8_0` near-lossless) —
quantized models use about half the RAM for almost the same accuracy.

| Family           | Full     | q8_0    | q5      | When to use                                 |
|------------------|----------|---------|---------|---------------------------------------------|
| `tiny`           | 78 MB    | 44 MB   | 32 MB   | Fastest, least accurate. Good for testing.  |
| `base`           | 148 MB   | 82 MB   | 60 MB   | Light, low-RAM Macs.                         |
| `small`          | 488 MB   | 264 MB  | 190 MB  | Good balance; the 8 GB default.              |
| `medium`         | 1.5 GB   | 823 MB  | 539 MB  | Most accurate English; the 16 GB+ default.   |
| `large-v3-turbo` | 1.6 GB   | 874 MB  | 574 MB  | Multilingual only; best for other languages. |

Ids look like `small.en-q5_1`, `medium-q8_0`, `large-v3-turbo-q5_0` (medium and
large use `q5_0`, the rest `q5_1`); `large-v3-q5_0` is also available. The full
list with pinned SHA-256 checksums is in `scripts/model_catalog.sh`. On an
Apple-Silicon Mac, every model runs faster than real time.
</details>

---

## Setup (start to finish)

You'll run a few commands in **Terminal** (open it from Spotlight: press ⌘-Space,
type "Terminal", hit Return). Copy-paste each block.

### 1. Install the build tools (one time)

```sh
xcode-select --install
```

A dialog appears — click **Install** and wait for it to finish (a few minutes).
If it says the tools are already installed, you're good.

### 2. Get the code

```sh
git clone https://github.com/ropats16/cado.git cado
cd cado
```

(Every command after this is run from inside the `cado` folder.)

### 3. Build it and download the speech model

```sh
make setup
```

This fetches the speech engine, then **auto-detects your chip + RAM and
downloads the matching model** (see the table above — on a 16 GB Apple Silicon
Mac that's `medium.en-q5_0`, **~540 MB**), checks its SHA-256, and finally
builds and packages the app. Let it finish.

> Want a specific model instead of the auto-pick? Pass `MODEL=`, e.g.
> `make setup MODEL=small.en-q5_1` (or `medium.en`, `small` for multilingual, …).

### 4. Install the app

```sh
make install
```

This copies **Cado.app** to your Applications folder and opens it. Look for
a small **avocado icon in your menu bar** (top-right of the screen). Click
it to see the app's status and controls.

### 5. Grant the two permissions

**First launch:** Cado opens a short setup window that walks you through both
permissions, offers the speech model recommended for your Mac (download with
progress, Cancel and Retry; checksum-verified before use — optional if
`make setup` already installed one) and shows how to dictate. It updates by itself as you grant things in System Settings. Close
it any time; it opens again at the next launch until you press **Done** (or
**Finish Later**), and **Set Up Cado…** in the avocado menu reopens it. The steps below are the same
thing by hand.

Cado needs two macOS permissions. Click the avocado menu-bar icon to see which
still need granting; each one still missing is listed there. When neither is
listed, both are granted and dictation works.

1. **Microphone** — so it can hear you. The first time you dictate, macOS asks
   for permission; click **Allow**.
2. **Accessibility** — so the hotkey works and it can type into other apps. Open
   **System Settings → Privacy & Security → Accessibility**, find **Cado**
   in the list, and turn its switch **on**. (The menu's "Accessibility: Not
   granted" line opens this screen for you.)

Each permission's line leaves the menu once it's granted; when both are gone, the menu status changes to **Ready**. 🎉

A third permission, **Screen & System Audio Recording**, is only for
[meeting notes](#meeting-notes): macOS asks for it the first time you click
**Record Meeting**. Dictation never needs it.

> ⚠️ **If you just granted Accessibility but it still says "Not granted,"** see
> [Troubleshooting](#troubleshooting) below — there's a quick one-time reset.

### 6. Dictate!

Put your cursor in any text field, **hold Control + Shift**, speak a sentence,
then **release**. After a moment your words appear, with punctuation and
capitalization. Try it in Notes, Chrome, Slack, or the Terminal.

---

## Upgrading from VoiceType

Cado was called VoiceType. If you had VoiceType installed, quit it first
(`pkill -x VoiceType`), then:

- **Your settings and models move over by themselves.** On first launch Cado
  moves `~/Library/Application Support/VoiceType/` to `…/Cado/` (config and
  models, no re-download), unless the Cado folder already has data or
  `CADO_APP_SUPPORT` is set. Until that first launch, `make setup` skips the
  model download and the `make model` family refuses to run, so nothing lands
  in the Cado folder and blocks the move. If you used `VOICETYPE_APP_SUPPORT`,
  set `CADO_APP_SUPPORT` instead.
- **Grant the permissions again, once.** The bundle ID changed, so macOS treats
  Cado as a new app: grant Microphone and Accessibility as in
  [step 5](#5-grant-the-two-permissions). Remove the stale **VoiceType** entry
  from **System Settings → Privacy & Security → Accessibility** (the **–**
  button), or reset both old grants:

  ```sh
  tccutil reset Accessibility com.local.VoiceType
  tccutil reset Microphone com.local.VoiceType
  ```

- **Launch at login** doesn't carry over: if you used it, turn on **Launch Cado
  at login** in Settings again.
- **Clean up the old app** — delete it; optionally remove its old signing
  keychain:

  ```sh
  rm -rf /Applications/VoiceType.app
  security delete-keychain ~/Library/Keychains/voicetype-signing.keychain-db
  ```

---

## Using Cado day to day

- **Hold Control + Shift** to record; **release** to transcribe and insert.
- Or **toggle**: press **⌃⌥Space** once to start, press again to stop — handy for
  longer passages where you don't want to hold a key down.
- **Press Esc while recording to cancel** — nothing is transcribed or inserted.
- Recording **auto-stops** after the max dictation length (Settings; default
  10 min, or "No limit", which still stops at 30 min) so a forgotten recording
  can't run forever. A notification tells you when that happens.
- The avocado shows **listening → transcribing → done**. Drag it where you
  like (it remembers the spot per display). With **Always show the mascot** on,
  click the small resting one to start, click again to stop.
- Your existing clipboard is restored after each dictation, so dictating never
  overwrites something you copied. (A password-manager copy isn't put back, so
  its auto-clear still holds — the dictation stays on the clipboard instead.)
- **Set Up Cado…** in the avocado menu reopens the setup window, on the first
  step that still needs you (a permission revoked, a model missing).
- Quit anytime from the avocado menu (**Quit Cado**).

### Recent dictations

Lost a dictation, or want it somewhere else too? Cado can keep your last 10 so
you can copy one again. It's off by default.

- Turn it on in **Settings → Dictation → Keep recent dictations**.
- **Recent Dictations** then appears in the avocado menu. Click one to copy it.
- Only the last 10 are kept, in a small file in Cado's own support folder on
  your Mac. Turn the setting off and they're deleted.

Everyday dictations are never written to your notes folder.

### Notes folder

**Settings → Meetings** also picks a notes folder (default `~/Documents/Cado`).
Meeting notes are saved there as plain Markdown, so you can point it at an
Obsidian vault. **Library…** in the menu lists and opens them.

### Meeting notes

Needs macOS 14.2 or later (on older macOS, **Record Meeting** is greyed out
and says why).

- **Start:** click **Record Meeting** in the avocado menu. Cado records only
  the meeting app's audio as "Others" — never everything your Mac plays — plus
  your microphone as "Me". One meeting app running (Zoom, Teams, Slack,
  Webex, Discord, FaceTime, or a browser for Meet): it's picked for you and
  named in the menu. Several (e.g. Zoom and Chrome): pick one from the
  submenu. None: the submenu says so and lists the other apps playing audio.
- **While recording:** the menu-bar avocado gets a record dot and the elapsed
  time, the menu shows **Stop Recording — 12:34** and which app is recorded,
  and the mascot stays on screen. Dictation is off until you stop (a hotkey
  press says so).
- **Transcribed as you go:** while you talk, Cado transcribes the meeting on
  your Mac in short passages (a few seconds of speech each, cut at pauses), so
  most of it is done by the time you stop. Dictation and meetings share one
  transcription queue, one passage at a time (unless meetings use a model of
  their own, see **Language** below).
- **Language:** **Settings → Meetings → Meeting Language** is **Same as
  dictation** by default, so meetings use the dictation model and language,
  exactly as before. For meetings that mix languages (say Hindi and English),
  choose **Auto-detect**: Cado detects the language of each passage on its own
  and writes it in its own script (Hindi in Devanagari with the `small` model or
  larger, English in Latin letters; nothing is translated or romanised). Or
  choose one language. Meetings use the dictation model when it can do that.
  When it can't (an English-only `.en` model, or an engine that doesn't know
  the language), they get a model of their own: first what Automatic would
  pick for that language (Turbo for the European languages it supports, Apple
  Speech where it supports the language, or the model you named for an
  engine), else a multilingual Whisper model (Whisper's Automatic pick for
  your Mac among the models you've downloaded). It's loaded only while
  a meeting is transcribed (the first passage waits a second or so for it) and
  let go two minutes after the last one, whatever **Keep model loaded** says
  (that setting is the dictation model's), so dictation keeps its own model and
  speed. While both are loaded a meeting takes more memory: roughly 0.7 GB
  with `small` (the whole benchmark process peaked near 0.7 GB with only
  `small` loaded; the increase itself wasn't measured). If no multilingual model is downloaded, the card
  says so with a **Download** button, and meetings use the dictation model
  meanwhile, and the note says so. A meeting keeps the language it started
  with, also when it's recovered after a crash. Limits: a sentence that
  switches language midway comes out in one language (passages are cut at
  pauses, so people taking turns are fine); under Auto-detect a very short
  reply can still be written in the wrong language or script; smaller models
  are weaker at Hindi (`base` may write it in Urdu script; `small` is
  readable; larger ones are much better, see `plans/meeting-languages-47.md`).
- **Stop:** click **Stop Recording**. Only the last passage or two (what was
  being said as you stopped) is left to transcribe, so on a Mac that keeps up
  the note is ready shortly after, however long the meeting was. A Mac that
  can't keep up (a big model on an older Mac) finishes the rest after you stop;
  the menu shows "Transcribing Meeting… n of m". Cado saves "Meeting with Zoom
  — date time" to your notes folder, with the date, the length and the
  Me/Others conversation. A notification says when it's saved.
- **First time:** macOS asks to let Cado record system audio. If you don't
  allow it (or it was turned off), the other side records as silence: the
  note says Others may be missing and how to turn it on (System Settings ›
  Privacy & Security › Screen & System Audio Recording).
- **The audio and the transcript so far:** while a meeting records, its audio
  and the transcript so far are written to a private folder in Cado's support
  folder (`~/Library/Application Support/Cado/Meetings In Progress`), readable
  only by your user account and left out of Time Machine backups. The audio is
  about 230 MB per hour for each side. The folder is deleted once the note is
  safely saved. If the note can't be saved (for example the notes folder is
  unavailable or the disk is full), Cado first tries to keep the audio in the
  `Meeting Audio` folder. If that fails too, the recording stays in this folder
  and Cado finishes the note the next time it starts, and tells you once. A
  recording on disk is never deleted before its note is saved. The note then
  says: "This note couldn't be saved when the meeting ended; it was finished the
  next time Cado started." Two copies of Cado on one Mac never touch each
  other's meetings.
- **Keep meeting audio:** off by default, the meeting's audio is deleted once
  the note is saved. To keep it, turn on **Settings → Meetings → Keep meeting
  audio**: each meeting's audio is then kept as `Me.wav` and `Others.wav`
  (about 115 MB per hour each, even for a meeting where no speech was heard) in
  `~/Library/Application Support/Cado/Meeting Audio/<note title>/`. Whatever the
  setting, the audio is kept there when part of the meeting couldn't be
  transcribed; the note says where.
- **If you quit Cado mid-meeting**, nothing is lost: the recording is kept
  safely on disk. The next time Cado starts, it finishes transcribing and saves
  the complete note, which says: "Cado was quit during this meeting; the note
  was finished the next time Cado started."
- **If Cado crashes or is force-quit** (a crash, Force Quit, the Mac losing
  power) during a meeting, the meeting isn't lost: the next time Cado starts
  and its speech model is ready, it finishes the note from what was recorded
  and saves it with a line saying Cado quit unexpectedly and the note was
  recovered, then a notification. Up to about a second of audio right before
  the crash can be lost (a few more seconds after a power cut). Meetings with
  no speech are just deleted. If Cado can't recover a meeting after trying on
  two launches, it stops trying: it saves a note with what was transcribed
  before and keeps the audio in the `Meeting Audio` folder. If even that fails,
  the untouched recording is moved to the `Meeting Audio` folder and Cado says
  where it is ("Couldn't finish a meeting"). It is never deleted. While a
  recovery runs, the menu shows **Recovering Meeting…** with its progress, and
  **Record Meeting** is unavailable until it's done.
- **Limits:** a meeting stops by itself after 2 hours (the note is still
  written). If the disk fills up mid-meeting, Cado says "Meeting audio isn't
  being saved to disk" and recording goes on. From then on the audio is held in
  memory until the note is written at the end. If Cado quits unexpectedly
  before the note is saved, the part held in memory can't be recovered; only
  the part already on disk can. Without headphones the mic also hears the other
  side, so their words can appear under "Me" too. Notes saved before this
  label changed say "Them"; they still open and show "Others" (the files
  aren't changed).
- **Summaries:** see [Summaries](#summaries) below.
- **Safari:** Safari plays web audio through WebKit's shared media process,
  which every WebKit-based app uses (Mail, and apps with web views) and which
  macOS gives no public way to tell apart. So with Safari as the meeting app,
  "Others" can also pick up sound those apps play during the meeting. Every
  other app is recorded on its own (Chrome never includes Chrome Canary, Edge
  never Edge Beta); for a clean "Others", use a meeting app or another browser.

### Summaries

Needs macOS 26 or later with Apple Intelligence turned on (System Settings ›
Apple Intelligence & Siri). Elsewhere, Settings › Meetings says why
and nothing changes.

- **After a meeting:** once its note is saved, Cado asks Apple Intelligence's
  on-device model for a summary and adds it to the note: a **Summary** section
  with **Key points**, **Decisions** and **Action items**, between the note's
  opening lines and the transcript (which then gets a **Transcript** heading).
  It runs on your Mac; nothing is sent anywhere. The note is saved first and
  is complete without a summary: summarizing never delays or risks it, and if
  Cado quits or the summary fails, the note just has no summary.
- **Long meetings:** the on-device model reads only a few pages at a time, so
  Cado summarizes a long transcript in parts (cut between turns) and then
  combines them. A part the model declines (it can refuse some topics) is left
  out, and the summary says part of the meeting couldn't be summarized.
- **Summarize again:** in the Library, a meeting note's summary card has
  **Regenerate Summary** (or **Summarize** for a note without one, such as one
  saved before summaries or with them off). The new summary replaces the old
  one in place; the rest of the note, including anything you added, is kept.
- **Turn off:** Settings › Meetings › **Summarize meetings** (on by
  default). Existing summaries stay; you can still summarize a note from the
  Library. Automatic summaries skip very short meetings (under about 40
  words). If you edit the transcript while a summary is being written, Cado
  keeps your edit and doesn't write it.
- **In other Markdown apps:** the section sits between two hidden comments
  (`<!-- cado:summary -->` … `<!-- /cado:summary -->`) that Obsidian and other
  Markdown apps don't show; they let Cado find and replace it. Edit inside them
  and a regenerate replaces your edits; outside them, edits are kept.
- **Summaries can be wrong.** They come from a small model reading a speech
  transcript; the note says so under each summary, and the transcript below
  is what was said.

---

## Changing the model or hotkey

Settings live in a plain text file you can open from the menu
(**Advanced › Open Config File…**) or at:

```
~/Library/Application Support/Cado/config.json
```

**Speech engine.** By default (**Automatic** in Settings, `"engine": "auto"`)
Cado picks the engine from what's already downloaded — it never downloads
anything by itself:

| Mac / language | Engine |
|---|---|
| Apple Silicon, a Turbo language (English + 24 EU languages), Turbo's model downloaded (Settings › Speech Model › Download, or `make parakeet-model`) | **Turbo** (Parakeet) |
| Apple Silicon, macOS 26, no Turbo for it (not downloaded, or a language like Japanese, Chinese, Korean), Apple Speech takes the language and its model is downloaded | **Apple Speech** |
| Auto-detect language, Intel, or anything else (incl. a model that fails to load) | **Whisper** (whisper.cpp), with its own Automatic model for your RAM |

Settings' Automatic row names the engine it picked and why it isn't Turbo
(e.g. "Automatic (Whisper — Turbo isn't downloaded)"). Pick an engine there (or
set `engine`) to override it. Why these defaults: [`plans/bench-results/15`](plans/bench-results/15/README.md).

**Switch to a different model.** By default the app picks one for your chip +
RAM (**Automatic** in Settings). To use another, download it (Settings → Speech Model
→ **Download a model**, or the command below), then pick it in
**Settings → Speech Model** — it switches right away, no restart (a dictation already
being transcribed finishes on the old model):

```sh
make model MODEL=small.en-q8_0   # downloads it and checks its checksum
```

Or set `"model": "small.en-q8_0"` in `config.json`. Models you haven't
downloaded show under **Not downloaded** in Settings with the command to fetch
them, and each has a **Download** button. Either way, downloads land in a
`.part` file (one can resume the other's) and only get their real name once
complete and checksum-verified. A file that doesn't match its published SHA-256
is refused; the first use of a new file shows **Verifying…** while it's hashed
(once — the result is cached). If a switch fails, Cado keeps (or goes back
to) the model it was using and Settings says why.

**Language.** English-only (`.en`) models always transcribe English: if the
language set isn't English, Settings › Speech Model says so under Language,
with the fix (choose a model without ".en" in its name). With a multilingual
model, pick the language in Settings (or `"language": "de"`, or `"auto"` to
detect it each time). Meetings have their own language setting (see
**Meeting notes › Language**).

**Keep model loaded.** Automatic by default: kept loaded, except on Macs with
8 GB or less, where the model is unloaded after `modelIdleMinutes` (default 5)
without a dictation and reloaded as soon as you start the next recording (it is
never unloaded mid-recording). Settings offers Automatic / Keep loaded /
Unload when idle.

> Curious what the app would auto-pick for this Mac? Run
> `scripts/detect_hardware.sh` — it reports the detected arch, RAM, and the
> model (diagnostic only; it changes nothing). The app logs its pick at launch.

**Where models live.** `~/Library/Application Support/Cado/models/`. To
relocate everything (config, models), set `CADO_APP_SUPPORT` to another
folder — the app (when launched from that shell, e.g. `swift run`) and every
script honour it the same way, using `$CADO_APP_SUPPORT/models`.

**Change the hotkey.** The `hold` setting is the trigger. The default is a
pure-modifier combo (it types no character anywhere):

```json
"hold": { "keyCode": -1, "modifiers": ["control", "shift"] }
```

Other good no-character options (edit the `modifiers` list):
- `["control", "option"]` → ⌃⌥
- `["command", "shift"]` → ⌘⇧
- `["function", "shift"]` → fn+Shift *(note: the Globe/fn key is ignored on some Macs)*
- A single key: `{ "keyCode": 61, "modifiers": [] }` → hold **Right Option**

Modifier names are case-insensitive and accept aliases: `control`/`ctrl`,
`option`/`alt`, `shift`, `command`/`cmd`, `function`/`fn`/`globe`. Single-key
holds work with the sided modifiers: Left/Right ⌃ (59/62), ⌥ (58/61), ⇧ (56/60),
⌘ (55/54). Easiest of all: Settings → Dictation → Hotkeys → Change….

**Change the toggle key.** `toggle` is the press-to-start / press-to-stop hotkey.
Unlike `hold`, it fires on a single press, so it usually pairs a normal key with
modifiers. The default is ⌃⌥Space:

```json
"toggle": { "keyCode": 49, "modifiers": ["control", "option"] }
```

(`keyCode` 49 is Space.) Pick modifiers that aren't a normal typing combo so the
keypress isn't inserted into your text.

**Cancel key.** `cancelKeyCode` is the key that aborts an in-progress recording
(default `53` = Esc).

After editing, relaunch Cado (quit from the menu, reopen from Applications).
If a binding is empty, unmatchable, or `hold` and `toggle` collide, Cado
logs the problem at startup and the menu shows a **Config issue** warning.

| Setting               | What it does                                        |
|-----------------------|-----------------------------------------------------|
| `engine`              | Speech engine: `auto` (default, also when the key is missing — unless an older config hand-set a whisper `model`/`modelPath`, which stays on `whisper`: Turbo, else Apple Speech, else whisper, among engines already downloaded — see **Speech engine** above); `whisper` (whisper.cpp, any Mac, the fallback); `whisperkit` (Core ML, Apple Silicon; models via Settings › Speech Model › Download, or `make whisperkit-model WHISPERKIT=<id>`); `parakeet` ("Turbo": Apple Silicon, English + 24 EU languages, picked explicitly, not under auto-detect; model via Settings › Speech Model › Download, or `make parakeet-model`). A Core ML model's first load on a Mac (and after a macOS update) compiles it: "Preparing the speech model for this Mac" meanwhile; `apple-speech` (macOS 26; models managed by macOS, downloaded from Settings). If it can't run on this Mac or in the chosen language, Cado uses whisper and says why (the setting is kept). |
| `model`               | whisper's model: `auto` (default: pick for this Mac) or a model id, e.g. `small.en-q5_1`. |
| `modelPath`           | A specific whisper model `.bin` file; overrides `model` when set (default empty). |
| `engineModels`        | Other engines' model picks by engine id, e.g. `{"whisperkit": "auto"}` (unset = `auto`). |
| `keepModelWarm`       | Keep the model loaded (`true`) or unload it when idle (`false`). Unset = automatic: unload only on ≤ 8 GB Macs. |
| `modelIdleMinutes`    | Idle minutes before unloading, when not kept warm (default 5). |
| `hold`                | The hold-to-talk hotkey (see above).                |
| `toggle`              | The press-to-start / press-to-stop hotkey.          |
| `cancelKeyCode`       | Key that cancels a recording (default 53 = Esc).    |
| `maxRecordingSeconds` | Auto-stop after this many seconds (default 600; `0` = no limit, capped at 30 min). |
| `trailingSpace`       | Add a space after each dictation (default off).     |
| `language`            | `en` (default), another code like `de`, or `auto`. English-only models always use `en`. |
| `threads`             | CPU threads; `0` = auto (performance cores, max 8). |
| `keepMicWarm`         | Keep the mic on from launch (default off: it stays on 30 s after each dictation). |
| `mascotAlwaysVisible` | Keep a small resting Cado on screen; click it to start/stop dictating (default off). |
| `mascotInScreenShares`| Let screen shares, recordings and screenshots capture Cado (default off: hidden). |
| `mascotPositions`     | Where you dragged Cado, per display (written when you drag it). |
| `notesFolder`         | Folder for meeting notes (`""` = default `~/Documents/Cado`). |
| `dictationHistory`    | Keep the last 10 dictations for **Recent Dictations** in the menu (default `false`). |
| `keepMeetingAudio`    | Keep a meeting's audio after its note is saved (default `false`: deleted). |
| `meetingSummaries`    | Summarize each meeting note after it's saved (default `true`; needs macOS 26 with Apple Intelligence). |
| `summaryProvider`     | Who writes summaries: `on-device` (default, Apple Intelligence on this Mac). |
| `meetingLanguage`     | Language meetings are transcribed in: `same` (default, also when the key is missing: dictation's `language` and model), `auto` (detected per passage, on a multilingual model), or a code like `hi`. |

---

## Troubleshooting

**“I granted Accessibility but it still says Not granted.”**
Setup signs the app with a **stable self-signed certificate**, so once you grant
Accessibility it should keep working across rebuilds. If it ever gets stuck
(e.g. you built once before the certificate existed), reset it once and grant
again:

```sh
pkill -x Cado                                 # quit the app
tccutil reset Accessibility com.ropats16.Cado # clear the stale grant
open /Applications/Cado.app                   # relaunch
```

Then re-grant Accessibility in **System Settings → Privacy & Security →
Accessibility** (remove any old "Cado" entry with the **–** button first,
then toggle the new one on).

**The hotkey does nothing.**
Make sure the menu says **Ready** (both permissions granted). If your chosen
combo still doesn't fire, try a different one (see *Changing the hotkey*). For
`hold`, prefer a pure-modifier combo — a bare normal key gets typed into your
text. For `toggle`, keep at least one modifier with the key for the same reason.

**“Speech model missing” in the menu.**
The model the app wants isn't downloaded. Click it to open Settings › Speech Model and
**Download** it (or pick a downloaded model there). From a source checkout,
`make model MODEL=…` fetches the same file. If you set `modelPath`, confirm it
points at a real file.

**“Speech model failed to load.”**
Usually a corrupt or incomplete download (it failed its checksum). Delete the
file from the models folder and download it again in Settings › Speech Model (or run
`make model MODEL=<name>`).

**Text doesn't appear after I speak.**
If no text field is focused, Cado copies the transcript to your clipboard
and shows a notification — click into a field first, or just paste with ⌘V.
Very short recordings (a fraction of a second) are ignored on purpose.

**Build failed.**
Confirm the build tools are installed (`xcode-select --install`) and you're on
macOS 14+ with an Apple-Silicon Mac.

**Check the engine without any of the UI/permissions** (handy sanity test):

```sh
.build/release/Cado --selftest \
  --model "$HOME/Library/Application Support/Cado/models/ggml-medium.en.bin" \
  --wav Sources/CWhisper/whisper.cpp/samples/jfk.wav
```

It should print the transcript of the sample audio. Without `--model` it uses
the engine's Automatic pick (add `--engine parakeet`, `whisperkit` or
`apple-speech` to check another engine).

---

## Privacy

Everything runs on your Mac. No accounts, no tracking, and no audio or text
ever leaves your machine. The only things that touch the network are model
downloads (when you run setup or click **Download**), the update check (once
a day; off in Settings › General) and an optional, off-by-default anonymous
usage count you can switch on — see
[Network activity](#network-activity) for the full list.

Dictated text isn't kept after it's pasted, unless you turn on
[Recent dictations](#recent-dictations): then the last 10 stay in a file on your
Mac until you turn it off.

Meeting recording only happens when you click **Record Meeting**, and only
records the meeting app you picked plus your mic. While it records, the audio
and its transcript so far are written to a private folder on your Mac that only
your user account can read, so a crash or a quit can't lose the meeting (unless
the disk was full; see [Limits](#meeting-notes)). That folder is deleted once
the note is safely saved. The audio is kept after that
only if you turn on **Keep meeting audio**, or if part of the meeting couldn't
be transcribed. It never leaves your Mac.

Meeting [summaries](#summaries) are written by Apple Intelligence's on-device
model: the transcript never leaves your Mac.

---

## Network activity

Every host Cado or its setup scripts contact, and when. Nothing here sends
your audio, transcripts or settings anywhere; each request only fetches a
file.

| Host | When | What's sent / received | Opt-in? |
| --- | --- | --- | --- |
| `huggingface.co` | `make setup` (`scripts/download_model.sh`) and the other `scripts/download_*_model.sh` scripts | Downloads whisper.cpp model files (and the VAD model for benchmarks), WhisperKit and Parakeet model folders. Each file is checked against a pinned SHA-256; WhisperKit/Parakeet files are also pinned to one repo commit. | You run the script |
| `huggingface.co` | In the app, only when you click **Download** in Settings › Speech Model (or, for a meeting model, Settings › Meetings › Meeting Language) | Downloads whisper.cpp model files (from the same place as `make model`, pinned by SHA-256 only, like the script) and WhisperKit/Parakeet model files (pinned by commit and SHA-256), each verified before use. A plain file request: no cookies, no account. | Yes, per click |
| Apple | In the app, only when you click **Download** for an Apple Speech model in Settings › Speech Model | Cado asks macOS to install the language model; macOS downloads it from Apple, not Cado. | Yes, per click |
| `github.com` | Release builds of the app: about once a day while Cado runs, and when you choose **Check for Updates…** in the menu (or **Check Now** in Settings › General) | Fetches the update feed, `github.com/ropats16/cado/releases/latest/download/appcast.xml` ([Sparkle](https://sparkle-project.org)). If there's a newer version, Cado asks before installing it (unless you tick "Automatically download and install updates" in that prompt), then downloads its DMG from the same GitHub release (GitHub redirects both the feed and the DMG to `release-assets.githubusercontent.com`); the download must match the release's Ed25519 signature and Cado's code signature, or it's discarded. No system profile or identifier is sent (just a normal HTTPS request, with Cado's version in the User-Agent). Builds made with `make install`/`make package` never check. | On by default; turn off **Automatically check for updates** in Settings › General |
| `nom.telemetrydeck.com` | In the app, once per launch, only if you turned on **Send anonymous usage count** (onboarding, or Settings › General) | One small JSON signal: a random anonymous ID (SHA-256 hashed; deleted if you turn it off), Cado's version, macOS version (major.minor) and chip type (arm64/x86_64). Never audio, text or file names. Only sent by a build with a TelemetryDeck app ID; Cado 0.1.0 has none, so this switch sends nothing yet. | Yes, **off by default** |

Meeting summaries (Apple Intelligence's on-device model) contact nothing:
macOS downloads and updates that model itself, not Cado.

Downloads from `huggingface.co` are mostly redirected to Hugging Face's CDN
(`*.hf.co`, e.g. `us.aws.cdn.hf.co`; the host varies by region). The speech
libraries Cado uses (WhisperKit, FluidAudio) are set up never to download
anything on their own; they only load model folders already on disk. WhisperKit
would fetch a tokenizer from `huggingface.co` if a model folder's own
`tokenizer.json` couldn't be read, so Cado reads every tokenizer file WhisperKit
could pick in the folder (including any under `models/openai/`) first and
refuses the model if one can't be read: that request is never made.

**Building from source and developer tools** (not the app) also use the network:

- `github.com` — `git submodule update` fetches whisper.cpp
  (`ggml-org/whisper.cpp`), and SwiftPM fetches the Swift packages:
  `FluidInference/FluidAudio`, `argmaxinc/argmax-oss-swift` (WhisperKit),
  `sparkle-project/Sparkle` (its prebuilt framework, from that repo's GitHub
  releases) and, through them, `apple/swift-argument-parser`.
- `www.openslr.org` — only `scripts/fetch_bench_fixtures.sh`, the developer
  benchmark's audio fixtures (LibriSpeech test-clean, SHA-256 pinned). The app
  never contacts it.

**Not in the app yet.** These are planned and will be listed in the table above
when they land: meeting summaries through
`openrouter.ai` (issue #35, off by default, sends a transcript only if you turn it on).

---

## For developers

```sh
make run          # build (release) and run from the source tree
make build        # compile only
make package      # assemble dist/Cado.app
make install      # build + package + copy to /Applications
make clean        # remove build artifacts
make release VERSION=x.y.z  # signed, notarized DMG (maintainer; see docs/RELEASING.md)
make brand        # regenerate the app icon + embedded mascot art from plans/mascot (needs rsvg-convert)
make acknowledgements  # regenerate the in-app Acknowledgements text from ACKNOWLEDGEMENTS.md + LICENSE
```

whisper.cpp is vendored as a git submodule under `Sources/CWhisper/whisper.cpp`
and built purely with SwiftPM (no cmake).

**The build is arch-conditional** — `Package.swift` branches on the arch of the
machine running SwiftPM:

- **Apple Silicon (`arm64`):** the Metal build, unchanged from before Phase 5.
  whisper + ggml + the Metal backend, with the shader **embedded** into the
  binary at build time (no Xcode Metal toolchain needed) and compiled on the GPU
  at runtime, so the `.app` is self-contained.
- **Intel (`x86_64`):** a CPU-only build — no Metal at all; x86 CPU kernels built
  with AVX2/FMA/F16C plus the Accelerate/BLAS backend. `embed_metal_shader.sh`
  self-skips on x86, so `make`/`setup`/`package` need no arch branching.

Because the manifest branches on the **host** arch (not on any `--arch` flag),
to exercise the Intel path on an Apple Silicon Mac you must run the whole
toolchain under Rosetta:

```sh
arch -x86_64 swift build -c release --manifest-cache none
```

Don't use `swift build --arch x86_64` — that still runs the manifest as `arm64`
and selects the Metal branch. `--manifest-cache none` matters too: SwiftPM caches
the compiled manifest by content, not by arch, so a prior `arm64` build can
otherwise shadow the x86 branch and link-fail on duplicate symbols (real Intel
Macs are unaffected — they only ever compile the manifest as x86). Smoke-test the
resulting x86 binary with the [`--selftest` check](#troubleshooting) (a plain
`x86_64` binary runs under Rosetta automatically).

**Binary size.** FluidAudio (Parakeet) is pulled in with `traits: []`, which
drops its NemoTextProcessing library: the release binary goes from 25.6 MB to
17.2 MB, but only with a Swift 6.2+ toolchain (a 6.1 toolchain still links
it). Its `FluidAudio_FluidAudio.bundle` holds only the LuxTts G2P data its TTS
uses, so `make package` doesn't copy it; the ASR path never reads it.

See `plans/IMPLEMENTATION-NOTES.md` for the durable build/integration details.

### Benchmarking an engine

`Cado --bench` runs a speech engine over fixed audio fixtures, through the
same engine interface the app uses, and reports dictation latency (p50/p90),
real-time factor on ~10 min of audio, peak memory, model load time and word
error rate — as a table and a JSON file you can compare across Macs:

```sh
bash scripts/fetch_bench_fixtures.sh       # one time: ~331 MiB download → .bench/fixtures
make build
.build/release/Cado --bench --git-sha "$(git describe --always --dirty)" \
  --model "$HOME/Library/Application Support/Cado/models/ggml-medium.en.bin"
```

See [`plans/benchmark.md`](plans/benchmark.md) for options, what each number
means, the JSON schema, fixture licenses, and how to add an engine.

---

## License

Cado is MIT-licensed — see [`LICENSE`](LICENSE). The open-source projects and
models it builds on, and their licenses, are listed in
[`ACKNOWLEDGEMENTS.md`](ACKNOWLEDGEMENTS.md) and in the app's menu-bar menu
under **About Cado**.
