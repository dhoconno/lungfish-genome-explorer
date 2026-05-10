# Implementation Plan: Expanded MSA Action Registry and Viewport

Date: 2026-05-03
Branch: `codex/alignment-tree-viewers`

## Phase 0: Orchestration and Registry Foundation

- [x] Survey external graphical MSA tools with official documentation.
- [x] Collect independent biology, UI/UX, architecture, and QA/CLI assessments.
- [x] Create `MultipleSequenceAlignmentActionRegistry` in `LungfishIO`.
- [x] Add registry validation tests requiring provenance and CLI contracts for scientific data actions.
- [x] Add `lungfish msa actions` and `lungfish msa describe`.
- [x] Add `lungfish msa export --output-format fasta` for full or selected aligned FASTA with provenance sidecar.
- [x] Add CLI tests for registry JSON/TSV output.
- [x] Add CLI tests for selected aligned FASTA export and provenance.
- [x] Fix MAFFT wrapper argv to include resolved default options relevant to provenance.
- [x] Fix stale XCUI robot MSA row-gutter identifier.

## Phase 1: P0 Viewport Interaction

- [ ] Add overview strip (`multiple-sequence-alignment-overview`) showing conservation/gap/variable-site density and the visible window.
- [ ] Add go-to/search scope support for column, ungapped coordinate, row, annotation, and motif.
- [ ] Complete keyboard selection: arrow moves active cell, Shift extends block, Esc clears, row gutter selects rows, column header selects columns.
- [ ] Expand selected-item inspector for row/site/block statistics.
- [ ] Add coordinate map inspector rows for aligned column, ungapped row coordinate, consensus coordinate, and codon/CDS coordinate where available.
- [ ] Add stable AX proxy elements for active cell, selected row range, selected column range, and selected annotation.
- [ ] Add graphical tests for matrix nonblank, selected block, variable-site selection, and annotation lane visibility.

## Phase 2: CLI Action Runtime and Operation Center

- [ ] Introduce shared `MSAActionDescriptor` runtime adapters so GUI operations build CLI argv from the same action registry.
- [x] Add uniform `msaActionStart|Progress|Warning|Failed|Complete` JSON events with stable `operationID`.
- [ ] Consolidate MSA/import CLI JSON-line parsing into a generic Operation Center runner.
- [ ] Add Operation Center tests for success, warning, failure, cancel, final bundle URLs, and stderr details.
- [ ] Add artifact tests requiring final-path provenance and no `/tmp` leakage.

## Phase 3: Annotation CLI and Viewport Parity

- [x] Implement `lungfish msa annotate add`.
- [x] Implement `lungfish msa annotate edit|delete`.
- [x] Implement `lungfish msa annotate project`.
- [x] Keep MSA annotations SQLite-backed and update JSON compatibility snapshots.
- [ ] Add annotation table parity with `.lungfishref`: select, center, zoom, edit, delete, export, filter.
- [x] Add app-level accessibility coverage for visible annotation tracks and the shared annotation drawer.
- [ ] Add XCUI tests for Add Annotation from Selection and Apply Annotation to Selected Rows.
- [x] Add artifact tests for projection through gaps/indels, provenance, and track rendering.
- [ ] Add warning generation tests for low-confidence projection through gapped/frameshifted regions.

## Phase 4: Extraction, Export, Consensus

- [x] Implement `lungfish msa extract` for FASTA and derived `.lungfishmsa`.
- [ ] Add `.lungfishref` output support to `lungfish msa extract` after consensus/reference bundle annotation semantics are designed.
- [x] Implement `lungfish msa export` for aligned FASTA.
- [x] Extend `lungfish msa export` to PHYLIP, NEXUS, CLUSTAL, Stockholm, and A2M/A3M.
- [x] Implement FASTA-backed `lungfish msa consensus` with threshold, gap policy, row subset, and provenance.
- [ ] Add consensus `.lungfishref` output and richer ambiguity policy once reference bundle annotation propagation is specified.
- [ ] Route viewport context menus through CLI-backed extraction/export actions.
- [x] Preserve or explicitly warn about annotation loss for each export format.
- [ ] Add end-to-end CLI and app tests for selected row/column extraction, clipboard copy, file export, and derived bundles.

## Phase 5: Masking, Trimming, Row Filtering

- [x] Implement explicit range-based `lungfish msa mask columns` as a non-destructive derived bundle operation.
- [x] Add annotation-driven and gap-threshold mask selectors.
- [ ] Add codon-position mask selectors after CDS/reference bundle coordinate semantics are finalized.
- [x] Implement native gap-only and gap-threshold trimming.
- [ ] Add `trimAl` and `ClipKIT` wrappers once fake-tool tests and provenance contracts are in place.
- [ ] Implement row filter derived bundles by selection, metadata, gap fraction, identity, and explicit include/exclude lists.
- [ ] Add operation panels with resolved defaults and plugin-pack readiness.
- [ ] Add CLI fake-tool tests plus deterministic fixture artifact tests.

## Phase 6: Display Modes and Row Organization

- [ ] Add color modes: residue, conservation, difference from consensus, difference from reference, codon/nonsynonymous, no color.
- [ ] Add reference/anchor pinning.
- [ ] Add row metadata columns in the bottom Rows tab.
- [ ] Add hide/sort/filter controls that affect view state and export options without mutating source data.
- [ ] Add tests ensuring hidden rows are handled explicitly on export.

## Phase 7: Phylogenetics Handoff

- [x] Add `lungfish msa distance` for identity and p-distance matrices.
- [ ] Add tree-inference command family and action registry entries under a tree CLI root.
- [ ] Launch tree inference from MSA selections/masks and create `.lungfishtree` outputs.
- [ ] Record exact selected rows, masks, trim state, model, seed, bootstrap options, tool version, and final tree bundle provenance.
- [ ] Add XCUI tests for MSA-to-tree Operation Center progress and output opening.

## Phase 8: Debug Build Gate

- [ ] Run focused unit tests for registry, CLI, MSA bundle, annotation store, and MAFFT pipeline.
- [ ] Run app tests for viewer routing and inspector state.
- [ ] Run XCUI fixture smoke tests for MSA and tree opening.
- [ ] Run graphical semantic pixel checks.
- [ ] Build debug app with bundled CLI.
- [ ] Report build path, passing checks, and any deferred feature gates.

## Current Blocking Defects

- Any data-changing action that lacks CLI support or provenance is blocked from GUI exposure.
- Large alignment rendering still needs chunked SQLite-backed reads before claiming scale beyond moderate fixtures.
- Annotation projection must not silently cross low-identity, gapped, or frameshifted regions without warnings.
- Manual edit mode stays deferred until explicit edit-script provenance is designed.
