# FASTQ Document Inspector & Operations -- Information Architecture

## Status: Design Proposal
## Date: 2026-03-08
## Author: Team C (macOS Application Architecture)

---

## Executive Summary

This document specifies the complete information architecture for the FASTQ
workflow in Lungfish Genome Browser. It covers five areas: (1) the Document
Inspector layout when a FASTQ file is selected, (2) the operation
configuration pattern, (3) results display, (4) histogram sizing and
before/after comparison, and (5) the overall view hierarchy with
state-dependent content.

The design follows the Xcode Inspector model for metadata, the Final Cut Pro
Inspector model for operational parameters, and the Keynote Inspector model
for disclosure-group sectioning. All recommendations reference existing
codebase patterns (SwiftUI DisclosureGroup sections in DocumentSection.swift,
CoreGraphics chart views in FASTQChartViews.swift, NSSplitViewController in
MainSplitViewController.swift).

---

## 1. Document Inspector for FASTQ Files

### 1.1 Overall Structure

The Inspector uses the existing three-tab segmented control (Document /
Selection / AI). When a FASTQ file is selected in the sidebar, the
**Document** tab displays the following sections in a scrollable VStack.
Each section is a SwiftUI `DisclosureGroup` with a bold `.headline` label,
matching the existing `DocumentSection.swift` pattern.

```
+----------------------------------------------+
|  [Document]  [Selection]  [AI]               |
+----------------------------------------------+
|                                              |
|  sample_R1.fastq.gz                          |
|  4.2 GB  |  12.4M reads  |  PE/R1           |
|                                              |
|  [====== quality sparkline =========]  Q32.1 |
|  [A 28%] [T 27%] [G 23%] [C 22%]            |
|                                              |
|  --- Section A: File Summary --------  [-]   |
|  Filename       sample_R1.fastq.gz           |
|  File Size      4.2 GB                       |
|  Read Count     12,403,881                   |
|  Format         Paired-End (R1)              |
|  Mean Length    151.0 bp                      |
|  GC Content     42.3%                        |
|                                              |
|  --- Section B: Provenance -----------  [-]  |
|  (only shown for derived files)              |
|                                              |
|  --- Section C: Quality Metrics ------  [-]  |
|  (key stats grid)                            |
|                                              |
+----------------------------------------------+
```

### 1.2 Section A: File Summary

**Header card** (always visible, not collapsible):

- **Line 1**: Filename in `.headline` weight, single line, truncated middle.
- **Line 2**: Three pipe-separated metadata chips in `.subheadline`
  `.secondary`: file size | read count (formatted "12.4M reads") | format
  label (SE / PE-R1 / PE-R2 / Interleaved).
- **Line 3**: Quality sparkline. This is a 200x16pt horizontal filled-area
  chart showing the per-position mean quality score. Drawn inline using
  CoreGraphics (same pattern as `FASTQSummaryBar`). The rightmost label
  shows the overall mean Q score in `.monospacedDigit` `.semibold`.
