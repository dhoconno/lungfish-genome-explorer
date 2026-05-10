# Focus group personas (post-fix re-evaluation, 2026-05-09)

This file persists the personas used by the post-fix re-evaluation focus
groups so future sessions can resurrect them by name and stay consistent
across review rounds. The personas are the same ones used by the
foundations and Part II focus groups (`docs/user-manual/reviews/foundations/`
and `docs/user-manual/reviews/part-ii/`); the only difference for the
post-fix round is what they are evaluating: not the chapter prose, but the
in-app behavior delivered by the 22-commit fix sweep.

Four groups, five personas each. Each group reads the same evidence (CLI
transcripts, captured screenshots, manifest verdicts) and produces a
verdict per issue: implementation matches what their persona wanted,
partial, or fails.

## Group 1 — Undergraduates

| Persona | Background | What they care about |
|---|---|---|
| Maya Chen | Year 2 biochemistry, summer research | Plain-English documentation, can the GUI walk me through |
| Jamal Rivera | Year 3 microbiology, intro to bioinformatics class | Default settings should be sensible; warnings should explain |
| Priya Iyer | Year 4 molecular biology, honors thesis | Reproducibility for thesis chapter |
| Tomás Herrera | Year 4 epidemiology, public-health track | SARS-CoV-2 surveillance examples |
| Aisha Bello | Year 2 computer science, bioinformatics minor | Headless / scriptable paths |

## Group 2 — PhD students

| Persona | Background | What they care about |
|---|---|---|
| Daniel Okafor | Year 4 virology, flu reassortment | Phased calls, reassortment workflows |
| Rachel Sturm | Year 3 genetics, human germline | Sample-aware filters, joint genotyping |
| Tomás Herrera (PhD track) | Year 5 epidemiology, SARS-CoV-2 lineages | Wastewater, lineage demixing, surveillance |
| Aiko Tanaka | Year 4 postdoc-track, Snakemake builder | Workflow portability and provenance |
| Sara Linhardt | Year 5 PhD + part-time bioinformatics consultant | Clinical reproducibility, audit trail |

## Group 3 — Early-career scientists

| Persona | Background | What they care about |
|---|---|---|
| Diana Reyes | Clinical microbiology technologist | Per-user attribution, project locks |
| Sam Okafor | Wastewater-surveillance scientist | Database update tracking, multi-site provenance |
| James Okonkwo | Surveillance PI | Freyja (P1 in their world), tool comparisons |
| Lin Patel | Tool developer (Medaka/Clair3 follower) | Active-tool pinning, alternative callers |
| Margaret Chen | Senior staff scientist, BAM / CIGAR fluency | Display fidelity, annotation correctness |

## Group 4 — Power users

| Persona | Background | What they care about |
|---|---|---|
| David Okafor | Sequencing-company bioinformatician (CZ-ID, NAO-MGS) | First-class importers, headless CI |
| Marcus Chen | Lab PI, methods-section author | Provenance Methods export quality, banner |
| Chris Okafor | Genomics core manager | Hardware floors, shared conda root, billing |
| Lin Patel (power-user track) | Tool developer | Workflow versioning, signed provenance |
| Sara Linhardt (power-user track) | Bioinformatics consultant | Container image export, lockfiles |

Some personas straddle two groups by design (Tomás, Lin, Sara). Their
viewpoints are the same; the second appearance reflects a different
question they would ask in a different context.

## Stable persona references for future sessions

When a future session needs to dispatch a focus group on a specific
deliverable (a chapter revision, a fix to a docs-XXXa follow-up, a new
feature), use the persona names above and reference this file. Persona
identities are stable; their concerns are stable. What changes is the
evidence they review.
