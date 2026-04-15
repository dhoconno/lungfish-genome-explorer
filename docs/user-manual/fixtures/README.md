# Fixtures

Real-world, provenance-tracked data used by chapters and tests. Fixtures are
docs-only — never imported from app unit tests and never modified in place by
the agents.

## Size discipline

- 10 MB per file maximum.
- 50 MB per fixture set maximum.
- Files larger than these caps ship a `fetch.sh` that pulls from a pinned
  NCBI/ENA URL and caches locally.

## Required metadata (`README.md` in every fixture set)

- Source (accession, DOI, URL).
- License — must permit redistribution in this repo.
- Citation block (BibTeX or equivalent) that chapters include.
- Total size, per-file size.
- Notes on internal consistency (reads align to reference, variants called from
  reads, etc.).

## Pathogen tiers

Choose fixtures from this ordered list unless a chapter has a specific reason
otherwise (deviations require one sentence of justification in the fixture
README):

1. **SARS-CoV-2** — monopartite ~30 kb RNA. Default workhorse.
2. **Influenza A** — eight-segment genome. Multi-sequence pedagogy.
3. **HIV-1** — overlapping ORFs, spliced transcripts (Tat, Rev). Exon/intron
   pedagogy.

## Sets

- `sarscov2-clinical/` — pilot fixture. Clinical isolate of SARS-CoV-2.
  Used by chapter 04-variants/01-reading-a-vcf.
