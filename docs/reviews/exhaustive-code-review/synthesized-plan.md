# Exhaustive Code Review — Synthesized Implementation Plan

## Cross-Expert Convergence Analysis

Five expert teams independently identified the same top issues:

| Issue | Swift | UX | Bioinfo | Arch | QA |
|-------|-------|-----|---------|------|-----|
| runModal() migration (57 sites) | CRITICAL | CRITICAL | — | MEDIUM | — |
| Giant file splitting (10 files >7K) | HIGH | — | — | CRITICAL | — |
| FASTA full-file memory load | — | — | HIGH | CRITICAL | — |
| Missing test coverage (UI/Plugin) | — | — | — | — | CRITICAL |
| objc_setAssociatedObject abuse | HIGH | — | — | HIGH | — |
| NotificationCenter overuse | MEDIUM | — | — | MEDIUM | — |
| Color definitions scattered 3+ places | — | HIGH | — | — | — |
| No semantic color system | — | HIGH | — | — | — |
| ObservableObject→@Observable migration | MEDIUM | — | — | LOW | — |
| Bare DispatchQueue.main.async (19 sites) | HIGH | — | — | — | — |
| VCFVariant type duplication | — | — | HIGH | — | — |
| Chromosome aliasing duplicated 3x | — | — | — | HIGH | — |
| Plugin module orphaned (not wired in) | — | — | HIGH | MEDIUM | CRITICAL |
| Yeast mito codon table bug | — | — | CRITICAL | — | — |
| Missing CLI commands | — | — | HIGH | — | — |
| VoiceOver on custom views | — | HIGH | — | — | — |
| TrackRendererBase missing | — | — | — | HIGH | — |
| FormatRegistry untested | — | — | — | — | CRITICAL |
| ReferenceFrame untested | — | — | — | — | CRITICAL |

---

## Phased Implementation Plan

### Guiding Principles
1. **Test before refactor**: Write tests for existing behavior before changing it
2. **Small commits**: Each phase produces testable, reviewable commits
3. **No regressions**: Full test suite must pass after each phase
4. **Outside-in**: Fix bugs and add tests first, then refactor structure

---

## Phase 1: Critical Bug Fixes & Safety Net Tests
**Goal**: Fix scientific correctness bugs and add tests for the most critical untested systems.
**Risk**: LOW (additive changes — new tests + isolated bug fixes)
**Estimated scope**: ~15-20 new test files, ~90 new tests, 3-5 bug fix files

### 1A. Critical Bug Fixes
- [ ] Fix yeast mitochondrial codon table: add `table["ATA"] = "M"` (Bioinfo 5.2)
- [ ] Fix BED toAnnotation() missing chromosome field (Bioinfo 2.6)
- [ ] Fix force unwrap in FASTAWriter (Arch 6.3)
- [ ] Fix `try!` in Sequence.subsequence() (Swift 2.4)
- [ ] Fix deprecated `NSApp.activate(ignoringOtherApps:)` (Swift 1.2)
- [ ] Fix hardcoded version in WelcomeView (UX 6.3)

### 1B. Critical Test Coverage
- [ ] ReferenceFrame unit tests (~20 tests) — coordinate math foundation
- [ ] RowPacker unit tests (~15 tests) — feature packing algorithm
- [ ] FormatRegistry unit tests (~11 tests) — format detection/dispatch
- [ ] PluginRegistry unit tests (~20 tests) — plugin lifecycle
- [ ] ImportService unit tests (~15 tests) — primary user data entry point
- [ ] BgzipIndexedFASTAReader regression tests (~4 tests) — infinite loop regression
- [ ] GenomicRegion arithmetic tests (~5 tests)

### 1C. Logging Foundation
- [ ] Define per-module Logger subsystem constants (com.lungfish.{core,io,ui,workflow,plugin,app})
- [ ] Add `.public` privacy annotations to all non-sensitive Logger interpolations
- [ ] Replace `debugLog()` in AppDelegate with Logger `.debug` level
- [ ] Replace remaining `print()` statements with Logger calls
- [ ] Replace NSLog calls with Logger (UX 6.2)

**Test gate**: All existing 3,663 tests pass + ~90 new tests pass

---

## Phase 2: macOS 26 API Compliance & Technical Debt
**Goal**: Eliminate all deprecated API usage and concurrency hazards.
**Risk**: MEDIUM (behavioral changes to modal dialogs)
**Estimated scope**: 57 runModal replacements, 19 DispatchQueue fixes, 30+ associated object removals

