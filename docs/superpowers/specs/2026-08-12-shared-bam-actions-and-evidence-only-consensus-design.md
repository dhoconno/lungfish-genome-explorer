# Shared BAM Actions and Evidence-Only Consensus Design

**Date:** 2026-08-12

**Status:** Approved design

**Scope:** Every full BAM/CRAM viewer; NAO-MGS explicitly excluded

## Goal

Give every full Lungfish BAM/CRAM viewer the same region, read-selection, extraction, copy, zoom, and consensus capabilities. Existing results must gain the capabilities when opened in a new build; users must not rerun the workflow that produced the BAM.

Consensus is read evidence, never reconstructed reference. At every reference-coordinate position whose filtered depth is below the chosen minimum depth, the emitted consensus base must be `N`. Lungfish must never copy a reference base into a consensus sequence merely because read evidence is absent or insufficient.

## Scope

The shared contract applies to:

- directly imported BAM and CRAM files;
- mapping-result BAM/CRAM views;
- reference-bundle alignment tracks;
- EsViritu full alignment evidence;
- TaxTriage full alignment evidence;
- NVD full alignment evidence; and
- future views that adopt the full `ViewerViewController` / `SequenceViewerView` alignment stack.

NAO-MGS is explicitly excluded. Its multi-panel MiniBAM implementation, actions, and data flow remain unchanged in this project.

This work does not add annotation mutation, variant calling, primer trimming, duplicate marking, or filtered-BAM creation to read-only classifier evidence. Those are distinct scientific workflows and retain their current availability rules.

## Current Failure

The classifier migration embeds a real full viewer, but several actions still discover their input through mapping-only ownership:

- selected-read extraction requires `activeMappingViewportController.currentResult` and therefore returns without doing anything for classifier evidence;
- app menu zoom and sequence actions target the root viewer instead of the embedded classifier evidence viewer;
- `zoomToFit()` requires `viewerView.sequence`, although detached evidence has a valid contig identity and length in `referenceFrame`;
- selected-range context menus expose reference-sequence extraction, not BAM reads overlapping the selected region; and
- classifier Inspector setup deliberately clears consensus export even though `samtools consensus` can call an evidence-only consensus from BAM without a reference FASTA.

These are host/action-routing limitations, not missing data in existing classifier results. A valid coordinate-sorted BAM plus BAI/CSI contains enough information for coordinate selection, zooming, region read extraction, selected-read copy/extraction, and evidence-only consensus.

## Design Principles

### One action context

Introduce one App-owned alignment action context used by all full BAM/CRAM viewers. The context describes the currently displayed evidence without pretending that detached classifier evidence is a mapping result.

It carries:

- BAM/CRAM URL and explicit BAI/CSI URL;
- active contig name and length;
- optional decoding reference URL for CRAM;
- stable sample, result, workflow, and provenance identities;
- final output root and a capability describing whether derived outputs may be written there;
- current BAM/index/reference snapshots;
- effective MAPQ, base-quality, read-group, and excluded-flag filters; and
- optional source-read resolution information when original FASTQ bundles are retained.

Mapping/reference-bundle hosts and detached classifier hosts construct the same context. Shared actions consume the context rather than asking whether a mapping-result controller exists.

### One active full viewer

Window-level menu validation and dispatch must resolve the actual active full sequence viewer in this order:

1. active detached classifier evidence viewer, when present and available;
2. embedded mapping/reference-bundle viewer;
3. root viewer; or
4. multiple-sequence alignment viewer for actions that already support MSA.

The composition root owns this routing. Leaf classifier modules remain independent of `LungfishApp`.

### Capabilities follow evidence, not result type

Actions are enabled from concrete evidence and destination capabilities:

- a contig and `referenceFrame` enable coordinate selection, navigation, zoom, and whole-contig/selected-region scope;
- a readable BAM/CRAM plus explicit index enables region and read-name extraction;
- loaded aligned records enable selected-read copy;
- an alignment provider enables evidence-only consensus;
- a validated reference enables mismatch rendering and other explicitly reference-dependent interpretation only; and
- annotation or mutable bundle workflows remain disabled when the view lacks their required target.

## Region and Read Actions

Every included viewer supports the following behavior.

### Coordinate selection and zoom

- Dragging on the ruler/sequence canvas creates an explicit coordinate selection.
- The selected interval is visible in the status bar and Inspector.
- `Zoom to Selected Region` operates on the active full viewer.
- `Zoom to Fit` uses the active contig length from `referenceFrame`; it does not require a loaded reference sequence.
- Zoom in, zoom out, reset, go-to-position, and keyboard shortcuts operate on the same active viewer.
- Changing samples or contigs clears selection and selected-read state that belongs to the previous evidence identity.

### Reads overlapping a region

The selected-range context menu exposes `Extract Reads in Selected Region…`. It uses the explicit BAM/CRAM index and the selected contig interval, not reference-sequence extraction. If no explicit selection exists, an equivalent action may target the visible interval only when its title says `Visible Region`.

