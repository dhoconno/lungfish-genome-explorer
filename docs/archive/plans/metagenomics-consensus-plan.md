# Metagenomics Feature: Consensus Phased Implementation Plan

**Date**: 2026-03-22
**Source documents**:
- `docs/designs/metagenomics-workflow-design.md` (genomics expert)
- `docs/designs/DESIGN-005-TAXONOMY-VISUALIZATION.md` (UX expert)
**Target**: Swift 6.2, macOS 26, strict concurrency

---

## Guiding Principles

1. **Data layer first, UI last.** Every phase produces artifacts that can be
   validated with automated tests before any AppKit code is written.
2. **One actor boundary per phase.** Each new actor or `@MainActor` class is
   introduced in its own phase so isolation issues surface immediately.
3. **Parsers are pure functions.** Kreport/Bracken/Kraken parsers take `Data`
   or `URL` and return value types. No singletons, no side effects.
4. **Reuse existing infrastructure.** CondaManager for tool execution,
   ProvenanceRecorder for provenance, GenomicSummaryCardBar for summary
   cards, FASTQDerivativeRequest for virtual FASTQ output, OperationCenter
   for progress display.
5. **Max ~500 new lines per phase.** Phases that approach that limit are
   split along natural file boundaries.

---

## Phase 1: Data Models and Parsers

**Goal**: Define all metagenomics value types in LungfishIO and LungfishWorkflow, and implement the kreport parser with full test coverage.

**Dependencies**: None (leaf phase).

### New Files

| File | Module | Contents |
|------|--------|----------|
| `Sources/LungfishIO/Formats/Kraken/TaxonomicRank.swift` | LungfishIO | `TaxonomicRank` enum (U, R, D, K, P, C, O, F, G, S, S1) with `displayName`, `ringIndex`, CaseIterable, Codable, Sendable |
| `Sources/LungfishIO/Formats/Kraken/TaxonNode.swift` | LungfishIO | `TaxonNode` reference type (class, Sendable via immutability after construction): taxId, name, rank, depth, readsCladeDirect, readsClade, fractionClade, fractionDirect, children, parentTaxId; also `TaxonTree` struct wrapping root + summary stats (totalReads, classifiedReads, unclassifiedReads, unclassifiedFraction) with `allNodes()`, `node(taxid:)`, `nodes(at:)` |
| `Sources/LungfishIO/Formats/Kraken/KreportParser.swift` | LungfishIO | `KreportParser.parse(url:) throws -> TaxonTree`, `KreportParser.parse(data:) throws -> TaxonTree`; pure-function parser, builds tree from indentation + rank codes |
| `Sources/LungfishIO/Formats/Kraken/BrackenParser.swift` | LungfishIO | `BrackenParser.mergeBracken(url:into:) throws`; reads bracken TSV, patches `brackenReads` / `brackenFraction` on matching nodes |
| `Sources/LungfishWorkflow/Metagenomics/MetagenomicsModels.swift` | LungfishWorkflow | `MetagenomicsTool` enum, `DatabaseCollection` enum with download URLs / sizes / RAM estimates / display names, `MetagenomicsDatabase` struct (Codable, Sendable, Identifiable), `DatabaseLocation` enum (local / bookmark), `DatabaseStatus` enum, `MetagenomicsGoal` enum (classify, profile, profileMarkers, extract), `MetagenomicsPrecision` enum (sensitive, balanced, precise) with parameter mappings |
| `Tests/LungfishIOTests/Kraken/KreportParserTests.swift` | Tests | Full parser test suite |
| `Tests/LungfishIOTests/Kraken/BrackenParserTests.swift` | Tests | Bracken merge test suite |
| `Tests/LungfishWorkflowTests/Metagenomics/MetagenomicsModelsTests.swift` | Tests | Model encoding / decoding, collection metadata |
| `Tests/LungfishIOTests/Kraken/Fixtures/sample.kreport` | Fixtures | Minimal kreport fixture (20-30 lines covering all ranks, unclassified, subspecies) |
| `Tests/LungfishIOTests/Kraken/Fixtures/sample.bracken` | Fixtures | Matching bracken output for the fixture |

### Modified Files

None. All new code.

### Test Plan

