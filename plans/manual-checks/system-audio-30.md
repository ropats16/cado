# Manual checks: system-audio capture (#30, capture half)

Needs the packaged app (`make package` → `dist/Cado.app`): the usage string
and the grant belong to the bundle. Launch it through `open` so Cado — not
the terminal — is the app macOS asks about. Output goes to the log file.

```sh
pkill -x Cado
# Optional, for a fresh prompt (service name unverified; else remove Cado from
# System Settings › Privacy & Security › Screen & System Audio Recording):
tccutil reset AudioCapture com.ropats16.Cado
```

## Which apps can be recorded

```sh
open -W --stdout /tmp/cado-sat.log --stderr /tmp/cado-sat.log dist/Cado.app --args --system-audio-test --list
cat /tmp/cado-sat.log
```

- [ ] Open meeting apps (Zoom, Teams, a browser…) are listed, marked
      "(meeting app)", each with its Core Audio processes.
- [ ] Play a call or video in Chrome/Edge/Brave/Arc, then `--list` again: its
      helper processes (`….helper`) appear under the browser.
- [ ] Safari: play a video; Safari's entry includes `com.apple.WebKit.GPU`
      processes (all WebKit apps' — expected).

## Recording one app

Play audio in the target app (e.g. a YouTube video in Brave) and, at the same
time, something from another app (e.g. Music):

```sh
open -W --stdout /tmp/cado-sat.log --stderr /tmp/cado-sat.log dist/Cado.app \
  --args --system-audio-test --app com.brave.Browser --seconds 8 --out /tmp/cado-sat.wav
cat /tmp/cado-sat.log; afplay /tmp/cado-sat.wav
```

- [ ] First run: macOS asks to let Cado record system audio, with Cado's
      usage string ("…during a meeting you start…").
- [ ] Allowed: the log ends "Sound captured: the system-audio permission is
      granted." (exit 0), and the WAV holds the target app's audio only — not
      Music's, not Cado's sounds.
- [ ] Denied: the log ends "Only silence…" (exit 3) and the WAV is silent; no
      crash, no error.
- [ ] The system-audio recording indicator in the menu bar goes away when the
      run ends.

## Changes mid-recording

- [ ] Start a 20 s `--app` run on a browser before any tab plays (log:
      "tapping … (N process(es))"), then start a video: the log shows a
      restart ("Audio route changed; restarting capture.") and the WAV has the
      video from shortly after it began.
- [ ] Switch output (speakers ↔ AirPods) during a run: the WAV continues
      (small gap at the switch).
