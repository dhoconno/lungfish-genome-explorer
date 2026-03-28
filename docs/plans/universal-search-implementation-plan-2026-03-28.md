# Universal Project Search - Implementation Plan (2026-03-28)

## Status
- Owner: Project lead orchestration (Codex main agent)
- Branch: `metagenomics-workflows`
- Last updated: 2026-03-28
- Execution mode: Implement in recursive slices until feature-complete for integration testing.

## Goal
Introduce a project-scoped universal search that indexes datasets and analysis artifacts so users can reliably find entities by:
- Dataset type (`FASTQ`, `VCF`, etc.)
- Sample metadata (`sample_name`, `sample_role`, templates like `air_sample`)
- Date ranges (`collection_date`, run/save timestamps)
- Manifest JSON content
- Analysis signatures (e.g., Kraken2/Bracken taxa, EsViritu virus detections such as `HKU1`)

The solution must be extensible, include CLI support for debugging/performance monitoring, and preserve existing behavior.

## Non-Goals (Phase 1)
- Full natural-language query understanding.
- Cross-project/global indexing (search is strictly within one project root).
- Remote/cloud search services.

## Architecture Decision
### Chosen backend: per-project SQLite search index (`.universal-search.db`)

Why this is selected:
- Structured predicates and range filters are first-class in SQL.
- Deterministic CLI and test behavior.
- Easy to evolve schema with migrations.
- Fits existing local-file architecture and offline workflows.

### Core Services evaluation (rejected for Phase 1)
Options considered: Core Spotlight / metadata indexing APIs.

Why deferred:
- Optimized for document discovery/ranking, not multi-attribute scientific filtering.
- Harder to guarantee deterministic query semantics for CLI debugging.
- More complexity for schema-like extensibility (typed bioinformatics fields).

Decision: prioritize SQLite now; keep adapter boundary so Core Services can be added later as optional acceleration if needed.

## Searchable Entity Inventory (Phase 1)
### 1) FASTQ dataset bundle (`*.lungfishfastq`)
- Core fields: dataset name, path, bundle type, processing state.
- Sample metadata from `metadata.csv` / resolved fields:
  - `sample_name`, `sample_type`, `sample_role`, `metadata_template`
  - `collection_date`, `geo_loc_name`, `host`, `organism`, `batch_id`, `run_id`
  - template/custom metadata fields
- Sidecar metadata (`*.lungfish-meta.json`): download/ingestion timestamps, source hints.

### 2) Reference/VCF dataset bundle (`*.lungfishref`)
- Bundle manifest fields (`manifest.json`) flattened to searchable key/value pairs.
- Variant track metadata from manifest (`variants[*]`).
- Variant database sample-level fields (sample names + metadata JSON from `samples` table).

### 3) Classification analysis result (`classification-*`)
- Sidecar metadata from `classification-result.json`.
- Parsed Kraken2 report (`classification.kreport`) taxa names (index top/breadth-limited taxa set for recall).
- Database/config fields for provenance filters.

### 4) EsViritu analysis result (`esviritu-*`)
- Sidecar metadata from `esviritu-result.json`.
- Detected virus entities from TSV (name, accession, family/genus/species, sample ID).

### 5) TaxTriage result (`taxtriage-*`) [baseline]
- Result sidecar metadata (presence, run IDs, sample IDs where available).

### 6) Generic JSON manifests in project
- Any `manifest.json` and `*-result.json` files flattened recursively into searchable attributes.

## Extensibility Model
- Store entity rows + normalized attribute rows (EAV-style) in SQLite.
- Add new entity indexers as independent scanner functions (no query API redesign needed).
- Query parser maps field tokens to attribute predicates; unknown `key:value` falls back to generic attribute matching.

## Query Model
- Free text terms: full-text/LIKE match across indexed text payload.
- Field tokens (phase 1):
  - `type:<entity-type>` e.g. `type:fastq_dataset`, `type:classification_result`
  - `format:<format>` e.g. `format:fastq`, `format:vcf`
  - `sample:<text>`
  - `virus:<text>`
  - `role:<value>` e.g. `role:air_sample`
  - `date>=YYYY-MM-DD`, `date<=YYYY-MM-DD`
  - Generic `key:value` metadata filter

## UI/UX Delivery Plan
### Phase 1 UX integration (incremental)
- Reuse sidebar search field for universal search inputs.
- Preserve current title/subtitle filtering as fallback.
- When project open: query universal index and include metadata matches in sidebar filtered tree.
- Keep query syntax lightweight and discoverable (placeholder/help text implemented).