| Test Name | Validates |
|-----------|-----------|
| `testParseMinimalKreport` | 6-column TSV parsing, correct root/unclassified split |
| `testTreeStructureFromIndentation` | Parent-child links reconstructed from leading spaces |
| `testSubspeciesRanks` | S1/S2 nodes are children of the S node |
| `testCladeSumConsistency` | `readsClade >= readsCladeDirect` for every node |
| `testFractionsSumToOne` | Root fractionClade ~= 1.0 (within rounding) |
| `testAllNodesFlattening` | `allNodes()` returns every node in pre-order |
| `testNodeLookupByTaxid` | `node(taxid:)` finds leaf and internal nodes |
| `testNodesAtRank` | `nodes(at: .species)` returns only species-rank nodes |
| `testEmptyKreportThrows` | Empty file produces a descriptive error |
| `testMalformedLineSkipped` | Lines with wrong column count are skipped with warning |
| `testBrackenMerge` | Bracken values patched onto correct nodes, others remain nil |
| `testBrackenMergeUnknownTaxidIgnored` | Bracken rows with taxids not in tree are skipped |
| `testTaxonomicRankOrdering` | `ringIndex` values form a strictly increasing sequence |
| `testDatabaseCollectionMetadata` | Every collection has non-zero size, non-empty display name |
| `testMetagenomicsDatabaseCodable` | Round-trip encode/decode including bookmark location |
| `testPrecisionParameterMapping` | Each precision preset maps to expected confidence / hit-groups / Bracken threshold |

### Acceptance Criteria

- `swift test --filter KreportParserTests` passes.
- `swift test --filter BrackenParserTests` passes.
- `swift test --filter MetagenomicsModelsTests` passes.
- `TaxonTree` built from the fixture has the correct number of nodes at each
  rank, correct clade sums, and correct parent-child links.

### Estimated New Lines

~450 (models ~150, kreport parser ~120, bracken parser ~60, tests ~120).

---

## Phase 2: Database Registry Actor

**Goal**: Implement `MetagenomicsDatabaseRegistry`, the actor that manages database installations, verification, and bookmark-based relocation. No downloads yet -- just local registration, verification, and persistence.

**Dependencies**: Phase 1 (uses `MetagenomicsDatabase`, `DatabaseCollection`, `MetagenomicsTool`).

### New Files

| File | Module | Contents |
|------|--------|----------|
| `Sources/LungfishWorkflow/Metagenomics/MetagenomicsDatabaseRegistry.swift` | LungfishWorkflow | Actor with: `allDatabases()`, `databases(for:)`, `recommendedDatabase(for:ramBytes:)`, `registerExisting(at:) throws`, `verify(_:)`, `resolveLocation(_:)`, `remove(_:)`, persistence to `metagenomics-db-registry.json` |
| `Tests/LungfishWorkflowTests/Metagenomics/MetagenomicsDatabaseRegistryTests.swift` | Tests | Full registry test suite using temp directories |

### Modified Files

None.

### Test Plan

| Test Name | Validates |
|-----------|-----------|
| `testRegisterLocalDatabase` | Adds a database to registry, persists to JSON |
| `testRegisterDuplicateThrows` | Same path registered twice produces error |
| `testVerifyValidDatabase` | Directory with hash.k2d / opts.k2d / taxo.k2d returns `.ready` |
| `testVerifyMissingFilesReturnsCorrupt` | Missing required files returns `.corrupt` |
| `testRecommendedDatabaseByRAM` | 32 GB RAM recommends Standard, 16 GB recommends Standard-16, etc. |
| `testRecommendedViralBypassesRAM` | Viral DB recommended regardless of RAM when use case is viral |
| `testDatabasesFilteredByTool` | `databases(for: .kraken2)` excludes MetaPhlAn entries |
| `testRemoveDatabase` | Removes from registry, JSON updated, files untouched |
| `testPersistenceRoundTrip` | Write registry, create new actor instance, read back, all entries match |
| `testResolveLocalLocation` | Local path resolves to the same URL |

### Acceptance Criteria

- `swift test --filter MetagenomicsDatabaseRegistryTests` passes.
- Registry JSON round-trips correctly with multiple databases of different tools.
- RAM-based recommendation logic matches the table in the design doc.

### Estimated New Lines

~350 (actor ~220, tests ~130).

---

## Phase 3: Classification Pipeline

**Goal**: Implement the `MetagenomicsClassificationPipeline` that orchestrates Kraken2 (and optionally Bracken) execution via CondaManager, with provenance recording. This phase is CLI-testable -- no UI.

**Dependencies**: Phase 1 (models, parsers), Phase 2 (database registry for DB path resolution).

### New Files