- **Line 4**: Base composition as four colored rectangles in a horizontal
  stack, each labeled with the nucleotide letter and percentage. Colors:
  A = green (#5DB85D), T = red (#D9534F), G = amber (#F0AD4E),
  C = blue (#5BC0DE). Proportional widths sum to the available width.
  This is more compact than a pie chart and reads faster in a narrow pane.

**Collapsible detail** (DisclosureGroup, expanded by default):

| Label | Value | Notes |
|-------|-------|-------|
| Filename | `sample_R1.fastq.gz` | `.monospaced` caption, context menu "Copy" |
| File Size | `4.2 GB` | ByteCountFormatter |
| Read Count | `12,403,881` | NumberFormatter `.decimal` |
| Base Count | `1.87 Gb` | formatBases() |
| Format | `Paired-End (R1)` | from IngestionMetadata.pairingMode |
| Mean Length | `151.0 bp` | |
| Min / Max Length | `35 / 151 bp` | single row, slash-separated |
| Median Length | `151 bp` | |
| N50 | `151 bp` | |

### 1.3 Section B: Provenance (Derived Files Only)

This section appears only when `fastqDerivativeManifest != nil`. It replaces
the current `fastqDerivativeSection` in DocumentSection.swift with a richer
layout.

**Section header**: "Provenance" in `.headline`, with a small
`arrow.triangle.branch` SF Symbol to the left.

**Operation card** (always visible within the section):

```
+--------------------------------------------+
|  [scissors.badge.ellipsis]                 |
|  Quality Trim Q20 w4 (cutRight)            |
|  fastp v0.23.4                             |
|  3 Mar 2026  14:32   |   Duration: 2m 14s |
+--------------------------------------------+
```

- **Icon**: SF Symbol chosen by operation kind (see mapping below).
- **Operation name**: `operation.displaySummary` in `.callout` `.semibold`.
- **Tool name and version**: `operation.toolUsed` in `.caption` `.secondary`.
  If the tool string contains a version (e.g., "fastp 0.23.4"), parse and
  display as "fastp v0.23.4".
- **Timestamp + duration**: Two items on one line. Timestamp uses
  `DateFormatter` with `.medium` date and `.short` time. Duration is
  computed from `operation.createdAt` minus parent creation time, displayed
  as "Xm Ys" or "Xs" if under one minute.

**Operation kind to SF Symbol mapping**:

| Kind | Symbol |
|------|--------|
| subsampleProportion / subsampleCount | `dice` |
| lengthFilter | `ruler` |
| searchText / searchMotif | `magnifyingglass` |
| deduplicate | `minus.circle` |
| qualityTrim | `scissors` |
| adapterTrim | `bandage` |
| fixedTrim | `crop` |
| contaminantFilter | `xmark.shield` |
| pairedEndMerge | `arrow.triangle.merge` |
| pairedEndRepair | `wrench` |
| primerRemoval | `eraser` |
| errorCorrection | `checkmark.circle` |
| interleaveReformat | `arrow.left.arrow.right` |

**Command line block**:

Displayed as a scrollable monospace text block with a fixed maximum height
of 60pt (approximately 4 lines). Uses `.system(.caption, design: .monospaced)`
on a `.controlBackgroundColor` rounded rectangle with 6pt corner radius
and 1px `.separatorColor` border.

The block has a "Copy" button (doc.on.doc SF Symbol) in the top-right
corner, pinned with a ZStack overlay. Clicking copies the full command
to `NSPasteboard.general`. The text is `.textSelection(.enabled)` for
partial selection.

If the command exceeds 4 lines, the block is scrollable (ScrollView) but
NOT expandable -- the user copies and pastes into Terminal if they need
the full view. This keeps the inspector compact.

**Input file reference**:

A single `metadataRow` with label "Input" and value showing the parent
bundle name. The value is styled as a link (`.foregroundColor(.accentColor)`)
and is clickable. Clicking posts a `Notification` named
`.navigateToFASTQBundle` with the parent bundle's relative path, which
MainSplitViewController handles by selecting that item in the sidebar
outline view.

**Lineage chain** (when `manifest.lineage.count > 1`):

Rendered as a **vertical timeline**, not a breadcrumb. Each step is:

```
  [1]  Root FASTQ
   |     sample_R1.fastq.gz
   |
  [2]  Adapter Trim (auto-detect)
   |     fastp 0.23.4
   |
  [3]  Quality Trim Q20 w4        <-- current, highlighted
         fastp 0.23.4
```

Implementation:

- Each step is a VStack row containing:
  - A circled step number (ZStack: Circle fill `.quaternarySystemFill` +
    Text step number in `.caption2` `.semibold`), 20x20pt.
  - Operation display summary in `.caption`.
  - Tool name in `.caption2` `.tertiary`.
- Between steps, a 1pt-wide vertical line in `.separatorColor`, 16pt tall,
  inset to align with the circle center.
- The current (last) step has the circle filled with `.accentColor` and
  white text.
- Each step is tappable. Tapping navigates to that ancestor bundle in the
  sidebar (same notification mechanism as the parent link).

### 1.4 Section C: Quality Metrics

**Section header**: "Quality" in `.headline`.

**Stats grid** (2-column, label-value):

| Label | Value | Visual |
|-------|-------|--------|
| Total Reads | 12,403,881 | |
| Mean Length | 151.0 bp | |
| Mean Quality | 32.1 | QualityBar (existing) |
| GC% | 42.3% | |
| N% | 0.02% | |
| Duplication Rate | 8.4% | PercentageBar if available |
| Q20 Bases | 96.2% | PercentageBar green |
| Q30 Bases | 91.7% | PercentageBar blue |

**Expandable sub-sections** (nested DisclosureGroups, collapsed by default):

- "Length Distribution": inline sparkline (60pt tall filled area chart).
  Tapping opens the full chart in the main content area.
- "Quality per Position": inline sparkline (60pt tall, showing mean line
  with green/yellow/red background bands). Tapping opens full boxplot.
- "Quality Score Distribution": inline sparkline. Tapping opens full chart.

These sparklines are drawn with CoreGraphics in a custom NSViewRepresentable
wrapping a minimal version of the existing chart views, stripped of axis
labels and titles. They serve as previews; the full charts live in the
content area.

---

## 2. Operation Configuration

### 2.1 Options Analysis

| Option | Pros | Cons |
|--------|------|------|
| **A: Toolbar-based** (Preview markup) | Discoverable, quick access | Too many operations (15) for toolbar; parameters need forms, not just toggles |
| **B: Sheet-based** (export dialog) | Clear modal context, undo is just "Cancel" | Blocks main content; cannot preview results while configuring; feels heavyweight for frequent use |
| **C: Inspector-driven** (FCP Inspector) | Parameters visible alongside content; non-modal; preview possible | Inspector width (260-300pt) is narrow for complex forms; mixes configuration with metadata |
| **D: Source list / sidebar** (Mail) | Operations always visible; good for browsing | Takes permanent space; confuses "available operations" with "performed operations" |

### 2.2 Recommendation: Hybrid C+B -- Inspector-Initiated Sheet

**Primary pattern**: The Inspector's Selection tab gains a new "Operations"
section (DisclosureGroup) that shows a categorized list of available
operations. Each operation is a single row with icon + name. Clicking an
operation opens a **focused parameter sheet** (NSPanel presented as a
window-modal sheet) sized to the operation's parameter count.

This combines the discoverability of the Inspector (operations are always
browsable in the sidebar without leaving context) with the ergonomic
parameter editing of a sheet (proper form layout, cancel/run buttons,
adequate width).

**Why not pure Inspector (Option C)**:
The Inspector is 260-300pt wide. Operations like "Adapter Trim" or "Primer
Removal" need a mode popup, multiple text fields, a file picker, and
contextual help text. Cramming these into 260pt results in the current
problem: tiny fields, horizontal scrolling, and no room for inline
documentation. A sheet at 480-520pt width provides comfortable form layout.

**Why not pure Sheet (Option B)**:
Without the Inspector listing, users must remember what operations exist.
The current popup menu is flat and undiscoverable. The Inspector provides
a persistent, categorized catalog.

### 2.3 Operations Section in Inspector (Selection Tab)

```
+----------------------------------------------+
|  --- Operations --------------------  [-]    |
|                                              |
|  Sampling                                    |
|    [dice]  Subsample by Proportion           |
|    [dice]  Subsample by Count                |
|                                              |
|  Filtering                                   |
|    [ruler]         Filter by Read Length      |
|    [xmark.shield]  Contaminant Filter        |
|    [minus.circle]  Remove Duplicates         |
|                                              |
|  Trimming                                    |
|    [scissors]  Quality Trim                  |
|    [bandage]   Adapter Removal               |
|    [crop]      Fixed Trim (5'/3')            |
|    [eraser]    Custom Primer Removal         |
|                                              |
|  Search                                      |
|    [magnifyingglass]  Find by ID/Description |
|    [magnifyingglass]  Find by Sequence Motif |
|                                              |
|  Paired-End                                  |
|    [arrow.triangle.merge]  Merge Pairs       |
|    [wrench]                Repair Pairs      |
|    [arrow.left.arrow.right] Interleave       |
|                                              |
|  Correction                                  |
|    [checkmark.circle]  Error Correction      |
|                                              |
+----------------------------------------------+
```

Each row is a `Button` with `.plain` style. Hover highlights with
`.quaternarySystemFill`. Click opens the parameter sheet.

Category headers use `.caption` `.secondary` `.uppercase` with 4pt top
padding, matching Xcode's Inspector section sub-headers.

### 2.4 Parameter Sheet Design

The sheet is an NSPanel presented via `window.beginSheet()`. Size:
480pt wide x dynamic height (minimum 240pt, maximum 500pt, content-driven).

Layout follows Apple's sheet conventions (Keynote export sheet, Xcode
build settings sheet):

```
+------------------------------------------------+
|  [Operation Icon]  Quality Trim                |
|  Trim low-quality bases from read ends using   |
|  a sliding window approach.                    |
|                                                |
|  +----- Parameters --------------------------+ |
|  |  Quality Threshold    [  20  ]            | |
|  |  Window Size          [   4  ]            | |
|  |  Direction     [Cut Right (3') v]         | |
|  +-------------------------------------------+ |
|                                                |
|  [?] Documentation     [ Cancel ] [ Run    ]  |
+------------------------------------------------+
```

- **Header**: Operation icon (28pt) + operation name in `.title3` +
  one-sentence description in `.callout` `.secondary`.
- **Parameters group**: Rounded-rect background (`.controlBackgroundColor`),
  standard form layout with labels left-aligned at 140pt width, controls
  right-aligned. Uses the same control types as the current bottom pane
  (NSTextField, NSPopUpButton, NSButton checkbox) but with proper vertical
  spacing (8pt) and full-width layout.
- **Footer**: Left side has a help button ([?]) that opens inline
  documentation (a disclosure section within the sheet, not a separate
  window). Right side has Cancel and Run buttons. Run uses
  `.keyboardShortcut(.return)`.
- **Keyboard shortcut**: Cmd+Shift+O opens the Operations section
  in the Inspector. When the Inspector is hidden, this first shows the
  Inspector, then scrolls to Operations.

### 2.5 Preview Integration

While the sheet is open, the main content area remains visible behind it
(standard sheet behavior). After the operation completes, the sheet
dismisses and the result appears. There is no live preview during parameter
configuration -- FASTQ operations are inherently batch (they process
millions of reads). A "preview" would be misleading since it would either
be instant (on a tiny sample, unrepresentative) or slow (defeating the
purpose).

### 2.6 Undo/Cancel Behavior

- **Cancel button**: Dismisses the sheet. No state changes.
- **Run button**: Dismisses the sheet, starts the operation. The operation
  appears in the Operations Panel (existing `OperationsPanelController`).
- **Undo**: Derived bundles are stored as sibling directories. Undo is
  "delete the derived bundle" -- available via right-click on the derived
  file in the sidebar ("Delete" / "Move to Trash"). There is no Cmd+Z for
  completed operations because the operation creates a new file; it does
  not modify the original.

---

## 3. Results Display

### 3.1 How the User Sees the Result

When an operation completes:

1. **Sidebar update**: The derived bundle appears as a **child node** of the
   parent FASTQ bundle in the sidebar outline view, indented one level.
   The child node's icon uses the operation's SF Symbol (from the mapping
   in Section 1.3). The name is the operation's `shortLabel` (e.g.,
   "qtrim-Q20").

