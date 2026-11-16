# Opt-in anonymous launch ping (#26)

## Decision, 2026-11-16: TelemetryDeck over plain HTTP, no SDK

**What:** one signal per app launch, only if the user turned on "Help count
Cado's users" (onboarding Ready step or Settings › Usage Count). Off by
default; never pre-checked.

**Why TelemetryDeck:** privacy-first, EU-hosted, built for anonymous app
usage counts; it salts and re-hashes the user id server side, so the id we send
is not stored as-is. Free tier covers an indie app. Alternatives (Plausible,
self-hosted) add hosting or a web-first model for no gain here.

**Why no SDK:** Cado's promise is that every outbound request is listed in
the README. The SDK collects many default parameters (screen size, locale,
time zone, accessibility flags, session stats) and adds a dependency that must
be audited every update. The ingest API is one POST of a small JSON array, so
Cado builds that itself (`Sources/Cado/Telemetry/LaunchPing.swift`) and sends
only what is listed below.

**Contract** (https://telemetrydeck.com/docs/ingest/v2, read 2026-11-16):
`POST https://nom.telemetrydeck.com/v2/`, `Content-Type: application/json;
charset=utf-8`, body = JSON array of events; required `appID` (non-empty),
`clientUser`, `type`; optional `sessionID`, `isTestMode`, `payload` (flat
object). 200 `OK`, 422 on a bad body. Default parameter key names:
https://telemetrydeck.com/docs/ingest/default-parameters/.

**Exactly what is sent** (and nothing else):

```json
[{"appID":"<owner's TelemetryDeck app ID>",
  "clientUser":"<SHA-256 hex of a random UUID made on this Mac>",
  "type":"App.launched",
  "isTestMode":false,
  "payload":{"TelemetryDeck.AppInfo.version":"0.1.0",
             "TelemetryDeck.Device.systemMajorMinorVersion":"14.5",
             "TelemetryDeck.Device.architecture":"arm64"}}]
```

No transcript, audio, file names, hostname, serial, or locale. No `sessionID`
(TelemetryDeck derives a daily one). `isTestMode` is true in debug builds so
dev runs don't count. The TCP connection still shows the Mac's IP to
TelemetryDeck, as any request does; Cado adds no IP-derived field.
The request is a single POST, 5 s timeout, ephemeral session (no cookies, no
cache), off the main thread, never retried, failures silent.

**The id:** random UUID created at opt-in, stored in
`~/Library/Application Support/Cado/usage-ping-id`, SHA-256 hashed before
sending, deleted at opt-out (opting in again makes a new one).

**Inert until configured:** the app ID is read from Info.plist key
`CadoTelemetryAppID`, shipped empty; empty means nothing is ever sent.

**Owner's one step:** sign up at telemetrydeck.com, create an app, copy its
app ID into `CadoTelemetryAppID` in `Resources/Info.plist`, release.

**Unconfirmed:** the docs mark the `TelemetryDeck.` payload scope as reserved
for SDK use, while also listing these exact keys as the standard default
parameters; we use the standard keys so dashboards group by version/OS/arch.
Not verified against a live app (no real request was sent in development).
