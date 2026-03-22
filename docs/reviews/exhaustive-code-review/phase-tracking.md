# Phase Implementation Tracker

## Status Legend
- [ ] Not started
- [~] In progress
- [x] Complete
- [!] Blocked

---

## Phase 1: Critical Bug Fixes & Safety Net Tests
**Status**: NOT STARTED
**Baseline tests**: TBD (run `swift test` to establish)

### 1A. Bug Fixes
- [ ] Yeast mito codon table (CodonTable.swift)
- [ ] BED toAnnotation() chromosome (BEDReader.swift)
- [ ] FASTAWriter force unwrap
- [ ] Sequence.subsequence() try!
- [ ] NSApp.activate() deprecated param
- [ ] WelcomeView hardcoded version

### 1B. Critical Tests
- [ ] ReferenceFrameTests (20 tests)
- [ ] RowPackerTests (15 tests)
- [ ] FormatRegistryTests (11 tests)
- [ ] PluginRegistryTests (20 tests)
- [ ] ImportServiceTests (15 tests)
- [ ] BgzipReaderRegressionTests (4 tests)
- [ ] GenomicRegionTests (5 tests)

### 1C. Logging
- [ ] Per-module subsystem constants
- [ ] .public privacy annotations
- [ ] Replace debugLog() with Logger
- [ ] Replace print() with Logger
- [ ] Replace NSLog with Logger

### Sign-off
- [ ] All existing tests pass
- [ ] New tests pass
- [ ] Code reviewed
- [ ] Committed

---

## Phase 2: macOS 26 API Compliance & Technical Debt
**Status**: NOT STARTED

### 2A. runModal() Migration (57 sites)
- [ ] Create async sheet helpers
- [ ] AppDelegate (18 sites)
- [ ] MainSplitViewController (9 sites)
- [ ] SidebarViewController (3 sites)
- [ ] WelcomeWindowController (3 sites)
- [ ] Remaining (~24 sites)

### 2B. Concurrency Safety
- [ ] DispatchQueue.main.async → MainActor.assumeIsolated (19 sites)
- [ ] GenomicDocument remove Sendable
- [ ] NativeBundleBuilder split
- [ ] nonisolated(unsafe) Timer audit

### 2C. objc_setAssociatedObject Elimination
- [ ] ViewerViewController+BundleDisplay properties
- [ ] ViewerViewController+FASTQDrawer properties
- [ ] SequenceViewerView+Properties
- [ ] ParameterControlFactory properties

### Sign-off
- [ ] All tests pass
- [ ] Zero deprecated API warnings
- [ ] Committed

---

## Phase 3: Shared Abstractions & Deduplication
**Status**: NOT STARTED

### 3A. Color System
- [ ] SemanticColors enum
- [ ] Unified BaseColors source
- [ ] Update all references

### 3B. TrackRendererBase
- [ ] Protocol + base class
- [ ] Variant renderer refactor
- [ ] Translation renderer refactor
- [ ] Read renderer refactor

### 3C. ChromosomeAliasResolver
- [ ] Unified resolver in Core
- [ ] Consolidate 3 implementations

### 3D. Database Foundation
- [ ] GenomicDatabase protocol
- [ ] Refactor 3 databases

### 3E. Reader Dedup
- [ ] Sync FASTAReader/GenBankReader methods
- [ ] Remove AppDelegate duplicates
- [ ] GenerationGuard<T>

### 3F. Error System
- [ ] LungfishError protocol
- [ ] DocumentType rename

### Sign-off
- [ ] All tests pass
- [ ] Committed

---

## Phase 4: Giant File Splitting
**Status**: NOT STARTED

### 4A. ViewerViewController (10.6K → ~6 files)
### 4B. Dataset Controllers (21.9K + 24K)
### 4C. Track Renderers (24.6K + 18.4K)
### 4D. Navigation & Filtering (21K + 13.3K)
### 4E. Sheets & Drawers (17.8K + 25.4K + 7.3K)

### Sign-off
- [ ] All tests pass
- [ ] No file >3,000 lines
- [ ] Committed

---

## Phase 5: SwiftUI Migration & HIG Compliance
**Status**: NOT STARTED
(Details in synthesized-plan.md)

---

## Phase 6: Plugin System & CLI Expansion
**Status**: NOT STARTED
(Details in synthesized-plan.md)

---

## Phase 7: Format Handling & Performance
**Status**: NOT STARTED
(Details in synthesized-plan.md)

---

## Phase 8: Architecture & Polish
**Status**: NOT STARTED
(Details in synthesized-plan.md)
