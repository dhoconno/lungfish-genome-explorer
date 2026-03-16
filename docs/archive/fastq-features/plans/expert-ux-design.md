# Lungfish Genome Browser -- Expert UX Design Plan
# Sidebar Organization, Virtual FASTQs, Materialization, and Batch Operations

**Date:** 2026-03-14
**Status:** Comprehensive Design Specification
**Scope:** End-to-end UX for FASTQ project organization, virtual file hierarchy, materialization, reference management, and batch workflows
**Integrates:** batch-selection-sidebar-research.md, drawer-architecture-recommendation.md, fastq-operations-ux-plan.md, batch-processing-recipe-system.md, virtual-sequence-system-plan.md

---

## 1. Design Principles

Before any specific recommendation, the following principles govern every decision in this document. They are drawn from competitive analysis of Geneious Prime, Galaxy, CLC Genomics Workbench, and macOS system applications (Finder, Photos, Mail), filtered through the constraints of Lungfish's existing NSOutlineView sidebar + viewer architecture.

1. **The tree is the truth; flat views are lenses.** The sidebar hierarchy reflects real data provenance (parent -> child lineage). Virtual groups, batch groups, and smart filters are computed overlays that never alter the underlying structure. Deleting a virtual group never deletes data.

2. **Selection and navigation are separate concerns.** The tree handles navigation (find a specific file, understand lineage). Flat views handle selection (pick 96 barcodes for a batch operation). Forcing users to navigate a deep tree to construct a multi-selection is a usability failure.

3. **Virtual is the default; materialized is the exception.** Most pipeline outputs never need to be written as full FASTQ files. Virtual bundles (pointer + trim positions + read IDs) are the normal state. Materialization is an explicit export action, not an automatic consequence of running an operation.

4. **Show status, not mechanics.** Users care about "is this file ready for downstream tools?" and "what was done to this file?", not about whether a file is stored as a JSON manifest pointing at a parent or as a full FASTQ on disk. Status indicators answer user questions; implementation details stay hidden.

5. **Batch is a first-class concept.** A batch of 96 barcodes through a 3-step pipeline is not 288 individual operations. It is one batch run that produces one comparison table. The sidebar, progress display, and result presentation must reflect this.

6. **References are project infrastructure, not data files.** Reference sequences (genomes, barcode kits, primer sets, contaminant databases) serve operations. They should be organized separately from experimental data, easily selectable from operation configuration panels, and shareable across projects.

---

## 2. Sidebar Organization

### 2.1 Top-Level Structure

The sidebar shows the project as a tree with the following top-level structure:

```
Project Name
  References                          [special folder, pinned at top]
    Macaca mulatta (GCF_003339765.1)  [reference genome bundle]
    PhiX Spike-In                     [contaminant reference]
    SQK-NBD114.96 Barcodes            [barcode kit reference]
  Data                                [contains all experimental FASTQ files]
    sample-001.fastq.gz               [root FASTQ]
      barcode01                       [demux child - virtual]
        barcode01-filtered            [operation result - virtual]
      barcode02                       [demux child - virtual]
      ...
      barcode96                       [demux child - virtual]
    sample-002.fastq.gz               [another root FASTQ]
  Batch Results                       [auto-created when first batch completes]
    Filtered (96 barcodes)            [virtual batch group]
    Trimmed (96 barcodes)             [virtual batch group]
  Recipes                             [saved processing pipelines]
    Illumina WGS Standard             [built-in recipe]
    ONT Amplicon                      [built-in recipe]
    My Custom Pipeline                [user-created recipe]
```

### 2.2 The "References" Folder

**Purpose:** A dedicated, pinned top-level folder for all reference data used by operations. This follows Geneious's pattern where reference sequences live in a separate "Databases" or "References" area rather than mixed with experimental data.

**Behavior:**

- Always visible at the top of the sidebar, above Data. Cannot be dragged below Data.
- Contains `.lungfishref` bundles (reference genomes), barcode kit definitions, primer FASTA files, and contaminant reference databases.
- Items can be added by: (a) dragging files into the folder, (b) downloading from NCBI via the existing genome download pipeline, (c) importing from the barcode kit library.
- When an operation needs a reference (e.g., contaminant filter needs a reference genome, primer removal needs a primer FASTA), the operation configuration panel shows a dropdown populated from the References folder. This eliminates the file-picker-every-time pattern.
- The References folder is stored at `<project>/references/` on disk. Reference bundles are not duplicated -- they can be symlinked from the shared Application Support library.

**Visual design:**

