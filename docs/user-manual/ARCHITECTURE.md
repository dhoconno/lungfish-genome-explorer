# ARCHITECTURE — Lungfish User Manual

**Ownership:** Documentation Lead only.

This file holds the final TOC, audience mapping, prerequisite graph, and the
rationale behind every chapter placement. It is populated by the Documentation
Lead subagent at gate 1 for each chapter.

## Status

Sub-project 1 delivers one chapter (`04-variants/01-reading-a-vcf`). The full
TOC is drafted in the design spec (§9) as a starting brief and is finalised
here as sub-project 2 progresses.

## Pilot chapter

- `chapters/04-variants/01-reading-a-vcf.md`
  - audience: bench-scientist
  - prereqs: none (pilot intentionally stands alone)
  - fixture: `sarscov2-clinical`
  - rationale: VCF is one of the first file formats a bench scientist
    encounters when moving from reads to interpretable results. Clinical
    isolate keeps the VCF clean (single organism, high AF variants) so the
    reader's first exposure to VCF is unambiguous.
