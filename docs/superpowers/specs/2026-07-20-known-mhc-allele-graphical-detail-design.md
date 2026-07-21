# Known MHC Allele Graphical Detail Design

**Date:** 2026-07-20

**Status:** Approved design, pending implementation plan

## Purpose

Replace the evidence-heavy detail shown when a known full-length MHC genotype row or cell is selected with a fast, allele-centric graphical record view. The new view presents the reference allele's sequence, GenBank annotations, exon/CDS structure, and translation without parsing BAM files or recomputing cohort evidence during selection.

This tranche also publishes the closest reference records required by the later `_nov` and `_ext` graphical-detail work. Closest references are selected from the complete reference database, not from the subset of alleles called exactly in the cohort.

## Current Problem

Known-row selection currently runs synchronously on the main actor and rebuilds a large AppKit detail hierarchy. It recomputes or renders:

- aggregate support;
- selected-cell support;
- anchor summaries;
- same-locus co-occurrence;
- up to 24 supporting samples;
- GenBank field rows;
- comments and inspector selection state.

The selection path performs repeated scans, grouping, sorting, denominator calculation, and nested view creation. There is no asynchronous boundary. The visible delay is therefore main-thread work caused by evidence aggregation and rendering.

The genotype result bundle currently embeds the GenBank record metadata database but does not embed the reference sequence and per-feature geometry required for a self-contained graphical record view.

## Scope

### Included in this tranche

- A new self-contained MHC reference-visualization artifact in fresh full-length genotype results.
- Extraction of exact-call reference records.
- Extraction of each `_nov` and `_ext` candidate's persisted closest-reference record, including references that are not exact calls in any sample.
- A lightweight graphical detail view for known allele row and cell selections.
- Full-pane canonical GenBank and FASTA modes.
- Removal of support, co-occurrence, anchor, and supporting-sample evidence from known allele row and cell details.
- Metadata-only fallback for legacy, incomplete, or damaged visualization artifacts.
- Complete scientific provenance for artifact generation and publication.
- Tests, a fresh four-sample CLI analysis, and a new signed `Lungfish Debug` build.

### Deferred to the next tranche

- The graphical detail UI for `_nov` and `_ext` candidate rows.
- Novel-defining SNP tracks and consequence classification.
- Extension intron-fill and additional-exon tracks.
- Candidate translation projection and seven-versus-short-eighth-exon interpretation.
- Candidate-specific canonical GenBank records containing sample-support qualifiers.

Candidate rows retain their current detail implementation until that dedicated tranche. This implementation must not add a partial novel/extension graphical view.

### Explicitly out of scope

- Changes to unrelated LGE viewports or workflows.
- Refactoring the complete app genome viewer into a new shared framework.
- Resolving reference data through an external path when a result bundle is viewed.
- Inferring exon structure when the source reference does not provide feature annotations.
- Changing known-call, candidate-classification, provisional-naming, Excel, or haplotyping semantics.
- Building a new generalized artifact-security, filesystem-transaction, or viewer framework.
- Exhaustive adversarial hardening before the graphical interaction has been validated in debug use.

### Implementation phasing

This first implementation prioritizes a functional, responsive graphical detail pane and the scientific artifact needed to drive it. It reuses the result bundle's existing safe relative-path, checksum, size, and atomic-publication mechanisms. New validation is limited to the visualization format's essential invariants: supported schema, unique record identity, sequence checksum, required-role coverage, and in-bounds feature coordinates.

Broader fuzzing, a comprehensive malicious-filesystem matrix, generalized renderer extraction, additional cache layers, and performance micro-optimization are deferred until the detail-pane design has been exercised and approved in debug testing.

## Design Decisions

### 1. Compact result-bundle artifact

The workflow publishes a compact, versioned artifact containing only the reference records needed by the result. It does not copy the complete reference FASTA or annotation database into the genotype bundle.

The record set is the deduplicated union of:

1. Every raw reference sequence ID used by an exact known genotype call.
2. The persisted `closest_reference_name` for every classified `_nov` candidate.
3. The persisted `closest_reference_name` for every classified `_ext` candidate.

The second and third sets come from the all-reference candidate mapping and classification output. They are not derived from, filtered by, or intersected with exact genotype calls observed in the cohort.

The extraction step consumes the closest-reference identity already selected by the candidate-classification workflow. It does not independently choose another closest reference and cannot change a provisional candidate name.