| File | Module | Contents |
|------|--------|----------|
| `Sources/LungfishWorkflow/Metagenomics/MetagenomicsClassificationPipeline.swift` | LungfishWorkflow | Orchestrator: accepts goal, database, precision, input FASTQ paths; builds kraken2 command args; runs via CondaManager; optionally chains Bracken; records provenance via ProvenanceRecorder; reports progress via `@Sendable (Double, String) -> Void` callback |
| `Sources/LungfishWorkflow/Metagenomics/MetagenomicsEnvironment.swift` | LungfishWorkflow | `CondaEnvironment` definition for `lungfish-metagenomics` (kraken2, bracken, krakentools, metaphlan packages); tool-in-PATH detection helper |
| `Tests/LungfishWorkflowTests/Metagenomics/MetagenomicsClassificationPipelineTests.swift` | Tests | Unit tests with mock tool runner |

### Modified Files

| File | Change |
|------|--------|
| `Sources/LungfishWorkflow/Provenance/ProvenanceRecorder.swift` | No API changes needed; pipeline calls existing `beginRun` / `recordStep` / `completeRun` |

### Design Notes

- The pipeline class follows the `@unchecked Sendable` pattern (like
  `GenBankBundleDownloadViewModel`) so it can be called from
  `Task.detached` contexts.
- Progress is reported via a `@Sendable` closure, not `@Published` properties.
- The pipeline auto-detects paired-end from FASTQ bundle metadata and
  auto-detects read length for Bracken `-r` flag.
- `MetagenomicsPrecision` maps to concrete kraken2/bracken flags; the
  pipeline resolves these without the caller needing to know tool flags.

### Test Plan

| Test Name | Validates |
|-----------|-----------|
| `testClassifyCommandArgs` | Given goal=classify, precision=sensitive, paired=true: kraken2 args include `--paired`, `--confidence 0.0`, `--minimum-hit-groups 2` |
| `testProfileCommandArgsChainsKraken2ThenBracken` | Goal=profile produces two commands in sequence; Bracken input is kraken2 kreport output |
| `testPrecisionPresetsMapCorrectly` | Sensitive/balanced/precise each produce distinct confidence, hit-groups, threshold values |
| `testAutoDetectReadLength` | Read length extracted from FASTQ metadata, falls back to 150 |
| `testPairedEndDetection` | PE bundle produces `--paired` flag, SE bundle does not |
| `testMemoryMappingFlagWhenDBExceedsRAM` | DB size > 80% RAM triggers `--memory-mapping` |
| `testProvenanceRecordedForClassify` | After classify, ProvenanceRecorder has one step with correct tool/version/args |
| `testProvenanceRecordedForProfile` | After profile, ProvenanceRecorder has two steps with dependency link |
| `testProgressCallbackReceivesUpdates` | Progress callback invoked at least once with value in 0.0...1.0 |
| `testCancelStopsExecution` | Cancelling the Task stops the pipeline and cleans up partial output |

### Acceptance Criteria

- `swift test --filter MetagenomicsClassificationPipelineTests` passes.
- Command argument construction is deterministic and matches Kraken2
  documentation for all three precision presets.
- Provenance JSON for a two-step profile run includes `dependsOn` link.

### Estimated New Lines

~450 (pipeline ~250, environment ~60, tests ~140).

---

## Phase 4: Taxonomy Visualization Core (Sunburst + Table)

**Goal**: Implement the CoreGraphics sunburst chart (`SunburstChartView`) and the taxonomy table (`TaxonomyTableController`) as standalone NSView subclasses that accept a `TaxonTree` and render it. No integration with the main window yet.

**Dependencies**: Phase 1 (TaxonTree, TaxonNode, TaxonomicRank).

### New Files

| File | Module | Contents |
|------|--------|----------|
| `Sources/LungfishApp/Views/Metagenomics/TaxonomyPhylumPalette.swift` | LungfishApp | 20-slot phylum color palette (light/dark mode via `NSColor(name:)`), depth-tinting formula (saturation decay, brightness increase), colorblind-safe |
| `Sources/LungfishApp/Views/Metagenomics/SunburstChartView.swift` | LungfishApp | `SunburstChartView: NSView` -- `draw(_:)` with recursive ring rendering, center label, segment path computation, segment culling (< 0.5 degrees aggregated to "Other") |
| `Sources/LungfishApp/Views/Metagenomics/SunburstChartView+HitTesting.swift` | LungfishApp | `hitTest(radius:angle:)`, mouse tracking, single-click select, double-click zoom, click-center zoom-out |
| `Sources/LungfishApp/Views/Metagenomics/SunburstChartView+Accessibility.swift` | LungfishApp | VoiceOver elements for visible segments (role `.button`, label, value, hint), keyboard navigation (arrow keys, Enter, Escape) |
| `Sources/LungfishApp/Views/Metagenomics/TaxonomyTableController.swift` | LungfishApp | `NSOutlineView` data source + delegate: columns (Taxon Name with colored dot, Rank, Reads, Clade, %), disclosure triangles, sorting, alternating rows |
| `Tests/LungfishAppTests/Metagenomics/TaxonomyPhylumPaletteTests.swift` | Tests | Color assignment tests |
| `Tests/LungfishAppTests/Metagenomics/SunburstGeometryTests.swift` | Tests | Geometry calculation tests (no rendering) |

