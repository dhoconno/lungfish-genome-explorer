# Study-questions design (binding for the question-writing lanes)

Textbook editor lane. First version 2026-09-27, revised the same day after the owner's review.
Inputs read: `docs/user-manual/STYLE.md`, `ARCHITECTURE.md`, `GLOSSARY.md`, `build/mkdocs.yml`,
`build/hooks/shots.py`, `build/scripts/lint-chapter.sh` and every rule under
`build/scripts/lint/rules/`, the four named chapters, and `SYNTHESIS-TEXTBOOK.md` sections 0, 2.1,
5, 6, 7 and 8. Section 8 of that file supersedes parts of section 7 and parts of this spec's first
version, and the changes are folded in below. Where a lane's own review note conflicts with this
file, this file wins for question pages only. It changes nothing inside `chapters/`.

## 0. What the owner's review changed

Five things, all binding.

1. Difficulty is now the page's top-level structure, not a label on each question. Three named
   tiers, each with its own conceptual questions and its own design project scaled to the tier.
2. Every tier gets a design project, not just the hardest one.
3. Design projects never use a demo project. They use other real public data so the work feels
   like a real question.
4. Every design project must be solved in LGE for real before it ships, and the solved project
   plus a write-up goes to instructors. An unsolvable project is rewritten, never shipped.
5. Public pages keep the collapsed Guidance blocks, and a private instructor bank is produced
   alongside them.

## 1. Where the pages live

Decision: one page per chapter, mirroring the chapter tree.

```
docs/user-manual/study-questions/index.md
docs/user-manual/study-questions/<part-dir>/<chapter-stem>.md
```

The part directory and chapter stem are copied exactly, so
`chapters/03-reads/04-trimming-and-filtering.md` is answered by
`study-questions/03-reads/04-trimming-and-filtering.md`. The mapping is mechanical, so a script
can check that every chapter has a page and no page is an orphan, and no chapter file moves,
which keeps ARCHITECTURE rule 1 intact.

Rejected alternatives. One glossary-style page for the whole manual fails on size: 69 pages at
nine questions each with guidance is far longer than GLOSSARY.md, and the glossary works as one
page only because readers arrive by anchor and read one entry. One page per part gives a teacher
no unit smaller than a part and makes the per-chapter link an anchor into a long page. Questions
inside the chapters was ruled out by the owner and by chapter length.

## 2. Nav, the PDF, and the in-app surface

Nav: one top-level **Study Questions** section, placed last, after **Reference**. The index page
first, then one sub-section per part using the part's nav label from SYNTHESIS 2.1, each entry
titled with the chapter's nav title. Lane A adds the block; the ready-to-paste version is in
`STUDY-QUESTIONS-NAV-AND-LINKS.md`.

Placing the section last keeps the reading path through the manual unbroken and keeps the PDF's
part structure intact.

PDF: no config change needed. `mkdocs-with-pdf` walks the nav, so the section becomes the final
part with `toc_level: 3` showing the per-part sub-sections. Guidance blocks are `<details>`, which
the PDF renderer prints expanded. That is right for a printed study guide, and the index page says
so.

In-app help: question pages get no `help_id` and are not added to `help-ids.yaml`. Nothing for the
Code Cartographer to do.

## 3. The one-line chapter link

Each chapter's `## Next` gains exactly one sentence, as its final paragraph, after the
nav-successor sentence that ground rule 4 requires.

```markdown
To check your understanding of this chapter, work through [Questions on <Chapter Nav Title>](../../study-questions/<part-dir>/<chapter-stem>.md).
```

`## Next` rather than the chapter top, because the questions are summative: a reader who meets
them first treats them as a study guide for reading, which changes what the chapter is for. The
relative depth is always `../../`, since every chapter sits two levels below the manual root.

Appendices get pages on the same convention, except `appendices/cli-reference` (excluded by
SYNTHESIS 7), `appendices/keyboard-shortcuts`, `appendices/tool-versions` and
`appendices/bibliography`, which are lookup tables. `chapters/README.md` gets nothing. That is 62
chapters plus 7 appendices, so 69 pages plus the index.

## 4. Page structure

Fixed, so a reader who has seen one page can navigate any other.

```markdown
---
(frontmatter, section 5)
---

(two paragraphs: what the page is, that nothing is answerable by search, which tier to pick,
a link to the index, and one sentence on the design projects and the packs they need)

## Beginner
(one line: who it is for, what it assumes, how guided the project is)
### Question B1. <name>   **Explain.** About n minutes.
### Question B2. …
### Question B3. …
### Design project B4. <name>   **Design, guided.** About n minutes, every step given.

## Intermediate
### Question I1. … I2. … I3. …
### Design project I4. <name>   **Design, partly guided.** About n minutes.

## Advanced
### Question A1. … A2. … A3. …
### Design project A4. <name>   **Design, open-ended.** About n minutes.

## For instructors
(one paragraph: that numbers can be varied, that substitutes exist, that keys exist)
```

