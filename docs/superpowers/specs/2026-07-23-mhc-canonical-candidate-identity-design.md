# Canonical MHC Candidate Identity and Export Boundary Design

**Date:** 2026-07-23

## Scope

This change applies only to forward full-length ONT MHC genotyping runs and the
full-length MHC results surface. It corrects duplicate novel/extension allele
rows caused by sample-specific differences outside the reference-ready genomic
allele and establishes a strict boundary between internal evidence and
user-facing scientific artifacts.

Vestigial genotyping workflows are out of scope. Existing result bundles remain
readable; a fresh analysis run is required to obtain the new canonical
identities and artifacts.

## Problem

The current candidate writer groups unmatched consensuses by their complete
normalized sequence and derives `stable_cluster_id` from that sequence. In the
four-sample exemplar, multiple pairs of raw consensuses differ only in terminal
sequence outside the lifted coding span. The later GenBank builder trims each
pair to identical genomic sequences, but that happens after grouping,
classification, stable-ID assignment, viewport projection, and workbook
projection. Lungfish therefore shows two singleton rows for what is one shared
genomic allele.

The following pairs in
`2026-07-22-structural-ext-debug-v4.lungfishgenotype` demonstrate the defect:

- `Mafa-A1*067:05_ext`
- `Mafa-B*007:06:01_ext`
- `Mafa-B*013:16_ext`
- `Mafa-B*046:03_ext`

Each pair has distinct full-consensus sequences but an exactly identical
UTR-trimmed genomic sequence. The same mechanism affects some `_nov` rows.

## Chosen Design

Lungfish will use two identity layers.

### Internal raw-observation identity

Each full consensus retains an identity derived from its complete normalized
sequence. This identity continues to address:

- the raw consensus and its flanking sequence;
- sample and read-group membership;
- Savont source-cluster IDs and read counts;
- genotyping and reciprocal BAM query names;
- complete hit-shape summaries and evidence locators; and
- the mapping from raw observation to canonical allele.

These data remain stored in the `.lungfishgenotype` project so projects can be
shared between users and laboratories without losing traceability. They are
internal evidence, not reference-ready allele exports.

### Canonical allele identity

After reciprocal classification and closest-reference annotation liftover,
Lungfish derives the reference-ready genomic sequence by removing sequence
outside the outer lifted CDS boundaries. The canonical allele stable ID is the
existing deterministic SHA-256/UUID-compatible ID calculated from this exact
normalized UTR-trimmed genomic sequence.

Two observations merge into one named candidate only when all of the following
are true:

1. Their normalized UTR-trimmed genomic sequences are exactly equal.
2. Their classifications agree (`novel` or `extension`).
3. Their locus, provisional allele name, closest reference, closest-reference
   molecule class, and `extension_of` interpretation agree.
4. Neither record has conflicting or unresolved reference-readiness metadata.

Display name alone never causes a merge. Two candidates with the same
provisional name but different trimmed sequences remain separate rows with
different stable IDs.

Merged records aggregate observations, sample IDs, occurrence count, per-sample
read counts, total reads, support class, genotyping hit shapes, and compatible
cDNA interpretations. A deterministic representative raw observation is chosen
only for evidence navigation: highest cluster-read support, then raw stable ID
as the tie-breaker.

## Artifact Boundary

Every artifact intended to be opened or submitted outside Lungfish contains
only UTR-trimmed genomic sequences or derivatives computed from those
sequences.

### External/user-facing artifacts

The following rules apply:

- Candidate Alleles FASTA contains one UTR-trimmed genomic sequence per
  canonical allele.
- Candidate Alleles GenBank contains the same UTR-trimmed genomic sequence,
  lifted and rebased exon/CDS annotations, CDS translations, support metadata,
  project origin, and nucleotide/consequence comments.
- The root-level deduplicated unmatched FASTA contains only exact-deduplicated,
  UTR-trimmed, reference-ready genomic candidate sequences. It no longer
  exposes full consensuses or terminal flanking sequence.
- Any user-facing un-nameable FASTA or GenBank record is emitted only when
  defensible lifted outer CDS boundaries exist; its sequence is UTR-trimmed.
- The **Unmatched Alleles** Excel sheet stores the UTR-trimmed genomic sequence
  in its nucleotide column and the CDS-derived putative amino-acid translation
  in its translation column. It never stores a full consensus or flanking
  sequence.
- The Unified Genotype Pivot and viewport use canonical IDs and aggregate
  support into one row per compatible canonical allele.

If an un-nameable cluster has no defensible lifted outer CDS boundaries,
Lungfish retains its identifier, reason, support, and internal-artifact
reference in user-facing metadata, but leaves external nucleotide and
translation fields empty and omits it from sequence-only external files.
Lungfish must not present an untrimmed sequence as reference-ready.

### Internal project artifacts

The `.lungfishgenotype` bundle retains:

- a complete deduplicated raw-consensus FASTA, including flanking sequence;
- raw stable IDs and raw sequence checksums;
- the source-to-canonical identity mapping;
- every raw observation and its sample/read support;
- BAM/BAI artifacts and compact hit-shape summaries;
- per-observation classification and trim coordinates; and
- records explaining why a sequence could not be made reference-ready.

Internal paths are recorded in the candidate JSON and reproducibility
provenance. They need not be prominent in the Inspector artifact list, but they
remain resolvable within the project.

## Data Model