- Folder icon: `folder.badge.gearshape` SF Symbol in `.systemIndigo` tint.
- Items inside use their standard bundle icons (`.lungfishref` uses the existing indigo genome icon; barcode kits use `barcode`; primer files use `doc.text`).
- The folder is always expanded by default. It collapses if the user explicitly collapses it, and this preference persists.

**Context menu for References folder:**

| Menu Item | Action |
|-----------|--------|
| Add Reference Genome... | Opens the NCBI genome download sheet |
| Import Reference File... | Opens a file picker (FASTA, barcode CSV, primer FASTA) |
| Add from Barcode Kit Library... | Opens the barcode kit browser |

**Context menu for items inside References:**

| Menu Item | Action |
|-----------|--------|
| Open in Viewer | Opens the reference genome in the genome viewer |
| Get Info | Shows reference metadata in the Inspector |
| Remove from Project | Removes the reference from this project (does not delete from disk) |
| Show in Finder | Reveals the file in Finder |

### 2.3 Parent FASTQ -> Virtual Children Hierarchy

The sidebar hierarchy preserves the true data lineage. Each operation on a FASTQ produces a virtual child that nests under its input. This is Option B from the batch-selection-sidebar-research.md, chosen because it preserves provenance, supports per-barcode re-processing, and makes the tree itself a visual pipeline history.

**Hierarchy example (single FASTQ, serial operations):**

```
sample-001.fastq.gz                     [root - real file on disk]
  qtrim-Q20                             [virtual - trim positions file]
    adapter-trim                        [virtual - derived from qtrim output]
```

**Hierarchy example (demultiplexed, then batch processed):**

```
sample-001.fastq.gz                     [root]
  barcode01                             [virtual - demux read IDs + trims]
    barcode01-filtered                  [virtual - length filter on barcode01]
  barcode02                             [virtual]
    barcode02-filtered                  [virtual]
  ...
  barcode96                             [virtual]
    barcode96-filtered                  [virtual]
```

**Collapsed state management:**

When a parent FASTQ has more than 12 children (common after demux), the sidebar shows a summary row when collapsed:

```
sample-001.fastq.gz
  96 barcodes (12.4M total reads)       [synthetic summary row]
```

Expanding the parent replaces the summary row with the actual 96 barcode items. The summary row is not selectable for operations -- it is purely informational.

### 2.4 Visual Indicators for Virtual vs. Materialized Status

Every derived bundle in the sidebar shows its status through icon treatment, not through separate columns or badges. This keeps the sidebar narrow and avoids Geneious's problem of needing wide document tables for metadata columns.

**Icon treatment by status:**

| Status | Icon Treatment | Meaning |
|--------|---------------|---------|
| Virtual (default) | Operation SF Symbol in semantic color, standard opacity | Pointer-based derivative; data computed on demand from parent |
| Materialized | Same icon with a small filled circle badge (bottom-right) | Full FASTQ written to disk; ready for external tools |
| Materializing | Same icon with a spinning progress indicator replacing the badge | Export in progress |
| Stale | Same icon with a yellow warning triangle badge | Parent data has changed since this derivative was created |
| Error | Same icon with a red exclamation badge | Derivative creation or materialization failed |

**Additional visual cues:**

- Virtual items use `.secondaryLabelColor` for their title text, subtly distinguishing them from root FASTQ files which use `.labelColor`.
- Materialized items use `.labelColor` for their title text, signaling they are "full citizens" on disk.
- The subtitle line (below the title) shows key metrics: read count and mean quality in `.caption` `.tertiaryLabelColor`. Example: "23.4K reads  Q34.2".

### 2.5 Demultiplexed Group Appearance

Demultiplexed children appear nested under the parent FASTQ (not in a separate folder). This preserves the lineage relationship and is consistent with how other derived files appear.

**Why not a separate "Demux Results" folder:** A separate folder would break the visual lineage chain. The user would see `sample-001.fastq.gz` in Data and `barcode01` in a different folder, with no visual connection between them. The tree hierarchy IS the provenance display.

**Grouping within demux children:**

When sample metadata has been imported (via the existing "Import Sample Metadata" context menu), barcodes can be grouped by metadata fields:

```
sample-001.fastq.gz
  Group A (12 barcodes)
    barcode01 - Subject M001
    barcode02 - Subject M002
    ...
  Group B (12 barcodes)
    barcode13 - Subject M013
    ...
  Unassigned (72 barcodes)
    barcode25
    ...
```

Grouping is optional, toggled via the context menu on the parent FASTQ: "Group Barcodes By..." > Subject ID / Treatment Group / Plate Row / None. The default is no grouping (flat list of barcodes under the parent).

