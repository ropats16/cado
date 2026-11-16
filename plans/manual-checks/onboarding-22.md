# Manual checks: onboarding flow (#22)

Run on the packaged app (`make install`). "Fresh" means no grants and no
config:

```sh
pkill -x Cado
tccutil reset Microphone com.ropats16.Cado
tccutil reset Accessibility com.ropats16.Cado
rm ~/Library/Application\ Support/Cado/config.json
```

Launch rule: onboarding shows while `onboardingDone` is false in
`config.json`, unless Accessibility, Microphone and a model are all already
there (an upgrade), which sets it silently. **Done** and **Finish later** set it; the
close button doesn't. Steps follow live readiness (polled every ~2 s,
and at once when Cado becomes active again); a step that turns done moves on
by itself, a revoke never pulls you back.

## First launch

- [ ] Fresh: the "Welcome to Cado" window shows; no system prompt (mic or
      Accessibility) fires behind it.
- [ ] The window is a normal one: System Settings comes in front of it when
      opened from a step.
- [ ] Already-set-up upgrader (grants + a model, `onboardingDone` missing
      from the config): no onboarding; `config.json` now has
      `"onboardingDone" : true`.

## Microphone

- [ ] **Allow Microphone** → the system dialog shows above the window;
      Allow → the step turns done and moves to Accessibility.
- [ ] Mic denied (Don't Allow, or `tccutil reset` then deny): the step says
      it's off; **Open System Settings** opens Privacy › Microphone; switch
      Cado on → back in Cado, the step turns done and moves on.

## Accessibility

- [ ] First click on **Allow Accessibility…**: the system prompt shows
      and Cado appears in the Accessibility list (switched off).
- [ ] Switch it on → the step flips to done within ~2 s (briefly "Starting the
      hotkeys…") and moves on.
- [ ] Revoke Accessibility, then **Set Up Cado…** from the menu → lands on the
      Accessibility step.
- [ ] Re-signed build with a stale grant (Cado on in the list, hotkeys
      won't start): the step says to remove Cado with − and add it again.

## Model

- [ ] Recommended model preselected and marked; installed ones marked;
      picking another changes what **Download** fetches (and the detail text).
- [ ] **Download**: progress and percentage; the picker is locked meanwhile.
- [ ] **Cancel** → **Resume** picks up where it stopped.
- [ ] Go offline mid-download → the failure reason and **Retry**; back online,
      Retry finishes.
- [ ] After the download (already checksummed, so no "verifying"): preparing
      ("the first time takes a minute") → done; Automatic loads it with no Settings change (menu says
      Ready).
- [ ] A download started in onboarding shows in Settings › Model › Download
      a model (progress, Cancel), and one started in Settings shows in
      onboarding.
- [ ] **More models in Settings…** opens Settings.
- [ ] Intel Mac, or language set to auto-detect: a whisper model is
      recommended; its download works and resumes a `.part` file left by an
      interrupted `make model`.

## Ready and closing

- [ ] Ready shows the hold and toggle hotkeys as bound (rebind one in
      Settings while onboarding is open: Ready updates).
- [ ] **Done** closes the window; dictation works right away; next launch
      shows no onboarding.
- [ ] Close mid-flow with the close button (mic not asked, Accessibility not
      prompted): the remaining system prompts fire once (mic dialog;
      Accessibility prompt) and not again on reopen/close; next launch shows
      onboarding again.
- [ ] **Finish later** (something still missing): closes, the remaining
      system prompts fire once; next launch shows no onboarding (the menu
      still reopens it).
- [ ] **Set Up Cado…** (above Settings… in the menu) reopens it on the first
      unfinished step, or Ready when all is set; while it's open it just comes
      to the front.
- [ ] Light and dark mode: nothing clipped or low-contrast on any step.
