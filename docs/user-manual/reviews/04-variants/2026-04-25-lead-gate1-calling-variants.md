# Lead gate 1: 04-variants/02-calling-variants-from-a-bam

Date: 2026-04-25

## Chapter plan

Audience: bench-scientist. The reader has finished
`04-variants/01-reading-a-vcf` and can read REF, ALT, FILTER, and GT in a
VCF someone handed them. This chapter closes the loop: the reader produces
that same `variants.vcf.gz` themselves from the fixture's BAM. Estimated
length: 10 minutes. Fixture: `sarscov2-clinical`, reused verbatim. The
chapter intentionally points at the same artifact the previous chapter
opened, so the reader recognises the output and can compare row-for-row.

The conceptual arc is four beats. First, the BAM is the input that already
exists in the fixture. Second, because the fixture reads come from a tiled
amplicon protocol, primer-derived bases at read ends would inflate
allele-frequency estimates and have to be trimmed before calling. Third,
the reader runs `Call Variants` with iVar against the trimmed BAM. Fourth,
the resulting VCF lands in the variant browser and matches the file the
prior chapter dissected. Primer trimming is presented as a precondition for
iVar (the dialog enforces it), not as a generic preprocessing step.

## Shots

`primer-trim-dialog` shows the Primer Trim sheet launched from the
alignment Inspector with the QIASeqDIRECT-SARS2 scheme selected. It earns
its place because primer trimming is the conceptual hinge of the chapter:
the reader has to see that the primer scheme is a separate bundle they
pick, not a hidden default. `variant-call-dialog` shows the Call Variants
sheet with iVar selected against the freshly trimmed track, and surfaces
the primer-trim acknowledgement that iVar requires. It anchors the
Procedure section. `variant-table-fresh-call` shows the produced VCF in the
variant browser. It is the payoff shot, used in Interpretation to let the
reader confirm the new track matches the VCF read in chapter 01. Three
shots, no Operations Panel screenshot: the panel is an implementation
detail at this audience tier and does not earn a slot.

## Prereq-graph placement

This chapter slots directly after `04-variants/01-reading-a-vcf` in the
variants chain. The reader needs VCF literacy from chapter 01 to interpret
the output, which is why that is the listed prereq.

The chapter has one missing prereq that should land before this one ships
to readers: an alignment chapter under `03-alignments/` that introduces
BAM, sorted-and-indexed alignments, and the Inspector. The current draft
treats the BAM as a given fixture artifact and points at the alignment
Inspector without first explaining what an alignment track is. That is
acceptable for a stub but is a real gap for the published reader. Two
options for the Educator. First, write this chapter assuming a future
`03-alignments/01-opening-a-bam` chapter and add a stub link. Second, fold
a half-paragraph BAM primer into `## What it is` so the chapter stands
alone until alignment chapters land. Recommend option two for the body
draft, with the prereq updated to include the alignment chapter when it
ships.

Two further notes for downstream agents. The Cartographer needs to add
`variants.call` and `bam.primer-trim` features to `features.yaml` (entry
points: `Inspector > Call Variants…` and `Inspector > Primer Trim…`,
sources under `Sources/LungfishCLI/Commands/VariantsCommand.swift` and
`Sources/LungfishCLI/Commands/BAMCommand.swift`, plus the dialog states in
`Sources/LungfishApp/Views/Inspector/`). The chapter's `features_refs`
currently lists only `viewport.variant-browser` because the lint requires
every entry to resolve. Update the chapter once those feature ids exist.
The Educator also needs to add four glossary entries: `variant-caller`,
`primer-trim`, `primer-scheme`, and `amplicon`. They are listed in
`glossary_refs` so the lint will catch the omission until the entries are
written.

## Status

Ready for Educator to write the body. Approved to proceed, with two
caveats noted above. First, the Educator should fold a BAM primer into
`## What it is` until an `03-alignments/` chapter exists. Second, the
Cartographer should add `variants.call` and `bam.primer-trim` to
`features.yaml`, and the Educator should add the four new glossary
entries, before this chapter reaches gate 2.