### 2.6 Virtual Batch Group Nodes

When a batch operation completes across multiple barcodes, the system creates a virtual batch group node. This is the critical mechanism that separates navigation (tree) from selection (flat group), following the pattern from Finder Smart Folders, Photos Smart Albums, and Galaxy history tags.

**Placement:** Batch group nodes appear under a top-level "Batch Results" section in the sidebar. This section is auto-created when the first batch completes and auto-hidden when all batch groups are deleted.

```
Batch Results
  [ruler] Filtered (96 barcodes)        [virtual batch group]
  [scissors] Trimmed (96 barcodes)      [virtual batch group]
```

**Interaction model:**

- **Single click on group node:** The content area shows the Batch Comparison Table (cross-barcode metrics table from batch-processing-recipe-system.md Section 7). The Inspector shows batch-level summary statistics.
- **Expand group node:** Shows the 96 member items as a flat list. Each member shows its title and key metrics. Standard Cmd+click and Shift+click selection work for cherry-picking subsets.
- **Double-click on group node:** Same as single click (no special action -- the comparison table IS the primary view for a batch group).

**Relationship to tree hierarchy:** The batch group is a lens. The actual data for `barcode01-filtered` still lives nested under `barcode01` in the tree. The batch group references these items by URL. Selecting `barcode01-filtered` inside the batch group and selecting it inside the tree hierarchy navigate to the same bundle.

### 2.7 Context Menus

Context menus are the primary affordance for operations in the sidebar. They are context-sensitive based on the item type and selection count.

**Right-click on a root FASTQ:**

| Menu Item | Keyboard Shortcut | Action |
|-----------|-------------------|--------|
| Open | Return | Opens the FASTQ in the viewer |
| Run Operation... | Cmd+Shift+O | Opens the operations panel with this file as input |
| Demultiplex... | -- | Opens demux configuration in the drawer |
| Apply Recipe... | -- | Shows recipe picker submenu |
| --- | | |
| Export as FASTQ... | -- | File save panel for the raw FASTQ |
| Import Sample Metadata... | -- | CSV/TSV import for barcode sample assignments |
| --- | | |
| Show Package Contents | -- | Opens the .lungfishfastq bundle in Finder |
| Get Info | Cmd+I | Shows file metadata in the Inspector |
| Move to Trash | Cmd+Backspace | Moves the bundle to Trash |

**Right-click on a virtual derivative:**

| Menu Item | Keyboard Shortcut | Action |
|-----------|-------------------|--------|
| Open | Return | Opens the virtual dataset in the viewer |
| Run Operation... | Cmd+Shift+O | Opens operations with this as input (chaining) |
| --- | | |
| Materialize... | -- | Writes full FASTQ to disk (see Section 4) |
| Export as FASTQ... | -- | Materialize + save to user-chosen location |
| --- | | |
| Compare with Parent | -- | Opens comparison view |
| Reveal Parent in Sidebar | -- | Selects and scrolls to the parent item |
| --- | | |
| Get Info | Cmd+I | Shows metadata + provenance in Inspector |
| Delete | Cmd+Backspace | Deletes the virtual derivative |

**Right-click on a virtual batch group:**

| Menu Item | Action |
|-----------|--------|
| Run Operation on All... | Opens operation panel with all members as input |
| Apply Recipe to All... | Shows recipe picker |
| Select All Members | Selects all members in the outline view |
| --- | |
| Materialize All... | Batch materialization (see Section 4) |
| Export All as FASTQ... | Batch export to folder |
| --- | |
| Reveal in Hierarchy | Expands parent tree, highlights nested locations |
| Rename Group... | Edit the group's display name |
| Remove Group | Deletes the virtual group node (not the data) |

**Right-click with multiple items selected:**

| Menu Item | Action |
|-----------|--------|
| Run Operation on Selection... | Opens operation panel with selection as input |
| Apply Recipe... | Shows recipe picker |
| --- | |
| Materialize Selected... | Batch materialization |
| Export Selected as FASTQ... | Batch export |
| --- | |
| Create Group from Selection | Creates a new virtual batch group from selection |
| Select All Siblings | Selects all items at the same tree level (Cmd+Shift+A) |

---

## 3. Operation Flow

### 3.1 Discovering and Launching Operations

Users discover operations through three surfaces, each optimized for a different workflow:

**Surface 1: Context Menu (quick access)**
Right-click any FASTQ item > "Run Operation..." opens the operations panel. For the most common operations (Demultiplex, Quality Trim), dedicated top-level context menu items provide one-click access without navigating an operations list.

