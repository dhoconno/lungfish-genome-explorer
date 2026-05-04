# Implementation Plan: Native MSA and Tree Bundles/Viewers

Date: 2026-05-02
Branch: `codex/alignment-tree-viewers`

## Phase 0: Baseline and Expert Inputs

- [x] Create isolated worktree.
- [x] Run baseline Geneious import tests.
- [x] Collect independent MSA and tree expert requirements.
- [x] Verify current arm64/noarch conda availability for candidate tools.

## Phase 1: Native IO Models and Parsers

- [ ] Add `MultipleSequenceAlignmentBundle` model, manifest, parser, writer, and importer in `LungfishIO`.
- [ ] Add `PhylogeneticTreeBundle` model, manifest, Newick/Nexus parser, writer, and importer in `LungfishIO`.
- [ ] Write `.viewstate.json`, `alignment-index.sqlite` / `tree-index.sqlite`, and `.lungfish-provenance.json` during imports.
- [ ] Add fixture-driven tests for accepted formats, warnings, checksum/provenance, and project-local temp behavior.

## Phase 2: CLI Import Commands

- [ ] Add `lungfish import msa`.
- [ ] Add `lungfish import tree`.
- [ ] Emit JSON progress events compatible with Operation Center runners.
- [ ] Test CLI commands end to end against fixture datasets.

## Phase 3: App Import Center and Application Exports

- [ ] Add native Import Center cards for MSAs and trees.
- [ ] Add app-level CLI runners for MSA/tree import with Operation Center progress.
- [ ] Route parseable application-export MSA/tree files into native bundles.
- [ ] Keep binary preservation disabled by default for these import paths.

## Phase 4: Viewers

- [ ] Replace the prototype MSA split/list/detail layout with a full alignment canvas: frozen row-name gutter, frozen site ruler, labeled consensus row, variable-site controls, and no viewport statistics drawer.
- [ ] Add an MSA annotation drawer at the bottom of the viewport for visible/selected annotation rows; keep bundle statistics and selection details out of the drawer.
- [ ] Add MSA Inspector document state for bundle statistics, warnings, consensus preview, provenance summary, and source artifacts.
- [ ] Add MSA Inspector selected-item state for selected row/site/range/block details.
- [ ] Wire MSA selection context menus to the shared FASTA extraction idiom: extract, copy, export, create bundle, and run operation.
- [ ] Extend the `.lungfishmsa` import/alignment workflow to preserve source annotations through sequence-only tools by writing controlled FASTA headers plus sidecar row/annotation maps before MAFFT and rehydrating annotations into the final bundle after alignment.
- [ ] Support FASTQ-derived assembled/consensus sequence inputs by converting to controlled FASTA internally while retaining source FASTQ provenance and quality summaries as non-aligned sidecar metadata.
- [ ] Add `PhylogeneticTreeViewController` with tree canvas, searchable tip list, selection details, and collapse/search controls.
- [ ] Register `.lungfishmsa` and `.lungfishtree` as directory document types.
- [ ] Wire bundle opening from sidebar/document manager into the correct viewer.

## Phase 5: Plugin Packs

- [ ] Split the inactive combined phylogenetics pack into active `multiple-sequence-alignment` and `phylogenetics` packs.
- [ ] Pin exact conda packages and metadata.
- [ ] Add smoke tests and registry tests for both packs.
- [ ] Add operation-panel gating that reports required pack readiness.

## Phase 6: Artifact and UI Testing

- [ ] Add artifact tests asserting manifest/payload/provenance shapes for imported bundles.
- [ ] Add app tests for Import Center cards and viewer smoke state.
- [ ] Add XCUI-style fixture tests or readiness tests for opening native MSA/tree bundles.
- [ ] Add optional env-gated conda workflow tests for installed real tools.

## Phase 7: Debug Build

- [ ] Run targeted test suites.
- [ ] Build `Lungfish` debug app.
- [ ] Report build path, test results, and any deferred scope.

## Implementation Notes

- Use project-local `.tmp` via `ProjectTempDirectory` whenever staging is needed.
- Do not use `/tmp` in new import workflows.
- For first usable scope, import/view correctness takes priority over running tree inference or MSA generation.
- Unsupported rich formats should warn cleanly and avoid partial bundles.
- Application export import may reuse native importers where possible; it must not silently preserve binary artifacts in the initial alignment/tree flow.