### Modified Files

None (standalone views, not yet wired into the app).

### Design Notes

- The sunburst precomputes an array of `SegmentGeometry` structs (inner/outer
  radius, start/end angle, node reference, CGPath) before `draw(_:)`.
  Hit testing scans this array.
- The table uses `NSOutlineView` with `NSTreeNode`-backed data source.
  Sorting preserves hierarchy (children sorted within parent).
- Label rendering inside segments uses arc-tangent rotation and WCAG
  luminance contrast check for text color.
- The sunburst maintains a `zoomRoot: TaxonNode` property. Double-click sets
  a new zoom root; clicking center resets to parent. Zoom animation is
  deferred to Phase 6.

### Test Plan

| Test Name | Validates |
|-----------|-----------|
| `testPhylumColorAssignment` | Each of the 20 phyla gets a distinct color |
| `testDepthTintingSaturationDecay` | Saturation decreases by 0.12 per depth level, clamped at 0.15 |
| `testDepthTintingBrightnessCap` | Brightness increases by 0.06 per depth, capped at 0.95 |
| `testDarkModeColorsAreBrighter` | Dark mode variant brightness > light mode variant brightness |
| `testSegmentAngleProportional` | Child segment angles sum to parent angle; each proportional to cladeCount |
| `testSmallSegmentsAggregated` | Segments < 0.5 degrees merged into "Other" |
| `testCenterRadiusIs15Percent` | Center circle radius = 15% of available radius |
| `testHitTestFindsCorrectNode` | Given (radius, angle), returns the node whose segment contains that point |
| `testHitTestCenterReturnsZoomRoot` | Point inside center circle returns the current zoom root |
| `testHitTestOutsideReturnsNil` | Point beyond outermost ring returns nil |
| `testZoomRootChangesVisibleTree` | Setting zoomRoot to a genus node makes genus children the innermost ring |

### Acceptance Criteria

- `swift test --filter TaxonomyPhylumPaletteTests` passes.
- `swift test --filter SunburstGeometryTests` passes.
- The sunburst can be instantiated in a test window with the sample kreport
  fixture and renders without assertion failures (manual verification).
- Outline view populates with correct hierarchy and sorts correctly.

### Estimated New Lines

~500 (palette ~80, sunburst drawing ~150, hit testing ~80, accessibility ~50, table controller ~90, tests ~50).

---

## Phase 5: TaxonomyViewController Integration

**Goal**: Wire the sunburst and table into a `TaxonomyViewController` (following the `FASTQDatasetViewController` pattern), add the summary bar, breadcrumb trail, action bar, filter bar, and integrate into `ViewerViewController` for sidebar-driven display.

**Dependencies**: Phase 1 (data models), Phase 4 (sunburst + table views).

### New Files

| File | Module | Contents |
|------|--------|----------|
| `Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift` | LungfishApp | Top-level `@MainActor` NSViewController: contains summary bar, breadcrumb, NSSplitView (sunburst | table), action bar; accepts `TaxonTree`, coordinates selection sync between sunburst and table |
| `Sources/LungfishApp/Views/Metagenomics/TaxonomySummaryBar.swift` | LungfishApp | `TaxonomySummaryBar: GenomicSummaryCardBar` with 8 cards: Total Reads, Classified %, Unclassified %, Species count, Genera count, Top Hit, Shannon H', Simpson 1-D |
| `Sources/LungfishApp/Views/Metagenomics/TaxonomyBreadcrumbBar.swift` | LungfishApp | 28px bar showing zoom path (root > Domain > Phylum > ...), clickable segments, SF Symbol chevrons |
| `Sources/LungfishApp/Views/Metagenomics/TaxonomyActionBar.swift` | LungfishApp | 36px bottom bar: Extract Sequences, Export Report, Copy Chart, Info toggle |
| `Sources/LungfishApp/Views/Metagenomics/TaxonomyFilterBar.swift` | LungfishApp | Search field + rank picker + min-reads slider above the table; real-time filtering with 150ms debounce |
| `Sources/LungfishApp/Views/Metagenomics/TaxonomyTooltipView.swift` | LungfishApp | Hover tooltip showing name, rank, reads, percentages (follows HoverTooltipView pattern) |
| `Sources/LungfishApp/Views/Viewer/ViewerViewController+Taxonomy.swift` | LungfishApp | Extension: `showTaxonomyView(_:)` / `hideTaxonomyView()`, child controller management |