Every question and project carries a collapsed Guidance block as its last element. Question
numbering is tier-lettered (B, I, A) so a teacher can say "do I1 to I4" without ambiguity.

## 5. The three tiers

| Tier | Who it is for | What it assumes | Its design project |
|---|---|---|---|
| Beginner | A reader who has just finished the chapter | The chapter and nothing more | Guided. Every step written out, small record, under an hour |
| Intermediate | A reader who wants to work with real data | Beginner, plus comfort with the chapter's main procedure | Partly guided. Goal and route given, settings and order left open |
| Advanced | A reader who wants to judge fitness for purpose | Everything above, plus willingness to reach a negative conclusion | Open-ended. A requirement is stated, the method is the reader's |

Each tier's conceptual questions carry a verb from the old four-level scheme, now used as a
per-question label rather than as the page's structure: Explain, Apply, Analyse. The Design label
belongs to the project. A Beginner tier leans on Explain and Apply, Intermediate on Apply and
Analyse, Advanced on Analyse and Explain-at-depth.

Writers must not let a tier drift upward. The owner's review was that the first pilots were
frustratingly hard for new learners, so the test for a Beginner question is whether a reader who
has read the chapter once and taken no notes can start it without rereading.

## 6. Question types that resist a text search

Eight shapes, all search-proof. A page uses at least four.

1. Predict an outcome, then explain the mechanism.
2. Interpret a result the chapter does not show, given as a table, a log line, or a described screen.
3. Diagnose a failed or misleading run, naming more than one cause where more than one exists.
4. Calculate on new numbers using a convention the chapter states.
5. Compare tools or settings for a scenario the chapter's table does not cover.
6. Transfer to a different organism, gene, or data type.
7. Design an experiment and state what would falsify it.
8. Hands-on LGE project with a defined deliverable.

Banned: anything answerable by quoting a definition, "what is the default of X", "list the six
operations", and any question whose answer is a single number printed in the chapter.

## 7. How design projects specify data

Binding rules.

Data is real public data named by accession with its version, and never a demo project. The demo
projects are what the chapter's own procedure uses, so reusing them tests recall of the chapter
rather than transfer.

Every accession is verified by an actual fetch (NCBI esummary or efetch, or the ENA browser API)
before the page ships, and the fetched length goes into `datasets` in the frontmatter with the
date. Discovery metadata is not verification, the rule `demo-data.md` set for the primer fixtures.
For allele-level records, also confirm the record's own `/allele` qualifier, since title text and
qualifier can disagree.

Size ceiling: everything one question downloads totals under about 100 MB and runs on a laptop in
under the stated time. Sequence records and small read slices qualify. Whole genomes, large SRA
runs and anything needing a Kraken 2 standard database do not, so a chapter whose subject needs
such data gets a design project on a small slice or a different question.

Each project ends with an explicit "Hand in" sentence. The default shape is a table, one
screenshot, and a paragraph.

A project names any plugin pack it needs beyond what the chapter already required.

## 8. The answer-key requirement

Every design project is solved in LGE for real by its writer, before the page ships. This is what
makes the tier promise honest, and it caught two real defects during the pilot work.

### How to run

Use the installed Preview app's CLI at
`/Applications/Lungfish Preview.app/Contents/MacOS/lungfish-cli`, with the normal tool root, which
these runs only read from. Never mutate `~/.lungfish`. Where a run would write to the tool root,
APFS-clone it to scratch with `/bin/cp -Rc` and set `LUNGFISH_CONDA_ROOT`, but see the trap below
before cloning. For a step that exists only in the window, run the CLI equivalent and say so in
the write-up, naming the GUI step it stands for.

Two traps found on 2026-09-27, both worth knowing before starting.

A varVAMP design needs the bundled primer-design adapter, which a bare development binary of the
CLI does not carry, and it needs the tool root holding the upstream source verification record. Run
against a cloned conda root it fails the adapter contract after varVAMP itself has already
succeeded, which reads as a tool failure and is not one. Run varVAMP from the installed app's CLI
against the real tool root.

`lungfish-cli convert` fails with a provenance generation mismatch when the working directory is
reached through a symlink, which includes `/tmp` on macOS, because it resolves the path to
`/private/tmp` and then compares against `/tmp`. Work in a real path such as a folder under the
home directory. Both items are routed as code findings in the lane report.

### What to stage, and where

Locally, under the scratchpad, in exactly this layout. The orchestrator commits and pushes to the
private repo `dhoconno/lungfish-manual-instructor`, which mirrors the same layout.

