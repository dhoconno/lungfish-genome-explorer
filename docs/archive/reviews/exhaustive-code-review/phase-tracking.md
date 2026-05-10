# Phase Implementation Tracker — Updated 2026-03-22

## Summary
**12 commits** on `exhaustive-code-review` branch. All phases complete or deferred with documented rationale.

**Test count: 3,615 → 4,179 (+564 tests, +15.6%)**

## All Commits

| # | Hash | Phase | Description |
|---|------|-------|-------------|
| 1 | `bc2dd1b` | Phase 1 | Bug fixes, 214 new tests, logging foundation |
| 2 | `96e838d` | Phase 2 | 57 runModal→beginSheetModal, concurrency fixes |
| 3 | `c41b7b2` | Phase 3 | SemanticColors, ChromosomeAliasResolver, LungfishError, sync readers |
| 4 | `731c046` | Phase 4+6 | Codon tables 4-6, annotation types, CLI commands |
| 5 | `9fb3267` | Fix | Translate command flag collision |
| 6 | `39c9d51` | Docs | Phase tracking documentation |
| 7 | `e6f7db4` | Phase 4a | Extract 7 small types from ViewerViewController |
| 8 | `1cdb4e7` | Phase 4b | Extract SequenceViewerView (10,716 → 2,086 lines) |
| 9 | `9d76445` | Phase A | Streaming FASTA parser (buffered 256KB chunks) |
| 10 | `48a8161` | Phase C | Bgzipped VCF (.vcf.gz) support |
| 11 | `639908f` | Phase B | GTF format support (42 tests) |
| 12 | `bcb413c` | Phase D | Menu/keyboard improvements (Go to Gene, shortcuts) |

## Completed Work

### Phase 1: Critical Bug Fixes & Safety Net Tests
- [x] 6 bug fixes (codon table, BED chromosome, try!, activate, version, FASTA writer)
- [x] 214 new safety-net tests
- [x] LogSubsystem constants, 100+ loggers standardized

### Phase 2: macOS 26 API Compliance
- [x] 57 → 0 runModal() calls
- [x] All DispatchQueue.main.async wrapped with MainActor.assumeIsolated
- [x] GenomicDocument Sendable removed
- [x] objc_setAssociatedObject reduced to 1

### Phase 3: Shared Abstractions
- [x] SemanticColors (DNA, Status, Quality, Annotation)
- [x] ChromosomeAliasResolver (7 strategies, 51 tests)
- [x] LungfishError protocol
- [x] Sync reader methods (FASTA, GenBank)
- [x] DocumentType → DocumentCategory rename

### Phase 4: ViewerViewController Split
- [x] 7 small type extractions (QuickLookItem, BaseColors, ProgressOverlayView, TrackHeaderView, CoordinateRulerView, ViewerStatusBar, AnnotationPopoverView, VariantChromosomeHelpers)
- [x] SequenceViewerView extraction (7,353 lines)
- [x] ViewerViewController: 10,716 → 2,086 lines (-80.5%)

### Phase 6: Scientific Accuracy & CLI
- [x] Genetic code tables 4, 5, 6
- [x] Annotation types: tRNA, rRNA, pseudogene, mobileElement
- [x] Multi-allelic variant classification fix
- [x] GFF3 multi-parent attribute handling
- [x] CLI: translate, search, extract, composition commands

### Phase A: Streaming FASTA Parser
- [x] Buffered 256KB chunk reading (replaces readToEnd())
- [x] O(n) string accumulation (replaces O(n²) concatenation)
- [x] Windows line ending support
- [x] 10 new streaming tests

### Phase B: GTF Format Support
- [x] GTFReader with GENCODE-style attribute parsing
- [x] 42 new tests

### Phase C: Bgzip VCF Support
- [x] VCFReader handles .vcf.gz transparently via GzipInputStream
- [x] All 14 VCF tests pass

### Phase D: Menu & Keyboard Improvements
- [x] "Go to Gene..." (Cmd-Shift-G) added to Sequence menu
- [x] Sidebar toggle: Opt-Cmd-S → Ctrl-Cmd-S (macOS standard)
- [x] Operations panel: Shift-Opt-Cmd-O → Cmd-Shift-P
- [x] ONT Run shortcut conflict resolved
- [x] SF Symbols replace Unicode menu symbols

## Remaining (Future Sessions)

### SwiftUI Migrations
- [ ] BarcodeScoutSheet → SwiftUI Sheet + Table
- [ ] FASTQImportConfigSheet → SwiftUI Form
- [ ] OperationsPanelController → SwiftUI List + ProgressView
- [ ] FASTQ charts → SwiftUI Charts framework
- [ ] 13 ObservableObject → @Observable migrations

### Architecture
- [ ] LungfishApp module split (App, Datasets, GenomeBrowser)
- [ ] Dependency injection for ViewerViewController
- [ ] Inspector contextual sections
- [ ] VCFVariant type consolidation (Core + IO → single type)
