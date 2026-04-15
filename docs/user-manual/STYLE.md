# STYLE, Lungfish User Manual

Derived from `lungfish_brand_style_guide.md` (memory). The linter in
`build/scripts/lint/` enforces every mechanical rule here.

## Prose rules

Two hard rules apply to every chapter and every agent-facing doc under
`docs/user-manual/` and `.claude/agents/`.

First: **no em dashes.** Never write `—` in chapter or doc prose. Use a period
and start a new sentence. When the em dash introduced a list or a noun-phrase
elaboration, a colon is usually right. Hyphens inside compound adjectives
(`read-only`, `five-color`) are fine.

Second: **bullet lists are capped.** At most five items per list, at most two
lists per H2 section. Longer enumerations become prose or a Markdown table. If
a genuine five-item enumeration is genuinely parallel, it may stay as a list;
if it exceeds five, restructure.

Lint: `em-dash.js` (error), `bullet-cap.js` (warning, so genuine exceptions
can ship with a review note).

## Written identity

The product is **Lungfish** in title case, one word. Never `LUNGFISH`,
`LungFish`, `Lung Fish`, or lowercase `lungfish`. Kit names are **Lungfish Air Kit** and
**Lungfish Wastewater Kit**. The device is the **InBio Apollo Sampler**. The
consumable is the **Cassette**: capitalised site-facing, lowercase in prose.
Lint: `written-identity.js`.

## Palette

Five colors, nothing else, in prose hex references and embedded SVG fills.

| Name | Hex | Use |
|---|---|---|
| Lungfish Creamsicle | `#EE8B4F` | Primary accent, headings, CTAs |
| Peach | `#F6B088` | Secondary warm tint |
| Deep Ink | `#1F1A17` | Primary text. Never pure black. |
| Cream | `#FAF4EA` | Page backgrounds. Never pure white. |
| Warm Grey | `#8A847A` | Captions, metadata |

Never use red-amber-green in data viz: encode severity with Deep Ink weight
and annotation. Never place Creamsicle on Peach, and never use Creamsicle for
body text. Lint: `palette.js`, `data-viz.js`.

## Typography

| Role | Face | Sizes |
|---|---|---|
| Display / H1 | Space Grotesk Bold | 32–40pt |
| Section / H2 | Space Grotesk Medium | 24–28pt |
| Subsection / H3 | Space Grotesk Medium | 18–22pt |
| Body | Inter Regular | 11–14pt |
| Caption / Label | Inter SemiBold | 9–11pt |
| Data / Code | IBM Plex Mono | 10–12pt |

Prose never names a font. Inline HTML `style=` attributes and `<style>` blocks
must use only these faces. Lint: `typography.js`.

## Voice

Six qualities describe the Lungfish voice: Purposeful, Precise and scientific,
Trustworthy and calm, Actionable, Thoughtful, Inclusive and empowering. Never
hyped, never cold.

Banned patterns the linter flags include `revolutionary`, `breakthrough`,
`powerful`, `cutting-edge`, `AI-powered`, `game-changing`, `unleash`, and
`leverages`. `next-generation` is permitted only when literally referring to
NGS inside a primer. `!` at the end of a body sentence is banned (permitted in
quoted CLI output). Superlative chains such as "most advanced, most accurate,
most…" are banned. Lint: `voice.js`.

## Chapter structure

Every chapter opens with a primer heading (`## What it is` or `## Why this
matters`) before any `## Procedure` section. Every chapter has YAML
frontmatter validated by `frontmatter.js`. Every `<!-- SHOT: id -->` marker in
the body has a matching entry in the frontmatter `shots[]` list and vice
versa. Every `prereqs[]`, `glossary_refs[]`, `fixtures_refs[]`, and
`features_refs[]` entry resolves to an existing target. Lint:
`frontmatter.js`, `primer-before-procedure.js`.

## Fixture references

When a chapter uses a fixture, it cites the fixture's `README.md` citation
block via `{{ fixtures_refs[] | cite }}`. Chapters do not reproduce licenses
or accessions inline.

## Audience tiers

Every chapter declares one tier: `bench-scientist`, `analyst`, or
`power-user`. No chapter may mention a concept the audience tier has not been
primed for.

## Screenshots

Screenshots sit on Cream backgrounds (light appearance) unless the chapter is
specifically about dark-mode features. Dark-mode screenshots sit on a Deep Ink
containment panel. Annotation callouts and brackets use Creamsicle at 2px
stroke. SVG overlays are composited post-capture, not drawn in the app.

## Frontmatter schema

```yaml
title: <human title>
chapter_id: <path-style id matching file location>
audience: bench-scientist | analyst | power-user
prereqs: [<chapter_id>, ...]
estimated_reading_min: <int>
shots:
  - id: <kebab-case>
    caption: "<sentence>"
glossary_refs: [<term>, ...]
features_refs: [<features.yaml id>, ...]
fixtures_refs: [<fixture dir name>, ...]
brand_reviewed: false
lead_approved: false
```