```
scratchpad/instructor-staging/answer-keys/<part>/<chapter-stem>/<tier>/<Project Name>.zip
scratchpad/instructor-staging/answer-keys/<part>/<chapter-stem>/<tier>/SOLUTION.md
scratchpad/instructor-staging/bank/<part>/<chapter-stem>.md
```

No Git LFS is available, so every zip stays under 50 MB. If a solved project exceeds that, stage a
build recipe plus a result summary instead of the project, and say in `SOLUTION.md` why and what
the recipe reproduces. The pilot projects are 40 KB to 656 KB, so the limit binds only on projects
carrying reads or databases. Exclude `.tmp` and `.DS_Store` from every zip.

`SOLUTION.md` holds the data with verification dates, the exact commands with run times, the key
numbers as a table, what a correct submission shows, acceptable variations, and notes for the
instructor. It names the CLI version used, because a preset or default may change between builds.

The private bank entry per chapter holds fuller answers for the conceptual questions, a variant
table per tier so a graded set can differ from the published one, verified substitute records for
each design project, and marking notes. It never enters the manual and is never linked.

Question pages never link to keys or to the bank. The link is a frontmatter `answer_keys` list of
ids, which is how an instructor asks for the right one.

A design project that cannot be solved is rewritten or dropped. Recording why in the lane report is
required, because an unsolvable project usually means either the data was wrong or the feature does
not do what the chapter implies, and the second is a docs finding.

## 9. Frontmatter

Question pages are not chapters, so `frontmatter.js` and `settings-coverage.js` skip them (both
return early outside `/chapters/`, verified by reading the rules). They carry their own block.

```yaml
---
title: Questions on <Chapter Nav Title>
page_type: study-questions
chapter_id: <the chapter's own chapter_id, verbatim>
checked_against: "2026.9.52"
tiers:
  beginner: {questions: 3, design_minutes: 40}
  intermediate: {questions: 3, design_minutes: 60}
  advanced: {questions: 3, design_minutes: 120}
datasets:
  - accession: NG_011806.1
    what: F5 RefSeqGene
    source: NCBI Nucleotide
    size: "81,578 bases"
    tier: intermediate
    verified: 2026-09-27
demo_projects: []
answer_keys:
  - 01-foundations/01-what-is-a-genome/beginner
  - 01-foundations/01-what-is-a-genome/intermediate
  - 01-foundations/01-what-is-a-genome/advanced
glossary_refs: [reference-genome, coordinate]
reader_checked: false
expert_checked: false
---
```

`chapter_id` is the link back and a script can assert it matches the path. `tiers` records the
shape so the orchestrator can see no tier is thin. `datasets` records every accession with the
tier that uses it and the date it was verified, which makes the data rule auditable.
`demo_projects` stays present and is normally empty, so a reviewer can see at a glance that the
no-demo rule held. `answer_keys` lists the three ids. `checked_against` keeps the version out of
prose, so ARCHITECTURE rule 2 holds.

## 10. How many questions per page

Three conceptual questions plus one design project per tier, so twelve items per page. That is the
default and the cap.

A concept-only chapter may drop to two conceptual questions in a tier if there is genuinely not a
third worth asking, and must say nothing about it on the page. A chapter whose data cannot support
a Beginner-scale project may make that project paper-only, and the tier line then says so in one
sentence. No page exceeds three conceptual questions per tier.

Total time per page: about 45 minutes of reading-and-thinking questions per tier, plus the
project's stated time. The two pilots come to 150 and 360 minutes.

## 11. Prose rules that still apply

Everything in STYLE.md, unchanged. No em dashes, no semicolons, no colon joining clauses
mid-sentence, the ai-tells list including "worked example", palette, typography, voice, and the
bullet caps of five items per list and two lists per section.

Two behaviours differ on these pages, both verified by reading the rules.

Chapter frontmatter keys, `shots[]` and `parameters_refs` are not required, and question pages
carry no `<!-- SHOT: -->` markers, since the hook only rewrites markers under `chapters/`. A
question that wants the reader to look at a screen describes it in words.

`app-name.js` applies "spell it out at first mention" only under `/chapters/`, but question pages
do it anyway, because a learner may arrive on a question page first. Both pilots do.

Numbered steps are ordered lists. Keep each question to at most two lists, and put the hand-in as
a sentence rather than a third list.

## 12. Lint change made

One, small, and implemented here.

`bullet-cap.js` counted lists per H2 only. On a tiered page the H2 is a container for several
independent H3 questions, so three questions each with one list tripped a cap meant to stop a wall
of bullets inside one stretch of prose. The counter now resets at H3 as well as H2, which matches
the rule's intent, since an H3 starts such a stretch just as an H2 does.