### 2A. runModal() → beginSheetModal Migration
- [ ] Create async helper: `NSAlert.presentSheet(for:)` and `NSSavePanel.presentSheet(for:)`
- [ ] Migrate AppDelegate alert calls (18 sites)
- [ ] Migrate MainSplitViewController (9 sites)
- [ ] Migrate SidebarViewController (3 sites)
- [ ] Migrate WelcomeWindowController (3 sites, including SwiftUI callbacks)
- [ ] Migrate remaining locations (~24 sites across other files)
- [ ] Add tests for sheet presentation flow

### 2B. Concurrency Safety
- [ ] Wrap all bare `DispatchQueue.main.async` with `MainActor.assumeIsolated` (19 sites)
- [ ] Remove `Sendable` conformance from `GenomicDocument` (contradicts @MainActor)
- [ ] Split NativeBundleBuilder: @MainActor view model + non-isolated build engine actor
- [ ] Audit `nonisolated(unsafe)` Timer properties

### 2C. objc_setAssociatedObject Elimination
- [ ] Move ViewerViewController+BundleDisplay stored properties to class body
- [ ] Move ViewerViewController+FASTQDrawer stored properties to class body
- [ ] Move SequenceViewerView+Properties stored properties to class body
- [ ] Move ParameterControlFactory stored properties to proper locations

**Test gate**: All tests pass, no runtime warnings, no deprecated API usage in build log

---

## Phase 3: Shared Abstractions & Deduplication
**Goal**: Extract shared patterns to reduce duplication and establish foundations for file splitting.
**Risk**: MEDIUM (new abstractions must preserve behavior)
**Estimated scope**: ~8 new files, modifications to ~20 existing files

### 3A. Color System Unification
- [ ] Create `SemanticColors` enum (success, failure, warning, info) in LungfishUI or Core
- [ ] Create single `BaseColors` source of truth (consolidate 3+ definitions)
- [ ] Update all status indicators to use SemanticColors
- [ ] Update all DNA base color references to single source

### 3B. Track Renderer Foundation
- [ ] Create `TrackRenderer` protocol in LungfishUI
- [ ] Create `TrackRendererBase` class with shared coordinate transforms, zoom detection, hit testing
- [ ] Refactor VariantTrackRenderer to extend TrackRendererBase
- [ ] Refactor TranslationTrackRenderer to extend TrackRendererBase
- [ ] Refactor ReadTrackRenderer to extend TrackRendererBase

### 3C. Chromosome Alias Resolution
- [ ] Create `ChromosomeAliasResolver` in LungfishCore
- [ ] Consolidate VCF aliasing into resolver
- [ ] Consolidate BAM aliasing into resolver
- [ ] Consolidate bundle building aliasing into resolver
- [ ] Add tests for all aliasing strategies

### 3D. Database Foundation
- [ ] Create `GenomicDatabase` protocol in LungfishIO
- [ ] Extract shared SQLite connection/migration/query patterns
- [ ] Refactor AnnotationDatabase to conform
- [ ] Refactor VariantDatabase to conform
- [ ] Refactor AlignmentMetadataDatabase to conform

### 3E. Reader Deduplication
- [ ] Add sync parsing methods to FASTAReader (eliminate AppDelegate duplication)
- [ ] Add sync parsing methods to GenBankReader
- [ ] Remove duplicate parsers from AppDelegate
- [ ] Extract GenerationGuard<T> utility

### 3F. Error System
- [ ] Create `LungfishError` protocol in Core (user description, technical description, recovery suggestion)
- [ ] Conform module error types to LungfishError
- [ ] Update error presentation to use recovery suggestions
- [ ] Rename DocumentType collision (Core→DocumentCategory, App→FileFormat)

**Test gate**: All tests pass, duplication metrics improved

---

## Phase 4: Giant File Splitting
**Goal**: Break the 10 largest files into maintainable units.
**Risk**: MEDIUM-HIGH (structural changes, many file moves)
**Estimated scope**: 10 source files → ~60 files

### 4A. ViewerViewController Extraction (10.6K → ~6 files)
- [ ] Extract SequenceViewerView.swift
- [ ] Extract ProgressOverlayView.swift, TrackHeaderView.swift, ViewerStatusBar.swift
- [ ] Extract BaseColors.swift (now unified from Phase 3)
- [ ] Extract ViewerViewController+Fetching.swift
- [ ] Extract ViewerViewController+Navigation.swift
- [ ] Move associated-object properties into class body (done in Phase 2C)

### 4B. Dataset Controllers (21.9K + 24K → ~12 files each)
- [ ] Split VCFDatasetViewController: Coordinator, Filter, TableData, Statistics, Export, Genotype
- [ ] Split FASTQChartViews: one file per chart type + shared layout
- [ ] Split FASTQDatasetViewController extensions as needed

