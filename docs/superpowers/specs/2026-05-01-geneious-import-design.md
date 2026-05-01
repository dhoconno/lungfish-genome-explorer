# Geneious Import Design

Date: 2026-05-01

## Summary

Add a new Import Center operation, "Import Geneious Export", for `.geneious` archives and Geneious-export folders. The importer will inventory the export, map supported contents to existing Lungfish Genome Explorer bundle types, preserve unsupported but meaningful payloads, and record reproducibility provenance for every created bundle or project artifact.

The first implementation should be Geneious-first but not Geneious-dependent. Users should be able to import or at least preserve a Geneious export on machines that do not have Geneious installed. Native decoding of Geneious sidecar payloads is technically feasible with the Geneious public API, but product packaging must be gated by legal and redistribution review before bundling any Geneious libraries.

## Goals

- Add a dedicated Import Center workflow for `.geneious` archives and Geneious-export folders.
- Reuse existing LGE import paths for standard formats instead of creating parallel parsers.
- Decode Geneious native sequence and annotation objects when a legally acceptable decoder path is available.
- Provide a no-Geneious baseline that inventories exports, imports standard embedded files, and preserves unsupported native contents with warnings.
- Map supported contents to `.lungfishref`, `.lungfishfastq`, `.lungfishprimers`, project analysis artifacts, or project attachments as appropriate.
- Preserve Geneious-specific metadata, including document names, descriptions, colors, original locations, operation records, unresolved source references, and document class names.
- Write complete provenance for the scan, decode, staging, and final LGE import steps.

## Non-Goals

- Do not launch, automate, or require the Geneious desktop application for the default workflow.
- Do not make the first Geneious importer depend on new MSA or phylogenetic tree viewers.
- Do not reverse-engineer undocumented binary payloads as the primary strategy when the Geneious API can decode them.
- Do not flatten complex future data types, such as UShER MAT trees or whole-genome HAL alignments, into lossy FASTA/Newick output during Geneious import.
- Do not treat Geneious operation records as LGE reproducibility provenance. They should be retained as source metadata, while LGE writes its own provenance.

## Source Types

The importer should accept:

- Single `.geneious` zip archives.
- Geneious-export folders.
- Archives or folders containing a mix of Geneious-native files and standard files.

The scanner should recognize, but not necessarily fully import in phase 1:

- Geneious XML document metadata and `fileData.*` sidecar payloads.
- DNA/RNA/protein sequence documents and sequence-list documents.
- Sequence annotations and annotation-only exports.
- Alignments, assemblies, trees, graphs, chromatograms, reports, publications, operation records, workflows, and miscellaneous Geneious documents.
- Standard embedded or neighboring files such as FASTA, GenBank, EMBL, GFF, BED, FASTQ, QUAL, SAM, BAM, CRAM, VCF, WIG, BigWig, PHYLIP, NEXUS, Newick, MEGA, ABI/AB1, CSV, TSV, PDF, HTML, and text.

## Sample Fixture Findings

The sample file `/Users/dho/Downloads/MCM_MHC_haplotypes-annotated.geneious` is a zip archive with one main XML document and thirteen `fileData.*` sidecar blobs. It was exported by Geneious 2026.0.2 and contains:

- One reference-only `OperationRecordDocument`.
- One `DefaultSequenceListDocument` named `MCM_MHC_haplotypes-annotated`.
- Seven nucleotide sequences totaling 38,355,179 bases.
- Sequence payloads stored in sidecar blobs rather than inline XML.
- 14,601 decoded annotations across the seven sequences.
- Seven excluded source document URNs that should be surfaced as unresolved-source warnings.
- Per-sequence metadata such as Geneious color, source location, comments, sample name, assembly/read fields, and MAFFT-related fields.

This fixture proves that a pure XML parser cannot recover full content from all real `.geneious` exports. The phase 1 importer can still inventory and preserve the file, but native sequence extraction requires a decoder capable of reading Geneious sidecar payloads.

## Format Mapping