The candidate document advances to schema version 4. Version 4 separates:

- `stable_cluster_id`: canonical UTR-trimmed allele ID for named candidates;
- `fasta_record_id`: canonical external FASTA record ID;
- `sequence_sha256`: canonical UTR-trimmed genomic sequence checksum;
- `source_sequence_cluster_ids`: complete raw-consensus stable IDs merged into
  the canonical allele;
- `representative_source_sequence_cluster_id`: deterministic raw evidence
  cluster used for the selected alignment/detail-pane locator; and
- observation-level `source_sequence_cluster_id`: the raw consensus identity
  whose BAM query and hit summaries support that observation.

The existing Savont `source_cluster_ids` field keeps its current meaning and is
not reused for raw sequence identities.

The schema decoder remains backward compatible with versions 1 through 3.
Older documents synthesize a one-to-one source/canonical relationship.

Un-nameable records retain raw identity unless a reference-ready trim can be
established. A trim-ready un-nameable sequence may use a separate canonical
export identity while preserving its raw source identity internally.

## Pipeline Data Flow

1. Normalize and exact-deduplicate complete raw consensuses.
2. Assign raw stable IDs and write the internal raw-consensus evidence FASTA.
3. Map raw IDs to the reference library and retain BAM/BAI plus compact hit
   shapes.
4. Classify every raw sequence and select/liftover the closest reference.
5. Calculate orientation-correct outer lifted CDS trim coordinates and
   reference-readiness status once in a shared canonicalization component.
6. Produce an orientation-correct UTR-trimmed genomic sequence for each
   reference-ready record.
7. Group compatible named records by the exact canonical sequence and
   interpretation fields.
8. Aggregate observations and choose the representative raw evidence record.
9. Write schema-v4 candidate JSON plus the internal source-to-canonical map.
10. Generate viewport rows, workbook rows, public FASTA, and GenBank from the
    same canonical records.
11. Validate that every externally serialized sequence equals the canonical
    trimmed sequence and that no full raw sequence leaks into an external
    sequence field.

Canonicalization occurs after per-raw mapping and classification. Lungfish does
not trim before alignment because terminal and intronic structure is required
to recognize cDNA extensions correctly.

## Validation and Failure Behavior

Publication is blocked when:

- a named candidate lacks defensible lifted outer CDS boundaries;
- a canonical sequence is empty or contains invalid nucleotide characters;
- the canonical ID/checksum does not match the canonical sequence;
- merged records disagree on required interpretation fields;
- an observation references a raw ID absent from the internal evidence map;
- a BAM locator query does not match the observation's raw source identity; or
- an external FASTA, GenBank, or Excel sequence differs from the canonical
  trimmed sequence.

Records with different trimmed sequences remain separate and carry an explicit
ambiguity/readiness reason when scientifically valid. Two records with the same
trimmed sequence but conflicting required interpretation fields block
publication: a sequence-derived canonical ID cannot safely represent two
incompatible biological interpretations. Lungfish never merges merely to reduce
row count.

## Provenance

The workflow provenance records:

- the raw identity normalization and hash rule;
- the canonical identity normalization and hash rule;
- the liftover and outer-CDS trim rule;
- the reference-readiness gate;
- the exact merge compatibility fields;
- the deterministic representative-evidence selection rule;
- source and destination paths, checksums, and file sizes for internal and
  external sequence artifacts;
- candidate schema version 4 and source-to-canonical mapping counts;
- the resolved user options/defaults, exact argv, application/tool versions,
  runtime identity, wall time, exit status, and useful stderr required by
  `AGENTS.md`.

The final provenance points at published bundle paths rather than temporary
staging paths.

## User Experience

For the exemplar, the viewport and Unified Genotype Pivot should show four
shared extension rows rather than eight singleton extension rows. The known
duplicate novel pairs whose trimmed sequences are identical should also
collapse. Selecting a merged row still exposes its combined sample/read support
and permits navigation to raw evidence through internal project artifacts.

The Inspector emphasizes matrices and reference-review artifacts. Internal raw
artifacts remain available for traceability without being mistaken for
submission-ready sequences.

## Testing

Tests cover:

- exact raw-sequence differences outside the retained interval merge;
- differences inside the retained interval remain separate;
- identical display names with different canonical sequences remain separate;
- `_nov` and `_ext` records never merge with each other;
- conflicting locus, closest-reference, or `extension_of` interpretations do
  not merge;
- aggregated sample/read/occurrence/support values are correct;
- representative raw evidence selection is deterministic;
- BAM locators retain raw query IDs after canonical IDs change;
- schema-v4 round trips and schemas 1 through 3 still decode;
- FASTA, GenBank, Excel, and viewport use one canonical record and trimmed
  sequence;
- no external artifact contains terminal flanking sequence;
- un-nameable records without defensible trim boundaries expose metadata but no
  external sequence;
- internal raw FASTA and source-to-canonical mapping retain complete evidence;
- provenance contains the identity, trim, merge, artifact, runtime, and command
  details above; and
- a real four-sample CLI rerun produces the expected shared extension records
  and valid sorted/indexed BAM artifacts.

## Non-Goals

- Changing allele-naming rules, SNP counting, extension structural
  classification, or locus sort order.
- Removing raw sequence or alignment evidence from the project.
- Retrofitting old result bundles in place.
- Refactoring unrelated Lungfish workflows or hardening the detail pane beyond
  what this identity change requires.