### 4C. Track Renderers (24.6K + 18.4K → ~6 files each)
- [ ] Split VariantTrackRenderer: Density, Squished, Expanded, ColorScheme, GenotypeGrid, Utils
- [ ] Split TranslationTrackRenderer: Orchestration, CodonRenderer, FrameLayout, ColorScheme

### 4D. Navigation & Filtering (21K + 13.3K → ~5 files each)
- [ ] Split ChromosomeNavigatorView: Container, Ideogram, Minimap, RegionSelection, Bookmarks
- [ ] Split SmartFilterTokens: Model, Parser, TokenView, PredicateBuilder

### 4E. Sheets & Drawers (17.8K + 25.4K + 7.3K → ~5 files each)
- [ ] Split BarcodeScoutSheet: Sheet, DetectionEngine, AssignmentView, Preview, Config
- [ ] Split MultiSequenceSupport: Layout, Renderer, Consensus, Selection, DataSource
- [ ] Split AnnotationTableDrawerView: Container, DataSource, DetailView, FilterBar

**Test gate**: All tests pass, no file >3,000 lines in modified set

---

## Phase 5: SwiftUI Migration & HIG Compliance
**Goal**: Migrate suitable components to SwiftUI, fix HIG violations.
**Risk**: MEDIUM (UI changes visible to users)
**Estimated scope**: ~6 components migrated, ~15 HIG fixes

### 5A. SwiftUI Migrations (high-value targets)
- [ ] BarcodeScoutSheet → SwiftUI Sheet + Table (~60% code reduction)
- [ ] FASTQImportConfigSheet → SwiftUI Form
- [ ] OperationsPanelController → SwiftUI List + ProgressView
- [ ] FASTQ chart views → SwiftUI Charts framework
- [ ] OperationPreviewView → SwiftUI
- [ ] AboutWindowController → SwiftUI

### 5B. ObservableObject → @Observable Migration
- [ ] Migrate GenomicDocument
- [ ] Migrate RecentProjectsManager, WelcomeViewModel
- [ ] Migrate MultiSequenceState
- [ ] Migrate DatabaseBrowserViewModel
- [ ] Migrate OperationCenter, PluginRegistry
- [ ] Migrate remaining 7 classes

### 5C. HIG Fixes
- [ ] Add "Go to Gene..." keyboard shortcut (Cmd-G or Cmd-Shift-G)
- [ ] Fix sidebar toggle shortcut to Cmd-Ctrl-S (standard)
- [ ] Simplify Operations panel shortcut (remove 4-modifier combo)
- [ ] Fix shortcut conflicts (Cmd-Shift-O)
- [ ] Enable toolbar customization
- [ ] Add VoiceOver support to custom views (OperationPreview, Ruler, Sparklines)
- [ ] Improve error messages with recovery suggestions
- [ ] Add onboarding guidance to welcome screen
- [ ] Fix tooltip delay minimum (0 → 0.1s)
- [ ] Replace Unicode menu symbols with SF Symbols
- [ ] Fix font hierarchy in sidebar (group headers vs children)

### 5D. NotificationCenter Refactoring
- [ ] Replace high-traffic notification channels with @Observable view models
- [ ] Create shared ReadDisplaySettings observable for inspector↔viewer
- [ ] Document ADR for observer pattern selection rules
- [ ] Convert remaining notification observers to closure-based API with token tracking

**Test gate**: All tests pass, VoiceOver audit passes

---

## Phase 6: Plugin System & CLI Expansion
**Goal**: Wire plugin module into app, expand CLI for headless testing.
**Risk**: LOW-MEDIUM (additive features)
**Estimated scope**: ~15 new files, ~100 new tests

### 6A. Plugin System Activation
- [ ] Wire LungfishPlugin into LungfishApp dependency
- [ ] Wire LungfishPlugin into LungfishCLI dependency
- [ ] Eliminate duplicate Strand/SequenceAlphabet types (re-export from Core)
- [ ] Add progress/cancellation to plugin API
- [ ] Add plugin protocol compliance tests

### 6B. Scientific Accuracy
- [ ] Add genetic code tables 4, 5, 6, 12, 13 (at minimum)
- [ ] Fix multi-allelic variant classification
- [ ] Add tRNA, rRNA, pseudogene, mobile_element annotation types
- [ ] Add barcode/UMI tag parsing to AlignedRead
- [ ] Expand restriction enzyme database (top 100 from REBASE)
- [ ] Add nearest-neighbor Tm calculation option
- [ ] Add longestOnly mode to ORF finder
- [ ] Fix GFF3 multi-parent attribute handling

