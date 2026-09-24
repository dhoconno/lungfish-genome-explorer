# STYLE, Lungfish User Manual

Derived from `lungfish_brand_style_guide.md` (memory). The linter in
`build/scripts/lint/` enforces every mechanical rule here.

## Prose rules

Five hard rules apply to every chapter and every agent-facing doc under
`docs/user-manual/` and `.claude/agents/`.

First, **no em dashes.** Use a period and start a new sentence.

Second, **no semicolons.** Split the sentence.

Third, **no colons inside a sentence.** A colon may end a short lead-in line
that is immediately followed by a list, a table, or a fenced code block, and
nowhere else. Do not use a colon where an em dash used to be.

Fourth, **no overused words or patterns.** The banned list lives in
`build/scripts/lint/rules/ai-tells-words.txt`, every inflection included.
Sentence shapes such as "It's not X, it's Y" and "No X. No Y. Just Z" are
banned too. A control whose label happens to be on the list is written in
straight double quotes, which the linter exempts.

Fifth, **bullet lists are capped.** At most five items per list, at most
two lists per H2 section. Longer enumerations become prose or a table.

The linter enforces these rules with `em-dash.js` (an error), `semicolon.js`,
`sentence-colon.js`, `ai-tells.js`, and `bullet-cap.js`.

## Written identity

The app is **Lungfish Genome Explorer**. Spell it out at first mention in
every chapter body, then write **LGE**. **Lungfish** alone names the research
collaborative (the **Lungfish Research Collaboratory**), never the app. The
installed preview build is "Lungfish Preview.app" and may be named that way
inside quotes or code. Never `LUNGFISH`, `LungFish`, `Lung Fish`, or lowercase
`lungfish` in prose. The linter enforces this with `app-name.js`.

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

## Chapter template (2026-09 campaign)

Chapters follow this order. Concept-only chapters use the first two sections
and whatever else applies.

1. `## What it is`. The concept in two to four short paragraphs. Every
   term is glossed the first time it appears in the chapter. The reader is
   an undergraduate who has taken genetics and never opened a terminal.
2. `## Why you would do this`. The biological motivation, tied to the
   chapter's fixture.
3. `## Before you start`. What must already be in the project, which tool
   pack, whether Docker Desktop is needed, how long the example takes.
4. `## Procedure`. Numbered steps, exact menu path, one action per step,
   a `<!-- SHOT: id -->` marker wherever the reader needs to see the screen.
5. `## Settings`. One paragraph per setting, in the fixed shape below,
   covering every setting `parameters.yaml` lists for the chapter's
   `parameters_refs`.
6. `## Reading the results`. What appears in the viewport and the
   Inspector, what each number means, worked against the fixture.
7. `## What good looks like`. The checks to apply before trusting the
   result.
8. `## On the command line`. One shell block that reproduces the
   procedure.

Each Settings entry is one paragraph that begins with the control's label
in bold with a period inside the bold. The paragraph then has three
sentences in this order. What it does, what the default is and why, when
to change it.

    **Minimum read length.** Discards reads shorter than this after
    trimming. The default is 50 bases, long enough to map uniquely on most
    genomes. Lower it for very short amplicons, raise it when adapters
    leave many short fragments.

When the setting has a command-line flag, the entry may carry a fourth
sentence that names it, in the fixed form "On the command line this is
`--flag`." When the setting has no flag, the fourth sentence may say "This
setting has no command-line flag." Nothing else goes in a fourth sentence,
and the full flag list for every command lives in
`chapters/appendices/cli-reference.md`, not in the chapter.

    **Minimum read length.** Discards reads shorter than this after
    trimming. The default is 50 bases, long enough to map uniquely on most
    genomes. Lower it for very short amplicons, raise it when adapters
    leave many short fragments. On the command line this is
    `--min-length`.

Explanations use the same sentence shapes across chapters. Introduce a
number with what it measures ("Depth is the number of reads covering a
position"), then what a typical value looks like on the fixture, then what
a bad value looks like.

## Fixture references

When a chapter uses a fixture, it names the fixture by its consistency-sheet
name and links the fixture folder on GitHub in the Before you start section,
which is where the `README.md` with the source, license, and citation lives.
Chapters do not reproduce licenses or citation blocks inline, and the build
has no citation macro, so never write `{{ fixtures_refs[] | cite }}`.

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
