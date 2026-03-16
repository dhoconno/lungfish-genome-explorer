# FASTQ/FASTA Workflow Architectural Redesign

## Status: Architectural Plan
## Date: 2026-03-14

---

## 1. Executive Summary

This document proposes a redesigned FASTQ/FASTA workflow architecture for Lungfish Genome Browser. The core idea is a **virtual filesystem** where operations on sequence data produce lightweight pointer-based "virtual" datasets that can later be **materialized** into real files for downstream consumption (mapping, assembly, export). The design covers module boundaries, on-disk layout, sidebar representation, batch dispatch, reference sequence management, and state tracking.

---

## 2. Module Boundary Analysis

### Current State

The existing architecture splits FASTQ concerns across three modules:

| Module | Current Responsibilities |
|---|---|
| **LungfishIO** | Data models: `FASTQDerivatives.swift` (operation kinds, payloads, manifests), `FASTQBundle.swift` (bundle helpers), `FASTQDemultiplexMetadata.swift`, `ProcessingRecipe.swift`, `FASTQBatchManifest.swift`, `ReferenceSequenceFolder.swift` |
| **LungfishWorkflow** | Tool execution: `DemultiplexingPipeline.swift` (cutadapt invocation), native tool runners |
| **LungfishApp** | Service + UI: `FASTQDerivativeService.swift` (orchestration), `BatchProcessingEngine.swift` (batch dispatch), `FASTQDatasetViewController.swift`, `FASTQMetadataDrawerView.swift`, `SidebarViewController.swift` |

### Proposed Boundary Refinement

The module split is sound but has two friction points that should be addressed:

**A. `FASTQDerivativeService` is too large and mixes concerns.**

`FASTQDerivativeService.swift` currently handles: (1) operation dispatch, (2) file I/O for creating bundles, (3) tool invocation via LungfishWorkflow, (4) statistics computation, and (5) materialization. This should be decomposed:

| New Component | Module | Responsibility |
|---|---|---|
| `VirtualDatasetFactory` | LungfishApp | Creates virtual manifests, writes pointer files. Pure data manipulation, no tool execution. |
| `MaterializationService` | LungfishApp | Converts virtual datasets to real FASTQ/FASTA files. Calls into LungfishWorkflow for tool execution. |
| `FASTQOperationDispatcher` | LungfishApp | Routes `FASTQDerivativeRequest` to the appropriate factory method or tool pipeline. Thin coordinator. |
| `FASTQStatisticsService` | LungfishApp | Computes and caches dataset statistics. Decoupled from operation creation. |

**B. `ProcessingRecipe` belongs in LungfishIO (correct placement).**

Recipes are serializable data that must be readable without AppKit. Current placement in LungfishIO is correct. The `BatchProcessingEngine` (LungfishApp) consumes recipes at execution time.

**C. `ReferenceSequenceFolder` is correctly in LungfishIO.**

The `ReferenceSequenceFolder` enum handles filesystem layout for reference sequences. It belongs in LungfishIO because it defines on-disk structure without UI concerns. The proposed reference discovery/selection UI belongs in LungfishApp.

### Dependency Direction (unchanged, reinforced)

```
LungfishApp  -->  LungfishWorkflow  -->  LungfishIO  -->  LungfishCore
     |                                       ^
     +---------------------------------------+
```

LungfishIO types flow upward as value types (structs/enums). LungfishApp orchestrates; LungfishWorkflow executes tools. No reverse dependencies.

---

## 3. Virtual-to-Materialized FASTQ Lifecycle

### 3.1 The Three States

Every FASTQ dataset in the project exists in one of three states:

```
                   create operation
  [Physical]  ----------------------->  [Virtual]
  (root FASTQ)                          (pointer + metadata)
                                             |
                                             | materialize
                                             v
                                        [Materialized]
                                        (full FASTQ on disk)
```

**Physical:** The original imported FASTQ file. Lives in a `.lungfishfastq` bundle with its `.fai` index and `.lungfish-meta.json` sidecar. This is the "root" of any derivation chain.

**Virtual:** A `.lungfishfastq` bundle containing only a `derived.manifest.json` (the existing `FASTQDerivedBundleManifest`) plus lightweight payload files (read ID lists, trim position TSVs, orient maps, preview FASTQs). No full FASTQ copy. The manifest's `rootBundleRelativePath` and `parentBundleRelativePath` encode the lineage.

