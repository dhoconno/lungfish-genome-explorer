# Fixtures

Real-world, provenance-tracked data used by chapters and tests. Fixtures are
docs-only. They are never imported from app unit tests, and they are never
modified in place by the agents.

## Size discipline

Per-file cap is 10 MB. Per-fixture-set cap is 50 MB. Files larger than these
caps ship a `fetch.sh` that pulls from a pinned NCBI or ENA URL and caches
locally.

## Required metadata

Every fixture set has a `README.md` that records source (accession, DOI, or
URL), license (must permit redistribution in this repo), a citation block in
BibTeX or equivalent format that chapters can include, total and per-file
size, and notes on internal consistency such as whether reads align to the
included reference and whether variants were called from those reads.

## Pathogen tiers

Chapters choose fixtures from this ordered list unless a specific reason
pushes them elsewhere (deviations require one sentence of justification in
the fixture README).

1. **SARS-CoV-2**: monopartite ~30 kb RNA. Default workhorse.
2. **Influenza A**: eight-segment genome. Multi-sequence pedagogy.
3. **HIV-1**: overlapping ORFs, spliced transcripts (Tat, Rev). Exon/intron pedagogy.

## Sets

`sarscov2-clinical/` is the pilot fixture, a clinical isolate of SARS-CoV-2.
It is used by chapter 04-variants/01-reading-a-vcf.