**Surface 2: Operations Sidebar within FASTQDatasetViewController**
When viewing a FASTQ file, the left edge of the content area shows a categorized operations list (180pt fixed width, source list style). This is the existing design from fastq-unified-design.md. Categories: Sampling, Filtering, Trimming, Search, Paired-End, Correction, Demultiplexing. Clicking an operation populates the parameter bar and (for Tier 3 operations) opens the configuration drawer.

**Surface 3: Inspector Selection Tab**
The Inspector's Selection tab shows the same categorized operations list. This is useful when the operations sidebar in the content area is collapsed or when the user is inspecting metadata and wants to quickly launch an operation. Clicking an operation here has the same effect as clicking it in the operations sidebar.

**The tiered hybrid model determines the configuration surface:**

| Tier | Param Count | Config Surface | Examples |
|------|------------|----------------|----------|
| Tier 1 | 0-3 | Parameter bar only | Quality trim, subsample, length filter, dedup |
| Tier 2 | 4-8 | Parameter bar (essentials) + drawer (advanced) | Adapter removal, primer removal, contaminant filter |
| Tier 3 | Complex | Bottom drawer (full config) | Demultiplex, assembly, read mapping |

### 3.2 Selecting Reference Sequences for Operations

Several operations require a reference sequence: contaminant filtering needs a contaminant genome, primer removal needs a primer FASTA, read mapping needs a reference genome, demultiplexing needs a barcode kit.

**Current problem:** Each operation that needs a reference forces the user to navigate a file picker dialog every time, even if they use the same reference for every run.

**Solution: References folder integration.**

When an operation's configuration panel includes a reference selection control (NSPopUpButton or file picker), it is pre-populated with items from the project's References folder:

```
+-------------------------------------------+
|  Reference:   [Macaca mulatta (GCF...) v] |
|                Macaca mulatta (GCF...)     |
|                PhiX Spike-In              |
|                ----                       |
|                Browse...                  |
|                Download from NCBI...      |
+-------------------------------------------+
```

The dropdown lists all References folder items of the appropriate type (genome references for mapping, contaminant references for filtering, barcode kits for demux). A separator and "Browse..." / "Download from NCBI..." items at the bottom provide escape hatches for references not yet in the project.

When the user selects "Browse..." and picks a file, a dialog asks: "Add to project References folder?" with Yes/No. If Yes, the file is copied (or symlinked) into the References folder for future use.

**Default reference memory:** The last-used reference for each operation type is remembered per-project in the project settings. When the user opens "Contaminant Filter" configuration, the reference dropdown defaults to whatever they used last time.

### 3.3 Batch Selection

Batch selection is the critical interaction for the demux -> filter -> trim -> orient workflow where users need to apply the same operation to 20-96 barcode children.

**Primary mechanism: Virtual batch groups (Section 2.6)**

Select a batch group node in the sidebar, then choose "Run Operation on All..." from the context menu or the operations panel. The operation runs on every member of the group. When the operation completes, a new batch group appears with the results.

**Secondary mechanism: Select All Siblings (Cmd+Shift+A)**

When one barcode child is selected, Cmd+Shift+A selects all siblings at the same tree level. This is useful for the first batch operation (before any batch groups exist) and for ad hoc selections.

**Tertiary mechanism: Sidebar search filter**

The search field gains scope buttons for filtering by operation type:

```
[Search...] [All v]
             All
             Demux Results
             Filtered
             Trimmed
             Custom...
```

When a filter is active, the sidebar collapses the hierarchy and shows only matching items as a flat list. Cmd+A selects all visible items. This is equivalent to Finder's search mode.

**Selection validation:** Before running a batch operation, the system validates that all selected items are compatible inputs (same format, same pairing mode). If validation fails, a non-modal alert explains which items are incompatible and offers to exclude them.

### 3.4 Progress Indication

Progress display follows the tiered model and scales from single operations to 96-barcode batch runs.

**Single operation progress:**

- Compact spinner + status label in the run bar (existing pattern).
- Determinate progress bar when the operation reports percentage (most do).
- Status text shows the current phase: "Quality trimming... 45% (5.6M / 12.4M reads)".
- Cancel button adjacent to the progress indicator.

**Batch operation progress:**

The content area switches to the Batch Progress Grid (from batch-processing-recipe-system.md Section 7):