### Modified Files

| File | Change |
|------|--------|
| `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift` | Add `taxonomyViewController` property, call show/hide from sidebar selection handler |
| `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift` | Recognize kreport sidebar items, route to taxonomy display |

### Design Notes

- The NSSplitView between sunburst and table is a raw NSSplitView (not
  NSSplitViewController) per macos26-api-rules. Default 60/40 split. Minimum
  widths: 300px chart, 260px table.
- Bidirectional selection sync: clicking a sunburst segment selects + scrolls
  to the table row; clicking a table row highlights the sunburst segment.
  Use a suppression flag to prevent feedback loops (same pattern as
  `NSTableView` programmatic selection in FASTQ drawer).
- Shannon and Simpson diversity indices are computed from `TaxonTree` species
  nodes using standard formulas.
- The breadcrumb bar updates when `SunburstChartView.zoomRoot` changes.
- The filter bar filters both the table (hidden rows) and the sunburst
  (filtered nodes drawn as "Other" aggregate).

### Test Plan

| Test Name | Validates |
|-----------|-----------|
| `testSummaryBarCardCount` | Summary bar has exactly 8 cards |
| `testShannonDiversityCalculation` | Known distribution produces expected H' value (within 0.01) |
| `testSimpsonDiversityCalculation` | Known distribution produces expected 1-D value (within 0.01) |
| `testBreadcrumbUpdatesOnZoom` | Setting zoomRoot updates breadcrumb segments |
| `testBreadcrumbClickResetsZoom` | Clicking an ancestor segment in breadcrumb changes zoomRoot |
| `testFilterBarHidesNonMatchingRows` | Typing "coli" in filter field hides rows not containing "coli" |
| `testFilterBarPreservesAncestors` | Ancestor rows of matches remain visible (grayed) |
| `testRankFilterShowsOnlySpecies` | Rank picker set to "Species" hides all non-species rows |
| `testMinReadsFilter` | Setting min reads to 100 hides taxa with fewer clade reads |
| `testSelectionSyncSunburstToTable` | Selecting a sunburst segment selects the corresponding table row |
| `testSelectionSyncTableToSunburst` | Selecting a table row highlights the corresponding sunburst segment |

### Acceptance Criteria

- `swift test --filter TaxonomyViewControllerTests` passes.
- Selecting a kreport result in the sidebar displays the taxonomy view
  in the main viewport (manual verification).
- Summary bar, breadcrumb, table, and sunburst all display correctly with
  the sample fixture data.
- Bidirectional selection sync works without feedback loops.

### Estimated New Lines

~480 (view controller ~120, summary bar ~60, breadcrumb ~70, action bar ~50, filter bar ~60, tooltip ~40, viewer extension ~30, tests ~50).

---

## Phase 6: Sunburst Animation, Context Menu, and Export

**Goal**: Add zoom animation (300ms ease-in-out), context menus on sunburst segments and table rows, chart-to-clipboard export, and TSV/CSV report export.

**Dependencies**: Phase 4 (sunburst view), Phase 5 (taxonomy view controller).

### New Files

| File | Module | Contents |
|------|--------|----------|
| `Sources/LungfishApp/Views/Metagenomics/SunburstChartView+Animation.swift` | LungfishApp | Zoom animation state machine: interpolate inner/outer radius + start/end angle over 300ms via `CVDisplayLink` or `CADisplayLink`; respect `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` (instant transition when true); ancestor fade-out, children fade-in |
| `Sources/LungfishApp/Views/Metagenomics/SunburstChartView+ContextMenu.swift` | LungfishApp | Right-click menu: Extract Sequences, Select All in Clade, Deselect, Zoom to, Reset Zoom, Copy Taxon Name, Copy Statistics |
| `Sources/LungfishApp/Views/Metagenomics/TaxonomyExportService.swift` | LungfishApp | `exportReport(tree:format:to:)` for TSV/CSV; `copyChartToPasteboard(view:)` renders sunburst at 2x into PNG on pasteboard |