| Geneious or standard content | LGE destination | First behavior |
| --- | --- | --- |
| DNA/RNA sequences with annotations | `.lungfishref` | Import as reference sequence plus annotation tracks, preserving sequence metadata. |
| Standard FASTA, GenBank, EMBL | Existing reference import | Reuse `ReferenceBundleImportService`. |
| GFF, GTF, BED | Existing annotation track import | Attach to a reference bundle when a target reference can be resolved. |
| FASTQ or sequence-with-quality reads | `.lungfishfastq` | Reuse FASTQ ingestion when the data represents reads. Preserve consensus/trace quality data if it cannot be represented. |
| SAM, BAM, CRAM | Existing alignment track import | Reuse alignment-track support. |
| VCF, BCF | Existing variant track import | Reuse variant-track support. |
| WIG, bedGraph, BigWig, Geneious graphs | Signal tracks where supported | Import standard signal files when possible; otherwise preserve raw graph data. |
| Primer-like annotations | `.lungfishprimers` candidate | Offer primer-scheme import only when required fields can be inferred safely. |
| Multiple sequence alignments | Deferred native MSA support | Recognize and preserve; import standard sequence content only when not lossy. |
| Phylogenetic trees | Deferred native tree support | Recognize and preserve Newick/NEXUS/MEGA/Geneious tree data for future `.lungfishtree`. |
| ABI/AB1 chromatograms | Unsupported native trace data | Preserve as project binary files with warnings. |
| PDFs, publications, HTML reports, text, CSV/TSV | Project attachments or analysis artifacts | Preserve and show in the import report. |
| Operation records and document history | Source metadata | Preserve as import metadata, not as LGE provenance. |
| Unknown Geneious document classes | Unsupported native documents | Preserve raw payloads and report class names. |

## Architecture

### Import Center Entry Point

Add a new "Geneious Export" card in the Import Center. It should accept files or folders and start a two-step workflow:

1. Scan and preview.
2. Import selected supported contents.

The preview should group results into supported imports, preserved unsupported files, warnings, and errors. It should also show the planned output bundle names before any data is written.

### Scanner

The scanner is a Swift service that performs safe structural inspection without requiring Geneious:

- Walk selected folders recursively.
- Open `.geneious` archives as zip files.
- Reject zip-slip paths and unsafe symlinks.
- Compute file sizes and SHA-256 checksums.
- Parse visible XML metadata when available.
- Record Geneious version, minimum version, document class names, document names, hidden-field metadata, sidecar names, and unresolved document references.
- Identify standard files by extension and lightweight content sniffing.
- Produce a `GeneiousImportInventory` used by the preview UI and provenance writer.

The scanner must not execute anything from the source archive.

### Native Decoder

Native Geneious decoding should be a separate helper boundary, not interleaved with Import Center UI code. The preferred implementation is a small JVM helper that:

- Receives an extracted `.geneious` archive path and an output staging directory.
- Uses the Geneious public API to decode supported document classes.
- Writes canonical staged files such as FASTA, GFF3 or annotation JSON, metadata JSON, operation-record JSON, and raw unsupported payload copies.
- Reports exact warnings, unsupported document classes, and decode errors in structured JSON.

The decoder must not call Geneious UI initialization. Proof-of-concept work showed that XML serializer initialization plus direct Geneious public API sequence document decoding can extract the sample sequences and annotations without launching the desktop app.

Bundling or distributing Geneious API jars requires legal review. Until that review is complete, the product design should support three runtime modes:

- `inventory-only`: available to every user; scans, imports standard files, and preserves native contents.
- `native-decoder-available`: uses the LGE-provided or locally configured decoder to stage canonical outputs.
- `external-geneious-export`: accepts high-fidelity standard exports created by users who have Geneious.

### Staging and Existing Import Reuse

Decoded or discovered standard files should be staged into a temporary import workspace with stable filenames and a manifest. Existing import services should then consume those staged files:

- Reference sequences and annotations go through reference bundle import/build paths.
- FASTQ data goes through FASTQ ingestion.
- BAM/CRAM/SAM, VCF/BCF, and signal tracks use current track import/build paths.
- Unsupported files are copied into a project-managed import-assets location or bundle attachment area, depending on the final destination.

Staging paths are implementation details. Final provenance must point at final stored payloads in `.lungfish*` bundles or project-managed artifact directories.

## User Workflow

1. User selects "Geneious Export" in the Import Center.
2. User chooses a `.geneious` file or folder.
3. LGE scans the source and shows a preview:
   - Native Geneious documents found.
   - Standard files found.
   - Planned LGE outputs.
   - Unsupported contents that will be preserved.
   - Warnings such as missing sidecars, unresolved source URNs, unsupported document classes, or native decoder unavailable.
4. User chooses output options:
   - Combined reference bundle for sequence lists, default.
   - Split top-level sequence documents into separate bundles, optional.
   - Preserve raw Geneious export, default enabled.
   - Include unsupported standard/binary files as project attachments, default enabled.
5. LGE imports supported data and writes an import report.
6. The project sidebar shows created bundles and preserved files.

## Metadata Preservation

For decoded sequence and annotation content, preserve:

- Original Geneious document name and display name.
- Document class and Geneious export version.
- Description/comment fields.
- Original file location and imported-from metadata.
- Geneious colors where present.
- Per-sequence fields such as sample name, data type, source sequence count, mean coverage, and alignment-related fields.
- Annotation names, types, intervals, directions, and qualifiers.
- Operation records and excluded document references as source metadata.

Coordinate conversion must be explicit. Geneious `SequenceAnnotationInterval` uses 1-based inclusive display coordinates, while LGE `AnnotationInterval` uses 0-based start-inclusive/end-exclusive coordinates. The decoder should use the Geneious API interval conversion when possible, or subtract one from starts while leaving inclusive ends as exclusive ends.

## Provenance

Every output bundle or project artifact created by this workflow must include LGE provenance. This is a blocking requirement.

The provenance record should include:

- Workflow name and version, such as `geneious-import`.
- Exact argv or reproducible command for scanner and decoder helper invocations.
- User-visible options and resolved defaults.
- Source paths, file sizes, SHA-256 checksums, and archive member checksums when practical.
- Geneious export version and document class inventory.
- Decoder runtime identity, including Java version and Geneious API jar identity when used.
- Existing LGE import service calls and their options.
- Staged file paths and final stored payload paths.
- Final payload checksums and sizes.
- Warnings and unsupported-content records.
- Exit status, wall time, and stderr or structured diagnostics when useful.

If an existing CLI import writes provenance during staging, the GUI workflow must preserve or rehydrate it so the final `.lungfish*` bundle points at final stored payloads rather than temporary staging files.

Geneious operation records should be stored as source-history metadata. They do not replace LGE provenance because they do not describe the LGE import, runtime, checksums, final output paths, or app options.

## Error Handling

The workflow should distinguish hard failures from importable warnings:

- Hard failures: unreadable source path, invalid zip structure, unsafe archive path, missing required sidecar for selected native decode, unsupported decoder runtime, failed final bundle write, or checksum mismatch.
- Warnings: unsupported document class, unresolved Geneious source URN, decoder unavailable, standard file preserved but not imported, graph/trace/tree/MSA content deferred, annotation qualifier not mapped to a first-class field, or reference target not resolved.

Users should be able to complete an import with warnings as long as selected supported outputs are valid and unsupported contents are preserved.

## Testing

Tests should cover:

- Scanner inventory for the real sample fixture when available via an environment variable.
- Scanner inventory for small checked-in synthetic `.geneious` archives that contain safe XML metadata.
- Zip-slip and malformed-archive rejection.
- Standard-file discovery inside folders and archives.
- Native decoder JSON contract using a small fixture when legal packaging is settled.
- Coordinate conversion for Geneious annotations.
- Import preview grouping and warning rendering.
- Provenance content for each created bundle and preserved project artifact.
- Fallback behavior when the native decoder is unavailable.

Large real Geneious exports should remain external fixtures unless licensing and repository-size constraints allow checked-in test data.

## Rollout

Phase 1: Inventory and preservation baseline.

- Add Import Center card.
- Scan `.geneious` archives and folders.
- Import standard embedded files through existing services.
- Preserve native Geneious files and unsupported binary files.
- Write import reports and provenance.

Phase 2: Native sequence and annotation decode.

- Add decoder helper boundary.
- Complete legal review for Geneious API redistribution or local configuration.
- Decode supported sequence-list and sequence-document classes to canonical staged outputs.
- Import decoded sequences and annotations into `.lungfishref`.

Phase 3: Broader Geneious object coverage.

- Add richer mapping for graphs/signal tracks, primer-like annotations, assemblies, variant calls, and operation records.
- Expand warnings and preservation rules for chromatograms, publications, and workflow documents.

Phase 4: Optional Geneious companion exporter.

- Consider a Geneious plugin only as an optional high-fidelity export path for users who already have Geneious.
- Keep the no-Geneious baseline available.

## Acceptance Criteria

- A user without Geneious can select a `.geneious` archive, see its inventory, import any standard files, preserve unsupported native payloads, and receive clear warnings.
- A user with a supported native decoder can import decoded nucleotide sequences and annotations from the sample export into native LGE reference/annotation formats.
- Existing LGE importers are reused for standard formats wherever possible.
- Unsupported data is not silently discarded.
- Every created output includes complete provenance that identifies the original Geneious source and the final LGE payloads.
- The sample file's seven sequences, 38,355,179 bases, 14,601 annotations, Geneious metadata, and unresolved source references are represented in preview and import outputs when native decoding is enabled.