Changed: `docs/user-manual/build/scripts/lint/rules/bullet-cap.js` (reset on depth 2 or 3, message
reworded, comment explaining why). Test changes: the existing bullet-cap test's expected wording,
plus a new test and fixture `fixtures/bullet-cap-h3.md` proving two lists under each of two H3
subsections of one H2 do not fire. All 16 rule tests pass.

Regression check: every chapter and appendix under `chapters/` plus the three question pages lint
clean in strict mode after the change, with the single pre-existing warning on
`chapters/README.md`, which is a contributor index and not a chapter.

No other lint change was needed. The per-list cap of five and the ai-tells list both caught real
problems in my own drafts and were left alone.

Recommended but not implemented: a campaign checker `build/scripts/campaign/check-study-questions.mjs`
asserting one page per chapter, `chapter_id` matching the path, three tiers each with a design
project, every `datasets[].verified` present, `demo_projects` empty or justified, and `answer_keys`
matching the tiers. It belongs beside `check-links.mjs` rather than in the chapter linter, whose
contract is chapter files. Deferred because the writing lanes have not run and it would have
nothing to check.

## 13. Writer and reviewer workflow for 69 pages

Question writing starts only after a chapter's revision lane has landed, since a question testing a
number the revision changed is wrong on arrival. Revision lanes add only the one-line `## Next`
link.

One writer per part, eleven writers, each writing every page for their part in one pass so tiers
and voice stay consistent. A writer reads the revised chapter, verifies every accession, and solves
all three design projects before handing over.

Then two checks per page.

The undergraduate reader check asks one thing per question: could this be answered by finding a
sentence in the chapter? It also checks that the Beginner tier is genuinely approachable for a
reader who has read the chapter once, which is the owner's specific concern. The reader reports and
never edits. `reader_checked: true` when clean.

The subject-expert check is correctness. Every number in every Guidance block is recomputed, every
accession refetched, every claim about LGE checked against the release candidate, and every design
project's key numbers reproduced from the staged project. `expert_checked: true` when clean.

Both checks run per page, batched per part, so eleven handoffs each.

Lint gate before either check: `LUNGFISH_MANUAL_STRICT=1 bash docs/user-manual/build/scripts/lint-chapter.sh <page>`
with no issues, plus one local `mkdocs build` per part.

Definition of done: 69 pages plus the index, all lint-clean, both flags true per page, every design
project solved with its key and bank entry staged, the nav block merged by lane A, every chapter
carrying its link, and one table in the lane report listing every accession with its verification
date and every answer-key zip with its size.

## 14. Pilots delivered

- `docs/user-manual/study-questions/index.md`
- `docs/user-manual/study-questions/01-foundations/01-what-is-a-genome.md`, 9 conceptual questions
  plus 3 design projects across the three tiers.
- `docs/user-manual/study-questions/10-primer-design/04-designing-qpcr-and-dpcr-assays.md`, same
  shape.

All accessions fetched and lengths recorded on 2026-09-27: `NM_000518.5` 628, `NG_011806.1` 81,578,
`NG_016465.4` 257,188, `NC_001807.4` 16,571, `NM_001101.5` 1,812, `NM_000344.4` 1,482,
`NM_017411.4` 1,482, and eleven HLA records each confirmed with its own `/allele` qualifier.
dbSNP placements used in guidance were read from the refsnp API (rs334, rs33930165, rs33950507,
rs6025, rs113993960). Coding-position arithmetic was computed from each record's own CDS join.

All six design projects solved. Staged answer keys, with zip sizes: genome tier projects 52 KB,
84 KB and 132 KB; qPCR tier projects 40 KB, 160 KB and 656 KB, plus an 8 KB oligo-by-allele
mismatch table for the Advanced project. Every zip is far under the 50 MB limit.

Both pages and the index lint clean in strict mode, and a local `mkdocs build` with the proposed
nav rendered all three with working cross-links and collapsed guidance.

## 15. The discriminating-sites tooling

`msa discriminating-sites` and an MSA highlight for the same are in development. No question on any
page may depend on them yet, and the pilots do not: the Advanced qPCR project's specificity check
is done by reading the alignment or by varVAMP's own BLAST screen. Once the tooling ships, the
Advanced project on that page is the first place to use it, and the corresponding paragraph in the
answer key already says so. Later writers may use it freely.

## 16. Open questions for the owner

1. Should the three excluded lookup appendices (keyboard shortcuts, tool versions, bibliography)
   really get no page, given that the CLI reference is already excluded by your earlier answer?
2. The instructor bank and answer keys assume instructors can be given access to a private repo.
   Is there a request route for a teacher outside the collaborative, or is this for internal use
   only for now?
3. Two CLI defects surfaced while solving the pilots, both routed in the lane report. Do you want
   them filed as code items in this campaign, or handled separately?