The extraction dialog offers the existing FASTQ/FASTA output choices and standard destination behavior. The normal output is a provenance-bearing `.lungfishfastq` bundle (including FASTA-mode derived bundles where supported by the existing extraction infrastructure). Source FASTQ records may be used when they can be resolved without ambiguity; otherwise extraction is derived from the displayed BAM/CRAM.

### Individual reads

- A click selects one aligned record.
- Command-click toggles records and Shift-click adds records.
- Right-click preserves an existing multi-selection when the clicked record is already selected; otherwise it selects the clicked record.
- `Copy as FASTA (aligned orientation)` remains an in-memory clipboard action and includes aligned sequence plus useful coordinate/CIGAR/MAPQ header information.
- `Extract Reads… (original reads)` resolves selected QNAMEs from retained source FASTQ when possible, falling back to BAM/CRAM read-name extraction when source reads are unavailable.
- Extraction includes mates according to the established `ReadIDBAMExtractionConfig` contract and writes a provenance-bearing output bundle.
- Secondary/supplementary records without sequence are reported explicitly rather than silently appearing to copy.

## Consensus Scope and Controls

The Analysis Inspector exposes a persistent, explicit `Consensus Scope` control in every included full alignment viewer:

- `Whole contig`
- `Selected region`

The choice is never inferred from the mere existence of a selection. `Selected region` is disabled, with the explanation `Select a region in the viewer first`, when the active evidence has no explicit user selection. Whole-contig scope means the entire active contig, not every contig in a multi-contig BAM.

Changing samples or contigs preserves the user's preferred scope when meaningful. If the preference is `Selected region` and the new evidence has no selection, generation remains disabled until the user makes a new selection; Lungfish must not silently switch to whole contig.

The existing controls remain shared:

- Bayesian or simple caller;
- IUPAC ambiguity codes;
- minimum depth;
- minimum MAPQ;
- minimum base quality;
- duplicate, secondary, supplementary, and read-group inclusion; and
- insertion/deletion output policy appropriate to the exported sequence.

Consensus track display and consensus export use the same resolved filters.

## Global Evidence-Only Consensus Invariant

This invariant applies to every consensus generated from BAM or CRAM anywhere in Lungfish, whether or not a validated reference is present:

> For each reference-coordinate position in the requested scope, if the depth after applying the exact consensus filters is below `minimumDepth`, the output character at that position is `N`.

Implementation must enforce the invariant after the caller returns:

1. Call `samtools consensus` for the explicit region and caller settings.
2. Fetch per-position depth for the identical BAM/CRAM, interval, MAPQ, base-quality, flag, and read-group filters.
3. Normalize the caller output to the requested reference-coordinate interval.
4. Replace every reference-coordinate position whose filtered depth is below the threshold with `N`.
5. Validate that the final reference-coordinate projection covers the requested interval before publication.

This postcondition is authoritative even if a future `samtools` version changes uncovered-site behavior. A FASTA supplied for CRAM decoding, mismatch display, coordinate validation, or annotation display is never consulted to replace `N`. Reference sequence may not enter the consensus base-selection fallback path.

Insertions are evidence-derived bases between reference coordinates and are retained only when the chosen output policy enables them. Deletion representation follows the explicit export policy. Neither changes the rule for low-depth reference-coordinate positions.

## Consensus Output

`Generate Consensus…` opens the standard FASTA sequence destination dialog after resolving the explicit scope. It offers:

- native `.lungfishref` sequence bundle;
- plain FASTA file;
- clipboard; and
- system share.

The native bundle is the durable scientific output and must carry complete provenance. Plain FASTA output must receive its own adjacent provenance sidecar. Clipboard output is ephemeral and must show a clear summary of scope and filters before copying; it does not masquerade as a reproducible stored artifact.

Record names and suggested filenames include sample/evidence label, contig, scope, and selected coordinates when applicable. Names must not claim that an EsViritu final-consensus artifact was reused: this action calls a new consensus directly from the selected BAM/CRAM evidence.

## Provenance

Every stored consensus or read-extraction output must meet the repository's scientific provenance requirements. The final bundle or output directory records:

- workflow and tool names and versions;
- exact argv and reproducible shell command;
- all user-visible options and resolved defaults;
- explicit scope (`whole-contig` or `selected-region`) and zero-/one-based coordinate representations;
- contig identity and expected length;
- caller mode, ambiguity setting, minimum depth, MAPQ, base quality, read groups, excluded flags, and indel policy;
- the global `lowDepthPolicy: N` and `referenceFillPolicy: never` invariants;
- BAM/CRAM, BAI/CSI, and decoding-reference paths where applicable;
- input and final-output checksums and file sizes;
- runtime/conda/container identity and executable checksum where applicable;
- start/end timestamps, wall time, exit status, and useful stderr;
- temporary-to-final publication mapping; and
- failure provenance for every attempted scientific subprocess or publication step.

Outputs publish atomically. Sidecars must point to final stored payloads, not staging paths. Existing final evidence remains read-only; new outputs are written to a project-owned derived-output location or a destination explicitly selected by the user.