### 2. Lightweight genotype-specific renderer

`LungfishGenotypeUI` receives a small in-memory record model and renders a static whole-record overview. It does not embed `ViewerViewController`, construct a temporary `.lungfishref`, or depend on the app-only genome viewer target.

This avoids a module dependency cycle and excludes viewer state that is irrelevant to the genotype detail pane, including BAM tracks, variant tracks, global viewport notifications, annotation drawers, search indexes, and genome navigation state.

The visual language matches the parsed GenBank/reference viewport: coordinate ruler, nucleotide strip, feature tracks, numbered exon blocks, CDS, and colored translation.

### 3. Canonical rather than source-text GenBank

The GenBank mode displays a deterministic Lungfish-generated canonical record. It preserves the biological record content and provenance but does not promise byte-for-byte reproduction of the source file's whitespace, line wrapping, or qualifier ordering.

The canonical text displayed by a particular analysis is materialized during the analysis and stored in the visualization artifact. A future formatter change therefore cannot silently alter the scientific text shown for an existing result.

### 4. B2 document navigation

The detail pane has a persistent `Overview / GenBank / FASTA` switcher.

- `Overview` shows a graphical canvas with a facts rail.
- `GenBank` uses the full pane width for the canonical, selectable record.
- `FASTA` uses the full pane width for the canonical, selectable sequence record.

Returning to `Overview` restores the existing record model and feature selection without rereading the bundle artifact.

## Artifact Contract

### Manifest descriptor

`ONTGenotypeResultBundleManifest` gains an optional `mhcReferenceVisualizations` descriptor. Legacy bundles decode with this property absent.

The descriptor contains:

- schema version;
- structured JSON artifact reference;
- canonical multi-record GenBank artifact reference;
- canonical multi-record FASTA artifact reference;
- reference-record count;
- SHA-256 and byte size for every artifact.

All paths are safe bundle-relative paths and are validated without following symlinks.

Recommended bundle paths:

```text
artifacts/reference/mhc-reference-visualizations.json
artifacts/reference/mhc-reference-records.gb
artifacts/reference/mhc-reference-records.fasta
```

### Structured document

The version 1 JSON document contains:

- document schema version;
- generation metadata;
- records indexed by raw reference sequence identity;
- canonical artifact checksums;
- no sample read-support matrix.

Each reference record contains:

- raw reference sequence name;
- resolved allele label and locus when available;
- sequence length, bases, and sequence SHA-256;
- source definition, organism, molecule type, product, note, and relevant record fields;
- feature list;
- annotated CDS translation data;
- exact canonical GenBank text stored for this analysis;
- exact canonical FASTA text stored for this analysis;
- one or more usage roles.

Each feature contains:

- deterministic feature identity;
- source ordinal;
- original feature type;
- zero-based half-open interval list;
- strand;
- original GenBank location expression when available;
- exon number when available;
- qualifiers required for display and canonical serialization.

Usage roles are:

- `exact_known_call`;
- `closest_novel_reference`;
- `closest_extension_reference`.

A record may have multiple roles. Closest-reference roles retain the stable cluster IDs of the candidates that selected the record, but version 1 does not add candidate sequence, SNP, extension, or sample-support drawing data.

### Canonical GenBank and FASTA files

The `.gb` and `.fasta` artifacts are deterministic concatenations of the record strings stored in JSON. Their record ordering follows raw reference sequence source ordinal, then raw sequence identity as a stable tie-breaker.

The files provide interoperable scientific artifacts while the JSON provides O(1) UI lookup and structured drawing data. Tests verify byte equivalence between JSON record strings and the corresponding concatenated records.

## Artifact Generation

After exact calls and candidate classifications are finalized, the workflow:

1. Collects exact-call raw reference identities.
2. Collects persisted closest-reference identities from every classified `_nov` and `_ext` candidate.
3. Deduplicates the union while preserving usage roles and stable candidate cluster IDs.
4. Fetches each sequence from the indexed reference FASTA.
5. Fetches feature rows for each raw identity from the declared reference annotation database.
6. Fetches record fields from the declared GenBank metadata store.
7. Validates feature intervals against sequence length.
8. Preserves annotated translation rather than inferring unsupported translations.
9. Creates canonical GenBank and FASTA text.
10. Writes the JSON, GenBank, and FASTA artifacts into the staged result bundle.
11. Validates checksums, sizes, record counts, role coverage, and canonical-text consistency.
12. Adds the manifest descriptor and provenance before publishing the manifest last.