```
| Barcode | Step 1: Q Trim  | Step 2: Filter  | Step 3: Orient  |
|---------|-----------------|-----------------|-----------------|
| BC01    | [=======] Done  | [===   ] 42%    | [     ] Pending |
| BC02    | [=======] Done  | [     ] Pending | [     ] Pending |
| BC03    | [=====  ] 68%   | [     ] Pending | [     ] Pending |
| ...     |                 |                 |                 |
```

Each cell is a mini progress indicator with color-coded status:
- Pending: gray background
- Running: system blue progress bar + percentage
- Completed: green checkmark + key metric (e.g., "98.4% retained")
- Failed: red X + error message on hover
- Cancelled: gray X

**Background operation support:** For long-running operations (assembly, large batch runs), a "Send to Background" button minimizes the progress grid but keeps a progress pill in the toolbar area:

```
[Filtering 96 barcodes... 34%  [x]]
```

The user can click the pill to return to the full progress grid, or click X to cancel.

### 3.5 Operation History and Provenance

Every operation is recorded in the derivative manifest's lineage array. Users access provenance through two surfaces:

**Surface 1: Inspector Provenance Timeline**

When a derived file is selected, the Inspector's Document tab shows a vertical timeline (from fastq-inspector-ia.md Section 1.3):

```
[1]  Root FASTQ
      sample-001.fastq.gz

[2]  Demultiplex (SQK-NBD114.96)
      cutadapt 4.6

[3]  Quality Trim Q20 w4            <-- current, highlighted
      fastp 0.23.4
```

Each step is clickable, navigating to that ancestor in the sidebar. The current (last) step is highlighted with accent color.

**Surface 2: Batch Comparison Table**

When a batch group is selected, the comparison table shows per-step metrics across all barcodes. Column headers are the pipeline steps. Users can see at a glance which barcodes had unusual retention rates, quality changes, or failures.

**Command reproducibility:** The Inspector shows the exact command line used for each operation, with a Copy button. For batch operations, the comparison manifest records the recipe definition so the entire pipeline can be re-run.

---

## 4. Materialization UX

### 4.1 What Materialization Means

Virtual derivatives are pointer-based: they store read IDs, trim positions, and orient maps that reference the root FASTQ. They are compact (KBs instead of GBs) and sufficient for all in-app operations (viewing, statistics, further processing).

Materialization writes the actual FASTQ file to disk -- extracting reads from the root, applying trims, and writing the result. This is needed when:

- The user wants to use the file in an external tool (command-line BLAST, Galaxy upload, SRA submission)
- The user wants to share the file with a collaborator
- The user wants to archive a specific pipeline output

### 4.2 Triggering Materialization

**Single file materialization:**

Right-click a virtual derivative > "Materialize..." opens a confirmation dialog:

```
+-------------------------------------------------------+
|  Materialize "barcode01-filtered"?                     |
|                                                        |
|  This will write the full FASTQ file to disk.          |
|  Estimated size: 156 MB (23,412 reads)                 |
|  Source: sample-001.fastq.gz                           |
|                                                        |
|  Output location:                                      |
|  [x] Inside bundle (alongside virtual data)            |
|  [ ] Export to folder...                               |
|                                                        |
|  [Cancel]                        [Materialize]         |
+-------------------------------------------------------+
```

The default output location is inside the `.lungfishfastq` bundle in a `materialized/` subdirectory. This keeps the file associated with its metadata. The "Export to folder..." option opens a save panel for placing the file elsewhere.

**Batch materialization:**

Right-click a batch group > "Materialize All..." opens a similar dialog with aggregate sizing:

```
+-------------------------------------------------------+
|  Materialize 96 files in "Filtered"?                   |
|                                                        |
|  Estimated total size: 14.2 GB                         |
|  Estimated time: ~8 minutes                            |
|                                                        |
|  Output location:                                      |
|  [x] Inside each bundle                               |
|  [ ] Export all to folder...                           |
|                                                        |
|  [Cancel]                     [Materialize All]        |
+-------------------------------------------------------+
```

**Quick export (combined materialize + save):**

Right-click > "Export as FASTQ..." combines materialization with a save panel. The file is materialized to a temp location, then moved to the user's chosen destination. This is the "I just want the file" shortcut.

### 4.3 Progress Feedback During Materialization

Single file materialization shows progress in the toolbar area as a progress pill:

```
[Materializing barcode01-filtered... 67%  [x]]
```

Batch materialization shows the same batch progress grid used for operations, with one column ("Materializing") and rows for each file.

The user can continue working while materialization runs in the background. The sidebar icon updates from the standard operation icon to the spinning progress indicator, then to the materialized badge (filled circle) when complete.