2. **Automatic selection**: The sidebar selects the new child node. This
   triggers the standard selection flow: the main content area loads the
   derived dataset's FASTQDatasetViewController, and the Inspector shows
   the derived file's metadata including full provenance.

3. **Toast notification**: A brief notification banner appears at the top
   of the content area: "[checkmark.circle.fill] Quality Trim completed --
   10,234,556 reads retained (82.5%)". This uses the existing overlay
   pattern (ProgressOverlayView style) with a 3-second auto-dismiss.

### 3.2 Document Structure

```
Sidebar Outline:
  [folder] Project
    [doc] sample_R1.fastq.gz           <-- root FASTQ
      [scissors] qtrim-Q20             <-- derived (trim)
        [bandage] adapter-trim         <-- derived-of-derived
      [dice] subsample-n10000          <-- another derived branch
    [doc] sample_R2.fastq.gz           <-- root FASTQ (mate)
```

Derived files are nested under their parent in the outline view. The outline
supports arbitrary depth (trim-of-subsample-of-original). Each level uses
the operation's icon.

The sidebar uses `NSOutlineView` with `isItemExpandable` returning true for
any FASTQ bundle that has children. Children are discovered by scanning
sibling directories for `.lungfishfastq` bundles whose
`parentBundleRelativePath` points to this bundle.