If sequence data is present but annotations are absent, the workflow publishes a sequence-only visualization entry. It does not synthesize exon or CDS geometry. If the reference sequence itself cannot be resolved, artifact generation fails before successful bundle publication because the result would contain an unresolved exact call or closest-reference identity.

## Provenance

Artifact generation is a scientific transformation and must satisfy the repository provenance requirements.

The provenance step records:

- workflow/tool name and Lungfish version;
- exact CLI argv or reproducible internal command;
- user-visible options and resolved defaults;
- runtime identity;
- source reference bundle and manifest;
- indexed reference FASTA and its indexes;
- annotation database when present;
- GenBank record database;
- exact-call report input;
- candidate-classification input;
- output JSON, GenBank, and FASTA paths;
- SHA-256 and byte size for every input and output;
- start time, completion time, wall time, stderr when useful, and exit status.

Final-location provenance points to the published bundle paths rather than temporary staging paths. Atomic-publication failure must leave no successful manifest or partially declared visualization artifact.

## Known Allele Detail Experience

### Overview layout

The selected B2 overview contains:

#### Header

- resolved allele name;
- raw reference accession;
- locus;
- reference-record class;
- sequence length;
- optional `Observed in sample <sample>` badge for cell selection.

#### Graphical canvas

- whole-record coordinate ruler;
- nucleotide-density strip across the complete record;
- gene and CDS tracks;
- numbered exon blocks;
- intron gaps only when present in the reference geometry;
- annotated translation aligned to CDS coordinates.

The initial overview fits the full record to the available canvas width. Version 1 does not introduce the full genome viewer's pan/zoom state. FASTA mode provides exact base-level inspection.

#### Facts rail

- allele;
- raw accession;
- locus/gene;
- molecule type;
- definition;
- organism;
- product;
- sequence length;
- exon count;
- CDS length;
- protein length;
- previous designations;
- note;
- saved matrix comments.

Hovering or selecting a graphical feature updates a bounded feature-information area in the facts rail with feature type, exon number, coordinates, strand, source location, and relevant qualifiers.

### GenBank mode

GenBank mode presents the stored canonical record in a read-only, selectable, monospaced full-width view. Switching records changes the displayed text by O(1) lookup and does not regenerate it.

### FASTA mode

FASTA mode presents the stored canonical FASTA record in a read-only, selectable, monospaced full-width view. It uses the raw reference identity and resolved allele label in the canonical header.

### Selection behavior

- A single known row opens the allele-centric overview.
- A single known cell opens the same overview and adds only the selected-sample badge.
- Known row and cell detail contains no unique-read count, alignment count, support fraction, co-occurrence, anchor, or supporting-sample list.
- Sample-column selection retains the current sample summary behavior.
- Multi-row, multi-cell, and mixed selection retain bounded compact summaries.
- Candidate selection retains its current behavior until the next tranche.
- Existing comments, highlight state, matrix targets, and inspector publication remain available without publishing support evidence as visible detail rows.

## Performance Contract

### Bundle load

- Visualization artifact reading, validation, and indexing happen off the main actor as part of the existing asynchronous result load.
- Records are indexed once by raw reference sequence identity.
- The artifact is not decoded again on row selection or mode switching.

### Selection

- Known row and cell selection perform one dictionary lookup by raw identity.
- Selection performs no BAM access.
- Selection performs no SQLite query.
- Selection performs no FASTA read.
- Selection performs no cohort-wide filtering, grouping, sorting, co-occurrence, anchor-summary, denominator, or supporting-sample calculation.
- A reusable detail component updates in place rather than creating a number of subviews proportional to sample count.
- The number of detail subviews and feature rows depends only on the selected reference record, not on cohort size.

### Mode switching

- `Overview`, `GenBank`, and `FASTA` switch between already loaded record representations.
- Mode switching performs no disk access and no record reserialization.

## Error Handling and Compatibility

### Legacy bundles

If `mhcReferenceVisualizations` is absent, known selection shows a compact metadata-only view using the existing embedded GenBank record store. It states that graphical annotations require a newer analysis. It does not fall back to the former evidence-heavy detail.

### Damaged artifacts

Checksum, size, schema, unsafe path, duplicate identity, out-of-bounds feature, canonical-text inconsistency, or unresolved role errors are reported as nonfatal visualization-integrity warnings during UI load. Known calls remain visible. The detail pane falls back to metadata-only content.