### Modified Files

| File | Change |
|------|--------|
| `Sources/LungfishApp/Views/Metagenomics/SunburstChartView.swift` | Call into animation extension on double-click instead of instant zoom |
| `Sources/LungfishApp/Views/Metagenomics/TaxonomyActionBar.swift` | Wire Export Report and Copy Chart buttons to `TaxonomyExportService` |
| `Sources/LungfishApp/Views/Metagenomics/TaxonomyTableController.swift` | Add right-click context menu on table rows (same items as sunburst context menu) |

### Test Plan

| Test Name | Validates |
|-----------|-----------|
| `testAnimationRespectsReduceMotion` | When `reduceMotion` is simulated, zoom is instant (0ms duration) |
| `testAnimationKeyframeInterpolation` | At t=0.5 of a zoom, radii are at midpoint between start and end |
| `testContextMenuItemsPresent` | Right-click on a segment produces menu with all 7 expected items |
| `testExportReportTSV` | TSV export has correct header, one row per node, tab-delimited |
| `testExportReportCSV` | CSV export uses commas, quotes names containing commas |
| `testCopyChartProducesPNG` | After `copyChartToPasteboard`, pasteboard contains PNG data |
| `testCopyChartAt2xResolution` | PNG dimensions are 2x the view's point size |
| `testScrollWheelZoomDebounced` | Rapid scroll events produce at most one zoom per 200ms |

### Acceptance Criteria

- `swift test --filter SunburstAnimationTests` passes.
- `swift test --filter TaxonomyExportServiceTests` passes.
- Double-clicking a sunburst segment produces a smooth 300ms zoom animation
  (manual verification).
- Right-click menus appear on both sunburst segments and table rows.
- "Export Report..." saves a valid TSV; "Copy Chart" puts a PNG on the
  pasteboard (manual verification).

### Estimated New Lines

~400 (animation ~120, context menu ~60, export service ~100, tests ~120).

---

## Phase 7: Sequence Extraction and Virtual FASTQ Output

**Goal**: Implement the extraction pipeline (kraken2 output + extract_kraken_reads.py) and the extraction configuration sheet. Extracted reads become virtual FASTQ derivatives in the sidebar.

**Dependencies**: Phase 3 (classification pipeline produces .kraken output), Phase 5 (action bar triggers extraction).

### New Files

| File | Module | Contents |
|------|--------|----------|
| `Sources/LungfishWorkflow/Metagenomics/MetagenomicsExtractionPipeline.swift` | LungfishWorkflow | Wraps `extract_kraken_reads.py` from KrakenTools: accepts kraken output path, taxon IDs, include-children flag, original FASTQ paths; produces extracted FASTQ files; records provenance |
| `Sources/LungfishApp/Views/Metagenomics/TaxonomyExtractionSheet.swift` | LungfishApp | Sheet (520px wide): selected taxa list with checkboxes, "Include child taxa" toggle, "Include unclassified" toggle, FASTQ/FASTA radio, output name field, dynamic read count, Cancel/Extract buttons |
| `Tests/LungfishWorkflowTests/Metagenomics/MetagenomicsExtractionPipelineTests.swift` | Tests | Pipeline argument construction tests |

### Modified Files

| File | Change |
|------|--------|
| `Sources/LungfishApp/Services/FASTQDerivativeService.swift` | Add `case metagenomicsExtraction(krakenOutputPath:, taxonIDs:, includeChildren:, taxonName:)` to `FASTQDerivativeRequest` enum |
| `Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift` | Wire "Extract Sequences..." button and context menu item to present extraction sheet |
| `Sources/LungfishApp/Views/Metagenomics/TaxonomyActionBar.swift` | Transform action bar into progress view during extraction, revert on completion |

### Design Notes

- The extraction sheet is presented via `beginSheetModal` (not `runModal`,
  per macos26-api-rules).
- "Include child taxa" is on by default. Toggling it recalculates the total
  read count shown in the sheet.
- After extraction completes, a new `.lungfishfastq` bundle appears in the
  sidebar under the parent FASTQ. The bundle is initially pointer-based
  (virtual), following the existing `MaterializationState` lifecycle.
- The extraction pipeline follows the `@unchecked Sendable` pattern for
  `Task.detached` execution.

### Test Plan

