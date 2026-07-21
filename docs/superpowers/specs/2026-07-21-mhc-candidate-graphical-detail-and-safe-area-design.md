# MHC Candidate Graphical Detail and Viewport Safe-Area Design

**Date:** 2026-07-21

**Status:** Approved by the existing B2 detail-pane decisions and the user's request to proceed without another design checkpoint

## Purpose

Finish the graphical detail experience for full-length MHC `_nov` and `_ext` rows and keep the genotype viewport below the macOS project title. Candidate selection must remain instantaneous and must not read BAM, SQLite, FASTA, or GenBank files on the main actor.

## Scope

This tranche changes only the full-length genotype result viewport and the result-bundle loading needed to feed it. It includes:

- a persistent candidate detail component with `Overview / GenBank / FASTA` navigation;
- the already approved B2 canvas-with-facts-rail layout;
- the selected candidate's closest reference record resolved by stable cluster ID from the complete reference-database projection;
- exact candidate FASTA retained during existing asynchronous artifact validation;
- a bounded, reference-relative difference track derived once from persisted `reference_start` and extended `=/X` CIGAR data;
- exon 2/3, other-exon, intron/non-exon, insertion, and deletion location styling when the persisted data supports it;
- candidate identity, support, read-count, closest-reference, alignment, and sample facts;
- reuse of one detail hierarchy across row and cell changes;
- metadata fallback for legacy or incomplete bundles; and
- safe-area top anchors for the viewport content and lens selector.

It does not add a generalized genome viewer, parse BAM on selection, change candidate classification/naming, change Excel, or modify another Lungfish surface.

## Scientific boundary

The existing bundle authoritatively persists candidate identity, support, candidate FASTA, the all-reference closest match, reference annotations, and extended CIGAR. Those values are sufficient for a closest-reference canvas and reference-coordinate mutation/gap locations.

Older bundles do not persist reciprocal alignment strand or a normalized consequence projection. Therefore they must not label an exon SNP as synonymous or nonsynonymous, claim a candidate-specific exon count, or synthesize an authoritative candidate GenBank record. The UI labels the canvas as closest-reference geometry, shows exact candidate FASTA, and exposes the stored closest-reference GenBank record. Unsupported consequence or candidate-annotation facts are shown as unavailable rather than inferred.

The more ambitious consequence, candidate translation, seven-versus-short-eighth-exon, intron-fill sequence, and candidate-specific GenBank work remains a workflow-artifact tranche. It must be generated during analysis with final-path checksums, sizes, and provenance before the UI presents those values as scientific results.

## Data loading

`StreamingFASTAParser` already reads and validates every named candidate sequence off the main actor. It will retain only the required candidate records while hashing them. The total retained payload in the four-sample exemplar is about 70 KB. Un-nameable FASTA remains validation-only and is not retained.

`ONTGenotypeResultBundleData` exposes an immutable stable-cluster-ID sequence index. `ONTMHCReferenceVisualizationArtifact` exposes an immutable candidate-stable-ID reference index built from role assignments. Validation rejects one stable cluster ID mapping to more than one reference record.

The controller builds a bounded candidate presentation index when a result is configured. Selection performs stable-ID dictionary lookups and updates a persistent detail view. It performs no file access and no observation-wide evidence view construction.

## Detail experience

### Overview

The header shows provisional candidate name, stable cluster ID, classification, and closest reference. The graphical side shows the complete closest-reference ruler, sequence, gene, CDS, exon, and reference translation lanes. A separate candidate-difference lane is explicitly reference-relative and never paints reference feature coordinates onto the candidate sequence.

The facts rail shows:

- stable cluster ID and provisional name;
- `_nov` or `_ext` classification and singleton/shared support;
- supporting sample count/IDs, total cluster reads, and selected-sample reads;
- closest reference allele, raw reference ID, and reference molecule class;
- SNP, insertion, deletion, and long-gap totals;
- coverage, identity, MAPQ, and alignment score;
- candidate sequence length/checksum;
- selected matrix comments; and
- an explicit limitation note when consequence/translation projection is unavailable.

### GenBank

The full-width GenBank mode displays the already loaded canonical closest-reference GenBank record and labels it as the closest reference. It does not misrepresent it as a candidate record.

### FASTA

The full-width FASTA mode displays the exact validated candidate sequence with a deterministic header containing stable ID, provisional name, classification, and support summary. It performs no disk read when opened.

### Fallback

If either the candidate sequence or stable-ID closest-reference mapping is unavailable, the pane still shows bounded candidate facts and explains which graphical/document data requires a fresh analysis. It never falls back to one visible row per BAM alignment.

## Safe-area layout

The project window uses `.fullSizeContentView`, so the genotype viewport must anchor its top-level content and visible lens selector to `view.safeAreaLayoutGuide.topAnchor`. Genotype-only mode retains a zero *additional* inset while beginning at the safe-area top. The existing 48-point lens header spacing remains unchanged for haplotyped results.

## Performance and memory contract

- Candidate FASTA and closest-reference records are loaded/indexed once off the main actor.
- Candidate row selection performs no filesystem, BAM, SQLite, FASTA, or GenBank access.
- One candidate detail view is mounted and reconfigured in place.
- Visible view count is independent of BAM alignment count, observation count, and cohort size.
- Repeated candidate selection does not grow descendant count or active constraints.
- The existing bounded selection-state evidence summary remains available to the Inspector without becoming thousands of AppKit rows.

## Verification

- IO tests cover retained validated sequences and stable-ID reference indexing/ambiguity.
- component tests cover B2 modes, exact FASTA, closest-reference labeling, bounded reconfiguration, and fallback;
- viewport tests cover candidate wiring, large-evidence boundedness, stable-ID collision safety, and full-size-window safe-area placement;
- known-detail and full genotype viewport suites remain green;
- the four-sample exemplar is opened in a guarded debug build and candidate rows are repeatedly selected while memory is observed; and
- the final launched bundle is named `Lungfish Debug` and comes from this worktree's exact `build/Debug/Lungfish.app`.
