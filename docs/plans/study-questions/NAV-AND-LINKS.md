# Routed edits for the study-questions pages

This lane edited no chapter file and no `build/mkdocs.yml`. The two edits below belong to other lanes.
Design rationale is in `STUDY-QUESTIONS-SPEC.md`.

## Routed to lane A: `docs/user-manual/build/mkdocs.yml`

Append this section to the end of the `nav:` block, after `- Reference:`. Shown with the two pilot pages
only. The question-writing lanes add one line per chapter as their pages land, keeping each part's entries in
the part's nav order and titling each entry with the chapter's nav title.

```yaml
  - Study Questions:
    - How to Use the Study Questions: study-questions/index.md
    - Foundations:
      - What Is a Genome: study-questions/01-foundations/01-what-is-a-genome.md
    - Primer Design:
      - Designing qPCR and dPCR Assays: study-questions/10-primer-design/04-designing-qpcr-and-dpcr-assays.md
```

Nothing else in `mkdocs.yml` changes. `pymdownx.details`, `admonition`, `attr_list` and `md_in_html` are
already enabled, which is everything the guidance blocks need, and `mkdocs-with-pdf` picks the section up
from the nav with no config change.

Optional, and this lane's recommendation rather than a requirement: add `.guidance` styling to
`docs/user-manual/css/extra.css` so the block reads as an aside rather than plain body text. Warm Grey rule,
Cream background, Space Grotesk on the summary line. Lane A owns that file.

## Routed to lane A (Foundations): `chapters/01-foundations/01-what-is-a-genome.md`

Add as the last paragraph of `## Next`, after the existing sentences:

```markdown
To check your understanding of this chapter, work through [Questions on What Is a Genome](../../study-questions/01-foundations/01-what-is-a-genome.md).
```

## Routed to the Part 10 lane: `chapters/10-primer-design/04-designing-qpcr-and-dpcr-assays.md`

Add as the last paragraph of `## Next`, after the existing sentences:

```markdown
To check your understanding of this chapter, work through [Questions on Designing qPCR and dPCR Assays](../../study-questions/10-primer-design/04-designing-qpcr-and-dpcr-assays.md).
```

## Pattern for every other chapter

```markdown
To check your understanding of this chapter, work through [Questions on <Chapter Nav Title>](../../study-questions/<part-dir>/<chapter-stem>.md).
```

The part directory and chapter stem match the chapter's own path, and `../../` is correct from every chapter,
since all of them sit two levels below the manual root.

## Tier anchors, for anyone linking into a page

Each page's tiers render as `#beginner`, `#intermediate` and `#advanced`, and each question as a
slug of its heading, such as `#question-b1-naming-a-position-so-someone-else-can-find-it`. A teacher
assigning one tier can link the tier anchor. Chapters link the page itself, with no anchor, so the
reader picks their own tier.

## Routed to whoever owns STYLE.md: one line of wording

`docs/user-manual/STYLE.md` line 28 describes the bullet cap as "two lists per H2 section". The
linter now counts per H2 **or H3** section (see STUDY-QUESTIONS-SPEC.md section 12, and the rule's
own comment). No chapter changes behaviour, because the new rule is strictly more permissive, and
every chapter still lints clean. Suggested replacement for that clause:

> two lists per section, counting each H2 and each H3 as its own section.

This lane did not edit STYLE.md, since it belongs to another lane and campaign ground rule 6 keeps
STYLE.md out of scope for this revision.