Note from UX expert pass:
- Dedicated universal-search panel remains preferred long-term UX; implemented as Phase 2 to de-risk initial rollout while preserving discoverability now.

### Phase 2 UX (post-Phase 1)
- Dedicated universal search panel with result grouping (Datasets, Analyses, Manifest matches).
- Saved/recent queries and facet chips.

## CLI Plan
Add dedicated command for project-scoped universal search:
- `lungfish universal-search <project-path> --query "..."`
- `--reindex` to force rebuild
- `--limit`
- `--stats` to print index/query timings and entity counts
- JSON output via existing `--format json`

This CLI doubles as debugging + performance monitoring surface.

## Implementation Breakdown

### Milestone A - Core index + query engine (LungfishIO)
- [x] Add `ProjectUniversalSearchIndex.swift` with:
  - DB init/schema/migration hooks
  - full rebuild indexing flow
  - query execution API
  - stats/metrics API
- [x] Add query parser/model types (`ProjectUniversalSearchQuery*`).
- [x] Add indexers for FASTQ, VCF/reference, classification, EsViritu, manifests.

### Milestone B - App integration (LungfishApp)
- [x] Add `UniversalProjectSearchService` actor/service for lifecycle + async indexing.
- [x] Wire sidebar project open/reload hooks to index refresh.
- [x] Upgrade sidebar search behavior to consume universal search matches + legacy text fallback.

### Milestone C - CLI integration (LungfishCLI)
- [x] Add `UniversalSearchCommand` and register in CLI root.
- [x] Implement text/table/json outputs and `--stats` diagnostics.

### Milestone D - Testing and regression hardening
- [x] Add IO tests for index rebuild/query behavior with synthetic project fixtures.
- [x] Add parser tests for token/range queries.
- [x] Add App tests for search orchestration path (project service indexing/query behavior).
- [x] Add CLI tests for argument parsing/basic command execution path.
- [x] Run targeted test suites then broaden.

## Schema (Phase 1 Draft)
- `us_entities(id TEXT PRIMARY KEY, kind TEXT, title TEXT, subtitle TEXT, format TEXT, url TEXT, parent_url TEXT, mtime REAL, size_bytes INTEGER, indexed_at TEXT, search_text TEXT)`
- `us_attributes(entity_id TEXT, key TEXT, value TEXT, number_value REAL, date_value TEXT, bool_value INTEGER, value_type TEXT, PRIMARY KEY(entity_id,key,value), FOREIGN KEY(entity_id) REFERENCES us_entities(id) ON DELETE CASCADE)`
- Indexes:
  - `idx_us_entities_kind`, `idx_us_entities_format`, `idx_us_entities_url`
  - `idx_us_attr_key_value`, `idx_us_attr_key_date`, `idx_us_attr_key_number`

## Performance and Observability
- Capture timing metrics:
  - full index rebuild duration
  - per-entity-indexer durations
  - query latency
- Expose timings in CLI `--stats`.
- Keep rebuild idempotent and safe to re-run on filesystem change events.

## Risks and Mitigations
- Large projects may make full rebuild expensive.
  - Mitigation: start with full rebuild for correctness, add incremental diff indexing in Phase 2.
- Query syntax discoverability.
  - Mitigation: maintain plain-text search compatibility + add documented examples.
- Schema growth from manifest flattening.
  - Mitigation: cap extreme JSON flatten depth/entry count per file in Phase 1.

## Definition of Done (Phase 1)
- Project-level universal search returns expected results for FASTQ/VCF/classification/EsViritu/manifest use-cases.
- Sidebar can surface metadata-driven matches (not title-only).
- CLI command supports querying and performance diagnostics.
- Test coverage added for indexing/querying and no regressions in critical paths.

## Execution Log
- 2026-03-28: Plan created and persisted before implementation.
- 2026-03-28: Delegated expert passes launched for architecture/UX/bioinformatics inventory; outputs will be folded back into this plan and code comments.
- 2026-03-28: Implemented SQLite-backed `ProjectUniversalSearchIndex` + query parser models in `LungfishIO`.
- 2026-03-28: Implemented `UniversalProjectSearchService` actor and integrated sidebar search + debounced project reindexing in `LungfishApp`.
- 2026-03-28: Added `lungfish universal-search` CLI command with `--reindex`, `--stats`, and JSON/TSV/text outputs.
- 2026-03-28: Added IO and CLI tests covering parser tokens, indexing/query behavior, and command registration/parsing.
- 2026-03-28: Fixed SQLite binder recursion crash in universal-search index and added app-layer service tests for on-demand indexing and query coverage.
