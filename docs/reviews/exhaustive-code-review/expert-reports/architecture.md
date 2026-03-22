# Architecture & Code Quality Expert Review — 2026-03-21

## Executive Summary
42 findings across 6 categories: 4 critical, 11 high, 17 medium, 10 low. Most pressing: giant file problem (10 files >7K lines, several >20K), duplicated patterns across database/reader implementations, inconsistent observer/notification patterns, and MainActor scheduling workarounds.

---

## 1. Module Architecture

### 1.1 Dependency graph is clean and acyclic — NO ACTION NEEDED
- Core → IO → UI → App (correct layering)

### 1.2 LungfishPlugin is an orphan module — MEDIUM
- Not wired into LungfishApp or LungfishCLI; plugins unreachable from app
- **Fix**: Wire into App/CLI or remove

### 1.3 LungfishApp is a monolith — HIGH
- 109 files: all view controllers, charts, services, settings, help in one module
- **Fix**: Split into LungfishApp (slim), LungfishDatasets (VCF/FASTQ/alignment), LungfishGenomeBrowser (viewer/tracks)

### 1.4 DocumentType name collision — MEDIUM
- Core.DocumentType (semantic categories) vs App.DocumentType (file formats)
- **Fix**: Rename to DocumentCategory and FileFormat

---

## 2. Code Duplication

### 2.1 FASTA parsing duplicated in AppDelegate — HIGH
- AppDelegate has complete sync parser duplicating FASTAReader
- Also duplicated: GenBank parsing, alphabet detection
- **Fix**: Add synchronous methods to IO readers

### 2.2 Database creation patterns duplicated — MEDIUM
- AnnotationDB, VariantDB, AlignmentMetadataDB each reimplement SQL patterns
- **Fix**: Extract GenomicDatabase protocol with shared connection/query management

### 2.3 Chromosome name aliasing duplicated 3x — HIGH
- VCF, BAM, and bundle building each implement independently with different strategies
- **Fix**: Create unified ChromosomeAliasResolver in LungfishCore

### 2.4 Generation counter pattern repeated 3x — LOW
- annotationFetchGeneration, sequenceFetchGeneration, variantFetchGeneration
- **Fix**: Extract generic GenerationGuard<T>

---

## 3. Giant File Splitting

| File | Lines | Priority | Proposed Split |
|------|-------|----------|----------------|
| MultiSequenceSupport.swift | 25,356 | **CRITICAL** | Layout, Renderer, Consensus, Selection, DataSource |
| VariantTrackRenderer.swift | 24,613 | **CRITICAL** | Density, Squished, Expanded, ColorScheme, GenotypeGrid, Utils |
| FASTQChartViews.swift | 24,089 | HIGH | One file per chart type + shared layout |
| VCFDatasetViewController.swift | 21,901 | HIGH | Coordinator, Filter, TableData, Statistics, Export, Genotype |
| ChromosomeNavigatorView.swift | 21,091 | HIGH | Container, Ideogram, Minimap, RegionSelection, Bookmarks |
| TranslationTrackRenderer.swift | 18,399 | MEDIUM | Orchestration, CodonRenderer, FrameLayout, ColorScheme |
| BarcodeScoutSheet.swift | 17,763 | MEDIUM | Sheet, DetectionEngine, AssignmentView, Preview, Config |
| SmartFilterTokens.swift | 13,292 | MEDIUM | Model, Parser, TokenView, PredicateBuilder |
| ViewerViewController.swift | 10,618 | HIGH | Lifecycle, Fetching, Navigation, +existing extensions |
| AnnotationTableDrawerView.swift | 7,286 | LOW | Container, DataSource, DetailView, FilterBar |

---

## 4. Design Patterns

### 4.1 Inconsistent observer patterns — MEDIUM
- 4 mechanisms: NotificationCenter, @Published/@Observable, callbacks, @Sendable progress
- **Fix**: Document decision rules (ADR); audit NotificationCenter for unnecessary broadcasts

### 4.2 Missing TrackRendererBase abstraction — HIGH
- Each renderer reimplements coordinate transforms, zoom detection, hit testing
- **Fix**: Create TrackRenderer protocol + TrackRendererBase in LungfishUI

### 4.3 @MainActor + @Published misuse — HIGH
- NativeBundleBuilder @MainActor but called from Task.detached (documented broken pattern)
- **Fix**: Split into @MainActor view model + non-isolated BundleBuildEngine actor

### 4.4 Singleton proliferation — LOW
- 6+ singletons (DocumentManager, PluginRegistry, NativeToolRunner, DownloadCenter, TempFileManager, AppSettings)
- Most justified; consider DI for DocumentManager and AppSettings

---

## 5. Performance

### 5.1 FASTA full file read into memory — CRITICAL
- `handle.readToEnd()` loads entire file (43GB lungfish genome = OOM)
- **Fix**: Streaming via buffered I/O or url.lines

### 5.2 O(n²) string concatenation in FASTA parsing — HIGH
- `currentBases += trimmedLine` for millions of lines
- **Fix**: Use array of substrings, join once at end

### 5.3 Expensive computed properties on SequenceAnnotation — MEDIUM
- `start`/`end` traverse intervals array on every access
- **Fix**: Cache at initialization (intervals are sorted)

### 5.4 CFRunLoop scheduling fragility — LOW
- Necessary workaround; document as tech debt for future Swift versions

---

## 6. Error Handling

### 6.1 Inconsistent alert presentation — MEDIUM (overlaps with macOS 26 runModal findings)
### 6.2 No cross-module error mapping — MEDIUM
- Module errors lose context crossing boundaries
- **Fix**: Create LungfishError protocol with user-facing + technical descriptions

### 6.3 Force unwrap in FASTAWriter — LOW
### 6.4 No batched error reporting — LOW

---

## 7. Additional Concerns

### 7.1 Subprocess argument safety — MEDIUM
- NativeToolRunner uses Process() (safe from injection) but needs documentation

### 8.1 No dependency injection — MEDIUM
- ViewerViewController reaches through hierarchy for dependencies
- **Fix**: Inject via coordinator pattern incrementally

### 8.2 Deep VC navigation chains — MEDIUM
- `mainWindowController?.mainSplitViewController?.viewerController` repeated 10+ times
- **Fix**: Convenience accessor or responder chain

### 8.3 Mixed @Observable/ObservableObject — LOW
- 13 classes still ObservableObject; standardize on @Observable

---

## Priority Summary

| Priority | Count | Key Items |
|----------|-------|-----------|
| **Critical** | 4 | MultiSequenceSupport split, VariantTrackRenderer split, FASTA streaming, FASTA memory |
| **High** | 11 | LungfishApp monolith split, FASTA duplication, chromosome aliasing, FASTQCharts/VCFDatasetVC/ChromNav/ViewerVC splits, TrackRendererBase, @MainActor/@Published, O(n²) strings |
| **Medium** | 17 | Plugin orphan, DocumentType rename, DB patterns, observer patterns, TranslationRenderer/BarcodeScout/SmartFilter splits, annotation caching, error mapping, DI, VC chains, subprocess audit |
| **Low** | 10 | Generation guard, AnnotationDrawer split, singletons, CFRunLoop docs, FASTAWriter unwrap, batched errors, @Observable migration, sandbox docs |
