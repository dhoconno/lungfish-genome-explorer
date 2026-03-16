# UX Research: Batch Selection of Demux Children in NSOutlineView Sidebar

**Date:** 2026-03-12
**Status:** Research Complete — Actionable Recommendations
**Scope:** How users select and operate on groups of barcode children after demultiplexing
**Related:** `batch-processing-recipe-system.md`, `fastq-inspector-ia.md`, `fastq-operations-ux-plan.md`

---

## 1. Problem Statement

After demultiplexing a FASTQ file, the sidebar contains 20-96 barcode child bundles nested under a parent. Users need to:

1. Select all barcode children to run a batch operation (e.g., "Filter by Read Length")
2. After that operation completes, find and select all filtered results for the next operation
3. Chain operations: demux -> filter -> trim -> orient, each time targeting all barcodes

With Option B (nested results under each barcode), the hierarchy grows deep and selecting "all filtered children" across 96 barcodes becomes a 96-click task. This is a critical usability failure for the primary workflow.

### Why Option B (Nested) Is Still Correct for the Data Model

Option B preserves the true parent-child lineage. Each barcode01-filtered is semantically a child of barcode01, not a sibling in a flat results folder. This matters for:

- Provenance tracking (the lineage timeline in the Inspector)
- Comparing a barcode's filtered output against its raw input
- Individual barcode re-processing (re-run just barcode47 with different parameters)
- Conceptual clarity: the tree IS the pipeline history

The problem is not the data model. The problem is that the sidebar's visual representation forces the data model's tree structure onto the selection model, and tree structures are hostile to cross-branch multi-selection.

---

## 2. Competitive Analysis: How Similar Tools Handle This

### Galaxy (web-based workflow platform)

Galaxy separates the concepts of "data history" (a linear list of all datasets) from "workflow execution" (a DAG of tools). After a batch operation, all outputs appear as a flat list in the history panel, tagged with their provenance. Users select outputs by tag, not by navigating a tree. Galaxy's history tagging system is the closest analogue to what Lungfish needs.

**Key insight:** Galaxy never asks users to navigate into 96 sub-trees. It provides flat, filterable views of batch results.

### Geneious Prime

Geneious uses a document table (flat list) as the primary selection surface, with a folder tree for organization. After a batch operation, results appear as new documents in the same folder, named with operation suffixes. Users sort/filter the document table by name, type, or metadata columns, then Cmd+A to select all visible. The folder tree is for navigation, not for batch selection.

**Key insight:** Geneious separates navigation (tree) from selection (flat table). Batch selection always happens in the flat table view.

### CLC Genomics Workbench

CLC presents batch results in a flat table with a "Source" column showing which input produced each output. Users can sort by source, group by operation, and select all results of a batch with Cmd+A after filtering. The navigation tree is purely for folder organization.

### IGV

IGV does not handle batch FASTQ processing, so it is not relevant to this specific interaction pattern.

### Finder (macOS reference)

Finder solves the "select items matching criteria across a hierarchy" problem with **Smart Folders** (saved searches). A Smart Folder can show "all files modified today" or "all files with tag 'filtered'" regardless of where they live in the folder hierarchy. The Smart Folder appears in the sidebar alongside regular folders, but its contents are a flat, virtual view.

### Photos (macOS reference)

Photos uses **Smart Albums** — the same concept. "All screenshots" or "All photos from last week" appear as albums in the sidebar, but their contents are computed from metadata, not manual organization.

### Mail (macOS reference)

Mail uses **Smart Mailboxes** — "All unread from VIPs", "All flagged messages". The Smart Mailbox appears in the sidebar as a first-class item.

---

## 3. Core Insight

Every successful tool that handles batch selection across hierarchies introduces a **virtual flat view** that sits alongside the hierarchy, not inside it. The tree remains the source of truth for structure and provenance. The flat view is the selection surface for batch operations.

Lungfish should do the same thing.

---

## 4. Recommended Solution: Batch Result Groups (Virtual Nodes)

### 4.1 The Concept

When a batch operation completes (e.g., "Filter by Read Length" across 96 barcodes), the system creates a **virtual group node** in the sidebar. This node:

