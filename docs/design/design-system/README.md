Lungfish is an open-source environmental surveillance research collaborative. This system covers its public face (the docs site, the user manual and site-facing material) and the Lungfish Genome Explorer (LGE) macOS app. The stance is clarity, not alarm. Be calm, precise and useful.

## Content fundamentals

- Write the name in title case as one word, and call Lungfish a collaborative, never a company or product.
- Name the app "Lungfish Genome Explorer (LGE)" on first use, then "LGE".
- Use the tagline *Seeing the invisible. Informing action.* in `body` at 40% of the wordmark size.
- Be purposeful, precise, calm and actionable. Name uncertainty rather than bury it.
- Address the reader as "you". Use no emoji and no marketing hype.

Use sentence case for headings. App controls use title case, as macOS does ("Create Project", "Open Project", "Run"). Prefer human and macaque examples over viral ones in teaching material.

A brand sentence sounds like this. "Air sampling is a leading indicator of emerging threats. By detecting what is circulating in indoor environments in near real time, sites can act before clinical data catches up."

App copy sounds like this. "Open projects with built-in viewers before installing tools. Analyses that need external tools will show their setup requirements."

## Color

Five colors are the whole brand. They are `creamsicle`, `peach`, `deep-ink`, `cream` and `warm-grey`.

| Ground | Share of the page |
|---|---|
| Light | Deep Ink 60%, Warm Grey 20%, Creamsicle 15%, Peach 5% |
| Deep Ink | Cream 60%, Creamsicle 25%, Peach 10% |

- Set text in `ink` on `canvas` or `card`, and secondary text in `text-secondary`.
- Use `warm-grey` for captions and metadata only. It is 3.4 to 1 on `cream`.
- Never set paragraphs in `creamsicle`. Use it for the accent bar, links, active markers, selected rows and glyphs.
- Never put `creamsicle` on `peach`. Never use pure white text on `deep-ink` or pure black anywhere.
- In the app, branded glyphs and the selected sidebar row use `creamsicle` on `selection-fill` or an `icon-well`. System controls keep the user's macOS accent color.

The app's asset-catalog accent is `lungfish-orange`. The brand manual's canonical accent is `creamsicle`. Use `creamsicle` for anything public, and change the app's runtime accent only with the owner's sign-off.

| Use | Tokens |
|---|---|
| Ready | `sage` dot on `success-fill`, with the word "Ready" |
| Needs attention | `creamsicle` dot on `attention-fill`, with a word |
| Destructive or error | `danger` on `danger-fill`, with a word |
| Data viz | `creamsicle` first series, `peach` second, `warm-grey` third, `deep-ink` axes, `cream` ground |
| Sequence views | `base-a`, `base-c`, `base-g`, `base-t`, `base-n` |

Never use a traffic-light red, amber and green set, and never let a dot carry meaning alone. Base colors are user-adjustable defaults and the only saturated colors outside the palette.

## Typography

| Role | Face | Styles |
|---|---|---|
| Display and headings | Space Grotesk | `display` 700, `heading-2` and `heading-3` 500 |
| Body and labels | Inter | `body` 400, `eyebrow` 600 uppercase and tracked |
| Code, CLI, data and sequence | IBM Plex Mono | `code`, `app-mono` |
| macOS app | System font (SF Pro) | the `app-*` styles |

Fall back to Arial for Space Grotesk and Inter, and to Consolas for Plex Mono. All three brand faces are free on Google Fonts. Do not ship them inside the app.

Every H1 gets the Creamsicle bar, `accent-bar-width` by `accent-bar-height` in `creamsicle`, flush left beneath it. After the logo it is the most consistent brand element. Keep line length at or under 68ch.

## Spacing and layout

- Brand pages use an 8px grid (`space-8`) with at least `space-48` margins on screen and 25mm in print.
- The Welcome window uses `space-18` gutters, `space-22` tile padding and `space-28` section rhythm.
- Viewports default to `space-16` panel padding and `space-4` stacks.
- List rows are single-line everywhere. Secondary text goes inline, never on a second baseline.

## Shape, borders and depth

- App shapes are rounded and continuous. Tiles use `radius-24`, rows `radius-20`, icon wells `radius-14` and `radius-18`, pills `radius-pill`.
- Docs are quieter, with `radius-8` callouts and images.
- Separate with `stroke` or `rule` hairlines, never shadows. A hovered tile's stroke turns `creamsicle` at `opacity-hover-stroke`.
- Disabled tiles and rows drop to `opacity-disabled`.
- Docs callouts get a `peach` wash at 28%, a `peach` border at 60% and a `callout-edge` left edge in `creamsicle`.

## Iconography

The app uses SF Symbols (`folder.badge.plus`, `folder`, `folder.fill`, `folder.badge.questionmark`) at medium weight in `creamsicle`, inside an `icon-well`. SF Symbols belong to Apple and are not in this system, so the web previews here substitute simple 2px stroke line icons.

Brand icons use a 2px stroke with rounded terminals in one color (`creamsicle` or `deep-ink`). They stay legible at 24px and scale to 96px.

The app icon is the only mark in this system. Show it on `cream` or `deep-ink` only, and never stretch, recolor, shadow or tile it.

## Not synced

- The brand wordmark and monogram are not in the repository. Set the name in plain type until those files are added.
- Brand font files are not in the repository. Load the three faces from Google Fonts.
- The app is SwiftUI, so there is no web component library. The component cards are static web renditions hand-written from the Welcome window, the operation preview view and the site theme.
- System semantic colors in read views (`systemGreen`, `systemYellow`, `systemOrange`, `systemIndigo`, `systemPurple`) and the manual's preview banner are not placed.