### 3.3 Before/After Comparison

The user compares by selecting the parent and child in sequence. But a
dedicated comparison mode is more useful:

**Comparison mode**: Right-click a derived file in the sidebar and choose
"Compare with Parent". This activates a split-pane comparison in the main
content area:

```
+--------------------------------------------------+
|  sample_R1.fastq.gz      |   qtrim-Q20           |
|  12.4M reads  Q32.1      |   10.2M reads  Q34.8  |
|                           |                       |
|  [=== length hist ====]   |   [=== length hist ==]|
|                           |                       |
+--------------------------------------------------+
```

- The content area splits vertically (left = parent, right = child).
- Summary bars are shown for both.
- Charts can be overlaid (see Section 4.4).
- The Inspector shows a **comparison summary**: delta reads, delta mean Q,
  reads removed, bases trimmed.

Implementation: `FASTQComparisonViewController` (new) embeds two
`FASTQSummaryBar` instances and overlaid chart views in a side-by-side
NSSplitView.

### 3.4 Chaining Multiple Operations

Operations chain naturally because each derived bundle can be the input
to another operation:

1. Select the derived file in the sidebar.
2. Open an operation from the Inspector's Operations section.
3. The sheet's header shows "Input: qtrim-Q20 (10.2M reads)" to confirm
   the user is operating on the derived file, not the root.