### 4.4 Where Materialized Files Appear

Materialized files do NOT create new sidebar entries. The existing virtual derivative item simply updates its status indicator from "virtual" (no badge) to "materialized" (filled circle badge). The file's location on disk changes (a `materialized/output.fastq.gz` file now exists inside the bundle), but the sidebar representation is unchanged.

This avoids the duplication problem where materialization would create a confusing second entry for the same logical dataset.

**Accessing the materialized file:**

- Right-click > "Show in Finder" reveals the `.lungfishfastq` bundle. Inside it, the `materialized/` directory contains the actual FASTQ.
- Right-click > "Copy File Path" copies the path to the materialized FASTQ file (not the bundle path). This is the path users paste into terminal commands.
- Drag the sidebar item to Finder or Terminal: drags the materialized FASTQ file (not the bundle directory).

### 4.5 Indicating "Ready for Downstream"

The materialized badge (filled circle at bottom-right of the icon) is the primary indicator. Additionally:

- The Inspector shows a "Materialized" status line with the file size and path.
- The subtitle in the sidebar changes from "23.4K reads  Q34.2" to "23.4K reads  Q34.2  156 MB" -- adding the file size confirms the file exists on disk.
- Hovering the sidebar item shows a tooltip: "Materialized FASTQ: /path/to/materialized/output.fastq.gz"

**Staleness detection:** If the root FASTQ is modified after materialization (rare but possible), the badge changes to a yellow warning triangle. The tooltip explains: "Source data has changed since materialization. Re-materialize to update." Right-click offers "Re-materialize..." to refresh the output.

---

## 5. Geneious Adaptation

### 5.1 What Geneious Does Well

Geneious Prime's core UX patterns that are relevant to Lungfish:

1. **Document table with metadata columns:** Geneious shows files in a flat table with sortable columns (Name, Type, Sequence Count, Modified Date, Description). Users sort and filter to find files. Batch selection is trivial: sort by type, Shift+click to select a range.

2. **Folder tree for organization, table for selection:** The left sidebar is a folder tree. The right pane is a document table showing the contents of the selected folder. This separation means the tree handles navigation and the table handles selection.

3. **Operations in a sidebar panel:** Geneious has a left-side "Operations" panel (or the "Annotate & Predict" toolbar section) where operations are listed by category. Selecting files in the table, then clicking an operation, opens a configuration dialog.

4. **Result naming conventions:** Geneious automatically names results with operation suffixes: "sample_trimmed", "sample_trimmed_mapped". This creates a readable flat namespace.

5. **Sequence View and Text View:** Multiple view modes for the same data. The viewer adapts to the content type.

### 5.2 How Lungfish Adapts These Patterns

Lungfish uses an NSOutlineView sidebar instead of Geneious's folder tree + document table architecture. This is a deliberate design choice: the outline view handles both navigation AND hierarchy display in a single pane, which is more space-efficient for the common case (small projects with clear lineage). The tradeoff is that batch selection in a tree is harder than in a flat table.

**Adaptation strategy:**

| Geneious Pattern | Lungfish Adaptation |
|------------------|---------------------|
| Document table with columns | The sidebar subtitle line shows key metrics (read count, quality). The Inspector Document tab shows full metadata. No separate document table is needed because the sidebar IS the document list. |
| Flat table for batch selection | Virtual batch group nodes provide flat selection surfaces within the tree. The sidebar search filter provides a global flat view. |
| Folder tree for organization | The sidebar tree handles organization through the References/Data/Batch Results top-level structure. |
| Operations sidebar panel | The operations sidebar within FASTQDatasetViewController (180pt, source list style) serves the same purpose. |
| Result naming | Derivatives use `shortLabel` from the operation (e.g., "qtrim-Q20", "adapter-trim"). These compose: "barcode01-filtered-trimmed". |
| Sequence View / Text View | The viewer content area adapts: genome viewer for references, FASTQ dashboard for reads, comparison view for before/after. Tab-based view switching within the content area. |

### 5.3 Geneious "Annotate & Predict" -> Lungfish Operation Categories

Geneious groups tools into "Annotate & Predict", "Align/Assemble", "Tools", etc. Lungfish uses a simpler categorization tuned to FASTQ workflows:

