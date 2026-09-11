# PCR primer pack: architecture proposal

Status: architecture approved by the user on 2026-09-10. Exemplar scope subsequently confirmed as full-length MHC class I, class II DP, class II DQ, and class II DRB. Prepared from separate UI/UX, scientific data-integrity, and tool-integration reviews. The current implementation covers shared storage, annotation-link infrastructure, and a read-only saved-results viewer; design engines and their interfaces are not implemented.

Workspace: `codex/pcr-primer-design`, based on `94a860e75`. All work is isolated from the concurrent MHC checkout.

## Recommended approach

Provide one optional PCR Primer Design pack with independently identified Primer3 and PrimalScheme environments. Reuse LGE's plugin manager, operation sheets, job infrastructure, sequence viewers, and provenance envelope. Keep each engine adapter separate from the shared result and presentation models.

Use a new versioned analysis bundle as the authoritative record. Preserve `.lungfishprimers` as the existing scheme exchange format, with compatible exports linked to their parent analysis. Choose the new extension during the approved schema design and register it consistently across the app, CLI, and file associations.

Alternatives considered:

- Extend `.lungfishprimers` to represent all analyses. This reduces format registrations but overloads a format centered on required BED and accession metadata, and complicates candidate results, probes, local sequences, and collections.
- Build independent result formats and interfaces for each tool. This simplifies the first adapter but duplicates provenance, annotation links, reopening, and batch status handling.

## User experience

Use a shared Primer Design entry point with separate operation choices. Show an explicit input summary before settings: document identity, selected records or alignment rows, selection scope, and coordinate context. Never infer that currently visible rows are selected rows.

For collections, show one row per alignment with its source, readiness, and per-input status. Offer the user an explicit choice between one scheme per MSA and a combined scheme from selected MSAs. Preserve separate alignment identities and result-to-input membership in both modes; selection of several alignments must not implicitly concatenate them or imply a jointly validated pool. The user confirmed both modes are required. Saved grouping metadata alone is not evidence that a combined panel was generated or validated.

Organize common controls by the user's task, with advanced controls collapsed and a visible indication when advanced settings have changed. Preserve settings with each run. Only expose capabilities verified for the installed engine revision. The requested uncovered-end policy must be named, explained, and recorded explicitly if supported; its implementation is not established by this proposal.

Open completed analyses as durable documents with Overview, Results, Sequence/Alignment, Files, and Provenance views. Synchronize result selection with annotations. Show cancellation, failure, and partial collection outcomes accurately. Reading existing results must not require installed design tools.

Geneious provides a useful interaction reference for sequence-context design and annotation-linked output: [official primer design feature overview](https://www.geneious.com/features/primer-design/). This proposal does not establish chemistry support or copy biological defaults from that interface.

## Durable scientific record

The analysis manifest should contain schema version, stable analysis/run/result IDs, analysis kind, status, input identities, and an inventory of relative payload paths with roles, formats, byte sizes, and SHA-256 checksums. Retain original input snapshots, native outputs byte-for-byte, useful logs, and a separately versioned normalized display model. Preserve unfamiliar native output files even when the current viewer cannot interpret them.

Identify sequences using stable record identity and sequence/source checksums, not display names or accessions alone. Alignment inputs additionally require alignment identity, stable row identity, and the coordinate mapping associated with the run. Retain explicit coordinate conventions, original and projected intervals, orientation, and mapping status. Surface unmappable coordinates rather than silently omitting annotations.

Plain FASTA cannot store annotations. Persist features in LGE's reference/alignment annotation storage with durable analysis/result links; interoperable annotation exports must preserve those links where their format permits. Attaching the same result again should be idempotent. SQLite can serve as an index but should not be the sole durable record.

Use LGE's canonical provenance envelope for the exact executed tool/workflow and version, argv, reproducible replay command, visible options and resolved defaults, runtime/conda identity, input/output paths, checksums, sizes, exit status, wall time, and useful stderr. Distinguish historical executed paths from replay paths after relocation. Publish payloads and provenance transactionally and rehydrate GUI-imported CLI output descriptors to the final stored payload. Missing provenance blocks successful publication.

## Existing integration surfaces

- `Sources/LungfishWorkflow/Conda/PluginPack.swift`: optional packs, tool identities, environments, smoke tests, and limited source-overlay support.
- `Sources/LungfishWorkflow/Conda/PluginPackStatusService.swift`: installation readiness and package identity checks. Readiness alone must not establish support for a fork-specific feature.
- `Sources/LungfishApp/Views/PluginManager/PluginManagerView.swift`: install/remove/progress surfaces.
- `Sources/LungfishApp/Views/Phylogenetics/IQTreeInferenceDialog.swift`: existing operation-sheet pattern.
- `Sources/LungfishIO/Bundles/PrimerSchemeBundle.swift`: compatible scheme format; current loader is not a complete analysis integrity validator.
- `Sources/LungfishIO/Bundles/MultipleSequenceAlignmentBundle.swift`: source metadata, per-row bidirectional coordinate maps, and annotation projections.
- `Sources/LungfishCore/Models/SequenceAnnotation.swift`: existing primer, primer-pair, and amplicon annotations.
- `Sources/LungfishIO/Bundles/AnnotationDatabaseRecord.swift`: conversion currently regenerates annotation UUIDs and does not restore parent UUIDs. Authoritative result links must survive this path.
- `Sources/LungfishWorkflow/Provenance/ProvenanceEnvelope.swift`, `ProvenanceRunBuilder.swift`, `ProvenancePublicationSnapshot.swift`, and `ScientificProvenancePolicy.swift`: scientific provenance and publication contracts.

## Validation required during implementation

Verify optional install and uninstall behavior, positively identified tool versions, unsupported capability messaging, cancellation, and per-input failures. Test schema compatibility, path containment, corrupted payload detection, reopening without tools, relocation after deletion of staging files, duplicate sequence names, changed source sequences, stable result/annotation links, discontinuous mapped intervals, orientation, unmappable coordinates, and rollback when provenance cannot be published. Use agreed benign or synthetic fixtures for biological workflow validation.

## Confirmed scope and remaining integration work

1. The exemplars are full-length MHC class I, class II DP, class II DQ, and class II DRB amplification. These are example categories, not validated assay presets.
2. Both independent schemes and combined schemes are required as explicit user choices.
3. The earlier work was found in the task “Assess PrimalScheme3 compatibility”; its archived patch files are under `/Users/dho/Documents/Codex/2026-09-03/i-d-like-you-to-inspect/outputs/`. No patch has been imported, installed, or applied here, and no engine capability is claimed from those files. This LGE checkout's specialist document contains an older PrimalScheme link rather than an immutable identity for those changes.

No claim is made that chemistry-specific design, conserved-region selection, combined-pool validation, or the uncovered-end modification has been implemented or validated.
