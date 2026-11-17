# Cado revamp mockups

Open `site-mockup.html` (landing page) and `app-mockup.html` (app windows) in a browser. Both are self-contained, light + dark (follows system; a Theme button overrides). Only external request is an optional Google Fonts stylesheet (Fraunces); falls back to system serif.

## Direction

Roughly 55/45 professional/playful. Warm paper surfaces, deep ink-green text, a serif for headlines and note titles, SF Rounded kept for UI/body, one deep-avocado accent used for the primary button, active tab, "Me" and selection. Product UI leads the hero; the mascot moves from centrepiece to a calm character that peeks over the window and acts as the status indicator.

## Kept from today

- Avocado mascot art (all poses, unchanged SVGs), warm cream/leaf-green palette, cheek-pink and pulse-coral accents.
- Copy and honest claims: on-device, MIT, plain Markdown, Me/Others, network table, permissions, brew install.
- Hero shows the real Library; hold-to-talk story; light + dark.

## Cues from the reference (not copied)

- Large serif display type with generous whitespace and slow section rhythm.
- Product screenshot as the hero, not an illustration.
- Quiet hairline-and-card UI, restrained colour, one dark inverted band for the trust section.
- Calm, factual copy; a fact strip instead of badges.

## Decisions to react to

1. **Typeface:** Fraunces (serif) for headings + SF Rounded body. Alternative: all-sans, or serif only on the website.
2. **Accent:** deep green (#2b5f27 light / #9bdc86 dark) replacing the system bright green on buttons and links. Apple system green stays only for live-status dots. Mixed-in app tint changes if you want the app to keep stock green.
3. **Mascot playfulness:** only in hero (peeking), 3-step cards, overlay states and download. No 3D buttons, bounce or glow. Dial up by enlarging the hero mascot back to centre.
4. **Summaries:** shown in the Library and site as "Coming soon" tag. Keep the tag until shipped.
5. **Dark band** for Private by design: keep it (strong trust signal) or stay on paper tones.

## What implementing touches

- Site: `site/index.html`, `site/styles.css` (new tokens, fonts, sections; real screenshots replace the HTML window; local font file needed to keep "no third-party requests").
- App: `Sources/Cado/Brand/Brand.swift` (accentText/accent, serif title font), `Settings/SettingsView.swift` (tabs), `Library/LibraryView.swift` + `LibraryDetailView.swift` (summary block, segmented control), `App/StatusMenu.swift`, `Onboarding/OnboardingView.swift`, new meeting-detection prompt and summary views, overlay unchanged.
- Mockup copy and sample note (Launch sync) is invented placeholder.
