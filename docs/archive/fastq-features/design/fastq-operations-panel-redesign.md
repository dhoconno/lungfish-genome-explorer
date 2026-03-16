# FASTQ Operations Panel Redesign Specification

**Version:** 1.0
**Date:** 2026-03-08
**Target:** macOS 26 Tahoe, AppKit/SwiftUI hybrid
**Minimum Window Size:** 1024 x 768 pt
**Design System:** Apple Human Interface Guidelines (macOS 26)

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Information Architecture](#2-information-architecture)
3. [Global Layout](#3-global-layout)
4. [Top Pane: Compact Data Summary](#4-top-pane-compact-data-summary)
5. [Middle Pane: Operation Preview](#5-middle-pane-operation-preview)
6. [Bottom Pane: Results Table](#6-bottom-pane-results-table)
7. [Operation Selector](#7-operation-selector)
8. [Document Inspector Integration](#8-document-inspector-integration)
9. [Operation Preview Specifications](#9-operation-preview-specifications)
10. [Animation and Transition System](#10-animation-and-transition-system)
11. [Color System](#11-color-system)
12. [Typography](#12-typography)
13. [Accessibility](#13-accessibility)

---

## 1. Executive Summary

This specification replaces the current two-pane FASTQ viewer (chart top / operation controls + console bottom) with a three-pane layout that introduces a **live operation preview** between the data summary and results. The preview pane renders schematic cartoon diagrams of reads being transformed by the selected operation, with parameter changes reflected in real time. The console is eliminated entirely; status information moves to inline feedback, the activity indicator bar, and the Document Inspector's provenance section.

### Problems Addressed

- Histograms consume excessive vertical space for information density delivered
- No preview of what an operation will do before execution
- Console output is developer-facing, not scientist-facing
- Operation controls are dense and not scannable
- No visual connection between parameter changes and their effect on data

### Design Principles

- **Progressive disclosure:** sparkline charts expand on hover/click; operation parameters reveal contextually
- **Direct manipulation:** parameter sliders and fields update the preview diagram instantly
- **Semantic color:** all colors derive from NSColor semantic tokens; no hardcoded RGB
- **Spatial memory:** operation categories are stable positions in a sidebar list, not a popup menu

---

## 2. Information Architecture

### View Hierarchy

```
FASTQDatasetViewController (NSViewController)
  +-- NSSplitView (vertical, 3 panes)
  |   +-- topPane: FASTQSummaryPane (NSView)
  |   |   +-- FASTQSummaryBar (NSView) — stat cards row
  |   |   +-- FASTQSparklineStrip (NSView) — 3 inline sparklines
  |   +-- middlePane: OperationPreviewPane (NSView)
  |   |   +-- parameterBar (NSStackView) — contextual controls
  |   |   +-- previewCanvas (OperationPreviewView, NSView) — schematic diagrams
  |   |   +-- runBar (NSView) — Run button + estimated output summary
  |   +-- bottomPane: ResultsPane (NSView)
  |       +-- NSTabView or segmented swap
  |       |   +-- ReadTableView (NSTableView) — columnar read browser
  |       |   +-- DerivedFilesView (NSTableView) — derivative lineage
  +-- operationSidebar: OperationListView (NSTableView, source list style)
```

### Operation Categories (sidebar groups)

```
SAMPLING
  Subsample by Proportion
  Subsample by Count

TRIMMING
  Quality Trim
  Adapter Trim
  Fixed Trim
  Primer Removal

FILTERING
  Length Filter
  Contaminant Filter
  Deduplicate

CORRECTION
  Error Correction

REFORMATTING
  Interleave / Deinterleave
  Paired-End Merge
  Paired-End Repair

SEARCH
  Find by ID/Description
  Find by Sequence Motif
```

---

## 3. Global Layout

### Three-Pane Split View

The main content area (between the sidebar and Document Inspector in the existing MainSplitViewController) hosts an NSSplitView with three vertical divisions.

```
+----------------------------------------------------------------+
| [Summary Bar: 9 stat cards, 48 pt]                              |
| [Sparkline Strip: 3 mini charts, 52 pt]                        |
|                                                                  |  Top Pane
| ...............divider (1 pt, NSColor.separatorColor).......... |  ~108 pt
|                                                                  |
| [Parameter Bar: contextual controls, 36 pt]                     |
| [Preview Canvas: schematic read diagrams, flexible]             |  Middle Pane
| [Run Bar: action button + output estimate, 36 pt]               |  ~220-340 pt
|                                                                  |
| ...............divider (1 pt, NSColor.separatorColor).......... |
|                                                                  |
| [Results Table: columnar read browser or derivative list]       |  Bottom Pane
|                                                                  |  ~remaining
+----------------------------------------------------------------+
```

### Pane Sizing Constraints

| Pane | Min Height | Max Height | Default Proportion |
|------|-----------|-----------|-------------------|
| Top (Summary) | 80 pt | 160 pt | 15% of view height |
| Middle (Preview) | 140 pt | 400 pt | 40% of view height |
| Bottom (Results) | 120 pt | unbounded | 45% of view height |

The NSSplitView dividers use `NSSplitView.dividerStyle = .thin` (1 pt). Divider color: `NSColor.separatorColor`.

### Pane Collapse Behavior

- Double-clicking the top divider collapses the summary pane (sparklines hide, stat cards remain as a single 48 pt row)
- Double-clicking the bottom divider collapses the results table
- The middle preview pane cannot be collapsed; it is the primary interaction surface

---

## 4. Top Pane: Compact Data Summary

### 4.1 Summary Bar (unchanged from current)

The existing `FASTQSummaryBar` is retained as-is. It occupies the top 48 pt of the pane.

- **Layout:** 9 horizontal stat cards, equal width, 6 pt inter-card spacing, 8 pt edge padding
- **Card height:** 40 pt (within the 48 pt row, 4 pt top/bottom padding)
- **Card background:** `NSColor.controlBackgroundColor` at 60% opacity, 4 pt corner radius
- **Card border:** `NSColor.separatorColor` at 0.5 pt
- **Label font:** `.systemFont(ofSize: 9, weight: .medium)`, `NSColor.secondaryLabelColor`
- **Value font:** `.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)`, `NSColor.labelColor`

### 4.2 Sparkline Strip (new)

Replaces the full-height tabbed histogram charts. Three sparklines displayed inline, side by side.

**Layout geometry:**

```
+-- 8 pt padding --+
| [Length Dist]  [Q/Position]  [Q Score Dist] |
| 52 pt tall     52 pt tall     52 pt tall    |
+-- 8 pt padding --+
```

- **Strip height:** 52 pt total (4 pt top padding + 44 pt chart + 4 pt bottom padding)
- **Each sparkline width:** `(availableWidth - 8*2 - 8*2) / 3` (equal thirds, 8 pt inter-chart gap)
- **Sparkline area:** 44 pt tall, variable width

**Sparkline rendering (CoreGraphics):**

- **Background:** `NSColor.controlBackgroundColor` at 40% opacity, 6 pt corner radius
- **Border:** `NSColor.separatorColor` at 0.5 pt
- **Chart title:** `.systemFont(ofSize: 9, weight: .medium)`, `NSColor.secondaryLabelColor`, top-left corner, 4 pt inset
- **Fill:** Bars for histograms, using the bottom 32 pt of the 44 pt area
- **Bar color:** Length = `NSColor.systemBlue` at 70% opacity; Q/Position = `NSColor.systemYellow` at 70% opacity (median line); Q Score = `NSColor.systemGreen` at 70% opacity
- **No axis labels** in sparkline mode — values are implied by shape
- **Disabled sparklines** (no quality data computed): draw with `NSColor.tertiaryLabelColor` at 20% opacity, centered text "Run Quality Report" in `.systemFont(ofSize: 9)`, `NSColor.tertiaryLabelColor`

**Sparkline expand interaction:**

- **Click** on any sparkline: presents an `NSPopover` (`.preferredEdge = .maxY`) containing the full-size chart (the existing `FASTQHistogramChartView` or `FASTQQualityBoxplotView`) at 360 x 280 pt
- **Popover behavior:** `.semitransient` (dismisses on click outside, stays on hover)
- **Transition:** `NSPopover` default spring animation (system-provided)
- **The popover chart** uses the existing drawing code from `FASTQChartViews.swift` unchanged

### 4.3 Quality Report Button

When quality data is not yet computed, a small button appears at the trailing edge of the sparkline strip:

- **Style:** `NSButton` with `.bezelStyle = .accessoryBarAction`
- **Title:** "Compute Quality Report"
- **Font:** `.systemFont(ofSize: 11, weight: .medium)`
- **Width:** intrinsic content + 12 pt horizontal padding
- **Position:** trailing edge, vertically centered in sparkline strip
- **Action:** same as existing `computeQualityReportClicked`
- **Progress:** the global `ActivityIndicatorView` (existing) in the window's bottom bar shows progress; no inline spinner

---

## 5. Middle Pane: Operation Preview

This is the centerpiece of the redesign. It contains three horizontal bands stacked vertically.

### 5.1 Parameter Bar

A single-row `NSStackView` at the top of the middle pane, 36 pt tall.

- **Background:** `NSColor.windowBackgroundColor` (matches toolbar material)
- **Bottom border:** 0.5 pt `NSColor.separatorColor`
- **Horizontal padding:** 12 pt leading, 12 pt trailing
- **Spacing between controls:** 12 pt (`.distribution = .fill`, `.spacing = 12`)

**Contents vary by operation.** Each control uses standard AppKit form controls:

| Control Type | AppKit Class | Height | Font |
|---|---|---|---|
| Text field | `NSTextField` | 22 pt | `.systemFont(ofSize: 12)` |
| Popup menu | `NSPopUpButton` | 22 pt | `.systemFont(ofSize: 12)` |
| Slider | `NSSlider` with `.controlSize = .small` | 22 pt | n/a |
| Checkbox | `NSButton(.switch)` | 16 pt | `.systemFont(ofSize: 11)` |
| Stepper + field | `NSStepper` + `NSTextField` | 22 pt | `.monospacedDigitSystemFont(ofSize: 12)` |

**Label placement:** Labels appear as `.systemFont(ofSize: 10, weight: .medium)` `NSColor.secondaryLabelColor` text directly above or leading-side of the control, depending on available width. When the pane width is >= 700 pt, labels appear inline to the left of controls. Below 700 pt, labels appear stacked above.

**Slider live binding:** All sliders and steppers dispatch to the preview canvas on `.continuous = true` value change. Text fields dispatch on `controlTextDidEndEditing` and on a 300 ms debounce timer (DispatchWorkItem pattern, matching existing `layoutSettleWorkItem`).

### 5.2 Preview Canvas

The main drawing surface for schematic read diagrams. This is a custom `NSView` subclass (`OperationPreviewView`) using CoreGraphics for rendering.

**Layout:**

- **Top edge:** 4 pt below parameter bar bottom border
- **Bottom edge:** 4 pt above run bar top border
- **Horizontal padding:** 16 pt on each side
- **Background:** `NSColor.textBackgroundColor` (white in light mode, dark gray in dark mode)
- **Border:** none (seamless integration with pane background)
- **Minimum height:** 100 pt (content area, excluding parameter and run bars)

**Canvas coordinate system:** `isFlipped = true`, origin at top-left. All read diagrams are drawn within a `drawableRect` inset 16 pt from canvas bounds on all sides.

**Common visual vocabulary (used across all operation previews):**

| Element | Shape | Dimensions | Color |
|---|---|---|---|
| Read body | Rounded rectangle | height: 20 pt, corner radius: 3 pt, width: proportional to read length | See per-operation spec |
| Read label | Monospaced text above read | `.monospacedSystemFont(ofSize: 9)` | `NSColor.secondaryLabelColor` |
| Base letter | Single character centered in a square cell | 12 x 12 pt cell when zoomed, no letters when squished | `NSColor.labelColor` |
| Quality bar | Thin rectangle below read body | height: 4 pt, same width as read | Color-mapped Q score (see below) |
| Threshold line | Dashed horizontal or vertical line | 0.5 pt width, dash pattern [4, 3] | `NSColor.controlAccentColor` |
| Arrow | Bezier path with triangular head | shaft: 1 pt width, head: 6 x 4 pt | `NSColor.secondaryLabelColor` |
| Fade overlay | Semi-transparent rectangle over discarded elements | same bounds as target | `NSColor.windowBackgroundColor` at 70% opacity |
| Keep highlight | No overlay (full opacity) | n/a | n/a |
| Bracket | "L"-shaped bracket with serif ends | 1 pt stroke, 4 pt serif length | `NSColor.tertiaryLabelColor` |

**Quality-to-color mapping (for per-base coloring):**

| Quality Range | Color |
|---|---|
| >= 30 | `NSColor.systemGreen` |
| 20-29 | `NSColor.systemYellow` |
| 10-19 | `NSColor.systemOrange` |
| < 10 | `NSColor.systemRed` |

**Read arrangement:**

- Reads are drawn horizontally, left-to-right representing 5' to 3'
- Multiple reads stack vertically with 8 pt inter-read spacing
- The canvas auto-scales read width to fit: `readPixelWidth = (drawableRect.width - interReadPadding) / maxReadLength * readLength`
- Maximum reads shown simultaneously: 12 (for subsample previews); 1-3 (for trim previews)

### 5.3 Run Bar

A 36 pt horizontal bar at the bottom of the middle pane.

- **Background:** `NSColor.windowBackgroundColor`
- **Top border:** 0.5 pt `NSColor.separatorColor`
- **Horizontal padding:** 12 pt leading, 12 pt trailing

**Contents (left to right):**

1. **Output estimate label:** `.systemFont(ofSize: 11)`, `NSColor.secondaryLabelColor`
   - Example: "Estimated output: ~1,250 reads (12.5% of 10,000)"
   - Updated reactively when parameters change, computed from the loaded statistics
   - If no estimate is computable, shows "Output depends on data content"

2. **Spacer** (flexible width)

3. **Run Operation button:** `NSButton` with `.bezelStyle = .rounded`, `.controlSize = .regular`
   - Title: "Run" (short, consistent)
   - Key equivalent: Command+Return
   - Width: 64 pt minimum
   - Uses `NSColor.controlAccentColor` as tint (`.bezelColor` on macOS 26)
   - Disabled state: 50% opacity, `.isEnabled = false` while an operation is in flight

4. **Progress indicator** (hidden by default): `NSProgressIndicator(.bar)`, `.controlSize = .small`, 120 pt wide, appears between estimate label and Run button during execution

---

## 6. Bottom Pane: Results Table

### 6.1 Tab Switching

A small `NSSegmentedControl` at the top of the bottom pane, 24 pt tall, `.segmentStyle = .automatic`.

Two segments:
- **"Reads"** — columnar read browser showing individual reads from the source or derived dataset
- **"Derived Files"** — table of derivative bundles with lineage information

### 6.2 Read Table

An `NSTableView` with the following columns:

| Column | Width | Font | Alignment |
|---|---|---|---|
| # (row index) | 48 pt | `.monospacedDigitSystemFont(ofSize: 11)` | trailing |
| Read ID | 200 pt (flexible) | `.monospacedSystemFont(ofSize: 11)` | leading |
| Length | 64 pt | `.monospacedDigitSystemFont(ofSize: 11)` | trailing |
| Mean Q | 56 pt | `.monospacedDigitSystemFont(ofSize: 11)` | trailing |
| GC% | 48 pt | `.monospacedDigitSystemFont(ofSize: 11)` | trailing |
| Sequence (truncated) | remaining | `.monospacedSystemFont(ofSize: 11)` | leading |

- **Row height:** 18 pt
- **Alternating row colors:** `NSTableView.usesAlternatingRowBackgroundColors = true`
- **Selection:** single row; selecting a read updates the middle pane preview to highlight that specific read in context
- **Sort:** click column headers for ascending/descending sort
- **Lazy loading:** rows loaded on demand from FASTQReader; display first 10,000 reads, "Load More" button at bottom

### 6.3 Derived Files Table

| Column | Width | Font |
|---|---|---|
| Name | 180 pt (flexible) | `.systemFont(ofSize: 12)` |
| Operation | 160 pt | `.systemFont(ofSize: 12)` |
| Date | 120 pt | `.systemFont(ofSize: 11)` |
| Read Count | 80 pt | `.monospacedDigitSystemFont(ofSize: 11)` |
| Size | 72 pt | `.monospacedDigitSystemFont(ofSize: 11)` |

- **Row height:** 22 pt
- **Double-click:** opens the derived dataset in a new tab (uses existing `DocumentLoader` pathway)

---

## 7. Operation Selector

### Sidebar Integration (replaces NSPopUpButton)

The operation selector moves from an `NSPopUpButton` in the bottom pane to a **narrow sidebar** on the left edge of the middle pane. This sidebar uses `NSTableView` with `.style = .sourceList`.

**Sidebar geometry:**

- **Width:** 180 pt (fixed; does not participate in split view resizing)
- **Background:** system source list background (automatic with `.style = .sourceList`)
- **Group header font:** `.systemFont(ofSize: 11, weight: .semibold)`, `NSColor.secondaryLabelColor`, all-caps
- **Item font:** `.systemFont(ofSize: 12)`, `NSColor.labelColor`
- **Item row height:** 24 pt
- **Group header row height:** 28 pt (includes 8 pt top padding for visual separation)
- **Selection style:** system source list highlight (`NSColor.controlAccentColor` rounded rect)
- **Icons:** SF Symbols at 13 pt, `NSColor.secondaryLabelColor`, leading edge

**SF Symbol assignments:**

| Operation | SF Symbol |
|---|---|
| Subsample by Proportion | `chart.pie` |
| Subsample by Count | `number` |
| Quality Trim | `scissors` |
| Adapter Trim | `link.badge.minus` (custom composite) or `minus.circle` |
| Fixed Trim | `ruler` |
| Primer Removal | `xmark.seal` |
| Length Filter | `arrow.left.and.right` |
| Contaminant Filter | `shield.slash` |
| Deduplicate | `square.on.square.dashed` |
| Error Correction | `wand.and.stars` |
| Interleave / Deinterleave | `arrow.triangle.branch` |
| Paired-End Merge | `arrow.triangle.merge` |
| Paired-End Repair | `wrench.and.screwdriver` |
| Find by ID | `magnifyingglass` |
| Find by Motif | `text.magnifyingglass` |

**Layout of middle pane with sidebar:**

```
+--------+---------------------------------------------+
|        | [Parameter Bar, 36 pt]                       |
| Oper.  |                                              |
| List   | [Preview Canvas, flexible]                   |
| 180 pt |                                              |
|        | [Run Bar, 36 pt]                              |
+--------+---------------------------------------------+
```

The sidebar is separated from the preview area by a 0.5 pt `NSColor.separatorColor` vertical line. No NSSplitView here; the sidebar is a fixed-width subview pinned to the leading edge, and the preview area fills the remainder.

**Collapse behavior:** When the FASTQ viewer width drops below 800 pt, the operation sidebar collapses to an `NSPopUpButton` in the parameter bar (graceful degradation). The popup uses the existing title strings and is the first control in the parameter bar's stack view.

---

## 8. Document Inspector Integration

### 8.1 New Section: Operation Provenance

When a derived FASTQ file is loaded, the Document Inspector's Document tab shows a new **"Provenance"** disclosure group below the existing metadata sections.

**Section structure (SwiftUI):**

```
DisclosureGroup("Provenance") {
    // Source file
    LabeledContent("Source") {
        Text(sourceFilename)
            .font(.callout)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    // Operation
    LabeledContent("Operation") {
        Text(operationDescription)
            .font(.callout)
    }

    // Parameters (dynamic key-value list)
    ForEach(parameters) { param in
        LabeledContent(param.key) {
            Text(param.value)
                .font(.callout)
                .monospacedDigit()
        }
    }

    Divider()

    // Command line (expandable)
    DisclosureGroup("Command") {
        Text(commandLine)
            .font(.system(size: 10, design: .monospaced))
            .textSelection(.enabled)
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(4)
    }

    // Timestamp
    LabeledContent("Created") {
        Text(formattedDate)
            .font(.callout)
    }

    // Tool version
    LabeledContent("Tool") {
        Text(toolVersionString)
            .font(.callout)
    }
}
```

**Provenance data source:** The `FASTQDerivedBundleManifest` (already stored in `DocumentSectionViewModel.fastqDerivativeManifest`) provides all fields. The command line is reconstructed from the `FASTQDerivativeRequest` enum case.

### 8.2 New Section: Estimated Impact

When an operation is configured (parameters set, not yet run), the Inspector shows a transient **"Estimated Impact"** section:

```
DisclosureGroup("Estimated Impact") {
    LabeledContent("Input Reads") {
        Text("10,000")
    }
    LabeledContent("Output Reads") {
        Text("~1,250")
    }
    LabeledContent("Reduction") {
        PercentageBar(percentage: 87.5, color: .orange)
            .frame(height: 6)
        Text("87.5%")
    }
}
```

This section is hidden when no operation is selected or when the middle pane is showing the idle state.

---

## 9. Operation Preview Specifications

Each operation defines a unique schematic preview drawn on the `OperationPreviewView` canvas. All previews share the common visual vocabulary defined in Section 5.2.

### 9.1 Subsample by Proportion

**Scene layout:**

```
    Sampled at 30%
    +-----------+  KEPT
    +-----------+  KEPT       <- full opacity
    +-----------+  DISCARDED  <- faded
    +-----------+  KEPT
    +-----------+  DISCARDED  <- faded
    +-----------+  DISCARDED  <- faded
    +-----------+  KEPT
    +-----------+  DISCARDED  <- faded
```

**Visual elements:**

- Draw 8 representative reads, stacked vertically with 8 pt spacing
- Each read is a rounded rectangle, 20 pt tall, full drawable width
- Read body color: `NSColor.systemBlue` at 60% opacity
- Quality bar beneath each read: 4 pt tall, color per-base quality gradient
- Read ID label (e.g., "Read 1", "Read 2") to the left, `.monospacedSystemFont(ofSize: 9)`

**Kept vs Discarded:**

- **Kept reads:** full opacity, no overlay. A small checkmark icon (SF Symbol `checkmark.circle.fill`, 10 pt, `NSColor.systemGreen`) appears at the trailing edge.
- **Discarded reads:** a `NSColor.windowBackgroundColor` overlay at 70% opacity is drawn over the read body. A small "X" icon (SF Symbol `xmark.circle`, 10 pt, `NSColor.tertiaryLabelColor`) appears at the trailing edge.

**Parameter response:**

- The proportion slider (0.0 to 1.0, step 0.01) is in the parameter bar
- As the slider moves, reads are probabilistically assigned kept/discarded status using a deterministic seed (so the pattern is stable for a given proportion, not random per frame)
- Algorithm: `readIndex < floor(totalDisplayedReads * proportion)` marks as kept (deterministic, not random)
- Transition: kept/discarded state change uses a 200 ms `CABasicAnimation` on the overlay opacity

**Summary text:**

- Centered above the reads: "Keeping **{n}** of 8 reads ({percent}%)" in `.systemFont(ofSize: 12, weight: .medium)`, `NSColor.labelColor`
- `{n}` and `{percent}` are bold; the rest is regular weight

### 9.2 Subsample by Count

**Identical to 9.1** except:

- Parameter bar shows a stepper + text field for count (integer, 1 to `statistics.readCount`)
- The 8 displayed reads are labeled "Read 1" through "Read 8"
- Kept count is `min(targetCount, displayedReads)` scaled: `floor(8 * targetCount / totalReadCount)`
- Summary text: "Keeping **{n}** of {total} reads (showing 8 representative)"

### 9.3 Quality Trim

**Scene layout: a single read, zoomed in to show individual bases.**

```
    5' -------- trim point -------> 3'
    |A|T|G|C|C|A|T|G|G|C|T|A|A|G|C|T|
    |32|35|28|30|22|18|15|12| 8| 5| 3| ...
           ^
           sliding window
```

**Visual elements:**

- A single read rendered at full width of the drawable area
- The read is divided into individual base cells: each cell is `cellWidth = drawableWidth / readLength` wide, 24 pt tall
- Base letter is centered in each cell (when `cellWidth >= 10 pt`; omitted when narrower)
- Base cell background color: quality-mapped color (see Section 5.2 quality-to-color table), with slight desaturation (60% alpha blend with `NSColor.textBackgroundColor`)
- Quality score number below each cell: `.monospacedDigitSystemFont(ofSize: 8)`, `NSColor.secondaryLabelColor`

**Trim visualization:**

- A vertical dashed line marks the **trim point**: 1.5 pt width, `NSColor.controlAccentColor`, dash pattern [4, 3]
- The region to be trimmed is overlaid with `NSColor.systemRed` at 15% opacity
- A bracket below the trimmed region is labeled "Trimmed: {n} bp" in `.systemFont(ofSize: 10)`, `NSColor.systemRed`
- The region to be kept has a bracket labeled "Kept: {n} bp" in `.systemFont(ofSize: 10)`, `NSColor.systemGreen`

**Parameter response:**

- **Quality threshold slider** (0 to 40, integer steps): moves the trim point along the read
  - The trim algorithm walks from the trim end (3' for cutRight, 5' for cutFront, both for cutBoth) with a sliding window
  - The sliding window is visualized as a translucent rectangle (`NSColor.controlAccentColor` at 20% opacity) of width = window size, that animates along the read
  - Trim point recalculates on every slider change
  - Transition: trim point moves with a 150 ms `CABasicAnimation` (ease-in-out)

- **Window size stepper** (1 to 20): changes the width of the sliding window overlay
  - Window width animates with 150 ms spring animation

- **Trim mode popup** (Cut Right / Cut Front / Cut Tail / Cut Both):
  - Changes which end(s) the sliding window scans from
  - For "Cut Both", two trim lines appear (one from each end)
  - Mode change triggers a 250 ms crossfade transition of the trimmed regions

**Read data source:** Uses the first read from the loaded FASTQ file. If quality data is not yet computed, uses a synthetic read of 50 bases with a gradient quality profile (Q35 at 5' tapering to Q5 at 3').

### 9.4 Adapter Trim

**Scene layout: a single read with adapter highlighted at the 3' end.**

```
    5'                                3'
    |G|E|N|O|M|I|C| |R|E|A|D|[ADAPTER]|
                                ^clip
```

**Visual elements:**

- A single read at full drawable width, 24 pt tall
- Genomic sequence portion: base cells colored `NSColor.systemBlue` at 30% opacity
- Adapter portion: base cells colored `NSColor.systemOrange` at 50% opacity, with a top border of 2 pt `NSColor.systemOrange`
- A label "Adapter" above the adapter region, `.systemFont(ofSize: 10, weight: .semibold)`, `NSColor.systemOrange`
- A vertical dashed clip line at the adapter junction: 1.5 pt, `NSColor.controlAccentColor`

**Trim animation:**

- Before: the full read with adapter is shown
- After parameter confirmation: the adapter portion slides right and fades out (200 ms, ease-out)
- A bracket appears below the remaining genomic portion: "Kept: {n} bp"
- A bracket in `NSColor.systemRed` at 50% opacity appears where the adapter was: "Removed: {n} bp"

**Parameter response:**

- **Auto-detect mode:** the adapter region is fixed at a representative length (20 bp); a label says "Adapter detected by overlap analysis"
- **Specify Sequence mode:** the text field contents are matched against the read; the adapter region shifts to where the match begins. If no match, the adapter region is shown at the 3' end with a "?" label and dashed outline

### 9.5 Fixed Trim

**Scene layout: a single read with ruler and shaded trim regions.**

```
    |<-- 5' trim -->|       genomic        |<-- 3' trim -->|
    |   10 bases    |        region        |   15 bases    |
    0    10    20    30    40    50    60    70    80    90  100
```

**Visual elements:**

- A single read at full drawable width, 24 pt tall
- A ruler below the read: tick marks every 10 bases, labels every 20 bases
  - Ruler height: 16 pt
  - Tick font: `.monospacedDigitSystemFont(ofSize: 8)`, `NSColor.tertiaryLabelColor`
  - Tick marks: 0.5 pt `NSColor.separatorColor`, 4 pt tall (minor) / 8 pt tall (labeled)

- **5' trim region:** overlay of `NSColor.systemRed` at 20% opacity, from position 0 to `trim5Prime`
  - Diagonal hatch lines at 45 degrees, 4 pt spacing, 0.5 pt `NSColor.systemRed` at 40%
  - Label: "5' Trim: {n} bp" centered in region

- **3' trim region:** identical styling, from `readLength - trim3Prime` to end

- **Kept region:** no overlay, full read color
  - Label: "Kept: {n} bp" centered

**Parameter response:**

- **5' trim stepper** (0 to readLength/2): 5' shaded region width changes
- **3' trim stepper** (0 to readLength/2): 3' shaded region width changes
- Both regions animate their edges with 150 ms ease-in-out
- If 5' + 3' >= readLength, the kept region shrinks to 0 and a warning label appears: "Warning: trim removes entire read" in `.systemFont(ofSize: 11, weight: .medium)`, `NSColor.systemRed`

### 9.6 Length Filter

**Scene layout: multiple reads of varying length with threshold lines.**

```
    min                                    max
    |                                       |
    |  +---+                                |  <- too short (faded)
    |  +----------+                         |  <- kept
    |  +------+                             |  <- kept
    |  +-+                                  |  <- too short (faded)
    |  +--------------+                     |  <- kept
    |  +--------------------+               |  <- too long (faded)
```

**Visual elements:**

- Draw 8 reads of varying lengths (sampled from the actual length distribution histogram)
- Reads are left-aligned, width proportional to length
- Read color: `NSColor.systemBlue` at 50% opacity (kept) or `NSColor.tertiaryLabelColor` at 30% (filtered)
- Read length label at trailing edge: `.monospacedDigitSystemFont(ofSize: 9)`, shows "{length} bp"

- **Minimum threshold line:** vertical dashed line, `NSColor.systemOrange`, 1 pt width, full canvas height
  - Label at top: "Min: {n} bp" in `.systemFont(ofSize: 10)`, `NSColor.systemOrange`

- **Maximum threshold line:** vertical dashed line, `NSColor.systemRed`, 1 pt width, full canvas height
  - Label at top: "Max: {n} bp" in `.systemFont(ofSize: 10)`, `NSColor.systemRed`

- Reads shorter than min: fade to 30% opacity, strikethrough line (1 pt, `NSColor.systemOrange`)
- Reads longer than max: fade to 30% opacity, strikethrough line (1 pt, `NSColor.systemRed`)

**Parameter response:**

- **Min length slider/stepper:** moves the min threshold line; reads crossing the threshold animate opacity (200 ms)
- **Max length slider/stepper:** moves the max threshold line; same animation
- The output estimate updates in the run bar based on the proportion of the length histogram that falls within [min, max]

### 9.7 Contaminant Filter

**Scene layout: reads in a vertical stack, some flagged as contaminant matches.**

```
    +--[genomic read]------------------+   PASS
    +--[genomic read]------------------+   PASS
    +--[CONTAMINANT MATCH]-------------+   FAIL  <- highlighted
    +--[genomic read]------------------+   PASS
    +--[CONTAMINANT MATCH]-------------+   FAIL  <- highlighted
    +--[genomic read]------------------+   PASS
```

**Visual elements:**

- Draw 8 reads stacked vertically
- Clean reads: `NSColor.systemBlue` at 50% opacity, "PASS" badge at trailing edge
  - Badge: rounded rect, 28 x 14 pt, `NSColor.systemGreen` at 20% fill, `.systemFont(ofSize: 9, weight: .semibold)`, `NSColor.systemGreen` text
- Contaminant reads (2 of 8, statistically proportioned): `NSColor.systemRed` at 30% opacity
  - A repeating pattern of small "X" marks (4 pt, `NSColor.systemRed` at 40%) overlaid on the read body
  - "FAIL" badge at trailing edge: rounded rect, `NSColor.systemRed` at 20% fill, `NSColor.systemRed` text
  - A label above the read: "PhiX match" or "Contaminant match" in `.systemFont(ofSize: 9)`, `NSColor.systemRed`

**Parameter response:**

- **K-mer size stepper:** changes the displayed k-mer window size. A small inset diagram shows a k-mer window on a contaminant read
- **Mismatch tolerance slider (0-3):** as tolerance increases, the displayed contaminant count may increase (illustrative; the exact count is estimated from data if available)
- Contaminant reads fade in/out with 200 ms animation when the estimated count changes

### 9.8 Error Correction

**Scene layout: a single read with highlighted mismatches being corrected.**

```
    Before:
    |A|T|G|C|C|a|T|G|g|C|T|A|A|G|c|T|
                ^           ^       ^
              error       error   error

    After (animated):
    |A|T|G|C|C|A|T|G|G|C|T|A|A|G|C|T|
                ^           ^       ^
            corrected   corrected corrected
```

**Visual elements:**

- A single read at full drawable width
- Normal bases: cells colored `NSColor.systemBlue` at 20% opacity
- Error bases (before correction): cells colored `NSColor.systemRed` at 40% opacity, base letter in `NSColor.systemRed` weight `.bold`
- A small downward arrow above each error base, `NSColor.systemRed`, 6 pt

**Correction animation (triggered on parameter change or on a looping 3-second timer):**

1. Error bases pulse: `NSColor.systemRed` opacity cycles 40% to 60% over 500 ms
2. Correction: error base letter cross-fades (200 ms) to the corrected letter
3. Cell color cross-fades (200 ms) from red to `NSColor.systemGreen` at 40% opacity
4. Arrow above changes from red downward to green checkmark (SF Symbol `checkmark`, 8 pt)
5. After 1 second in corrected state, the green fades to the normal blue (500 ms)

**Parameter response:**

- **K-mer size stepper:** higher k-mer values are shown to correct fewer (higher-confidence) errors. The display toggles between "3 errors detected" and "2 errors detected" with reads updating accordingly

### 9.9 Deinterleave

**Scene layout: interleaved reads separating into two streams.**

```
    Interleaved Input          R1 Output        R2 Output
    +--[R1: read_1/1]--+      +--[read_1]--+
    +--[R2: read_1/2]--+                       +--[read_1]--+
    +--[R1: read_2/1]--+      +--[read_2]--+
    +--[R2: read_2/2]--+                       +--[read_2]--+
    +--[R1: read_3/1]--+      +--[read_3]--+
    +--[R2: read_3/2]--+                       +--[read_3]--+
```

**Visual elements:**

The canvas is divided into three columns:

- **Left column (40% width):** "Input" header, interleaved reads stacked, alternating R1/R2
  - R1 reads: `NSColor.systemBlue` at 50% opacity
  - R2 reads: `NSColor.systemPurple` at 50% opacity
  - Labels: "R1" and "R2" prefixes in `.systemFont(ofSize: 9, weight: .bold)`

- **Middle column (10% width):** animated arrows flowing from left to right columns
  - Arrow shafts: 1 pt `NSColor.secondaryLabelColor`, bezier curves arcing from source to destination
  - Arrow heads: 6 x 4 pt triangles

- **Right columns (50% width, split in two):**
  - Top half: "R1 Output" header, blue reads only
  - Bottom half: "R2 Output" header, purple reads only
  - Reads slide into position from the center (300 ms spring animation, staggered 50 ms per read)

**Parameter response:**

- **Direction popup (Interleave / Deinterleave):** reverses the animation direction
  - Interleave: reads from two right columns merge into left column
  - Deinterleave: reads from left column split into two right columns
- Direction change triggers a full replay of the animation (500 ms total)

### 9.10 Deduplicate

**Scene layout: stacked reads with duplicates fading out.**

```
    +--[read_A: ATGCCATG...]--+   UNIQUE
    +--[read_B: ATGCCATG...]--+   DUPLICATE (fades out)
    +--[read_C: GCTTAAGC...]--+   UNIQUE
    +--[read_D: ATGCCATG...]--+   DUPLICATE (fades out)
    +--[read_E: GCTTAAGC...]--+   DUPLICATE (fades out)
    +--[read_F: TACCGGTA...]--+   UNIQUE
```

**Visual elements:**

- Draw 6-8 reads stacked vertically
- Group reads by "sequence content" (simulated: 3 groups, varying group sizes)
- First read in each group: full opacity, `NSColor.systemBlue` at 50% opacity
  - Badge at trailing edge: "UNIQUE" rounded rect, `NSColor.systemGreen` at 20% fill

- Duplicate reads: shown initially at full opacity with a "DUPLICATE" badge (`NSColor.systemOrange` at 20% fill)
- After a 500 ms delay, duplicates fade to 15% opacity over 300 ms
- Duplicates then slide up to close the gap, compacting the list (200 ms spring animation)

**Connecting lines between duplicates and their representative:**

- A thin line (0.5 pt, `NSColor.tertiaryLabelColor`, dash pattern [2, 2]) connects duplicate reads to their group's representative on the left edge

**Parameter response:**

- **Dedup mode popup (Identifier / Description / Sequence):**
  - Changing mode reshuffles which reads are marked as duplicates (illustrative; different grouping for each mode)
  - Reshuffle uses a 250 ms crossfade on badge state, followed by the fade+compact animation

- **Paired-aware checkbox:**
  - When enabled, reads are shown as paired (R1/R2 stacked within a light container box, 2 pt border radius, `NSColor.separatorColor` border)
  - Pairs are deduplicated as units

---

## 10. Animation and Transition System

### Timing Curves

All animations use Core Animation timing functions matching macOS system conventions:

| Animation Type | Duration | Timing Function |
|---|---|---|
| Parameter-driven preview update | 150 ms | `.easeInEaseOut` (`CAMediaTimingFunction(name: .easeInEaseOut)`) |
| Read fade in/out | 200 ms | `.easeOut` |
| Read slide/compact | 200 ms | Spring (damping 0.8, response 0.3) |
| Operation switch (full preview change) | 250 ms | Cross-dissolve (two-layer alpha blend) |
| Trim point movement | 150 ms | `.easeInEaseOut` |
| Error correction pulse | 500 ms | `.easeInEaseOut` (repeating) |
| Deinterleave arrow flow | 300 ms per read | Spring (damping 0.7, response 0.4), staggered 50 ms |
| Pane resize (split view) | System-managed | System spring |

### Frame Budget

The preview canvas targets 60 fps during animations. Since all rendering is CoreGraphics:

- During animation: use `CADisplayLink` to drive frame updates
- During idle: no redraw (static bitmap cached via `layer?.contents`)
- Parameter changes invalidate the cache and trigger a single redraw on the next display link tick

### Operation Switch Transition

When the user selects a different operation in the sidebar:

1. Current preview fades to 50% opacity over 125 ms
2. Parameter bar contents cross-dissolve (NSStackView arrangedSubviews swap with `.isHidden` animation)
3. New preview fades in from 50% to 100% over 125 ms
4. Total perceived transition: 250 ms

Implementation: use `NSAnimationContext.runAnimationGroup` with `allowsImplicitAnimation = true` for the parameter bar, and explicit `CABasicAnimation` on the preview layer's opacity.

---

## 11. Color System

All colors are derived from `NSColor` semantic tokens. No hardcoded RGB values.

### Semantic Color Mapping

| Purpose | NSColor Token | Usage |
|---|---|---|
| Read body (default) | `.systemBlue` at 50% alpha | Neutral read that passes filters |
| Read body (R2) | `.systemPurple` at 50% alpha | Second mate in paired reads |
| Kept/pass indicator | `.systemGreen` | Checkmark, "PASS" badge, kept bracket |
| Discarded/fail indicator | `.systemRed` | "FAIL" badge, contaminant overlay, trimmed region |
| Warning/duplicate | `.systemOrange` | "DUPLICATE" badge, min threshold line |
| Adapter highlight | `.systemOrange` at 50% alpha | Adapter region fill |
| Accent / threshold line | `.controlAccentColor` | Trim point line, sliding window, interactive elements |
| Primary text | `.labelColor` | Value labels, summary text |
| Secondary text | `.secondaryLabelColor` | Axis labels, descriptions, read IDs |
| Tertiary text | `.tertiaryLabelColor` | Disabled states, ruler ticks |
| Background (canvas) | `.textBackgroundColor` | Preview canvas background |
| Background (controls) | `.windowBackgroundColor` | Parameter bar, run bar |
| Background (cards) | `.controlBackgroundColor` at 60% alpha | Summary bar cards |
| Separator | `.separatorColor` | Dividers, borders, grid lines |
| Fade overlay | `.windowBackgroundColor` at 70% alpha | Discarded read overlay |

### Dark Mode

All `NSColor` semantic tokens automatically adapt to dark mode. No manual dark mode overrides are needed. The preview canvas will correctly invert because:

- `.textBackgroundColor` becomes dark gray
- `.labelColor` becomes white
- `.systemBlue/Green/Red/Orange` adjust saturation for dark backgrounds
- `.windowBackgroundColor` overlay for faded reads remains correct (dark overlay on dark = more opaque feel)

---

## 12. Typography

### Font Scale

| Context | Font | Size | Weight |
|---|---|---|---|
| Summary card label | `.systemFont` | 9 pt | `.medium` |
| Summary card value | `.monospacedDigitSystemFont` | 13 pt | `.semibold` |
| Sparkline title | `.systemFont` | 9 pt | `.medium` |
| Parameter label | `.systemFont` | 10 pt | `.medium` |
| Parameter control text | `.systemFont` | 12 pt | `.regular` |
| Preview summary text | `.systemFont` | 12 pt | `.medium` |
| Preview base letter | `.monospacedSystemFont` | 11 pt | `.regular` |
| Preview annotation | `.systemFont` | 10 pt | `.regular` |
| Badge text | `.systemFont` | 9 pt | `.semibold` |
| Run bar estimate | `.systemFont` | 11 pt | `.regular` |
| Table cell text | `.monospacedSystemFont` or `.systemFont` | 11-12 pt | `.regular` |
| Section header (Inspector) | `.headline` (SwiftUI) | System | System |
| Section body (Inspector) | `.callout` (SwiftUI) | System | System |
| Monospaced command text | `.system(size: 10, design: .monospaced)` | 10 pt | `.regular` |

All fonts use system-provided weights. No custom fonts.

---

## 13. Accessibility

### VoiceOver

- **Summary cards:** each card is an `NSAccessibilityElement` with role `.staticText`, value = "{label}: {value}" (e.g., "Reads: 1.2M")
- **Sparklines:** each sparkline is role `.image` with description "Length distribution sparkline chart" (etc.), with `.accessibilityLabel` describing the shape ("Bell-shaped distribution centered at 150 bp")
- **Operation sidebar:** standard source list accessibility (row-based, group headers announced)
- **Preview canvas:** role `.image` with dynamic `.accessibilityLabel` describing the current preview state. Example: "Quality trim preview showing 1 read of 150 bases, trim point at position 120, keeping 120 bases, trimming 30 bases from the 3 prime end"
- **Parameter controls:** standard AppKit accessibility (labels associated via `accessibilityLabel` property)
- **Run button:** `.accessibilityLabel = "Run operation"`, `.accessibilityHint = "Runs the selected FASTQ operation with the current parameters"`
- **Results table:** standard NSTableView accessibility (column headers, row descriptions)

### Keyboard Navigation

- Tab order: Operation sidebar -> Parameter bar controls (left to right) -> Run button -> Results table
- Arrow keys navigate the operation sidebar when focused
- Spacebar or Return activates the Run button when focused
- Command+Return runs the operation from anywhere in the FASTQ viewer

### Color Contrast

- All text meets WCAG 2.1 AA contrast ratio (4.5:1 for normal text, 3:1 for large text)
- Badge colors use both color AND text to convey status (never color alone)
- Kept/discarded states use both opacity AND icon (checkmark/X) to convey status
- Quality-to-color mapping is supplemented by numeric Q values displayed as text

### Reduced Motion

When `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` is true:

- All parameter-driven preview updates are instant (no animation)
- Operation switch uses a cut (instant swap) instead of crossfade
- Deinterleave reads appear in final position without sliding
- Error correction bases change color instantly without pulsing
- Duplicate compaction is instant (no slide)

### Dynamic Type

The FASTQ viewer respects system text size preferences via `NSFont.preferredFont(forTextStyle:)` for all non-fixed-size text. Fixed-size elements (base cells at 12x12 pt, badge dimensions) do not scale, as they represent data visualization rather than reading content.

---

## Appendix A: Implementation Priority

| Phase | Scope | Effort |
|---|---|---|
| Phase 1 | Three-pane split, sparkline strip, operation sidebar, parameter bar | 2 weeks |
| Phase 2 | Preview canvas framework + 3 operations (Quality Trim, Subsample Proportion, Length Filter) | 2 weeks |
| Phase 3 | Remaining 7 operation previews | 2 weeks |
| Phase 4 | Results table, Inspector provenance, animation polish | 1 week |
| Phase 5 | Accessibility audit, dark mode verification, reduced motion | 1 week |

## Appendix B: Files Affected

| File | Change |
|---|---|
| `FASTQDatasetViewController.swift` | Major rewrite: three-pane layout, operation sidebar, preview canvas hosting |
| `FASTQChartViews.swift` | Add `FASTQSparklineStrip` class; existing chart classes retained for popover use |
| `OperationPreviewView.swift` | New file: CoreGraphics preview canvas with per-operation drawing |
| `OperationPreviewAnimator.swift` | New file: CADisplayLink-based animation driver |
| `InspectorViewController.swift` | Wire provenance section for derived FASTQ files |
| `DocumentSection.swift` | Add Provenance and Estimated Impact disclosure groups |
| `QualitySection.swift` | No change (Inspector section unchanged) |
| `MainSplitViewController.swift` | Minor: update FASTQ view controller instantiation |

## Appendix C: Rejected Alternatives

1. **Toolbar segmented control for operations:** Rejected because 15 operations exceed the practical limit for a segmented control (Apple HIG recommends 5-7 segments maximum). A source list sidebar provides grouping and scrolling.

2. **SwiftUI Charts for sparklines:** Rejected for the sparkline strip because the existing CoreGraphics histogram code is already written and battle-tested. The sparklines are a miniaturized version of the same code. SwiftUI Charts would require bridging overhead and does not provide the per-pixel control needed for the 44 pt sparkline height.

3. **NSPopover for operation parameters:** Rejected because parameters must be visible alongside the preview for direct manipulation. A popover would break the spatial relationship between controls and preview.

4. **Full-width histograms with collapse toggle:** Rejected because even collapsed, full histograms waste vertical space. Sparklines with popover-on-click provide the same information in 52 pt instead of 240 pt.

5. **Console log retained as collapsible section:** Rejected because console output is not actionable for scientists. Operation status belongs in the activity indicator bar and Inspector provenance. Errors are shown as `NSAlert` sheets (already implemented).