### Missing source annotations

A valid sequence-only visualization shows the ruler, nucleotide strip, FASTA, and available record facts. The canvas states that source feature annotations were unavailable. No exon/CDS/translation inference is performed.

## Testing Strategy

### Artifact model and validation

- Round-trip the version 1 manifest descriptor and JSON document.
- Reuse the existing result-bundle artifact loader to reject unsafe paths, special files, size mismatch, and checksum mismatch.
- Reject schema mismatch, duplicate identities, invalid sequence checksums, out-of-bounds intervals, invalid strands, and inconsistent canonical text with focused fixtures.
- Verify legacy manifest decoding with no visualization descriptor.

### Extraction and canonical formats

- Use an `NHP00344`-shaped fixture with eight exon annotations.
- Verify sequence identity, exon coordinates/numbers, CDS coordinates, translation, qualifiers, and source ordinal.
- Verify canonical GenBank and FASTA bytes and deterministic record ordering.
- Verify sequence-only publication when the annotation track is absent.
- Verify unresolved required reference identity fails before successful publication.

### Complete-reference closest matching

- Create a fixture where a candidate's closest reference is not present among exact genotype calls.
- Verify the candidate retains that all-database closest reference for provisional naming.
- Verify that uncalled closest reference is included with `closest_novel_reference` or `closest_extension_reference` role.
- Verify extraction does not substitute the nearest exact-call genotype.
- Verify one reference can carry exact, novel-closest, and extension-closest roles simultaneously.

### Viewport behavior

- Verify known row selection displays graphical overview and facts rail.
- Verify known cell selection adds only the sample badge.
- Verify GenBank and FASTA full-pane modes show the stored canonical strings.
- Verify mode switching preserves record and selected feature state.
- Verify no support, alignment, co-occurrence, anchor, or supporting-sample sections are rendered.
- Verify comments, highlights, matrix targets, and selection callbacks remain intact.
- Verify candidate callback exclusivity and candidate detail remain unchanged.
- Verify legacy and damaged artifacts use metadata-only fallback.

### Deterministic performance protections

- Configure fixtures with the same selected allele and increasing cohort sizes.
- Verify selected-detail subview count remains constant.
- Verify no evidence aggregation hook, BAM reader, SQLite reader, FASTA reader, or formatter is invoked during selection or mode switching.
- Add a broad row-selection timing guard for a retained-demux-sized fixture while treating the deterministic dependency/subview assertions as the primary performance guarantee.

### Workflow and publication

- Verify the three artifact files are declared in the manifest with final relative paths, checksums, sizes, schema, and record count.
- Verify provenance contains actual reference, report, candidate, and output artifacts with final paths.
- Verify manifest-last atomic publication and rollback behavior.
- Verify explicit workbook and AI haplotyping revisions preserve the visualization descriptor.

### End-to-end validation

- Run the four exemplar samples through the embedded CLI against `IPD-MHC_NHKIR_classI_Mafa.lungfishref` into a new result path.
- Verify exact-call and uncalled candidate-closest reference roles in the published artifact.
- Verify `NHP00344` renders as `Mafa-E*02:01:01` with eight source exons and its annotated translation.
- Build and codesign `Lungfish Debug`.
- Verify `CFBundleName` is `Lungfish Debug` and the identifier is `com.lungfish.browser.debug`.
- Launch the debug build with the fresh result bundle.

## Next-Tranche Contract

The later candidate detail work extends the versioned model rather than replacing the known-reference model.

For each candidate it will add:

- stable cluster identity;
- candidate sequence and checksum;
- persisted all-reference closest-reference identity;
- projected reference features;
- nucleotide changes with explicit precedence:
  1. changes in exons 2 or 3;
  2. nonsynonymous exon changes outside exons 2 and 3;
  3. synonymous exon changes outside exons 2 and 3;
  4. intron changes;
- intron-fill and additional-exon spans for extensions;
- reference-relative translation and protein consequences;
- seven-exon versus short-eighth-exon interpretation;
- support class, distinct sample count, stable sample IDs, and read counts;
- canonical candidate GenBank and FASTA records containing explicit provenance and support qualifiers.

The candidate's closest-reference identity remains the result of searching the complete reference database. It is never restricted to exact-match genotypes observed in the analysis cohort.