| Test Name | Validates |
|-----------|-----------|
| `testExtractionCommandArgs` | Single taxon, include-children=true: produces correct `extract_kraken_reads.py` args |
| `testExtractionCommandArgsMultipleTaxa` | Multiple taxon IDs joined with commas in `-t` flag |
| `testExtractionPairedEnd` | PE input produces `-s` and `-s2` flags, `-o` and `-o2` outputs |
| `testExtractionFASTAOutput` | FASTA format selected: `--fastq-output` flag is absent |
| `testDerivativeRequestCodable` | `metagenomicsExtraction` case round-trips through Codable |
| `testExtractionSheetReadCountUpdates` | Toggling "Include child taxa" changes displayed read count |
| `testExtractionProvenanceRecorded` | After extraction, ProvenanceRecorder has a step with correct tool/args |

### Acceptance Criteria

- `swift test --filter MetagenomicsExtractionPipelineTests` passes.
- Selecting taxa in the sunburst/table and clicking "Extract Sequences..."
  opens the configuration sheet (manual verification).
- After extraction completes, a new virtual FASTQ bundle appears in the
  sidebar with the taxon name as its label (manual verification).

### Estimated New Lines

~400 (extraction pipeline ~120, extraction sheet ~140, derivative case ~20, tests ~80, wiring ~40).

---

## Phase 8: Database Management UI and Analysis Wizard

**Goal**: Implement the database management settings tab (download, verify, relocate, delete) and the three-step analysis wizard (goal picker, database picker, parameter panel).

**Dependencies**: Phase 2 (database registry), Phase 3 (classification pipeline).

### New Files

| File | Module | Contents |
|------|--------|----------|
| `Sources/LungfishApp/Views/Settings/Kraken2DatabaseManagerView.swift` | LungfishApp | Settings tab (SwiftUI via NSHostingController): database table with status indicators, download/cancel/delete actions, storage bar, location management, "Add Custom Database..." |
| `Sources/LungfishApp/Views/Metagenomics/MetagenomicsGoalPicker.swift` | LungfishApp | Step 1 sheet: radio buttons for Classify / Profile / Extract with SF Symbol icons and descriptions |
| `Sources/LungfishApp/Views/Metagenomics/MetagenomicsDatabasePicker.swift` | LungfishApp | Step 2 sheet: installed databases list with RAM-fit indicators, recommended badge, download-new / add-existing buttons |
| `Sources/LungfishApp/Views/Metagenomics/MetagenomicsParameterPanel.swift` | LungfishApp | Step 3 sheet: Precision slider (3 detents), threads slider, collapsible Advanced section with per-tool knobs |
| `Sources/LungfishApp/ViewModels/MetagenomicsAnalysisViewModel.swift` | LungfishApp | `@unchecked Sendable` view model: coordinates the three-step wizard, launches the classification pipeline, reports progress to OperationCenter |
| `Tests/LungfishAppTests/Metagenomics/MetagenomicsAnalysisViewModelTests.swift` | Tests | Wizard flow and pipeline launch tests |

### Modified Files

| File | Change |
|------|--------|
| `Sources/LungfishApp/App/MainMenu.swift` | Add "Metagenomics..." item to Analysis menu; add "Manage Metagenomics Databases..." to Tools menu |
| `Sources/LungfishApp/Views/Settings/` | Register new Databases tab in settings window |
| `Sources/LungfishApp/Views/Sidebar/` | Add right-click "Metagenomics..." context menu item on FASTQ bundles |
| `Sources/LungfishWorkflow/Metagenomics/MetagenomicsDatabaseRegistry.swift` | Add `download(collection:to:progress:) async throws` method using DownloadCenter pattern with resume support |

### Design Notes

- Database downloads use HTTP Range requests for resume, matching the
  existing `DownloadCenter` pattern used for genome downloads.
- The database manager view is SwiftUI hosted in an NSHostingController,
  consistent with other Settings tabs.
- The three-step wizard presents sheets sequentially. "Next" advances to the
  next sheet; "Back" returns to the previous. The final "Run Analysis" button
  dismisses all sheets and starts the pipeline.
- RAM recommendation: `ProcessInfo.processInfo.physicalMemory` compared
  against database `approximateRAMBytes`. Databases exceeding 80% of
  physical RAM show a warning and auto-enable `--memory-mapping`.
- Delete confirmation uses `beginSheetModal` (not `runModal`).

### Test Plan

