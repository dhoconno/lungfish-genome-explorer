# Manual campaign: primer design part and "Choosing a tool" guidance

Status: approved by the owner 2026-09-26. Plan files are exempt from the prose lint.

## Goals

1. A new manual part, `10-primer-design/`, that teaches PCR primer design and shows every
   LGE primer tool on real macaque MHC data from a new ninth demo project.
2. A "Choosing a tool" section in every chapter that offers more than one tool, plus a
   pack-by-pack overview in `01-foundations/07-plugin-packs.md`, so a reader who has never
   used the tools learns why they would pick one over another (minimap2 vs BWA-MEM2, Olivar
   vs PrimalScheme3, and so on).
3. Prose that works as a reference and as a guide for newcomers: the reader should learn how
   sequence analysis works in general as well as how to run the step in LGE.

## Owner decisions (2026-09-26)

- Example data for primer design: a NEW demo project `primer-design` (macaque MHC), built
  from public ENA/GenBank records (ENA terms of use), registered in the app in the next
  Preview release.
- Screenshots: write and review the prose first. Capture permissions (Preview, Finder, full
  screen control) were granted up front on 2026-09-26.
- Keep workflow packages; only the graphical builder was removed.

## Binding rules

`docs/user-manual/STYLE.md`, the prose rules memory (no em dashes, semicolons, mid-sentence
colons, AI-tell words, "Lungfish Genome Explorer (LGE)" then "LGE", bullet caps), human or
macaque examples, every setting explained, strict lint must report no issues. Chapter files
are never renamed or moved (ARCHITECTURE rule 1); new files are fine. One owning chapter per
shared concept, glosses and links elsewhere. Screenshots from /Applications/Lungfish
Preview.app, projects saved under ~/Desktop/lge-docs/.

Model note: the owner prefers Opus 4.8 for prose; this harness offers only Opus 5.5 and
Fable, so authors are Opus 5.5 under Fable-level review by the orchestrator.

## New part: 10-primer-design

1. `01-what-is-primer-design.md`: PCR, primer properties (length, Tm, GC, 3' end, hairpins,
   dimers), conserved sites and degenerate bases in an alignment, amplicon size, pools and
   tiling, qPCR probes, in-silico checks vs bench validation. Owns these concepts.
2. `02-designing-a-pcr-assay.md`: one primer pair with Primer3 on a single sequence and on
   an alignment template (macaque MHC example).
3. `03-designing-a-tiled-amplicon-scheme.md`: PrimalScheme3, Olivar, varVAMP tiled on the
   same Mamu-A1 alignment. How each method works, a comparison table from real runs,
   "Choosing a tool", and tuning (varVAMP threshold as k-of-N sequences, amplicon length,
   single-chain tiling).
4. `04-designing-qpcr-and-dpcr-assays.md`: varVAMP qPCR mode (primers plus probe), e.g. an
   allele-lineage detection assay, and what a probe adds.
5. `05-reviewing-and-ordering-primers.md`: the primer analysis viewer (Overview, Results,
   Binding inspection), coverage notes, exporting and ordering.

The existing appendix `appendices/primer-schemes.md` (bundle format) and
`04-alignments/03-primer-trimming.md` stay; they get links.

## Choosing-a-tool sweep (existing chapters)

Owners by part: reads (trimming, decontamination, read processing, ONT), alignments
(mapping), variants (callers), human germline (GATK vs others), classification (Kraken2,
EsViritu, TaxTriage, NAO-MGS, Freyja, NVD, 12S), assembly (SPAdes, Flye, hifiasm),
sequences (MAFFT modes, tree methods), genotyping (amplicon vs full-length). Each section:
what problem the tools solve, how each works in one paragraph, when each wins, when to use
the other, with bibliography citations. Plugin packs chapter gets the overview table.

## Phases

0. Research (parallel, read-only): primer-design fidelity inventory (every entry point,
   dialog setting, parameters.yaml entry, CLI command); demo data selection with ENA
   accessions; tool-choice research briefs with citations per part.
1. Demo project `primer-design`: add to build_demo_project.py and README, build it, run
   every primer analysis with the Preview CLI to get real numbers for the chapters.
2. Authoring: primer part chapters; choosing-a-tool sections per part; plugin packs table;
   GLOSSARY, bibliography, features.yaml, parameters.yaml, help-ids, mkdocs nav.
3. Review per chapter: two domain experts (genomics, sequencing), scientific editor,
   manual-fidelity-reviewer, undergraduate reader team plus synthesis, revision, strict
   lint, brand-copy-editor.
4. Screenshots with the granted permissions; SHOTS/recipes; media repo and media.lock.
5. Integrate: merge docs, publish the demo zip to the demo-projects prerelease, update the
   bundled demo manifest, next Preview release.

Delete this plan when the campaign ships.