**Materialized:** A virtual bundle that has been "realized" into a full FASTQ file on disk. The manifest gains a `materializedFASTQFilename` field. Once materialized, the bundle can serve as input to tools that require actual file paths (BWA, minimap2, assemblers).

### 3.2 Existing Implementation (Largely Correct)

The current `FASTQDerivativePayload` enum already models this well:

- `.subset(readIDListFilename:)` and `.trim(trimPositionFilename:)` are virtual payloads.
- `.full(fastqFilename:)`, `.fullPaired(...)`, `.fullMixed(...)` are materialized payloads.
- `.demuxedVirtual(...)` is a hybrid: virtual with a preview file.
- `.orientMap(...)` is virtual with a preview.

### 3.3 Proposed Changes to the Lifecycle Model

**A. Add explicit materialization state tracking to the manifest.**

```swift
// In FASTQDerivedBundleManifest (LungfishIO)
public struct FASTQDerivedBundleManifest: Codable, Sendable, Equatable {
    // ... existing fields ...

    /// When non-nil, this virtual bundle has been materialized to a full FASTQ.
    /// The filename is relative to this bundle directory.
    public var materializedFASTQFilename: String?

    /// Timestamp of materialization. Nil if not yet materialized.
    public var materializedAt: Date?

    /// Whether this bundle is currently being materialized (transient UI state,
    /// NOT persisted -- tracked by MaterializationService in-memory).
}
```

This avoids conflating "the operation that created this bundle" (always stored as the original payload type) with "whether a full file exists." A `.subset` bundle remains a `.subset` even after materialization -- the materialized file is an additional artifact.

**B. Materialization is on-demand, not automatic.**

Users explicitly request materialization via:
- Context menu: "Materialize FASTQ" on a virtual bundle in the sidebar
- Batch action: "Materialize All" on a demux group
- Implicit: when dragging a virtual bundle to an operation that requires a physical file (mapping, assembly export)

**C. Materialization pipeline.**

The `MaterializationService` reconstructs the full FASTQ by:
1. Reading the root bundle's physical FASTQ
2. Applying the lineage chain in order (subset filtering, trim application, orient RC)
3. Writing the result to `materialized.fastq.gz` inside the virtual bundle
4. Updating the manifest with `materializedFASTQFilename` and `materializedAt`

For `.demuxedVirtual` bundles, materialization uses seqkit to extract reads by ID list from the root FASTQ, then applies trim positions and orient maps.

**D. Materialized files are cache-like.**

A materialized file can be deleted to reclaim disk space. The virtual pointer data is the source of truth. Re-materialization regenerates the file. The UI should show materialization status with a visual indicator (filled vs hollow icon, or a small badge).

---

## 4. Reference Sequence Management Architecture

### 4.1 Current State

`ReferenceSequenceFolder` (LungfishIO) already implements:
- A "Reference Sequences" folder inside the `.lungfish` project directory
- `.lungfishref` bundles containing `manifest.json` + `sequence.fasta`
- Import, listing, and FASTA URL resolution

This is a solid foundation. The gaps are in discovery and UI integration.

### 4.2 Proposed Architecture

**A. Project-Level "References" Folder**