### 6C. CLI Commands
- [ ] Add `lungfish translate` (expose TranslationPlugin)
- [ ] Add `lungfish search` (expose PatternSearchPlugin)
- [ ] Add `lungfish extract` (subsequence extraction by region)
- [ ] Add `lungfish orf` (expose ORFFinderPlugin)
- [ ] Add `lungfish restriction` (expose RestrictionSiteFinderPlugin)
- [ ] Add `lungfish view` (BAM/VCF record viewing/filtering)
- [ ] Add `lungfish index` (create .fai, .tbi indices)
- [ ] Add BED/GFF3/VCF input to convert command
- [ ] Add N90, L50, L90 to assembly statistics
- [ ] Add CLI integration tests for all new commands

### 6D. Help System Expansion
- [ ] Add help topics for FASTQ workflows
- [ ] Add help topics for genome downloads/bundles
- [ ] Add help topics for alignment import
- [ ] Add help topics for demultiplexing
- [ ] Add keyboard shortcuts reference

**Test gate**: All tests pass, all CLI commands have argument parsing + execution tests

---

## Phase 7: Format Handling & Performance
**Goal**: Fix critical format gaps, improve performance for large files.
**Risk**: MEDIUM-HIGH (core I/O changes)
**Estimated scope**: ~10 modified/new files

### 7A. Format Gaps
- [ ] Implement streaming FASTA parser (url.lines instead of readToEnd)
- [ ] Fix O(n²) string concatenation in FASTA parsing
- [ ] Add GTF format support (reader or GFF3Reader auto-detect)
- [ ] Add bgzipped VCF support (decompress or shell to bcftools)
- [ ] Consolidate VCFVariant types (Core + IO → single type)
- [ ] Fix GenBank qualifier continuation spacing
- [ ] Cache SequenceAnnotation bounding region at init

### 7B. Additional Test Coverage
- [ ] FASTAIndex tests
- [ ] GzipSupport tests
- [ ] BigBed/BigWig reader tests
- [ ] Tool provisioning tests
- [ ] FASTQIngestionPipeline tests
- [ ] WorkflowRunner tests
- [ ] AnnotationSearchIndex tests
- [ ] BatchProcessingEngine tests
- [ ] Full workflow integration tests (import→view→export)
- [ ] Performance regression benchmarks

**Test gate**: All tests pass including new format/performance tests

---

## Phase 8: Architecture & Polish
**Goal**: Module restructuring, dependency injection, final polish.
**Risk**: HIGH (structural changes)
**Estimated scope**: Module split + DI framework

### 8A. Module Split
- [ ] Split LungfishApp into 3 modules (App, Datasets, GenomeBrowser)
- [ ] Update Package.swift dependencies
- [ ] Verify clean module boundaries

### 8B. Dependency Injection
- [ ] Create convenience accessor for ViewerController (eliminate deep chains)
- [ ] Begin coordinator pattern for ViewerViewController dependencies
- [ ] Inject AppSettings instead of global access

### 8C. Inspector Improvements
- [ ] Contextual inspector showing sections based on selection type
- [ ] Tab bar for drawer modes (annotation vs FASTQ metadata)

### 8D. Menu Organization
- [ ] Merge or rename Tools/Sequence/Operations for clarity
- [ ] Audit all keyboard shortcuts for conflicts

### 8E. Documentation
- [ ] Document observer pattern decision rules (ADR)
- [ ] Document subprocess security model
- [ ] Document sandbox/entitlements requirements
- [ ] Update help system with comprehensive topics

**Test gate**: All tests pass, architecture is clean

---

## Phase Dependencies

```
Phase 1 (bugs + tests) → no dependencies
Phase 2 (macOS 26 + debt) → Phase 1 (need safety net tests first)
Phase 3 (abstractions) → Phase 2 (need clean concurrency first)
Phase 4 (file splitting) → Phase 3 (need shared abstractions first)
Phase 5 (SwiftUI + HIG) → Phase 4 (need clean file structure first)
Phase 6 (plugins + CLI) → Phase 3 (need unified types first)
Phase 7 (formats + perf) → Phase 3 (need deduplication first)
Phase 8 (architecture) → Phases 4-7 (need everything clean first)
```

Phases 5, 6, and 7 can run in parallel after Phase 4.

---

## Success Metrics
- Zero deprecated API warnings in build
- Zero `runModal()` calls
- Zero `objc_setAssociatedObject` calls
- No source file exceeds 3,000 lines
- All modules have per-module Logger subsystems with .public annotations
- All CLI data operations have corresponding commands
- Test count increases from ~3,663 to ~4,000+
- All custom views have basic VoiceOver support
- Single source of truth for colors, chromosome aliasing, database patterns