| Test Name | Validates |
|-----------|-----------|
| `testGoalPickerAllOptionsPresent` | Three radio buttons with correct labels and SF Symbols |
| `testDatabasePickerShowsRecommended` | Recommended database has star badge based on system RAM |
| `testDatabasePickerDisablesUnmounted` | External-volume databases marked as unavailable when volume not mounted |
| `testParameterPanelDefaultsForSensitive` | Default precision slider position maps to sensitive defaults |
| `testParameterPanelAdvancedToggle` | Expanding advanced section shows all per-tool parameters |
| `testWizardFlowCompletesAndLaunches` | Completing all three steps triggers pipeline execution |
| `testWizardCancelAtAnyStep` | Cancel at step 2 returns to step 1; cancel at step 1 dismisses |
| `testDatabaseDownloadProgress` | Download progress callback updates the settings tab UI |
| `testDatabaseDeleteConfirmation` | Delete shows confirmation sheet, confirming removes from registry |
| `testDatabaseVerification` | "Verify" button checks file integrity and updates status indicator |

### Acceptance Criteria

- `swift test --filter MetagenomicsAnalysisViewModelTests` passes.
- Settings > Databases tab displays installed databases with correct status
  indicators (manual verification).
- Right-clicking a FASTQ bundle and selecting "Metagenomics..." opens the
  three-step wizard (manual verification).
- Completing the wizard starts a classification run visible in
  OperationCenter (manual verification).

### Estimated New Lines

~500 (database manager view ~120, goal picker ~60, database picker ~80, parameter panel ~80, view model ~80, menu/sidebar wiring ~30, tests ~50).

---

## Phase Dependency Graph

```
Phase 1: Data Models & Parsers
    |           |
    v           v
Phase 2:    Phase 4:
DB Registry   Sunburst + Table
    |           |
    v           v
Phase 3:    Phase 5:
Pipeline      TaxonomyViewController
    |           |
    |           v
    |       Phase 6:
    |       Animation + Export
    |           |
    v           v
Phase 7: Sequence Extraction
    |
    v
Phase 8: DB Management UI + Wizard
```

Phases 2 and 4 can proceed in parallel after Phase 1.
Phases 3 and 5 can proceed in parallel (3 depends on 1+2; 5 depends on 1+4).
Phase 6 depends only on 4+5 (UI polish).
Phase 7 depends on 3+5 (needs pipeline output + UI trigger).
Phase 8 depends on 2+3 (needs registry + pipeline).

---

## Total Estimates

| Phase | New Lines | New Files | Tests |
|-------|-----------|-----------|-------|
| 1. Data Models & Parsers | ~450 | 10 | 16 |
| 2. Database Registry | ~350 | 2 | 10 |
| 3. Classification Pipeline | ~450 | 3 | 10 |
| 4. Sunburst + Table | ~500 | 7 | 11 |
| 5. TaxonomyViewController | ~480 | 7 | 11 |
| 6. Animation + Export | ~400 | 3 | 8 |
| 7. Sequence Extraction | ~400 | 3 | 7 |
| 8. DB Management + Wizard | ~500 | 6 | 10 |
| **Total** | **~3,530** | **41** | **83** |

---

## Risk Assessment

| Risk | Mitigation | Phase |
|------|-----------|-------|
| Kraken2 not available on macOS ARM via conda | CondaManager already handles bioconda; verify kraken2 has osx-arm64 build; fall back to Rosetta 2 or container | 3 |
| Large database downloads (8-72 GB) timeout or corrupt | HTTP Range resume, SHA256 verification after download, retry with exponential backoff | 8 |
| CoreGraphics sunburst performance with 50K+ nodes | Segment culling (< 0.5 deg), offscreen tile cache, async path computation | 4, 6 |
| `extract_kraken_reads.py` is Python, not native | Ship in the conda environment alongside kraken2; long-term: rewrite in Swift using the .kraken parser from Phase 1 | 7 |
| NSSplitView delegate methods on macOS 26 | Use raw NSSplitView (not NSSplitViewController) with delegate; document why per macos26-api-rules | 5 |
| Selection sync feedback loops | Suppression flag pattern (same as existing NSTableView programmatic select) | 5 |

---

## Deferred / Out of Scope for V1

These items from the design documents are explicitly deferred:

- **MetaPhlAn marker-gene profiling** -- added in a follow-up phase after
  the Kraken2/Bracken pipeline is proven.
- **Comparative view** (side-by-side classification results) -- requires a
  multi-document architecture change.
- **Temporal tracking** (time-series taxonomy) -- research feature, not core.
- **Krona HTML import** -- low priority; kreport is the standard interchange.
- **Database auto-update checking** -- nice-to-have, not blocking.
- **Print support** (Cmd+P for sunburst) -- minor polish, easy to add later.
- **Inspector panel integration** (right sidebar taxon detail) -- can be
  added incrementally after Phase 5.