4. Run creates a grandchild bundle.

The lineage chain in the Inspector's Provenance section (Section 1.3)
shows the full history. The user can navigate to any ancestor by clicking
its step in the timeline.

---

## 4. Histogram Display

### 4.1 Compact vs Expanded

| Context | Display Mode | Size |
|---------|-------------|------|
| Inspector quality section | Sparkline | 200 x 16pt (inline with text) |
| Inspector expandable sub-section | Mini chart | full width x 60pt |
| Main content area (active tab) | Full chart | full width x capped height |
| Comparison overlay | Overlaid chart | full width x capped height |

### 4.2 Toggle Mechanism

- **Inspector sparkline to mini chart**: DisclosureGroup expansion. The
  sparkline is always visible as part of the Quality Metrics section. The
  DisclosureGroup "Length Distribution" expands to show the 60pt mini chart.
- **Mini chart to full chart**: Click. Clicking the mini chart in the
  Inspector switches the main content area's chart tab to the corresponding
  chart and scrolls the content area to make the chart visible.
- **Full chart expand/collapse in content area**: The existing segmented
  control (tabBar) switches between charts. No separate expand/collapse --
  the chart fills the available space within the 1/3 viewport cap.

### 4.3 Before/After Overlay

In comparison mode, histograms overlay parent and child data:

- **Parent data**: Rendered as a filled area with 30% opacity in the
  parent's color (systemBlue for length, systemGreen for Q score).
- **Child data**: Rendered as a filled area with 60% opacity in a
  contrasting color (systemOrange for length, systemTeal for Q score).
- **Legend**: Small legend in the top-right corner: colored square + label
  for each dataset.
- **Difference highlighting**: Bars where child count exceeds parent are
  tinted green (gained). Bars where child count is less than parent are
  tinted red with a striped pattern (lost). This is optional and toggled
  by a checkbox "Show Differences" below the chart.

Implementation: Add a second `bins` array to `FASTQHistogramChartView`
(optional overlay data). When overlay data is present, both datasets are
drawn in the same coordinate space with the parent behind and child in
front.

### 4.4 Chart Style

- **Histograms (length, Q score)**: Filled vertical bars with 1pt gap
  between bars. Bar corners are not rounded (sharp rectangles for data
  density). Fill color at 70% opacity with a 1pt border at 90% opacity.
  This is the existing style in `FASTQHistogramChartView` and should not
  change.
- **Quality per position**: Boxplot. This is the existing style in
  `FASTQQualityBoxplotView` (FastQC-inspired). No change.
- **Sparklines (Inspector)**: Filled area chart (no bars). A single
  `CGPath` with `addLine` for each point, closed at the bottom. Fill at
  20% opacity of the bar color, stroke at 60% opacity, 0.5pt line width.
  No axis labels. No title.

### 4.5 Axis Labels and Ticks

For full charts in the content area (existing behavior, retained):

- **Y-axis**: 5 horizontal grid lines with labels left of the chart area.
  Labels use `.monospacedDigitSystemFont(ofSize: 9)` `.secondaryLabelColor`.
  Values are formatted with K/M suffixes via `formatCount()`.
- **X-axis**: Labels spaced to avoid crowding (max density: one label per
  40pt). Labels use the same font. Values are raw integers.
- **Axis titles**: `.systemFont(ofSize: 10)` `.secondaryLabelColor`,
  centered below X-axis and rotated 90 degrees for Y-axis. Existing
  implementation in `FASTQHistogramChartView.draw(_:)`.

For mini charts in the Inspector (60pt height):
- No axis labels or titles.
- Two horizontal reference lines at 25% and 75% of max value, dotted,
  0.5pt, `.separatorColor` at 20% opacity.

### 4.6 The 1/3 Viewport Height Cap

The existing `chartHeightConstraint` caps chart height at
`min(viewHeight / 3.0, 240)`. This is correct for the single-chart view.

For comparison mode (two charts side by side), each chart gets half the
cap: `min(viewHeight / 3.0, 240) / 2.0` -- but this is too small. Instead,
in comparison mode, stack the summary bars above and use a single overlaid
chart at the full cap height. The overlay approach (Section 4.3) means we
do not need to double the chart space.

When the window is tall (>900pt), raise the cap to 300pt to give charts
more room. Formula: `min(viewHeight / 3.0, viewHeight > 900 ? 300 : 240)`.

---

## 5. Overall View Architecture

### 5.1 View Hierarchy

