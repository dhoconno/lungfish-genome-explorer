# UX/HIG Expert Review — 2026-03-21

## Executive Summary
47 actionable findings across HIG compliance, consistency, navigation, accessibility, and SwiftUI migration. The app has strong foundations (programmatic AppKit layout, proper NSSplitViewController usage, SF Symbols) but needs work on modal dialog patterns, color consistency, accessibility, and information architecture.

---

## 1. Apple HIG Compliance

### 1.1 57 uses of `runModal()` — CRITICAL
- **Files**: AppDelegate (19), MainSplitViewController (9), SidebarViewController (3), WelcomeWindowController (3), + others
- Blocks main thread, deprecated on macOS 26
- **Fix**: Replace all with `beginSheetModal(for:)` using async/await

### 1.2 `runModal()` in SwiftUI callbacks — HIGH
- **File**: WelcomeWindowController.swift lines 287, 303
- **Fix**: Move panel presentation to NSWindowController host using `beginSheetModal`

### 1.3 Toolbar customization disabled — MEDIUM
- **File**: MainWindowController.swift line 162 (`allowsUserCustomization = false`)
- **Fix**: Set `allowsUserCustomization = true`

### 1.4 Non-standard sidebar toggle shortcut — MEDIUM
- Uses Opt-Cmd-S instead of standard Cmd-Ctrl-S
- **Fix**: Use standard `NSSplitViewController.toggleSidebar(_:)` shortcut

### 1.5 Operations panel shortcut too complex — MEDIUM
- Shift-Option-Cmd-O (4 keys)
- **Fix**: Simplify to Cmd-Shift-O or function key

### 1.6 Shortcut conflict Cmd-Shift-O — LOW
### 1.7 Cmd-Shift-C domain shortcut — LOW (acceptable)

---

## 2. UI Consistency

### 2.1 DNA base colors defined in 3+ locations — HIGH
- ViewerViewController `BaseColors`, OperationPreviewView `FASTQPalette`, MultiSequence hardcoded, AppearanceSettings defaults
- All have slightly different RGB values for the same conceptual colors
- **Fix**: Single source of truth in `AppSettings.shared.sequenceAppearance`

### 2.2 No semantic color system — HIGH
- Status colors (`green`/`red`/`orange`) defined ad-hoc in each component
- SwiftUI `Color.green` vs `Color(nsColor: .systemGreen)` render differently
- **Fix**: Create `SemanticColors` enum (success, failure, warning, info)

### 2.3 Mixed AppKit/SwiftUI sheet button styles — MEDIUM
- Some sheets use AppKit NSButton, others SwiftUI buttons
- **Fix**: Standardize on SwiftUI for new sheets; ensure keyEquivalent on AppKit sheets

### 2.4 Font size hierarchy inverted in sidebar — MEDIUM
- Group headers 11pt < child items 13pt
- **Fix**: Use `NSFont.preferredFont(forTextStyle:)` or fix hierarchy

### 2.5 Unicode symbols instead of SF Symbols in menus — MEDIUM
- **Fix**: Use `NSImage(systemSymbolName:)` on `menuItem.image`

---

## 3. Navigation & Information Architecture

### 3.1 No "Go to Gene" keyboard shortcut — HIGH
- Gene jumping is the most frequent bioinformatics operation
- Annotation search index exists but has no keyboard entry point
- **Fix**: Add "Go to Gene..." with Cmd-G or Cmd-Shift-G

### 3.2 Inspector tabs split related content — HIGH
- Selection tab has 8 sections; Document tab has metadata
- User must switch tabs to see related information
- **Fix**: Contextual inspector that shows sections based on selection type

### 3.3 Dual drawer system confusion — MEDIUM
- AnnotationTableDrawer and FASTQMetadataDrawer occupy same space
- **Fix**: Tab bar or segment control to show which drawer is active

### 3.4 Menu bar ambiguity (Tools vs Operations vs Sequence) — MEDIUM
- **Fix**: Consider merging into "Analysis" menu, keep Operations as process monitor

### 3.5 Welcome screen lacks onboarding — MEDIUM
- No guidance on supported formats, getting started
- **Fix**: Add "Quick Start" tip and "Getting Started Guide" link

### 3.6 Only 5 help topics — LOW

---

## 4. Accessibility

### 4.1 Custom views lack VoiceOver support — HIGH
- OperationPreviewView, EnhancedCoordinateRulerView, FASTQSparklineStrip, ChromosomeNavigatorView
- **Fix**: Set `isAccessibilityElement`, `accessibilityRole`, `accessibilityLabel` on all custom views

### 4.2 Error messages are technical, not actionable — HIGH
- Raw `error.localizedDescription` shown to users
- **Fix**: Wrap common errors with user-friendly messages and recovery suggestions

### 4.3 No keyboard navigation for Smart Filter Tokens — MEDIUM
### 4.4 Tooltip delay minimum is 0 (should be 0.1s) — MEDIUM
### 4.5 Hardcoded font sizes prevent Dynamic Type — LOW

---

## 5. SwiftUI Migration Candidates

### HIGH PRIORITY
1. **BarcodeScoutSheet** — modal sheet with table/controls, ~60% code reduction
2. **FASTQImportConfigSheet** — form-style sheet, perfect for SwiftUI Form
3. **OperationsPanelController** — table with progress bars, fits List+ProgressView

### MEDIUM PRIORITY
4. **HelpViewController** — custom markdown renderer is maintenance burden
5. **AboutWindowController** — 370 lines of manual NSAttributedString

### LOW PRIORITY
6. **ChromosomeNavigatorView** — performance concern with large chromosome lists

### NOT RECOMMENDED for migration
- SequenceViewerView — performance-critical custom CoreGraphics
- AnnotationTableDrawerView — complex virtualized table

---

## 6. Additional Findings

### 6.1 Raw `.green` for completed download status — MEDIUM
### 6.2 NSLog in release path (inspector toggle) — MEDIUM
### 6.3 Hardcoded version "1.0.0" in WelcomeView — LOW
### 6.4 Hardcoded AI model names in settings — LOW
### 6.5 Deprecated `activate(ignoringOtherApps:)` — LOW

---

## Priority Summary

| Priority | Count | Key Items |
|----------|-------|-----------|
| **Critical** | 1 | runModal() migration (57 instances) |
| **High** | 7 | SwiftUI runModal, color duplication, semantic colors, Go to Gene, inspector IA, VoiceOver, error messages |
| **Medium** | 12 | Toolbar customization, shortcuts, sheet styles, font hierarchy, SF Symbols, drawers, menus, onboarding, filter keyboard nav, tooltip delay, NSLog, download colors |
| **Low** | 6 | Shortcut conflicts, help topics, Dynamic Type, version string, AI models, deprecated activate |
