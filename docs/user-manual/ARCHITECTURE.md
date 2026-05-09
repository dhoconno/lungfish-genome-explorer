# ARCHITECTURE, Lungfish User Manual

**Ownership:** Documentation Lead only.

This file holds the final TOC, audience mapping, prerequisite graph, and the
rationale behind every chapter placement. It is populated by the Documentation
Lead subagent at gate 1 for each chapter.

## Status

Sub-project 1 delivers one chapter (`04-variants/01-reads-to-variants`). The full
TOC is drafted in the design spec (§9) as a starting brief and is finalised
here as sub-project 2 progresses.

## Pilot chapter

The pilot is `chapters/04-variants/01-reads-to-variants.md`, targeted at the
bench-scientist audience. It has no prereqs: the pilot intentionally stands
alone so sub-project 1 can exercise the full pipeline without dependency on
chapters that do not yet exist. It uses the `sarscov2-srr36291587` fixture.

Rationale for placement: the first variants chapter now follows a complete
reads-to-variants path, starting from public SARS-CoV-2 reference and read
accessions, then mapping, primer trimming, variant calling, and variant review.
That keeps Claude's prose anchored in a reproducible workflow instead of a
prebaked VCF import.