The existing `ReferenceSequenceFolder.folderName = "Reference Sequences"` is the right approach. This folder should be:
- Auto-created when the project is opened (if it doesn't exist)
- Shown as a top-level section in the sidebar (like "Downloads")
- Populated by: (1) user drag-and-drop of FASTA files, (2) explicit "Add Reference" action, (3) auto-import when a downloaded genome bundle's FASTA is used as a reference

**B. Reference Discovery Service (LungfishApp)**

```swift
/// Discovers all eligible reference sequences for operations requiring one.
@MainActor
public final class ReferenceDiscoveryService {

    /// All reference sources within the current project.
    /// Combines: Reference Sequences folder + genome bundle FASTAs + any FASTA in project.
    public func discoverReferences(in projectURL: URL) -> [ReferenceCandidate] {
        var candidates: [ReferenceCandidate] = []

        // 1. Explicit references from Reference Sequences folder
        let refs = ReferenceSequenceFolder.listReferences(in: projectURL)
        candidates += refs.map { .projectReference($0.url, $0.manifest) }

        // 2. Genome bundle FASTAs (from Downloads or anywhere in project)
        //    Scan for .lungfishref bundles outside Reference Sequences too
        candidates += scanBundleFASTAs(in: projectURL)

        // 3. Standalone FASTA files in project
        candidates += scanStandaloneFASTAs(in: projectURL)

        return candidates
    }
}
```

**C. Reference Selection UI Pattern**

When an operation requires a reference (orient, contaminant filter, primer removal with reference FASTA), the operation panel should:

1. Show a dropdown/popup listing all `ReferenceCandidate` items from `ReferenceDiscoveryService`
2. Group by source: "Project References" / "Genome Bundles" / "Project FASTA Files"
3. Include an "Import from File..." option at the bottom that triggers `ReferenceSequenceFolder.importReference`
4. Remember the last-used reference per operation type (stored in `UserDefaults` or project metadata)

**D. Reference Candidate Model (LungfishIO)**

```swift
/// A reference sequence available for selection in operations.
public enum ReferenceCandidate: Sendable, Identifiable {
    case projectReference(URL, ReferenceSequenceManifest)
    case genomeBundleFASTA(URL, String)  // bundle URL, display name
    case standaloneFASTA(URL)

    public var id: String { fastaURL.absoluteString }
    public var displayName: String { ... }
    public var fastaURL: URL { ... }
}
```

---

## 5. Sidebar Hierarchy Design

### 5.1 Current Sidebar Structure

```
MyProject.lungfish/
  Downloads/
    GCF_049350105.2.lungfishref
  sample-reads.lungfishfastq          <-- parent bundle
    bc01-demux.lungfishfastq           <-- demux child (from demux/ scan)
    bc02-demux.lungfishfastq
    [Batch: Illumina WGS Standard]     <-- batch group node
      bc01-qtrim-Q20.lungfishfastq
      bc02-qtrim-Q20.lungfishfastq
```

The sidebar currently builds FASTQ children by scanning `demux/` subdirectories of parent bundles (`collectDemuxChildBundles`). Batch group nodes are virtual `SidebarItem` nodes with `type: .batchGroup`.

### 5.2 Proposed Hierarchy (Geneious-Inspired)

Geneious organizes sequence data as a flat-ish tree where operations produce child documents nested under the parent. The key UX principle: **the user sees a derivation tree, not a filesystem tree.**

```
MyProject.lungfish/
  Reference Sequences/                 <-- top-level, always visible
    Human_GRCh38.lungfishref
    PhiX_Control.lungfishref
  Downloads/
    GCF_049350105.2.lungfishref
  sample-reads.lungfishfastq           <-- root FASTQ (physical)
    Quality Trim Q20                   <-- virtual child (trim payload)
      Adapter Trim (auto)              <-- chained virtual (trim of trim)
    Subsample 10%                      <-- virtual child (subset payload)
    Demultiplex (ONT Native)           <-- demux group node
      bc01                             <-- demuxed virtual
        Quality Trim Q20               <-- operation on demuxed barcode
      bc02
      bc03
      [Batch: Illumina WGS Standard]  <-- batch results group
        bc01 - Q.Trim > A.Trim > Merge
        bc02 - Q.Trim > A.Trim > Merge
```

### 5.3 Implementation Changes

**A. SidebarItemType additions:**

```swift
public enum SidebarItemType {
    // ... existing cases ...
    case virtualFastq      // Virtual FASTQ (pointer-based, not materialized)
    case materializedFastq // Virtual FASTQ that has been materialized
    case demuxGroup        // Container for demultiplexed barcode bundles
    case referenceFolder   // The "Reference Sequences" top-level folder
}
```

Alternatively, keep `.fastqBundle` and add a `materialized: Bool` property to `SidebarItem` to track status without multiplying enum cases.

**B. SidebarItem enrichment:**

```swift
public class SidebarItem: NSObject {
    // ... existing fields ...

    /// For FASTQ bundles: whether the underlying data is virtual (pointer) or materialized.
    public var isMaterialized: Bool = false

    /// For FASTQ bundles: the operation that created this derivative (for display).
    public var derivativeOperation: FASTQDerivativeOperation?

    /// For FASTQ bundles: cached read count for inline display.
    public var readCount: Int?
}
```

**C. Sidebar tree construction changes:**

The current `buildSidebarTree` scans `demux/` for child bundles. This should be generalized to scan for **all derivative children**, not just demux outputs:

1. Load the parent bundle's `derived.manifest.json` to identify its children
2. Scan for `.lungfishfastq` subdirectories at `{parent}/derivatives/` (proposed new location, see Section 7)
3. Recursively build child items with operation labels as titles (not filenames)
4. Mark each child's materialization status from its manifest

**D. Display names from operations, not filenames:**

Instead of showing `bc01-qtrim-Q20.lungfishfastq` in the sidebar, show `Quality Trim Q20` using `FASTQDerivativeOperation.shortLabel`. The filename is an implementation detail. This matches Geneious behavior where operation results are named by what they represent.

**E. Reference Sequences folder as top-level section:**

In `loadProject`, after building the project tree, insert a "Reference Sequences" section if the folder exists (or always show it as a drop target):

```swift
// In loadProject(url:)
let refFolder = ReferenceSequenceFolder.folderURL(in: projectURL)
let refItem = SidebarItem(
    title: "Reference Sequences",
    type: .referenceFolder,  // or .folder with special icon
    icon: "cylinder.split.1x2",
    children: buildReferenceChildren(in: projectURL),
    url: refFolder
)
// Insert after Downloads folder
```

---

## 6. Batch Operation Dispatch Architecture

### 6.1 Current Architecture (Sound)

`BatchProcessingEngine` is an actor that:
1. Takes a `ProcessingRecipe` and a `DemultiplexManifest`
2. Iterates barcodes with bounded concurrency (`maxConcurrency`)
3. Applies recipe steps sequentially per barcode
4. Produces `BatchManifest` + `BatchComparisonManifest` for review

This architecture is well-designed. The actor isolation prevents data races, bounded concurrency prevents resource exhaustion, and the manifest system enables post-hoc comparison.

### 6.2 Proposed Enhancements

**A. Batch operations should produce virtual outputs by default.**

Currently, `BatchProcessingEngine.processBarcode` calls `derivativeService.createDerivative` which may produce full materialized FASTQs for some operation types. Batch mode should prefer virtual outputs to save disk space, with a "Materialize All" post-action.

**B. Batch scope expansion beyond demux.**

The current engine is tightly coupled to `DemultiplexManifest.barcodes`. Generalize to accept any collection of source bundles:

```swift
public func executeBatch(
    sources: [BatchSource],  // replaces demuxGroupURL + manifest
    recipe: ProcessingRecipe,
    batchName: String,
    outputDirectory: URL,
    progress: (@Sendable (BatchProgress) -> Void)? = nil
) async throws -> BatchManifest

public struct BatchSource: Sendable {
    public let bundleURL: URL
    public let displayName: String
    public let readCount: Int
}
```

This allows batch operations across: demux barcodes, multiple imported FASTQs, or any user-selected set of bundles.

**C. Batch operation UI trigger.**

When multiple FASTQ bundles are selected in the sidebar (multi-select), or when a demux group node is selected, the operations panel should offer "Apply Recipe to All" with a recipe picker. This triggers `BatchProcessingEngine.executeBatch`.

**D. Batch results in sidebar.**

Batch results already appear as `.batchGroup` nodes. Enhance these with:
- Inline read retention summary (e.g., "87% avg retention")
- Expandable to show per-barcode results
- Context menu: "Open Comparison Dashboard" to view the `BatchComparisonManifest`

---

## 7. File System Layout on Disk

### 7.1 Current Layout

```
MyProject.lungfish/
  Downloads/
    GCF_049350105.2.lungfishref/
      manifest.json
      genome.fasta.bgz
      ...
  Reference Sequences/                  <-- from ReferenceSequenceFolder
    PhiX_Control.lungfishref/
      manifest.json
      sequence.fasta
  sample-reads.lungfishfastq/           <-- root FASTQ bundle
    sample-reads.fastq.gz
    sample-reads.fastq.gz.fai
    sample-reads.lungfish-meta.json
    demux/                              <-- demux output directory
      barcode01/
        bc01.lungfishfastq/
          derived.manifest.json
          read-ids.txt
          preview.fastq
      barcode02/
        bc02.lungfishfastq/
          ...
      materialized/                     <-- temp full FASTQs during processing
        bc01-materialized.fastq.gz
      batch-runs/
        illumina-wgs/
          recipe.json
          batch.manifest.json
          comparison.json
          bc01/
            step-1-qtrim-Q20/
              bc01-trimmed.lungfishfastq/
```

### 7.2 Proposed Layout

Add a `derivatives/` directory alongside `demux/` for non-demux derivatives:

```
MyProject.lungfish/
  Reference Sequences/
    Human_GRCh38.lungfishref/
      manifest.json
      sequence.fasta
  Downloads/
    GCF_049350105.2.lungfishref/
  sample-reads.lungfishfastq/
    sample-reads.fastq.gz
    sample-reads.fastq.gz.fai
    sample-reads.lungfish-meta.json
    derivatives/                        <-- NEW: non-demux derivative output
      qtrim-Q20-{shortid}.lungfishfastq/
        derived.manifest.json
        trim-positions.tsv              <-- virtual payload (no full FASTQ)
      subsample-10pct-{shortid}.lungfishfastq/
        derived.manifest.json
        read-ids.txt
      orient-{shortid}.lungfishfastq/
        derived.manifest.json
        orient-map.tsv
        preview.fastq
        derivatives/                    <-- chained derivatives nest recursively
          qtrim-Q20-{shortid}.lungfishfastq/
            derived.manifest.json
            trim-positions.tsv
    demux/                              <-- demux output (unchanged)
      barcode01/
        bc01.lungfishfastq/
          derived.manifest.json
          read-ids.txt
          preview.fastq
          derivatives/                  <-- per-barcode derivatives
            qtrim-Q20-{shortid}.lungfishfastq/
              derived.manifest.json
              trim-positions.tsv
      batch-runs/                       <-- batch results (unchanged)
        illumina-wgs-standard/
          recipe.json
          batch.manifest.json
          comparison.json
```

### 7.3 Layout Design Rationale

**Why `derivatives/` inside each bundle?**

Each bundle "owns" its derivative children. This matches the logical hierarchy (parent -> child) and keeps the filesystem navigable. When a bundle is moved or copied, its derivatives travel with it.

**Why keep `demux/` separate?**

Demultiplexing is structurally different from other operations: it produces N children from 1 parent, with intermediate barcode directories. Keeping `demux/` as a parallel sibling to `derivatives/` avoids overloading the derivatives directory.

**Why `{shortid}` in directory names?**

A short UUID suffix (first 8 chars) prevents collisions when the same operation type is applied multiple times with different parameters. The sidebar shows human-readable operation labels; the filesystem name is for uniqueness.

**Materialized files live inside the virtual bundle:**

When a virtual bundle is materialized, the full FASTQ is written inside the bundle itself:

```
qtrim-Q20-a1b2c3d4.lungfishfastq/
  derived.manifest.json
  trim-positions.tsv              <-- original virtual payload
  materialized.fastq.gz           <-- generated on demand, deletable
```

---

## 8. State Management Patterns

### 8.1 Virtual vs Materialized Tracking

**On-disk truth:** The `derived.manifest.json` is the single source of truth. If `materializedFASTQFilename` is non-nil AND the referenced file exists, the bundle is materialized. If the file is missing (deleted to save space), the bundle reverts to virtual.

**In-memory state:** The sidebar's `SidebarItem.isMaterialized` flag is derived from the manifest at tree-build time. A `FileSystemWatcher` already monitors the project directory; materialization/deletion events trigger sidebar refresh.

**UI indicators:**
- Virtual bundle: hollow document icon, or a small "V" badge
- Materialized bundle: filled document icon, file size shown in subtitle
- Materializing: progress spinner overlay on the icon

### 8.2 Lineage Chain State

The existing `FASTQDerivedBundleManifest.lineage: [FASTQDerivativeOperation]` array correctly captures the full operation chain from root to this bundle. This is used for:
- Display: "Quality Trim Q20 > Adapter Trim (auto)" breadcrumb
- Reproducibility: the exact parameters are recorded
- Re-materialization: replay the chain from root

### 8.3 Invalidation

When a parent bundle is deleted or modified, child virtual bundles become invalid. Proposed handling:

1. **Deletion cascade:** When a user deletes a parent FASTQ bundle, prompt: "This will also remove N derivative datasets. Continue?"
2. **Root modification (unlikely):** If the root FASTQ is replaced, all derivatives are invalidated. Mark them with a warning badge. The user can re-run operations.
3. **No automatic invalidation propagation** -- the manifest stores SHA-256 hashes (`FASTQDatasetStatistics.contentSHA256`) that can be checked on demand for integrity verification.

### 8.4 Concurrency and State Mutations

All state mutations to sidebar items happen on `@MainActor` (the sidebar is AppKit). Operation execution happens on background actors (`BatchProcessingEngine` is an actor, `MaterializationService` should also be an actor). Communication follows the established pattern:

```swift
// Background actor completes work, notifies main actor
DispatchQueue.main.async { [weak self] in
    MainActor.assumeIsolated {
        self?.refreshSidebarSubtree(at: bundleURL)
    }
}
```

This avoids the `Task { @MainActor in }` pitfall documented in MEMORY.md.

---

## 9. Geneious-Inspired UX Patterns

### 9.1 Key Geneious Behaviors to Emulate

1. **Operations produce child documents:** In Geneious, running "Trim Ends" on a document creates a new child document nested under the original. The sidebar shows the derivation tree. Lungfish should do the same: operations on a FASTQ produce child bundles in `derivatives/`, shown as expandable children in the sidebar.

2. **Batch operations across selected documents:** In Geneious, selecting multiple documents and running an operation applies it to all. Lungfish already has `BatchProcessingEngine` for this, but the UX trigger should be: multi-select in sidebar, then choose operation from the operations panel.

3. **Reference sequences as first-class project citizens:** Geneious has a "Reference Sequences" folder where users import genomes. The existing `ReferenceSequenceFolder` provides this. The gap is surfacing it in the sidebar and integrating with operation panels.

4. **Progress and status indicators:** Geneious shows progress bars on documents being processed. Lungfish should show inline progress in the sidebar item's row while operations are running.

### 9.2 Behaviors NOT to Emulate

1. **Geneious's database-backed storage:** Geneious stores everything in a database, not a filesystem. Lungfish's filesystem-first approach (`.lungfish` project directories) is better for transparency, version control, and interop with command-line tools.

2. **Geneious's flat namespace:** Geneious has a flat folder structure with type-based organization. Lungfish's hierarchical project tree with nested bundles is more natural for genomics workflows where a single sample spawns many derivatives.

---

## 10. Migration Path from Current Architecture

### Phase 1: Add `derivatives/` directory support (non-breaking)

1. Modify `FASTQDerivativeService.createDerivative` to write non-demux derivatives into `{parentBundle}/derivatives/` instead of alongside the parent.
2. Modify `SidebarViewController.buildSidebarTree` to scan `derivatives/` in addition to `demux/` when building FASTQ bundle children.
3. Add `materializedFASTQFilename` and `materializedAt` fields to `FASTQDerivedBundleManifest` (backward-compatible: nil defaults).
4. Keep existing bundles working -- the sidebar scan is additive.

### Phase 2: Sidebar UX improvements

1. Show operation labels instead of filenames in the sidebar.
2. Add materialization status indicators.
3. Add "Reference Sequences" top-level section.
4. Add reference selection dropdown to operations that need it.

### Phase 3: Decompose FASTQDerivativeService

1. Extract `VirtualDatasetFactory` for pointer creation.
2. Extract `MaterializationService` for on-demand file generation.
3. Extract `FASTQStatisticsService` for stats computation.
4. Thin `FASTQOperationDispatcher` coordinator remains.

### Phase 4: Generalize BatchProcessingEngine

1. Accept `[BatchSource]` instead of `DemultiplexManifest`.
2. Add multi-select batch triggers in the sidebar.
3. Add "Materialize All" batch action.

---

## 11. Key Design Decisions Summary

| Decision | Rationale |
|---|---|
| Virtual bundles store pointer data, not full FASTQs | Disk space savings. A 10 GB FASTQ with 5 derivative chains would cost 60 GB with copies vs ~10 GB + a few MB of pointer files. |
| Materialization is explicit and on-demand | Users control disk usage. Virtual datasets are fully browsable (via preview FASTQs and computed statistics). Materialization only needed for export or tools requiring real files. |
| Materialized files are deletable cache | The virtual manifest is the source of truth. Users can reclaim space by deleting materialized files, re-generate when needed. |
| `derivatives/` inside each bundle (not flat) | Hierarchical nesting matches the logical derivation chain. Bundles are self-contained and portable. |
| `demux/` remains separate from `derivatives/` | Demux produces a fundamentally different structure (N children from 1 parent, with barcode directories). Mixing would complicate scanning logic. |
| Operations shown by label, not filename | Users think in terms of "Quality Trim Q20," not `qtrim-Q20-a1b2c3d4.lungfishfastq`. Filenames are implementation details. |
| Reference Sequences folder at project root | Matches Geneious pattern. All operations that need a reference can discover candidates from a single well-known location. |
| `ReferenceCandidate` union type for discovery | A single operation dropdown can list references from multiple sources (Reference Sequences folder, genome bundles, standalone FASTAs) without the user manually browsing. |
| Background -> MainActor via GCD + assumeIsolated | Per MEMORY.md, `Task { @MainActor in }` is unreliable from GCD background queues. The GCD pattern is the established fix. |