```
+---NSWindow (MainWindowController)-----------------------------------+
| NSToolbar (unified style)                                           |
|  [Chromosomes] [flex] [Translate] [flex] [Downloads] [flex]         |
|  [Annotations] [flex] [Inspector]                                   |
+---------------------------------------------------------------------+
|                                                                     |
| +---NSSplitViewController (MainSplitViewController)---------------+ |
| |                                                                 | |
| | +--Sidebar--+ +-------Content Area--------+ +---Inspector----+ | |
| | | (Panel 0) | |       (Panel 1)            | |   (Panel 2)    | | |
| | |           | |                            | |                | | |
| | | Outline   | |  State-dependent:          | | Tab bar:       | | |
| | | View      | |  - Welcome                | | [Doc][Sel][AI] | | |
| | |           | |  - Genome Viewer           | |                | | |
| | | [folder]  | |  - FASTQ Dashboard        | | Scrollable     | | |
| | |   [doc]   | |  - FASTQ Comparison       | | content per    | | |
| | |     [op]  | |  - VCF Viewer             | | tab            | | |
| | |   [doc]   | |  - Loading                | |                | | |
| | |           | |  - Error                  | |                | | |
| | |           | |                            | |                | | |
| | +-----------+ +----------------------------+ +----------------+ | |
| |                                                                 | |
| | +--- Activity Indicator Bar -----------------------------------+| |
| +-----------------------------------------------------------------+ |
+---------------------------------------------------------------------+
```

### 5.2 Content Area States

| State | Main Content | Inspector (Document tab) | Inspector (Selection tab) |
|-------|-------------|-------------------------|--------------------------|
| **No selection** | Welcome view (existing WelcomeWindowController content embedded) | "No Bundle Loaded" placeholder | Empty |
| **Loading FASTQ** | Centered spinner + "Scanning N reads..." label | "Loading..." placeholder | Empty |
| **Viewing FASTQ** | FASTQDatasetViewController: summary bar + chart tabs + console | Section A (File Summary) + Section C (Quality Metrics) + SRA/ENA/Ingestion metadata | Operations list (Section 2.3) |
| **Viewing derived FASTQ** | Same as above, populated with derived stats | Section A + Section B (Provenance) + Section C | Operations list (can chain further) |
| **Comparing FASTQ** | FASTQComparisonViewController: split summary + overlaid charts | Comparison summary (delta stats) | "End Comparison" button + operations list |
| **Viewing genome bundle** | ViewerViewController (existing) | Bundle metadata (existing DocumentSection) | Annotation/appearance controls (existing) |
| **Configuring operation** | Content area unchanged (sheet overlays) | Unchanged | Unchanged |
| **Operation running** | Content area unchanged; progress in Operations Panel + Activity Bar | Unchanged | Spinner next to the running operation row |
| **Error** | Centered error icon + message + "Try Again" button | "Error" state | Empty |

### 5.3 Inspector Content by Tab

**Document tab** (when FASTQ selected):
1. Header card (non-collapsible): filename, size, read count, format,
   sparkline, base composition.
2. Provenance section (DisclosureGroup, derived files only).
3. Quality Metrics section (DisclosureGroup).
4. SRA Metadata section (DisclosureGroup, if available).
5. ENA Metadata section (DisclosureGroup, if available).
6. Ingestion Metadata section (DisclosureGroup, if available).

**Selection tab** (when FASTQ selected):
1. Operations section (DisclosureGroup, expanded by default): categorized
   list of available operations per Section 2.3.
2. Quality Overlay toggle (existing QualitySection).

**AI tab**: Unchanged (existing AIAssistantPanel).

### 5.4 Toolbar Items

The existing toolbar items remain. No new toolbar items are added for FASTQ
operations. Rationale: the toolbar is for view-level toggles (Inspector,
Chromosomes, Annotations, Downloads, Translate), not for data operations.
Adding 15 FASTQ operations to the toolbar would violate Apple's guidance
that toolbars contain "frequently used commands that apply broadly."

One potential addition for future consideration: a "Compare" toolbar button
that activates comparison mode when two FASTQ items are selected in the
sidebar. But this is lower priority than the Inspector-driven operation
flow.

### 5.5 Split View Dividers