## Reference Handling

A reference has only these roles in this feature:

- decode CRAM;
- validate contig identity/length;
- render matches/mismatches and reference bases;
- support annotation/variant interpretation that independently requires it.

Reference presence must not determine whether BAM consensus is available. Missing reference disables reference-dependent rendering and analyses, while coordinate actions, BAM extraction, selected-read operations, and evidence-only consensus remain available for BAM. CRAM remains unavailable when its decoding reference cannot be resolved because the reads themselves cannot be decoded safely.

EsViritu per-sample `*_final_consensus.fasta` files are not automatically treated as mapping references. Their record names and sparse consensus lengths do not necessarily match the BAM contigs. This work does not substitute those files for the original alignment reference.

## Error Handling and Concurrency

- Validate BAM/CRAM, explicit index, contig, and snapshots before enabling output actions.
- Revalidate snapshots immediately before subprocess launch and final publication.
- Cancel in-flight fetches and scientific actions when evidence is replaced; an already-running output job remains visible in Operation Center and may finish only against its captured, validated snapshots.
- Stale or replaced evidence cannot publish results under the new evidence identity.
- Empty region extraction, empty read-name extraction, empty consensus, coordinate-length mismatch, unsupported caller behavior, and low-depth-all-`N` output are distinct user-visible outcomes.
- All-`N` consensus is valid evidence when no position meets minimum depth. Warn clearly, but allow the user to store it with provenance.
- Context-menu and main-menu actions must never fail silently. An unavailable action is disabled with a reason; a runtime failure appears in Operation Center and through the standard failure presentation.

## Compatibility and Migration

- Existing BAM/BAI and CRAM/CRAI results acquire these capabilities when opened in the new app build.
- EsViritu, TaxTriage, and NVD do not need to be rerun.
- No wrapper or synthetic reference bundle is created merely to activate viewer actions.
- No existing classifier result is mutated.
- Existing mapping/reference-bundle behavior is routed through the shared action context and must remain behaviorally compatible except for the new explicit consensus scope and stronger no-reference-fill rule.
- NAO-MGS receives no changes, new dependencies, or behavior through this work.

## Testing

All permanent tests use repository-owned, wholly synthetic fixtures and run with external volumes absent.

### Action routing

- Each included host resolves the same active viewer and action context.
- Main-menu and context-menu zoom target detached classifier evidence when active.
- Whole-contig zoom succeeds without `viewerView.sequence` when a valid contig frame exists.
- Region selection and state clearing work across sample/contig replacement.
- NAO-MGS source guards and behavior remain unchanged.

### Region and read extraction

- Selected-region extraction passes exact BAM/index/contig/coordinates and resolved filters.
- Mapping, direct import, reference bundle, EsViritu, TaxTriage, and NVD all reach the same extraction service.
- Selected-read copy preserves aligned orientation.
- Selected-read extraction works without a mapping-result controller and falls back to BAM-derived records with complete provenance.
- Failure, cancellation, stale-evidence, mate, duplicate, and secondary/supplementary cases are covered.

### Consensus

- Scope choice is explicit and persistent.
- Selected-region scope is disabled without an explicit selection and never silently falls back.
- Whole-contig and selected-region requests use exact coordinates and resolved filters.
- A synthetic reference whose bases differ from the reads proves consensus follows reads.
- Covered positions below minimum depth are `N`.
- Uncovered positions are `N`.
- The same tests pass with a reference absent and with a deliberately conflicting reference present.
- CRAM decoding may use a reference but still cannot fill low-depth positions.
- Consensus track and exported consensus agree for the same scope and filters.
- All-`N` output remains valid and provenance-bearing.

### Provenance and portability

- Success and every failure stage record exact commands, options/defaults, runtime, inputs/outputs, checksums/sizes, status, timing, and stderr.
- Final sidecars contain final paths and pass the repository provenance auditor.
- Static guards reject `/Volumes` dependencies and skip-on-missing-fixture behavior in the relevant suites.
- Regeneration of synthetic BAM/BAI/CRAM/reference fixtures is deterministic and provenance-audited.

## Acceptance Criteria

1. Every included full BAM/CRAM viewer supports region selection, zoom-to-selection, zoom-to-fit, selected-region read extraction, individual/multiple read selection, read copy, and selected-read extraction.
2. Consensus scope is always an explicit user choice between whole active contig and selected region.
3. Selected-region consensus cannot run without an explicit selection and never falls back silently.
4. Every BAM/CRAM consensus position below filtered minimum depth is `N` throughout the app.
5. No reference base is ever used to fill BAM/CRAM consensus output.
6. BAM consensus works without a reference; CRAM uses a reference only for decoding and still obeys the evidence-only invariant.
7. Stored scientific outputs contain complete, final-path provenance and publish atomically.
8. Existing EsViritu, TaxTriage, NVD, mapping, imported alignment, and reference-bundle results work without rerunning their producing workflow.
9. NAO-MGS remains unchanged.
10. Relevant tests pass without any external volume or external scientific data.