- Appears as a sibling of the parent FASTQ bundle (or as a child of a "Batch Results" group)
- Contains references to all 96 filtered outputs
- Is NOT a filesystem folder — it is a saved query: "all bundles created by batch operation X"
- Selecting it selects all 96 items for the purposes of running the next operation

The actual data stays nested under each barcode (Option B). The virtual group is a lens into those nested results.

### 4.2 Sidebar Representation

```
Project
  sample.fastq.gz                          [parent FASTQ]
    barcode01                               [demux child]
      barcode01-filtered                    [operation result — lives here physically]
    barcode02
      barcode02-filtered
    ...
    barcode96
      barcode96-filtered
  [ruler] Filtered (96 barcodes)            [virtual batch group — auto-created]
```

The virtual group uses a distinct icon (the operation's SF Symbol, e.g., `ruler` for length filter) and a count badge ("96 barcodes"). It appears at the same level as the parent FASTQ, visually associated but not nested inside the tree.

### 4.3 Interaction Model

**Selecting the virtual group node:**
- The content area shows the Batch Comparison Table (the NSTableView from `batch-processing-recipe-system.md` Section 7)
- The Inspector shows batch-level statistics (mean retention, outliers)
- The Operations section in the Inspector's Selection tab is enabled — any operation selected here runs on all 96 members

**Expanding the virtual group node:**
- Shows the 96 member items as a flat list (not nested)
- Users can Cmd+click to deselect specific barcodes before running the next operation
- Users can Shift+click to select a contiguous range

**Right-clicking the virtual group node:**
- "Run Operation on All..." (opens the operation sheet with all 96 as inputs)
- "Select All Members" (selects all 96 in the outline view)
- "Reveal in Hierarchy" (expands the parent tree and highlights the nested locations)
- "Remove Group" (deletes the virtual group, not the underlying data)

### 4.4 Chaining Operations

After running "Filter by Read Length" on the virtual group "Filtered (96 barcodes)", a new virtual group appears:

```
Project
  sample.fastq.gz
    barcode01
      barcode01-filtered
        barcode01-filtered-trimmed          [second operation result]
    ...
  [ruler] Filtered (96 barcodes)            [first batch group]
  [scissors] Trimmed (96 barcodes)          [second batch group — auto-created]
```

Each virtual group references the outputs of its batch operation. The chain is: select the first group, run an operation, the second group appears referencing the new outputs.

### 4.5 Implementation: `SidebarItemType.batchGroup`

Add a new case to `SidebarItemType`:

```swift
case batchGroup  // Virtual group referencing batch operation outputs
```

The `SidebarItem` gains an optional field:

```swift
/// For batchGroup items: the batch operation ID linking to BatchManifest.
public var batchOperationID: UUID?

/// For batchGroup items: the member bundle URLs (resolved from the batch manifest).
public var batchMemberURLs: [URL]?
```

When a batch operation completes, `SidebarViewController` creates a new `SidebarItem` of type `.batchGroup` with the operation's icon, a descriptive title, and the list of output bundle URLs. This item's `children` are populated lazily from `batchMemberURLs`.

The `batchOperationID` field already exists in `FASTQDerivedBundleManifest` (from `batch-processing-recipe-system.md` Section 6). The sidebar queries this to reconstruct batch groups on reload.

---

## 5. Complementary Selection Mechanisms

The virtual batch group solves the primary workflow. The following mechanisms address secondary needs and discoverability:

### 5.1 "Select Siblings" Command (Cmd+Shift+A)

When one barcode child is selected, Cmd+Shift+A selects all siblings at the same level. This is the analog of Finder's Cmd+A scoped to the current folder.

Implementation: In `SidebarViewController`, find the parent of the selected item, select all children of that parent. This requires walking the tree to find the parent, which `expandParents(of:)` already does.

Context menu entry: "Select All Siblings" — appears when a single item is selected and has siblings.

### 5.2 "Select by Operation" Context Menu

Right-clicking any derived bundle shows "Select All [Operation Name] Results" if the bundle was created by a batch operation. This selects all bundles sharing the same `batchOperationID`.

### 5.3 Filter Bar in Sidebar

Add a scope button to the existing `searchField` that filters sidebar items by operation type:

```
[Search...] [All v]
             All
             Demux Results
             Filtered
             Trimmed
             Custom...
```

When a filter is active, the sidebar collapses the hierarchy and shows only matching items as a flat list. This is equivalent to Finder's search mode, where the folder hierarchy disappears and results are flat.

The filtered view supports Cmd+A to select all visible items.

### 5.4 Keyboard Shortcuts Summary

| Shortcut | Action | Context |
|----------|--------|---------|
| Cmd+A | Select all visible items | When sidebar is focused and search filter is active |
| Cmd+Shift+A | Select all siblings | When a single item is selected that has siblings |
| Right Arrow | Expand selected node | Standard NSOutlineView behavior |
| Left Arrow | Collapse selected node | Standard NSOutlineView behavior |
| Option+Right Arrow | Expand node and all descendants | Standard NSOutlineView behavior |
| Space | Quick Look preview of selected bundle | Standard macOS behavior |

---

## 6. Visual Design for Batch Groups

### 6.1 Badge on Parent Indicating Batch Operations Applied

When a parent FASTQ has had batch operations run on its demux children, show a small stacked-badge indicator on the parent item:

```
  sample.fastq.gz  [3 ops]
```

The badge is a rounded pill showing the count of distinct batch operations applied. Clicking the badge is equivalent to expanding the batch groups section.

### 6.2 Virtual Group Node Appearance

The virtual batch group node should be visually distinct from filesystem items:

- **Icon:** The operation's SF Symbol (ruler, scissors, bandage, etc.) in the operation's semantic color
- **Title:** Operation name + count in parentheses: "Filtered (96 barcodes)"
- **Font:** Same as other sidebar items, but the title uses `.secondaryLabelColor` to signal it is virtual
- **Disclosure triangle:** Present, showing the member items when expanded
- **Background:** No special background — it sits in the sidebar like any other item

### 6.3 Member Items Within Virtual Group

When the virtual group is expanded, each member item shows:

```
  [ruler] Filtered (96 barcodes)
    barcode01-filtered              23.4K reads  Q34.2
    barcode02-filtered              18.1K reads  Q31.8
    ...
```

The subtitle shows key metrics (read count, mean quality) for at-a-glance comparison without opening the Batch Comparison Table.

### 6.4 Collapse Behavior for Deep Hierarchies

With 96 barcodes, even the flat virtual group list is long. Recommendations:

- **Default state:** Virtual group is collapsed (showing only the group node with count)
- **Expand behavior:** Shows all 96 members
- **Scroll optimization:** NSOutlineView already handles large child counts efficiently
- **Search within group:** The sidebar search field filters within expanded groups

---

## 7. Handling the "96 Barcodes Visible" Problem

Even with virtual groups solving the selection problem, users still face a sidebar with 96+ items when they expand the parent FASTQ. This needs visual management:

### 7.1 Collapsed Barcode Summary Row

When the parent FASTQ is collapsed, show a summary subtitle:

```
  sample.fastq.gz
    96 barcodes (12.4M total reads)         [summary row, not expandable]
```

This summary row is a synthetic child that appears only when the barcodes are collapsed. Expanding the parent replaces it with the actual 96 barcode items.

### 7.2 Grouped Collapse

If barcodes have been grouped (e.g., by plate quadrant, by sample type via metadata), the sidebar can show grouped sections:

```
  sample.fastq.gz
    Plate Row A (12 barcodes)
      barcode01
      ...
    Plate Row B (12 barcodes)
    ...
```

This requires sample metadata (which the "Import Sample Metadata" context menu action already supports). Grouping is optional and metadata-driven.

### 7.3 Sidebar Width Auto-Adjustment

The existing `maxLabelWidth(in:depth:)` method calculates optimal sidebar width. With deep nesting (barcode -> filtered -> trimmed), labels get truncated. The sidebar should:

- Cap indentation depth at 3 levels visually (even if the tree is deeper)
- Use abbreviated labels for deeply nested items: "bc01-filt-trim" instead of "barcode01-filtered-trimmed"
- Tooltip on hover shows the full name and lineage

---

## 8. Integration with Existing Batch Processing Engine

The `BatchProcessingEngine` (from `batch-processing-recipe-system.md`) already produces a `BatchManifest` with `batchID`, `barcodeLabels`, and `barcodeCount`. The `BatchComparisonManifest` contains `bundleRelativePath` for each step result.

The virtual batch group in the sidebar maps directly to a `BatchManifest`:

```swift
// When batch completes, create the sidebar group
let batchGroup = SidebarItem(
    title: "\(recipe.name) (\(manifest.barcodeCount) barcodes)",
    type: .batchGroup,
    icon: recipe.steps.last?.kind.sfSymbol ?? "rectangle.stack",
    children: [],  // populated lazily from comparison manifest
    url: batchDir,
    subtitle: nil
)
batchGroup.batchOperationID = manifest.batchID
```

On sidebar reload, scan for `batch.manifest.json` files and reconstruct the virtual groups. This is equivalent to how `collectDemuxChildBundles` currently scans for demux children.

---

## 9. Addressing the Developer's Preference (Option B)

The developer prefers Option B (nested under each parent). This recommendation preserves Option B completely:

- **Filesystem layout:** Unchanged. Each barcode's results nest under that barcode's directory.
- **Data model:** Unchanged. `parentBundleRelativePath` links child to parent.
- **Inspector provenance:** Unchanged. The lineage timeline works because the tree is intact.

What changes is the **sidebar presentation layer only**. The virtual batch group is a view-level concept that aggregates cross-branch items. It does not alter the filesystem or the data model. It is a computed sidebar node, not a stored entity.

The `batch.manifest.json` file (already specified in the batch processing design) provides the data needed to reconstruct these virtual groups. No new storage format is needed.

---

## 10. Implementation Priority

| Priority | Component | Effort | Depends On |
|----------|-----------|--------|------------|
| **P0** | `SidebarItemType.batchGroup` + virtual node creation on batch completion | Low | BatchProcessingEngine |
| **P0** | "Select All Siblings" (Cmd+Shift+A) | Low | None |
| **P1** | Virtual group expansion showing member items with metrics | Medium | BatchComparisonManifest |
| **P1** | Context menu "Run Operation on All..." for batch groups | Medium | Operation sheet system |
| **P1** | Sidebar search filter by operation type | Medium | Existing search infrastructure |
| **P2** | Collapsed barcode summary row | Low | None |
| **P2** | Badge on parent showing operation count | Low | None |
| **P3** | Grouped collapse by sample metadata | High | Sample metadata import |
| **P3** | Indentation depth capping and label abbreviation | Low | None |

---

## 11. Validation Plan

### Usability Test Protocol

**Task:** "You have demultiplexed a FASTQ file into 24 barcodes. Now filter all of them by read length (min 200bp), then quality trim all the filtered results."

**Success metrics:**
- Task completion time < 60 seconds (including both operations)
- Error rate: 0 incorrect selections (user selects the wrong set of files)
- Satisfaction: user rates the workflow 4+ on 5-point ease scale

**Comparison conditions:**
- Condition A: Current design (manual multi-select across 24 expanded tree branches)
- Condition B: Virtual batch groups (select the group node, run operation)

**Expected outcome:** Condition B should reduce task time by 80%+ and eliminate selection errors entirely, because the user never needs to manually construct a 24-item selection.

### Analytics Integration

Track these events:
- `batch_group_selected` — user clicked a virtual batch group
- `batch_group_operation_run` — user ran an operation from a batch group context
- `manual_multiselect_count` — how many items users manually Cmd+click select (should decrease)
- `select_siblings_used` — Cmd+Shift+A usage frequency

---

## 12. Summary

The fundamental insight is: **separate the data model (tree) from the selection model (flat group)**. Keep Option B for provenance and structural correctness. Add virtual batch groups as the selection surface for cross-barcode operations. This follows the established pattern from Finder Smart Folders, Photos Smart Albums, and Galaxy history tags.

The virtual batch group is:
- Cheap to implement (it is a sidebar node backed by an existing batch manifest)
- Zero risk to the data model (it is read-only, computed, and deletable without data loss)
- Immediately useful for the primary workflow (demux -> filter -> trim -> orient)
- Consistent with macOS conventions (Smart Folders, Smart Albums, Smart Mailboxes)