| Category | SF Symbol | Operations |
|----------|-----------|------------|
| Quality | `chart.bar` | Quality Trim, Quality Report |
| Sampling | `dice` | Subsample by Proportion, Subsample by Count |
| Filtering | `line.3.horizontal.decrease` | Length Filter, Contaminant Filter, Deduplication |
| Trimming | `scissors` | Adapter Removal, Fixed Trim, Primer Removal |
| Search | `magnifyingglass` | Find by ID, Find by Motif |
| Paired-End | `arrow.triangle.merge` | Merge Pairs, Repair Pairs, Interleave |
| Correction | `checkmark.circle` | Error Correction |
| Demultiplexing | `rectangle.split.3x1` | Demultiplex (Barcodes) |
| Assembly | `cube` | SPAdes Assembly (future) |
| Mapping | `arrow.right.doc.on.clipboard` | Read Mapping (future) |

### 5.4 The Inspector as Geneious's "Document Table" Replacement

Since Lungfish does not have a separate document table pane, the Inspector serves as the metadata display surface. When a file is selected in the sidebar:

- **Document tab:** File summary, provenance timeline, quality metrics, base composition. This replaces Geneious's document table columns.
- **Selection tab:** Available operations, quality overlay toggle. This replaces Geneious's toolbar operation buttons.
- **AI tab:** Natural language query interface for the selected data.

The Inspector is always visible (unless explicitly collapsed). It provides the "at a glance" metadata that Geneious puts in table columns, without requiring a separate table view.

### 5.5 Adapting Geneious's "Sequence View" for FASTQ

Geneious shows individual sequences in a "Sequence View" (linear sequence visualization with annotations) and a "Text View" (raw FASTA/FASTQ text).

Lungfish adapts this for FASTQ reads through the virtual sequence annotation system (from virtual-sequence-system-plan.md Part 4):

- When a user opens a virtual bundle and selects a read in the reads table, the viewer shows the read's full sequence as a mini "chromosome" with annotations overlaid.
- Annotations come from the `read-annotations.tsv` sidecar: barcode positions, trim boundaries, primer sites, adapter locations.
- The Annotation Drawer shows these per-read annotations in the same table format used for genome annotations.
- This is directly analogous to Geneious's Sequence View but specialized for read-level data.

---

## 6. Keyboard Shortcuts

| Shortcut | Action | Context |
|----------|--------|---------|
| Return | Open selected item in viewer | Sidebar focused, single selection |
| Cmd+Shift+O | Open operations panel | Any FASTQ selected |
| Cmd+Shift+A | Select all siblings | Single item selected in sidebar |
| Cmd+A | Select all visible items | Sidebar focused, search filter active |
| Cmd+I | Get Info (show in Inspector) | Any sidebar selection |
| Cmd+Backspace | Delete / Move to Trash | Any sidebar selection |
| Cmd+E | Export as FASTQ... | Virtual derivative selected |
| Space | Quick Look preview | Any sidebar selection |
| Right Arrow | Expand selected node | Standard NSOutlineView |
| Left Arrow | Collapse selected node | Standard NSOutlineView |
| Option+Right Arrow | Expand all descendants | Standard NSOutlineView |
| Escape | Cancel current operation / close drawer | Operation running or drawer open |

---

## 7. Implementation Priority

### Phase 1: Foundation (immediate)

| Component | Effort | Files Affected |
|-----------|--------|----------------|
| Add `SidebarItemType.virtualFastq` for visual distinction | Low | SidebarViewController.swift |
| Virtual/materialized icon badge rendering in sidebar cell | Low | SidebarViewController.swift (cell configuration) |
| "Materialize..." context menu item + confirmation dialog | Medium | SidebarViewController.swift, FASTQDerivativeService.swift |
| "Select All Siblings" (Cmd+Shift+A) | Low | SidebarViewController.swift |
| References folder creation and display | Medium | SidebarViewController.swift |

### Phase 2: Batch Operations (short-term)

| Component | Effort | Files Affected |
|-----------|--------|----------------|
| Virtual batch group node creation on batch completion | Medium | SidebarViewController.swift, BatchProcessingEngine.swift |
| Batch group expansion showing member items with metrics | Medium | SidebarViewController.swift |
| Context menu "Run Operation on All..." for batch groups | Medium | SidebarViewController.swift, FASTQDatasetViewController.swift |
| Sidebar search filter by operation type | Medium | SidebarViewController.swift |
| Batch progress grid view | High | New: BatchProgressViewController.swift |

### Phase 3: Reference Integration (medium-term)

| Component | Effort | Files Affected |
|-----------|--------|----------------|
| References folder file management (add, remove, symlink) | Medium | SidebarViewController.swift |
| Operation reference dropdown populated from References folder | Medium | FASTQDatasetViewController.swift, operation config views |
| Default reference memory per-project | Low | Project settings |
| "Download from NCBI..." in reference dropdown | Low | Existing genome download pipeline integration |

