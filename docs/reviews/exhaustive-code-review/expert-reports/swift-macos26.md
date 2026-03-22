# Swift/macOS 26 Expert Review — 2026-03-21

## Executive Summary
The codebase demonstrates solid architecture decisions around concurrency (correct `MainActor.assumeIsolated` from GCD, actor-based services), but has accumulated technical debt: pervasive `runModal()` usage, extensive `objc_setAssociatedObject` abuse, and over-reliance on `NotificationCenter` for inter-component communication.

---

## 1. macOS 26 API Compliance

### 1.1 `alert.runModal()` — 30+ occurrences — CRITICAL
- **Files**: AppDelegate (18 sites), SidebarViewController (2), MainSplitViewController (9)
- **Fix**: Replace with `beginSheetModal(for:)` async/await (pattern already used in 20+ places)
- **Risk**: Medium — each site needs a window reference

### 1.2 `NSApp.activate(ignoringOtherApps:)` deprecated — MEDIUM
- **Files**: AppDelegate (3 sites), WelcomeWindowController (1)
- **Fix**: Use `NSApp.activate()` (no parameter)

### 1.3 `NSSavePanel.runModal()` — HIGH
- AppDelegate line 3805
- **Fix**: Use `beginSheetModal(for:)` like other save panel sites already do

---

## 2. Swift 6.2 Concurrency

### 2.1 `GenomicDocument` combines @MainActor + ObservableObject + Sendable — MEDIUM
- Contradictory: @MainActor is inherently not Sendable across actor boundaries
- **Fix**: Remove Sendable conformance, migrate to @Observable

### 2.2 13 classes still use ObservableObject instead of @Observable — MEDIUM
- GenomicDocument, RecentProjectsManager, WelcomeViewModel, MultiSequenceState, DatabaseBrowserViewModel, OperationCenter, PluginRegistry, ProjectFile, EditableSequence, VersionHistory, ReferenceBundleBuilder, NativeBundleBuilder, AssemblyConfigurationViewModel
- Creates two observation systems (need both @ObservedObject and @Bindable)
- **Fix**: Migrate to @Observable macro

### 2.3 Bare `DispatchQueue.main.async` without MainActor.assumeIsolated — HIGH
- **Files**: AppDelegate (4 sites), SidebarViewController (1), MainSplitViewController (14 sites)
- Accesses @MainActor state from @Sendable closure without isolation
- **Fix**: Wrap in `MainActor.assumeIsolated { }`

### 2.4 `force try!` in production code — MEDIUM
- Sequence.swift line 318: `try!` in `subsequence()` on dynamic data
- **Fix**: Use `try` with error propagation (other `try!` on literals are acceptable)

---

## 3. Architecture & Simplification

### 3.1 ViewerViewController is 10,618 lines + 5 extensions (12,798 total) — HIGH
- Contains ViewerViewController, SequenceViewerView (~4000 lines), ProgressOverlayView, TrackHeaderView, CoordinateRulerView, ViewerStatusBar — all in one file
- **Fix**: Extract each class into its own file:
  - SequenceViewerView.swift
  - ProgressOverlayView.swift
  - TrackHeaderView.swift
  - CoordinateRulerView.swift
  - ViewerStatusBar.swift
  - BaseColors.swift

### 3.2 `objc_setAssociatedObject` abuse — 30+ properties — HIGH
- **Files**: ViewerViewController+BundleDisplay (lines 531-577), +FASTQDrawer (326-337), SequenceViewerView+Properties (18-57), ParameterControlFactory (539-543)
- `OBJC_ASSOCIATION_RETAIN_NONATOMIC` has no thread safety
- **Fix**: Move stored properties into original class declarations with `internal` access

### 3.3 NotificationCenter overuse — 49 observers, 40+ notification names — MEDIUM
- `handleReadDisplaySettingsChanged` alone has 18 `if let` casts from untyped userInfo
- Typos in keys silently fail
- **Fix**: Replace high-traffic channels with typed delegate protocols or @Observable view model bindings

### 3.4 AnnotationTableDrawerView at 7,286 lines — MEDIUM
- Contains three tabs, export, genotype display, bookmarks, query builders
- **Fix**: Split into per-tab implementations; extract variant query service

---

## 4. SwiftUI Migration Opportunities

### 4.1 Welcome window — already SwiftUI but unnecessarily wrapped — LOW
- Uses NSHostingView wrapping SwiftUI WelcomeView
- Could use pure SwiftUI Window scene or NSHostingController directly

### 4.2 FASTQ chart views — MEDIUM
- FASTQSummaryBar, FASTQHistogramChartView, FASTQQualityBoxplotView — all manual CoreGraphics
- **Fix**: Migrate to SwiftUI Charts framework (60-70% code reduction)

### 4.3 DatabaseBrowser — already correct pattern (reference for others)

### 4.4 Sidebar — NOT recommended for migration (complex drag-drop, context menus, lazy loading)

### 4.5 OperationPreviewView (1,737 lines) — MEDIUM
- Forms/controls UI, perfect for SwiftUI primitives

---

## 5. Logging Assessment

### 5.1 Inconsistent logging subsystems — LOW
- Only `com.lungfish.browser` and `com.lungfish.core` defined
- No subsystems for IO, Workflow, Plugin modules
- **Fix**: Define per-module subsystem constants

### 5.2 Privacy annotations inconsistently applied — MEDIUM
- Dynamic values without `.public` annotation are redacted in production builds
- For local desktop app, all data is non-sensitive
- **Fix**: Add `.public` to all non-sensitive interpolations

### 5.3 `debugLog()` file-writing logger in AppDelegate — LOW
- Duplicates os.log, opens/closes file handle on every call
- **Fix**: Replace with Logger `.debug` level

### 5.4 CLI uses bare `print()` — correct for CLI context

---

## 6. Memory Management

### 6.1 DownloadCenter.onBundleReady — no issue (correctly uses [weak self])

### 6.2 `nonisolated(unsafe)` Timer properties — LOW
- ViewerViewController, FASTQDatasetViewController, WorkflowExecutionView
- Technically safe since classes are @MainActor, but defeats compiler verification
- **Fix**: Consider Task + Task.sleep instead of Timer

---

## 7. Error Handling

### 7.1 Untyped errors in pipeline services — LOW
- Well-defined error types exist but function signatures use untyped `throws`
- **Fix**: Adopt typed throws (`throws(NativeToolError)`) for known error domains

---

## 8. Data Integrity

### 8.1 Notification-based settings dispatch has no ordering guarantee — MEDIUM
- Rapid slider changes can produce partial-update race conditions
- **Fix**: Replace with shared @Observable view model (inspector writes, viewer observes)

---

## Priority Summary

| Priority | Count | Key Items |
|----------|-------|-----------|
| **Critical** | 1 | runModal() deprecation (30+ sites) |
| **High** | 3 | Bare DispatchQueue.main.async (19 sites), objc_setAssociatedObject (30+ props), ViewerViewController split |
| **Medium** | 8 | ObservableObject→@Observable (13 classes), NotificationCenter overuse, GenomicDocument Sendable, FASTQ charts SwiftUI, logging privacy, activate() deprecated, OperationPreview migration, settings dispatch |
| **Low** | 5 | Logging subsystems, debugLog removal, nonisolated(unsafe) timers, typed throws, Welcome window |
