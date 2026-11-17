# Cado revamp mockups — revision 5

Open [site-mockup.html](site-mockup.html) and [app-mockup.html](app-mockup.html) in a browser. These are the approved static design studies. Their production implementation lives in `site/` and `Sources/Cado/`. Both follow the system theme; the Theme button cycles through light, dark and auto. They now use local system fonts and make no font requests.

## Direction

More professional, still recognisably Cado. Keep the current site's confident sans-serif typography and friendly mascot, combined with the generous spacing and product-led presentation of [Granola](https://www.granola.ai/). The user's preference for simpler layouts takes priority over the elaborate effects in the latest [TASTE guidance](https://github.com/Leonxlnx/taste-skill).

- Bold native sans-serif replaces Fraunces and rounded body text. Titles use tighter spacing; app controls retain compact native proportions.
- Pure white replaces the warm off-white page background. White windows and pale green secondary surfaces have clearer separation.
- A more saturated forest green anchors buttons, text emphasis and selections; the privacy band uses a richer deep green.
- The original production hero title and description are restored. A large avocado sits beside the copy on desktop and below it on mobile, with the entire Library window beneath.
- Raised leaf-green buttons (`#61C45E`) use dark text, a solid green base and rounded rectangular corners. Their pressed state depresses the face.
- The three steps now sit in generous pale-green cards, with larger mascots, bold titles and clear step numbers.
- The mascot remains in the wordmark, beside the hero copy, and in relevant app states.

| Role | Light value |
| --- | --- |
| Page | `#FFFFFF` |
| Window | `#FFFFFF` |
| Secondary surface | `#F1F5EE` |
| Primary text | `#16291E` |
| Primary action | `#137343` |
| Accent text | `#10683B` |
| Selection | `#E4F3DC` |
| Privacy band | `#103E29` |

Dark mode retains deep green surfaces, with a clearer mint accent (`#8FE0A4`) and brighter secondary labels.

## What to review

1. Does the bolder all-sans direction recover the clarity of the current site?
2. Is the white/green balance bright enough while retaining warmth?
3. Does the mascot feel appropriately present alongside the more professional layout?

All six app studies remain: Settings, Library, menu bar, overlay states, meeting prompt and onboarding. Controls inside illustrated windows are static; the theme control and website section links work. Summary content and the Launch sync note are illustrative; the website mockup retains its historical Coming soon summary label; the production site describes the shipped summary options. Placeholder download/GitHub controls are not release links.

## Validation

Rendered both pages in Chromium at 1440, 768 and 390 pixels, in light and dark modes. No JavaScript errors; theme switching works. The app settings tab strip scrolls horizontally on narrow screens. The approved direction has now been applied to the production website and native Swift app, retaining real controls, native settings tabs and shipped features. The native Library screenshot is rendered from the updated app.

## Mascot motion

Listening artwork has two outer rings and no red pit ring; the outermost ring is farther out and lighter. The larger hero mascot cycles through the original idle, listening, thinking and done artwork over 16 seconds. Listening gently pulses, thinking tilts, and completion makes a small hop. There is no visible animation control; reduced-motion preferences show a static idle pose. The loop pauses when the browser tab is hidden. All artwork is embedded in the mockup.

Small green line icons identify the four product facts and three macOS permission explanations. They are decorative inline SVGs; visible text remains the accessible label.

## Finishing pass

Pure white remains the page background. A localized pale-green halo and soft ground shadow frame the mascot. The step cards and download panel use slightly stronger green-tinted edges, subtle surface shading and shallow shadows. Headings and key labels have firmer weight; icons sit on small tinted tiles. Secondary buttons have a restrained raised edge and hover/press feedback.