### Phase 4: Polish (longer-term)

| Component | Effort | Files Affected |
|-----------|--------|----------------|
| Materialized file drag-to-Finder support | Medium | SidebarViewController.swift |
| Staleness detection for materialized files | Low | FASTQDerivativeService.swift |
| Collapsed barcode summary row with metrics | Low | SidebarViewController.swift |
| Grouped collapse by sample metadata | High | SidebarViewController.swift, sample metadata system |
| Batch materialization with progress grid | High | FASTQDerivativeService.swift, new UI |

---

## 8. Validation Plan

### 8.1 Usability Test Tasks

**Task 1: Basic Operation Chain**
"You have a FASTQ file. Quality trim it at Q20, then filter the result for reads longer than 200bp."

Success criteria:
- Task completion under 60 seconds
- User does not get confused about which file is the input for the second operation
- User understands the tree hierarchy shows the pipeline history

**Task 2: Batch Demux Workflow**
"You have demultiplexed a FASTQ file into 24 barcodes. Now quality trim all of them."

Success criteria:
- Task completion under 45 seconds (using batch group or Select All Siblings)
- Zero incorrect selections (user selects the right set of files)
- User does not manually Cmd+click 24 items

**Task 3: Materialization**
"You need to send the filtered version of barcode01 to a collaborator. Get the file."

Success criteria:
- User discovers "Materialize..." or "Export as FASTQ..." within 15 seconds
- User can locate the output file on disk
- User understands the difference between virtual and materialized

**Task 4: Reference Selection**
"Set up a contaminant filter using the PhiX reference that's already in your project."

Success criteria:
- User finds PhiX in the reference dropdown without opening a file picker
- Task completion under 20 seconds

### 8.2 Analytics Events

| Event | What It Measures |
|-------|-----------------|
| `sidebar_context_menu_opened` | How users discover operations |
| `batch_group_selected` | Adoption of batch group pattern |
| `batch_group_operation_run` | Batch group workflow completion |
| `select_siblings_used` | Cmd+Shift+A adoption |
| `materialize_triggered` | How often users need real files |
| `materialize_location_choice` | In-bundle vs export preference |
| `reference_dropdown_used` | References folder adoption |
| `reference_browse_fallback` | How often the dropdown is insufficient |
| `manual_multiselect_count` | Should decrease as batch groups are adopted |

---

## 9. Risk Mitigations

| Risk | Severity | Mitigation |
|------|----------|------------|
| 96 barcodes make the sidebar very long | High | Collapsed summary row; grouped collapse by metadata; virtual batch groups provide flat alternative |
| Users confuse virtual and materialized | Medium | Consistent icon badges; clear status in Inspector; tooltip on hover explains status |
| References folder feels redundant if project has few references | Low | Auto-hide References folder when empty; show "Add Reference..." placeholder |
| Deep nesting truncates labels | Medium | Cap visual indentation at 3 levels; abbreviate deeply nested labels; tooltip shows full name |
| Batch groups accumulate and clutter sidebar | Low | "Remove Group" context menu; auto-archive groups older than 30 days; collapsible Batch Results section |
| Materialization of large batches fills disk | Medium | Show estimated size before confirming; warn if disk space is low; support "Export to external drive" |
| Context menu gets too long | Medium | Group items with separators; hide advanced items behind "More..." submenu for power users |

---

## 10. Summary

This design unifies five previously separate specification documents into a coherent end-to-end UX for FASTQ project management in Lungfish. The core innovations are:

1. **References folder** -- a dedicated, always-visible project section for reference data that integrates directly with operation configuration dropdowns, eliminating repeated file picker interactions.

2. **Virtual batch groups** -- computed sidebar nodes that provide flat selection surfaces for cross-barcode batch operations, solving the fundamental tension between tree-based provenance display and flat-list batch selection.

3. **Materialization as explicit export** -- virtual derivatives are the default, with materialization as a deliberate action that adds a status badge rather than creating duplicate sidebar entries.

4. **Tiered operation configuration** -- simple operations use the parameter bar, complex operations use the bottom drawer, with the References folder feeding into both.

5. **Geneious-inspired organization adapted for NSOutlineView** -- the sidebar serves as both navigation tree and document list, with the Inspector replacing Geneious's metadata columns and the batch group replacing Geneious's flat table for selection.

The implementation is phased to deliver immediate value (virtual status indicators, Select All Siblings, basic materialization) while building toward the full vision (batch groups, reference integration, batch materialization) over subsequent sprints.