**Sidebar (Panel 0)**:
- Minimum width: 200pt.
- Maximum width: 350pt.
- Default width: 240pt.
- Collapsible: Yes (existing behavior via NSSplitViewItem `.canCollapse`).
- Divider style: `.thin` (existing).

**Content Area (Panel 1)**:
- Minimum width: 400pt.
- No maximum (fills remaining space).
- This is the only panel that stretches on window resize.

**Inspector (Panel 2)**:
- Minimum width: 260pt.
- Maximum width: 360pt.
- Default width: 280pt.
- Collapsible: Yes (existing behavior).
- Divider style: `.thin` (existing).

These values match the existing `MainSplitViewController` configuration.
No changes needed.

### 5.6 FASTQ Content Area Internal Split

Within `FASTQDatasetViewController`, the existing horizontal NSSplitView
(top = charts, bottom = operations console) changes:

**Current** (problematic):
```
+--------- Top Pane --------- +
| Summary Bar                  |
| Chart Tabs + Chart           |
+--------- Bottom Pane ------ +
| "FASTQ Operations" title     |
| [Operation Popup] [params]   |
| [Run] [Quality Report]       |
| Console log                  |
+------------------------------+
```

**Proposed**:
```
+--------- Top Pane ----------+
| Summary Bar                  |
| Chart Tabs + Chart           |
+--------- Bottom Pane -------+
| Console log (read-only)      |
+------------------------------+
```

The bottom pane becomes a pure operation log/console. All operation
selection and parameter configuration moves to the Inspector + sheet
(Section 2). The console shows timestamped entries: operation started,
progress updates, completion/failure messages. This is a read-only
monospace text view (existing `consoleTextView`).

The popup menu, parameter fields, and Run button are removed from the
bottom pane. This eliminates the visual hierarchy confusion between
"configure" and "view results" -- configuration is in the Inspector/sheet,
results are in the content area and sidebar.

The "Compute Quality Report" button moves to the Inspector's Quality
Metrics section (a button at the bottom of the DisclosureGroup content,
styled as `.link` to save space).

---

## 6. Implementation Priority

| Priority | Component | Effort | Files Affected |
|----------|-----------|--------|----------------|
| P0 | Move operations to Inspector Selection tab | Medium | InspectorViewController.swift, SelectionSection (new), FASTQDatasetViewController.swift |
| P0 | Parameter sheet for each operation | Medium | New: OperationSheetController.swift |
| P1 | Provenance timeline in Document tab | Low | DocumentSection.swift |
| P1 | Remove operation controls from bottom pane | Low | FASTQDatasetViewController.swift |
| P1 | Derived file nesting in sidebar | Medium | SidebarViewController.swift |
| P2 | Comparison mode | High | New: FASTQComparisonViewController.swift |
| P2 | Histogram overlay | Medium | FASTQChartViews.swift |
| P3 | Inspector sparklines | Low | New: FASTQSparklineView.swift |
| P3 | Base composition bar | Low | DocumentSection.swift |

---

## 7. Apple Precedent References

| Pattern | Apple App | How We Adapt It |
|---------|-----------|-----------------|
| Inspector with DisclosureGroups | Xcode File Inspector | Sections A/B/C with disclosure triangles |
| Inspector-initiated action sheet | Final Cut Pro color correction | Operation list in Inspector, params in sheet |
| Vertical timeline for history | Time Machine / Git history in Xcode | Lineage chain visualization |
| Inline sparklines | Activity Monitor | Quality sparkline in header card |
| Sheet for parameter forms | Keynote Export, Xcode Build Settings | Operation parameter sheets |
| Sidebar tree with operation icons | Xcode Project Navigator | Derived files nested under parent |
| Toolbar for view toggles only | Xcode, Final Cut Pro | No operation buttons in toolbar |
| Unified toolbar style | macOS 26 standard | Existing `toolbarStyle = .unified` |
| Comparison split view | FileMerge, Xcode diff viewer | FASTQ before/after comparison |
