# Full-Length MHC Compact Hit-Shape Artifact Design

Date: 2026-07-21

Status: Approved by user direction; implementation authorized

## Summary

Fresh full-length ONT MHC analyses will write schema-version 2 candidate and un-nameable JSON documents that preserve the compact topology of both alignment stages without embedding every BAM locator.

The JSON will record how many alignments connect each query to each target, which queries or targets are exact matches, and which are the biologically closest match or tied closest matches. The two sorted, indexed BAM/BAI pairs remain the authoritative per-alignment evidence. Only the single reciprocal alignment selected for a candidate or un-nameable record is retained as a locator because its start and CIGAR drive the graphical difference view.

This replaces the schema-version 1 behavior that serialized hundreds of thousands of repeated BAM paths, query names, target names, starts, and CIGAR strings. That behavior produced a 518 MB `candidate-alleles.json` in the Ionis exemplar, exceeded the loader's 256 MiB aggregate parsed-artifact budget, and caused the viewport to omit every novel and extension allele.

## Scope

This change is limited to the full-length ONT MHC scientific artifacts and their existing viewport and Excel consumers.

It will:

- write compact schema-version 2 candidate and un-nameable JSON documents;
- continue reading valid schema-version 1 documents within the existing safety budget;
- keep the typed candidate-artifact manifest at schema version 1 because its shape does not change;
- keep the existing 256 MiB loader budget unchanged;
- retain the two coordinate-sorted, indexed BAM/BAI pairs as authoritative evidence;
- expose compact alignment counts and exact/closest relationships in the viewport facts and both Excel projections;
- preserve every candidate and un-nameable stable cluster as one Excel detail row; and
- record the summary derivation and schema in workflow and workbook provenance.

It will not:

- raise memory or artifact-size limits;
- add a new database;
- add general BAM browsing to other Lungfish surfaces;
- rewrite existing result bundles in place;
- change candidate classification, provisional naming, or the four viewport tint categories; or
- remove the selected reciprocal locator required by the graphical allele-detail projection.

Fresh analysis is the supported way to obtain compact version-2 artifacts. Smaller version-1 bundles remain readable. Oversized version-1 bundles remain fail-soft and require a fresh analysis rather than bypassing the safety budget.

## Root Cause

The final cohort BAM maps reference-allele queries to namespaced sample-cluster targets. The current pipeline parses every mapped SAM record into an `ONTMHCEvidenceLocator`, groups those locators by target, and copies the full arrays into every candidate observation. The reciprocal classifier also stores all reciprocal locators for un-nameable clusters.

The viewport uses the observation arrays only for their count, while its matrix projection creates another flattened and sorted copy. Excel expands un-nameable locator arrays into one row per alignment. The duplicated strings are therefore expensive without being needed for normal rendering or analysis review.

The indexed BAMs already preserve every query name, target name, read group, coordinate, CIGAR, and optional tag. JSON should preserve the derived graph shape and classification decision, not a second copy of the BAM records.

## Version-2 Wire Model

### Genotyping hit shape

Each candidate observation contains one summary per source-cluster target:

```json
"genotyping_hit_summaries": [
  {
    "bam_path": "artifacts/alignments/genotyping-evidence.bam",
    "target_name": "CR1178|final_consensus_3_depth_106_ReadCount-106",
    "alignment_count": 381,
    "query_alignment_counts": {
      "NHP00344": 1,
      "NHP01122": 1
    },
    "exact_match_query_names": [],
    "closest_match_query_names": ["NHP11358"]
  }
]
```

Binding invariants:

- `alignment_count` is the number of unique schema-version 1 locator tuples represented by the summary.
- `query_alignment_counts` stores the count for every query-to-this-target edge and sums exactly to `alignment_count`.
- `exact_match_query_names` contains every query satisfying the existing known-genotype rule for that target.
- `closest_match_query_names` contains every query tied at the biological closest rank before deterministic lexical tie-breaking.
- all names are unique, nonempty, and canonically sorted in projections;
- every summary target belongs to the observation's sample and `source_cluster_ids`; and
- `bam_path` must equal the typed genotyping BAM declared in the artifact manifest.

An observation consolidating identical sequences from multiple source clusters retains a separate target summary for each source cluster. Counts are never merged across different BAM targets.

### Reciprocal hit shape

Each candidate and un-nameable record contains one summary for its stable cluster query:

```json
"reciprocal_hit_summary": {
  "bam_path": "artifacts/alignments/unmatched-to-reference.bam",
  "query_name": "0140f26a-7f48-59e0-8acd-619960c073fa",
  "alignment_count": 73,
  "target_alignment_counts": {
    "NHP00344": 1,
    "NHP11358": 1
  },
  "exact_match_target_names": [],
  "closest_match_target_names": ["NHP11358"]
}
```

Binding invariants mirror the genotyping summary:

- target counts sum to `alignment_count`;
- the query name equals the record's stable cluster ID;
- exact and closest target names occur in `target_alignment_counts`;
- exact targets follow the classifier's existing exact relationship rule;
- closest targets are the biologically tied best reciprocal relationships;
- the selected closest locator, when present, points to one of `closest_match_target_names`; and
- the BAM path equals the typed reciprocal BAM declared in the artifact manifest.

Candidates continue to require `selected_evidence`. Un-nameable records gain optional `selected_evidence`: it is absent only when no reciprocal alignment exists. It must be the classifier-selected closest analyzed alignment, never the lexically first locator.

## Aggregation and Ranking

The pipeline replaces `genotypingEvidenceLocators` with a streaming summary accumulator. It applies the same mapped-record validation and the same canonical six-field identity formerly used for locator deduplication. It parses CIGAR/NM metrics transiently, increments the appropriate query-to-target count, records all exact relationships, and retains the closest biological rank and ties. Coordinates and CIGARs are discarded after aggregation.

The reciprocal SAM parser continues to create typed alignments for classification. After classification, the writer reduces those alignments into target counts and exact/closest sets. The classifier-selected alignment remains the sole locator stored on each resulting record.

No GUI or workbook code reparses BAMs. A future explicit drill-down action may query the indexed BAM using names from the hit shape, but that is outside this change.

## Backward Compatibility

The loader accepts document schema versions 1 and 2:

- version 1 decodes locator arrays and normalizes them to the same in-memory counts/relationships available from the legacy payload;
- because version 1 lacks persisted ranking labels, exact/closest sets may be unavailable unless already represented by the selected record;
- version 2 decodes only compact summaries for observation and un-nameable bulk evidence;
- version 3 or later remains unsupported and fail-soft;
- the manifest remains schema version 1; and
- candidate and un-nameable documents in one bundle must use the same supported document version.

The loader validates checksums and sizes before decoding, validates summary arithmetic and typed BAM roles, and preserves known calls with an explicit integrity warning if candidate artifacts fail. It does not raise or bypass the aggregate parsed-artifact budget.

## Viewport Projection

The candidate matrix removes its unused per-sample arrays of BAM locators. It keeps only per-sample alignment counts derived from the summaries. The facts rail shows:

- total genotyping alignments;
- distinct genotyping query-to-target edges;
- exact genotyping query count;
- closest genotyping query names;
- reciprocal alignment and target counts; and
- exact/closest reciprocal target names.

The selected reciprocal locator remains available to the graphical detail presenter. The viewport does not open either BAM when a row is selected, so selection remains instantaneous and bounded in memory.

## Excel Projection

Both initial workbook generation and the explicit `current.xlsx` update use the same version-aware projection.

`Candidate Alleles` and `Un-nameable Clusters` become one row per stable cluster ID. They include numeric alignment/edge counts, exact/closest relationship names, existing sample support, and selected closest-alignment fields. The version-1 updater compacts old locator arrays into the version-2 row shape; it does not preserve one row per locator or invent a closest un-nameable locator.

The unified genotype pivot and managed `Full Sequencing Results 1` candidate block add only bounded numeric summary columns needed for analyst sorting. Detailed query/target relationship fields remain in the dedicated candidate and un-nameable sheets. Known rows leave candidate fields blank. Viewport visibility settings never remove workbook records.

The Interpretation Guide will state that BAMs are authoritative for individual alignments and that JSON/Excel carry a compact derived hit topology.

## Provenance

The candidate JSON and un-nameable JSON render transformations record:

- document schema version 2;
- the exact source BAM/BAI references, checksums, and sizes;
- canonical locator identity and deduplication rules;
- exact and closest ranking semantics;
- count reconciliation requirements;
- the absence of per-alignment locator arrays; and
- output paths, checksums, sizes, status, wall time, and runtime identity.

Initial workbook and explicit workbook-update provenance record the compact workbook projection version and all source artifact references. Existing CLI command, tool-version, runtime, stderr, and publication provenance remains intact.

## Testing and Acceptance

Automated tests must prove:

- version-2 JSON contains compact hit shapes and no observation or un-nameable locator arrays;
- query/target counts, exact sets, closest ties, and selected locators are deterministic and reconcile;
- version-1 fixtures remain readable within the existing byte budget;
- invalid counts, names, target ownership, selected relationships, or BAM roles fail soft;
- schema version 3 remains unsupported;
- large hit counts allocate no locator arrays in the UI;
- row selection does not open BAMs or duplicate hit maps;
- candidate and un-nameable Excel sheets contain exactly one data row per stable ID;
- both Excel update paths retain every candidate and emit the same compact fields;
- classification and graphical difference tracks remain unchanged; and
- full-length workflow provenance describes the new derivation.

The Ionis-sized regression fixture or a synthetic equivalent must produce candidate JSON plus un-nameable JSON and FASTA whose aggregate size is below the existing 256 MiB loader budget. A fresh four-sample CLI exemplar run is the final scientific integration check when runtime permits.
