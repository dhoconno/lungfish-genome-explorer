# Session 21 Spec: Viewport Classes, Bundle Architecture, BLAST Integration

## Context

Session 20 delivered the Import Center, NAO-MGS parser/viewer, minimap2 pipeline, SPAdes refactor, Orient/Map wizards, and Lungfish Orange color system. Several architectural pieces need completion before the tools are fully functional. This document specifies all remaining work with enough detail that tasks can be parallelized across independent agent teams.

All work MUST follow the project conventions in MEMORY.md. Key rules:
- Swift 6.2, macOS 26+, strict concurrency, `@MainActor` isolation
- NEVER use `Task { @MainActor in }` from GCD — use `DispatchQueue.main.async { MainActor.assumeIsolated { } }`
- NEVER use `runModal()` — use `beginSheetModal`
- NEVER save alignment data as SAM — always sorted indexed BAM
- Brand color: `Color.lungfishOrangeFallback` (#D47B3A) for branded elements; system accent for standard controls
- Dialog design: 480-520px width, button labeled "Run", header with tool icon + name + subtitle + dataset name
- Operations must call BOTH `OperationCenter.shared.update()` AND `.log()` for the Operations Panel
- Virtual FASTQ bundles must be materialized via `FASTQDerivativeService` before any tool runs on them
- See `docs/design/viewport-interface-classes.md` for the 5 viewport class architecture
- See `docs/design/palette.md` for color rules

---

## Track A: Viewport Interface Base Classes (Architectural Refactoring)

### Goal
Extract reusable base classes from existing result view controllers so new tools can be added with zero viewport code. See `docs/design/viewport-interface-classes.md` for the full spec.

### A1: ResultViewportController Protocol

Create `Sources/LungfishApp/Views/Results/Base/ResultViewportController.swift`:

```swift
protocol ResultViewportController: NSViewController {
    associatedtype ResultType
    func configure(result: ResultType)
    var summaryBar: GenomicSummaryCardBar { get }
    func exportResults(to url: URL, format: ExportFormat) throws
}

protocol BlastVerifiable {
    var onBlastVerification: ((BlastRequest) -> Void)? { get set }
}

struct BlastRequest {
    let taxId: Int?
    let sequences: [String]  // FASTA-formatted sequences to BLAST
    let readCount: Int
    let sourceLabel: String  // e.g. "taxid 130309" or "contig NODE_1"
}
```

### A2: TaxonomyResultViewController Base Class

Refactor `TaxonomyViewController.swift` into a base class that provides:
- Summary bar with configurable metric cards
- Taxonomy table (NSTableView, sortable, right-click BLAST context menu)
- Action bar (Export, selection info)
- BLAST drawer integration

Then make Kraken2, EsViritu, TaxTriage, NAO-MGS into thin subclasses/configurations:
- Kraken2: adds sunburst in detail pane
- EsViritu: adds detection table + BAM viewer in detail pane
- TaxTriage: adds report PDF + Krona HTML in detail pane
- NAO-MGS: adds coverage plots + edit distance histogram in detail pane

Key files to read first:
- `Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift`
- `Sources/LungfishApp/Views/Metagenomics/EsVirituResultViewController.swift`
- `Sources/LungfishApp/Views/Metagenomics/TaxTriageResultViewController.swift`
- `Sources/LungfishApp/Views/Metagenomics/NaoMgsResultViewController.swift`
- `Sources/LungfishApp/Views/Metagenomics/NaoMgsChartViews.swift`
- `Sources/LungfishApp/Views/Metagenomics/NaoMgsDataConverter.swift`

### A3: AlignmentResultViewController Base Class

Create a base class for read mapping results that wraps the existing BAM viewport:
- Summary bar: total reads, mapped %, unmapped %, reference name, aligner version
- Reuses existing `ViewerViewController` BAM rendering (read pileup, coverage depth)
- Mapping quality distribution chart
- Insert size distribution (paired-end)
- Flagstat summary panel

Used by: minimap2, BWA-MEM2, Bowtie2, HISAT2 (all produce sorted indexed BAM — identical viewport, different BAM content).

### A4: AssemblyResultViewController Base Class

Create a base class for assembly results:
- Summary bar: contig count, N50, total length, largest contig, GC%
- Contig table (NSTableView): Name, Length, Coverage, GC% — sortable
- Detail pane: sequence viewer for selected contig
- Statistics panel: Nx curve plot, length distribution histogram, GC distribution
- Right-click BLAST on contigs (see Track C)
- Export contigs (FASTA)

Used by: SPAdes, MEGAHIT, Flye, hifiasm.

Key file to read: `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift` (the existing assembly bundle display in the main viewer)

---

## Track B: NAO-MGS Proper Bundle Architecture

### Goal
Make NAO-MGS imports produce first-class bundle entities that appear as single items in the sidebar, support the taxonomy result viewer, and auto-fetch viral reference sequences from GenBank.

### B1: NAO-MGS Bundle Format

The import should produce a `.lungfishnaomgs` bundle (or reuse `.lungfishref` with a metagenomics manifest type):

```
naomgs-{sampleName}/
  manifest.json              ← NaoMgsManifest (new type)
  virus_hits.json            ← Serialized NaoMgsResult for fast reload
  {sampleName}.sorted.bam    ← Sorted indexed BAM
  {sampleName}.sorted.bam.bai
  references/                ← Auto-downloaded viral reference FASTAs
    KU162869.1.fasta         ← Fetched from GenBank efetch
    MT791000.1.fasta
    ...
```

The `NaoMgsManifest` should include:
- Sample name, import date, source file path
- Hit count, taxon count, top taxon
- List of reference accessions that have been fetched
- Version of nao-mgs-workflow that produced the results (if detectable)

### B2: Sidebar Integration

The `naomgs-{sampleName}` folder should appear as a single entity in the sidebar with an "N" icon (like K/E/T for other classifiers). Clicking it should open the `NaoMgsResultViewController`.

Key files to read:
- `Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift` — how `.lungfishref` and classification result bundles appear
- `Sources/LungfishApp/Views/Viewer/ViewerViewController+Taxonomy.swift` — how classification results wire into the viewer

The sidebar scanner at `SidebarViewController` needs to recognize the new bundle type and hide internal files (BAM, BAI, JSON, references/) from the file listing.

### B3: GenBank Reference Auto-Fetch

During import, after creating the BAM, fetch viral reference FASTAs for the top N accessions:

```
https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=nucleotide&id={accession}&rettype=fasta
```

Viral genomes are 3-30kb — downloads are near-instant. Fetch the top 20 accessions by read count during import. Store in `references/` within the bundle.

These references enable the BAM pileup viewer (MiniBAMViewController) to display aligned reads against the actual viral genome when a user selects a taxon and clicks an accession in the detail pane.

Key file to read:
- `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift` lines 2026-2110 — `downloadReferenceForNakedBundle()` shows the existing pattern for GenBank fetching
- `Sources/LungfishApp/Services/NCBIService.swift` — the NCBI API service

### B4: Multi-Sample Support

NAO-MGS is typically run on many wastewater samples. When a user imports a folder containing multiple `*virus_hits*.tsv.gz` files:
1. Parse each file separately
2. Create one bundle per sample
3. Add a cross-sample heatmap view (taxa × samples, Lungfish Orange color scale)
4. Optionally: time series view if dates are parseable from sample names

The multi-sample heatmap is a Tier 3 visualization per `docs/design/naomgs-visualization.md`.

---

## Track C: BLAST Integration for Assembly Viewer

### Goal
Add BLAST verification to the assembly contig viewer, reusing the existing BLAST drawer infrastructure.

### C1: Assembly Contig BLAST

Right-clicking a contig in the assembly viewer (or the contig table) should show:
```
+----------------------------------+
| BLAST Selected Contig            |
| BLAST Selected Contigs (N)       |
| ---                              |
| Copy Sequence                    |
| Copy Name                        |
| Export as FASTA...               |
+----------------------------------+
```

When "BLAST Selected Contig" is chosen:
1. Extract the contig sequence from the assembly FASTA
2. Submit to NCBI BLAST via the existing `BlastService`
3. Display results in the bottom BLAST drawer (same as taxonomy BLAST)

### C2: Multi-Contig Selection

The assembly contig table should support:
- Cmd+Click for discontiguous selection
- Shift+Click for range selection
- When multiple contigs are selected, the viewer should show them stacked vertically (each contig as a horizontal track with its own ruler)

The "BLAST Selected Contigs" context menu option should concatenate all selected contigs (separated by 100 N's) or BLAST them individually and merge results.

### C3: BLAST Request Unification

The `BlastRequest` struct from Track A should be the common currency for all BLAST operations:
- Taxonomy BLAST: sequences from reads matching a taxon
- Assembly BLAST: sequences from selected contigs
- NAO-MGS BLAST: sequences from reads matching a taxon (coverage-stratified selection per `docs/design/naomgs-visualization.md`)

All three use the same `BlastService` and bottom drawer display.

Key files to read:
- `Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController+Blast.swift`
- `Sources/LungfishApp/Services/BlastService.swift`

---

## Track D: Reference Picker Polish and Minimap2 End-to-End

### D1: Minimap2 End-to-End Test

Verify the full minimap2 pipeline works:
1. Select a FASTQ dataset in the sidebar
2. Open Map Reads from FASTQ Operations
3. Select MN908947 reference from the dropdown (should now work with genome bundle scanner fix)
4. Click Run
5. Verify: sorted indexed BAM appears in project, AlignmentResultViewController displays it

The reference picker was fixed in session 20 to scan `genome/*.fa.gz` files. Verify this works and that minimap2 conda tool is installed and executable.

Key files:
- `Sources/LungfishWorkflow/Alignment/Minimap2Pipeline.swift`
- `Sources/LungfishApp/Views/Metagenomics/MapReadsWizardSheet.swift`
- `Sources/LungfishApp/Views/Shared/ReferenceSequencePickerView.swift`
- `Sources/LungfishIO/Formats/FASTQ/ReferenceSequenceScanner.swift`

### D2: Orient End-to-End Test

Same as D1 but for the Orient operation:
1. Select FASTQ, open Orient from FASTQ Operations
2. Select reference, click Run
3. Verify oriented FASTQ derivative is created

### D3: SPAdes Materialization Verification

Verify that virtual FASTQ bundles (subset/trim/demux derivatives) are correctly materialized before SPAdes assembly. The fix was added in session 20 but not yet tested with a virtual bundle.

---

## Track E: NIO Crash Fix and Container Cleanup

### E1: Assembly Navigation Crash

**Bug:** `NIOPosix/System.swift:264: Precondition failed: unacceptable errno 9 Bad file descriptor in fcntl` when rapidly navigating between assembly contigs with arrow keys.

**Diagnosis:** Apple Containers NIO networking code encounters a stale fd when the container process terminates while NIO event loop is still active. See `memory/known-issues.md`.

**Fix approach:** In `SPAdesAssemblyPipeline.run()`, after collecting results and before returning, ensure the container is fully torn down:
1. Explicitly stop the container
2. Wait for the NIO event loop to drain
3. Add a small delay if needed
4. Only then return the result

Key file: `Sources/LungfishWorkflow/Assembly/SPAdesAssemblyPipeline.swift`
Also check: `Sources/LungfishWorkflow/Engines/AppleContainerRuntime.swift` for container lifecycle methods.

---

## Track F: Import Center Polish

### F1: Wire Remaining Import Types

Currently only NAO-MGS import has a wizard. Wire the other import types:
- BAM Import: use existing `AppDelegate.importBAMToBundle()` — just needs the file URL passed through
- VCF Import: use existing VCF import path
- FASTA Import: use `ReferenceSequenceFolder.importReference()`
- Kraken2 Import: parse `.kreport` file, create classification result bundle, display in TaxonomyViewController
- EsViritu Import: parse detection output, create result bundle
- TaxTriage Import: parse report files, create result bundle

### F2: Import History

Add an "Import History" section at the bottom of each Import Center tab showing recent imports with timestamps, file paths, and status (success/failed).

### F3: Drag-and-Drop Import

The Import Center should accept drag-and-drop of files onto the appropriate tab cards. Dropping a `.tsv.gz` file onto the NAO-MGS card should start the import wizard pre-populated with that file path.

---

## Track G: Color Palette Enforcement

### G1: Audit All Red Usage

Session 20 replaced `.red` with `Color.lungfishOrangeFallback` in wizard sheets. Audit ALL remaining `.red` usage in the app and replace validation/error messages with Lungfish Orange. Keep `.red` only for:
- System-level errors (network failures, crash reports)
- Mismatch indicators in alignment viewer (base mismatches vs reference)

Key command to find them:
```bash
grep -rn "foregroundStyle(\.red)" Sources/LungfishApp/
grep -rn "foregroundColor(\.red)" Sources/LungfishApp/
grep -rn "NSColor.systemRed" Sources/LungfishApp/
```

### G2: Lungfish Orange in Existing Views

Apply Lungfish Orange to:
- Import Center card icons (already done)
- Classification tool letter icons in sidebar (K, E, T circles)
- Operations Panel progress bars
- Summary bar metric card accents
- Chart primary series color

---

## Parallelization Guide

These tracks can be worked on simultaneously by independent agent teams:

| Track | Dependencies | Files Touched |
|-------|-------------|---------------|
| A (Viewport classes) | None | New files in Views/Results/, refactor existing VCs |
| B (NAO-MGS bundles) | None | NaoMgsResultParser, AppDelegate, SidebarVC, NCBIService |
| C (Assembly BLAST) | A4 (base class) | New files, BlastService, ViewerVC |
| D (Reference/minimap2) | None | Testing existing code, minor fixes |
| E (NIO crash) | None | SPAdesAssemblyPipeline, AppleContainerRuntime |
| F (Import Center) | B (for Kraken2/EsViritu/TaxTriage import) | ImportCenterViewModel, AppDelegate |
| G (Color palette) | None | Many files (search-and-replace) |

**Recommended parallel groups:**
- Group 1: Track A (largest, most impactful — architectural foundation)
- Group 2: Track B + F (NAO-MGS bundles + Import Center — related import infrastructure)
- Group 3: Track C + E (Assembly BLAST + crash fix — assembly-related)
- Group 4: Track D + G (Testing + polish — lower risk, can validate other tracks)

---

## Acceptance Criteria

For each track, the following must be true before marking complete:
1. `swift build` succeeds with zero errors (excluding pre-existing AppleContainerRuntime issues)
2. New code follows all MEMORY.md conventions
3. CLI parity: every GUI operation has a corresponding CLI command
4. Operations Panel: all long-running operations use `OperationCenter.shared.update()` AND `.log()`
5. Virtual FASTQ materialization: any tool that takes FASTQ input materializes virtual bundles first
6. Color: validation messages use `Color.lungfishOrangeFallback`, not `.red`
7. Dialogs: 480-520px width, "Run" button, header with icon + name + subtitle
8. BAM output: always sorted and indexed, never SAM
9. Build and launch from main repo command line for testing: `pkill -f "\.build/debug/Lungfish" 2>/dev/null; sleep 1; cd /Users/dho/Documents/lungfish-genome-explorer && swift build && .build/debug/Lungfish &`
