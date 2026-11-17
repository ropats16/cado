# Manual checks: OpenRouter summaries (#35)

What the tests can't reach: the real Keychain, the real OpenRouter API and
real models, and how the Settings card looks. Tests use a fake transport and
a fake key store only; no real request or Keychain item was made while
building this, and OpenRouter's current docs were read to code the request
(`POST https://openrouter.ai/api/v1/chat/completions`, Bearer key, `X-Title`;
errors as `{"error": {code, message, metadata}}`; public
`GET /api/v1/models`). Nothing was run against the live service.

Already verified without a human (`OpenRouterSummaryTests`): request URL,
headers (only Authorization, Content-Type, X-Title) and body; the shared
prompts and answer parsing; 401/402 -> not set up, 429/408 -> busy (retried by
the pipeline, then succeeds), context-length 400 -> too long, other statuses
and network failures stop the run, errors never contain the key, the
transcript or the provider's message; consent and key gating in the catalog
(nothing sent without both, even with Summarize meetings on, even when asked
by hand); the picker asks first and changes nothing until confirmed; switching
back withdraws consent; the key never reaches the config; model list only
fetched on Refresh and without a key; attribution names the model.

Owner steps (need a real OpenRouter key; use a small model and a short test
meeting, since requests cost money; a fresh key you can revoke afterwards):

1. **Consent flow.** Settings › Meetings. Written by shows Apple Intelligence
   (or, on a Mac without it, the card says why). Choose OpenRouter: the
   warning appears (text leaves this Mac, OpenRouter and the model's
   company), Written by stays on the warning, config has no
   `openRouterConsent: true` yet. Cancel: back to the old choice. Choose it
   again and confirm: key and model rows appear. Quit and reopen: still
   OpenRouter, still confirmed.
2. **No key, nothing sent.** Confirmed but no key: the switch's note says to
   add a key and the Summarize meetings switch is greyed. Record a short
   meeting: no summary, and no connection to `openrouter.ai` (check with
   Little Snitch / `nettop` or the Console log: no "Summary" send lines).
3. **Key to Keychain.** Paste the key, Save Key: the field becomes "Saved in
   Keychain". Open Keychain Access: a generic password for service
   `com.ropats16.Cado.openrouter`, account `api-key`. grep the config file
   (`~/Library/Application Support/Cado/config.json`) and Console for the key:
   not there. The first access by a dev/ad-hoc build may show a Keychain
   prompt (note which button works); a signed release build should not.
4. **Real request.** Record about a minute of a meeting (two speakers, with
   a decision and an action item). The note gets a Summary; the line under it
   names the model and OpenRouter and says the text was sent off the Mac. The
   OpenRouter activity page shows one request, and no transcript text appears
   in Console logs. Try Regenerate Summary in the Library. Try a long meeting
   (an hour or more of text): it splits into parts and merges.
5. **Model.** Pick another curated model; the next summary names it. Type a
   custom id (e.g. one from openrouter.ai/models); works. Type a nonsense id:
   the summary fails with a plain message in the Library and the old summary
   stays. Refresh: the list fills (only now is `openrouter.ai/api/v1/models`
   contacted); offline, Refresh shows the error and keeps the short list.
6. **Wrong key.** Remove Key, save a wrong one: a summary attempt says
   OpenRouter didn't accept the key (Library and Settings note), the note is
   untouched.
7. **Out of credits** (optional, a key with no credit): says the account is
   out of credits.
8. **Offline.** Turn Wi-Fi off, run Regenerate Summary: fails with the generic
   "Couldn't summarize right now" and the old summary is kept; nothing hangs
   (the request times out after about 90 s at most).
9. **Key removal.** Remove Key: the row returns to the paste field, the item is
   gone from Keychain Access, automatic summaries stop (nothing sent).
10. **Switching back.** Choose Apple Intelligence: summaries use it again
    (Apple Intelligence Macs), and choosing OpenRouter again shows the warning
    again.
11. **Rate limit** (hard to provoke): a 429 is retried with the pipeline's
    waits (2/5/10/15/30 s), then stops with the old summary kept.

Judgement calls to look at: the default model (`openai/gpt-4o-mini`) and
curated list (`OpenRouterModels.curated`; ids not verified against the live
catalog), the answer length cap (1,200 tokens), the 90 s request timeout.
