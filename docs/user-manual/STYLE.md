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
Never write "worked example". Name the thing instead, such as the example
run, the cornea sample, or the demo project.

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

Never use red-amber-green in data viz. Encode severity with Deep Ink weight
and annotation instead. Never place Creamsicle on Peach, and never use
Creamsicle for body text. The linter rules are `palette.js` and `data-viz.js`.

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
must use only these faces. The linter rule is `typography.js`.

## Voice

Six qualities describe the Lungfish voice. It is purposeful, precise and
scientific, trustworthy and calm, actionable, thoughtful, and inclusive and
empowering. It is never hyped and never cold.

Banned patterns the linter flags include `revolutionary`, `breakthrough`,
`powerful`, `cutting-edge`, `AI-powered`, `game-changing`, `unleash`, and
`leverages`. `next-generation` is permitted only when literally referring to
NGS inside a primer. `!` at the end of a body sentence is banned (permitted in
quoted CLI output). Superlative chains such as "most advanced, most accurate,
most…" are banned. The linter rule is `voice.js`.

## Chapter structure

Every chapter opens with a primer heading (`## What it is` or `## Why this
matters`) before any `## Procedure` section. Every chapter has YAML
frontmatter validated by `frontmatter.js`. Every `<!-- SHOT: id -->` marker in
the body has a matching entry in the frontmatter `shots[]` list and vice
versa. Every `prereqs[]`, `glossary_refs[]`, `fixtures_refs[]`, and
`features_refs[]` entry resolves to an existing target. The linter rules are
`frontmatter.js` and `primer-before-procedure.js`.

## Chapter template (2026-09 campaign)

Chapters follow this order. Concept-only chapters use the first two sections
and whatever else applies.

| Order | Section | What it holds |
|---|---|---|
| 1 | `## What it is` | The concept in two to four short paragraphs. Every term is glossed the first time it appears in the chapter. The reader is an undergraduate who has taken genetics and never opened a terminal. |
| 2 | `## Why you would do this` | The biological motivation, tied to the chapter's fixture. `## Choosing a tool` follows it in every chapter that offers more than one tool or mode for the same job (added 2026-09-26, see below). |
| 3 | `## Before you start` | What must already be in the project, which tool pack, which container runtime if any (as [Plugin Packs](chapters/01-foundations/07-plugin-packs.md#tools-that-run-in-containers) states it), and how long the example takes. |
| 4 | `## Procedure` | Numbered steps, exact menu path, one action per step, and a `<!-- SHOT: id -->` marker wherever the reader needs to see the screen. |
| 5 | `## Settings` | One paragraph per setting, in the fixed shape below, covering every setting `parameters.yaml` lists for the chapter's `parameters_refs`. |
| 6 | `## Reading the results` | What appears in the viewport and the Inspector, and what each number means, read against the fixture. |
| 7 | `## What good looks like` | The checks to apply before trusting the result. |
| 8 | `## On the command line` | One shell block that reproduces the procedure. |
| 9 | `## Next` | The chapter that follows in the nav first, then any side trips. |

No task chapter has a `## Troubleshooting` section. Advice that links a
symptom to a setting, such as what to change when a design covers too
little, goes at the end of `## What good looks like`, as a closing paragraph
or an H3 named for the situation, such as "When the design fails". A defect
in LGE itself goes to the known-defects registry in
`chapters/appendices/troubleshooting.md` and nowhere else.

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

## Conventions added in the 2026-09-27 revision

**Procedure headings.** When a procedure has H3 headings, each is a task
phrase that names the tool or the step, such as "Call with bcftools" or
"Open the Call Variants dialog". Never write "Step 3." or "3." in front of
it, because in-app search shows a heading alone. The numbered steps sit
inside the H3 as an ordered list.

**Percentages.** Running prose writes "95 percent". Tables, code, and quoted
screen text write "95%".

**Coordinates.** Positions in prose are 1-based and inclusive, as LGE shows
them on screen. A 0-based value, such as a BED start, appears only in its
own column or in a parenthesis that says it is BED.

**Next.** The `## Next` section names the chapter that follows in the nav
first. The last chapter of a part names the first chapter of the next part
in one sentence that says why a reader would go on.

**On the command line.** Every block uses the path convention in [Reading
an On the command line block](chapters/01-foundations/06-the-lungfish-project.md#reading-a-command-line-block).
It sets `PROJECT` once to the demo project's folder and writes every path
inside the project relative to `$PROJECT`. One sentence before the block
names the CLI Reference section that lists the commands' flags.

**Versions and history.** A chapter never names an LGE build number and
never tells the release history of a feature. The home page names the
version the manual describes, once.

**Figures.** A figure that is still to be drawn is placed with an
`<!-- ILLUSTRATION: id -->` marker at the point where it belongs, and the
chapter frontmatter's `illustrations:` list carries its id and a
one-paragraph brief. The home page, `index.md`, follows the same rule.

## Choosing a tool (added 2026-09-26)

A reader who has never used the tools in a plugin pack should finish this
section knowing which one to pick for their data and why. It teaches the
method, not only the menu.

1. Open with one or two sentences that name the decision and the property
   of the data that settles it, such as read length, error profile, how
   variable the targets are, or whether the genome is large.
2. Give each tool one paragraph. Say how it works in plain terms (for
   example, a mapper that indexes the reference and extends short exact
   matches, or a classifier that looks up every k-mer in a database), what
   data it was built for, what it does well, and where it struggles. Gloss
   every term at first use.
3. Follow with a table with the columns Tool, Built for, Choose it when,
   and Choose something else when. Keep cells short.
4. Close with the choice this chapter's fixture uses and why, and when a
   reader with different data should switch.
5. Cite each tool's paper through `appendices/bibliography.md` and state
   only what the paper, the tool's documentation, or LGE's own behaviour
   supports. Name speed and memory only as rough comparisons LGE users will
   notice. Mention tools LGE does not offer at most once, as context.

A concept that several chapters need, such as what a k-mer is, has one
owning chapter. Other chapters gloss it in one sentence and link there.

## Fixture references

When a chapter uses a fixture, it names the fixture by its consistency-sheet
name and links the fixture folder on GitHub in the Before you start section,
which is where the `README.md` with the source, license, and citation lives.
Chapters do not reproduce licenses or citation blocks inline, and the build
has no citation macro, so never write `{{ fixtures_refs[] | cite }}`.

## Audience tiers

Every chapter declares one tier, which is `bench-scientist`, `analyst`, or
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
