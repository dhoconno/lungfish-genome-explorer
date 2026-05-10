# Metagenomics Workflow Design

Complete analysis workflow for Kraken2/Bracken/MetaPhlAn metagenomics
classification, profiling, and sequence extraction within Lungfish.

## Table of Contents

1. [Design Philosophy](#1-design-philosophy)
2. [User-Facing Workflow](#2-user-facing-workflow)
3. [Database Management System](#3-database-management-system)
4. [Classification Pipeline](#4-classification-pipeline)
5. [Results Visualization (Sunburst)](#5-results-visualization-sunburst)
6. [Sequence Extraction](#6-sequence-extraction)
7. [UI Wireframes](#7-ui-wireframes)
8. [Data Model](#8-data-model)
9. [Provenance Integration](#9-provenance-integration)
10. [Implementation Plan](#10-implementation-plan)

---

## 1. Design Philosophy

The metagenomics workflow answers a single high-level question:
**"What organisms are in my sample?"**

Users should not need to know that Kraken2 does k-mer classification while
MetaPhlAn uses marker genes, or that Bracken re-estimates abundance at a
specific taxonomic level. The UI presents *biological questions*, and the
system selects and configures tools accordingly.

### Principles

- **Question-first**: The user picks a goal (classify, profile, extract),
  not a tool name.
- **Sensible defaults**: Every parameter has a biologically motivated
  default. The user can run an analysis without changing anything.
- **Progressive disclosure**: Basic mode shows 2-3 choices. Advanced mode
  exposes every knob, grouped by biological concern rather than tool flag.
- **Provenance by default**: Every run records the exact tool versions,
  database versions, and parameters, written as a `.lungfish-provenance.json`
  sidecar via the existing `ProvenanceRecorder` actor.
- **Virtual FASTQ output**: Extracted reads become pointer-based virtual
  FASTQ derivatives (the existing `MaterializationState` lifecycle),
  appearing in the sidebar like any other derived dataset.

---

## 2. User-Facing Workflow

### Entry Point

The user right-clicks a FASTQ bundle in the sidebar (or selects
"Metagenomics..." from the Analysis menu) and sees:

```
+----------------------------------------------------------+
|  Metagenomics Analysis                            [X]    |
+----------------------------------------------------------+
|                                                          |
|  Input: SRR12345678.lungfishfastq                        |
|         2.4 M reads, 150 bp PE, Illumina NovaSeq        |
|                                                          |
|  What would you like to do?                              |
|                                                          |
|  ( ) Classify reads            [chart.bar.doc.horizontal]|
|      Assign each read to a taxon. Fast overview of       |
|      what is in your sample.                             |
|                                                          |
|  ( ) Profile community         [chart.pie.fill]          |
|      Estimate relative abundance of organisms at each    |
|      taxonomic level. Best for comparing samples.        |
|                                                          |
|  ( ) Extract by organism       [arrow.down.doc]          |
|      Pull out reads belonging to a specific taxon.       |
|      Requires a prior classification run.                |
|                                                          |
|  [Next >>]                                               |
+----------------------------------------------------------+
```

SF Symbols used throughout this design:
- `chart.bar.doc.horizontal` -- classification
- `chart.pie.fill` -- profiling
- `arrow.down.doc` -- extraction
- `internaldrive` -- database
- `arrow.down.circle` -- download
- `checkmark.circle.fill` -- ready
- `exclamationmark.triangle` -- warning
- `externaldrive` -- external volume
- `magnifyingglass` -- search/filter
- `square.and.arrow.up` -- export
- `gearshape` -- advanced settings
- `clock` -- provenance/history
- `circle.hexagonpath` -- sunburst chart

### Step-by-Step Flow

```
FASTQ in sidebar
      |
      v
[1] Goal picker (classify / profile / extract)
      |
      v
[2] Database picker (with management UI)
      |
      v
[3] Parameter review (defaults pre-filled, advanced collapsed)
      |
      v
[4] Run (progress in OperationCenter, cancel-able)
      |
      v
[5] Results appear in a new tab/panel:
    - Sunburst taxonomy viewer
    - Table of taxa with counts
    - "Extract" button per taxon
      |
      v
[6] Extract produces a virtual FASTQ derivative in sidebar
```

### Goal-to-Tool Mapping

| User Goal            | Primary Tool | Secondary Tool | Output                     |
|---------------------|-------------|---------------|----------------------------|
| Classify reads      | Kraken2     | --            | .kraken + .kreport         |
| Profile community   | Kraken2     | Bracken       | .kreport + .bracken        |
| Profile (markers)   | MetaPhlAn   | --            | .metaphlan_profile         |
| Extract by organism | kraken2 + extract_kraken_reads.py | -- | virtual FASTQ |

The mapping is transparent: the user picks "Profile community" and the
system runs Kraken2 then Bracken automatically. The Provenance record
shows both steps.

---

## 3. Database Management System

### 3.1 Architecture

Databases are large (8-70 GB) and may live on external volumes. The
system uses a **manifest-based registry** that tracks database locations
without copying files.

```
~/.lungfish/databases/
    metagenomics-db-registry.json     <-- manifest
    kraken2/
        k2_standard_20240904/         <-- downloaded DB
            hash.k2d
            opts.k2d
            taxo.k2d
            manifest.json             <-- per-DB metadata
        k2_viral_20240904/
            ...
    bracken/
        (symlinks or embedded in kraken2 DB dirs)
    metaphlan/
        mpa_vOct22_CHOCOPhlAnSGB_202403/
            ...
```

External volumes are referenced by **bookmark** (not raw path), so the
system can re-resolve the volume even if the mount point changes:

```
~/.lungfish/databases/metagenomics-db-registry.json
{
  "formatVersion": "1.0",
  "databases": [
    {
      "id": "d8f1a2...",
      "name": "Kraken2 Standard",
      "tool": "kraken2",
      "collection": "standard",
      "version": "2024-09-04",
      "sizeBytes": 72483225600,
      "location": {
        "type": "local",
        "path": "~/.lungfish/databases/kraken2/k2_standard_20240904"
      },
      "lastVerified": "2026-03-20T12:00:00Z",
      "status": "ready"
    },
    {
      "id": "a3b7c9...",
      "name": "Kraken2 PlusPF (External)",
      "tool": "kraken2",
      "collection": "pluspf",
      "version": "2024-09-04",
      "sizeBytes": 77309411328,
      "location": {
        "type": "bookmark",
        "bookmark": "<base64-encoded security-scoped bookmark>",
        "lastKnownPath": "/Volumes/BioData/kraken2/k2_pluspf_20240904"
      },
      "lastVerified": "2026-03-18T09:30:00Z",
      "status": "ready"
    }
  ]
}
```

### 3.2 Kraken2 Database Catalog

Databases from Ben Langmead's pre-built collection at
`https://genome-idx.s3.amazonaws.com/kraken/`:

| Collection  | Size (GB) | Contents                              | RAM Needed | Recommended For           |
|------------|-----------|---------------------------------------|------------|---------------------------|
| Standard    | ~67       | Archaea, bacteria, viral, plasmid, human, UniVec | ~67 GB | General metagenomics |
| Standard-8  | ~8        | Same as Standard, capped at 8 GB      | ~8 GB      | Laptops, quick screening  |
| Standard-16 | ~16       | Same as Standard, capped at 16 GB     | ~16 GB     | 16 GB M-series Macs       |
| PlusPF      | ~72       | Standard + protozoa + fungi            | ~72 GB     | Clinical, environmental   |
| PlusPF-8    | ~8        | PlusPF capped at 8 GB                 | ~8 GB      | Laptops, clinical screen  |
| PlusPF-16   | ~16       | PlusPF capped at 16 GB                | ~16 GB     | 16 GB Macs, clinical      |
| Viral       | ~0.5      | RefSeq viral genomes only             | ~0.5 GB    | Viral surveillance        |
| MinusB      | ~11       | Standard minus bacteria               | ~11 GB     | Non-bacterial targets     |
| EuPathDB46  | ~34       | Eukaryotic pathogens (EuPathDB)       | ~34 GB     | Parasitology              |

**Smart recommendation logic:**

```
physical RAM >= 72 GB  -->  recommend PlusPF
physical RAM >= 32 GB  -->  recommend Standard
physical RAM >= 16 GB  -->  recommend Standard-16 or PlusPF-16
physical RAM <  16 GB  -->  recommend Standard-8 or PlusPF-8

use case == "viral"    -->  recommend Viral (regardless of RAM)
```

### 3.3 Database Picker UI

```
+----------------------------------------------------------+
|  Select Database                                         |
+----------------------------------------------------------+
|                                                          |
|  [internaldrive] Installed Databases                     |
|  +------------------------------------------------------+|
|  | [checkmark.circle.fill] Kraken2 Standard-16          ||
|  |   Version: 2024-09-04 | Size: 16.2 GB               ||
|  |   ~/.lungfish/databases/kraken2/...                   ||
|  |   RAM: 16 GB (fits your Mac)                  [star] ||
|  +------------------------------------------------------+|
|  | [checkmark.circle.fill] Kraken2 Viral                ||
|  |   Version: 2024-09-04 | Size: 0.5 GB                ||
|  |   ~/.lungfish/databases/kraken2/...                   ||
|  +------------------------------------------------------+|
|  | [externaldrive] Kraken2 PlusPF (External)            ||
|  |   Version: 2024-09-04 | Size: 72 GB                 ||
|  |   /Volumes/BioData/kraken2/...                        ||
|  |   [exclamationmark.triangle] Volume not mounted       ||
|  +------------------------------------------------------+|
|                                                          |
|  [arrow.down.circle] Download New Database...            |
|  [folder] Add Existing Database...                       |
|  [gearshape] Manage Databases...                         |
|                                                          |
+----------------------------------------------------------+
```

### 3.4 Download New Database Sheet

```
+----------------------------------------------------------+
|  Download Kraken2 Database                               |
+----------------------------------------------------------+
|                                                          |
|  Your Mac: Apple M2 Pro, 32 GB RAM                       |
|  Recommended: Standard (fits in 32 GB RAM)       [star]  |
|                                                          |
|  Available databases:                                    |
|  +------------------------------------------------------+|
|  | [star] Standard                                      ||
|  |   67 GB download, ~67 GB on disk                     ||
|  |   Archaea, bacteria, viral, human, plasmid           ||
|  |   Requires 67 GB RAM for classification              ||
|  +------------------------------------------------------+|
|  | Standard-16                                          ||
|  |   16 GB download, ~16 GB on disk                     ||
|  |   Same taxa, smaller hash (slightly less precise)    ||
|  |   Requires 16 GB RAM                                 ||
|  +------------------------------------------------------+|
|  | PlusPF                                               ||
|  |   72 GB download, ~72 GB on disk                     ||
|  |   + protozoa and fungi                               ||
|  |   Requires 72 GB RAM (exceeds your 32 GB)    [warn] ||
|  +------------------------------------------------------+|
|  | Viral                                                ||
|  |   0.5 GB download                                    ||
|  |   RefSeq viral only                                  ||
|  +------------------------------------------------------+|
|                                                          |
|  Download to: [~/.lungfish/databases/kraken2/] [Browse]  |
|                                                          |
|  [Cancel]                              [Download]        |
+----------------------------------------------------------+
```

After clicking Download, progress appears in the OperationCenter
activity monitor (same pattern as genome downloads). Downloads support
resume via HTTP Range requests.

### 3.5 Database Relocation

To move a database to an external volume:

1. User goes to Manage Databases
2. Selects a database, clicks "Move to..."
3. Picks a destination on an external volume
4. Lungfish moves the directory, creates a security-scoped bookmark,
   updates the registry

To add an existing database from an external volume:

1. User clicks "Add Existing Database..."
2. Navigates to the directory containing `hash.k2d` / `opts.k2d` / `taxo.k2d`
3. Lungfish validates the database files, creates a bookmark, adds to registry

### 3.6 MetagenomicsDatabaseRegistry Actor

Extends the existing `DatabaseRegistry` pattern:

```swift
/// Manages metagenomics database installations across local
/// and external storage.
public actor MetagenomicsDatabaseRegistry {

    public static let shared = MetagenomicsDatabaseRegistry()

    /// All registered databases (local + external).
    public func allDatabases() -> [MetagenomicsDatabase]

    /// Databases compatible with a specific tool.
    public func databases(for tool: MetagenomicsTool) -> [MetagenomicsDatabase]

    /// Recommended database for the current hardware.
    public func recommendedDatabase(
        for tool: MetagenomicsTool,
        ramBytes: UInt64
    ) -> MetagenomicsDatabase?

    /// Register a database from an existing directory.
    public func registerExisting(at url: URL) throws -> MetagenomicsDatabase

    /// Begin downloading a database from the catalog.
    public func download(
        collection: DatabaseCollection,
        to destination: URL,
        progress: @Sendable (Double, String) -> Void
    ) async throws -> MetagenomicsDatabase

    /// Move a database to a new location, updating bookmarks.
    public func relocate(
        _ database: MetagenomicsDatabase,
        to destination: URL
    ) async throws

    /// Verify a database's files are intact and accessible.
    public func verify(_ database: MetagenomicsDatabase) -> DatabaseStatus

    /// Resolve a bookmark for an external-volume database.
    /// Returns the current URL or nil if the volume is not mounted.
    public func resolveLocation(
        _ database: MetagenomicsDatabase
    ) -> URL?
}
```

---

## 4. Classification Pipeline

### 4.1 Tool Provisioning

Kraken2, Bracken, and MetaPhlAn are **not** bundled with the app (unlike
samtools/bcftools). They are installed via the existing `CondaManager`:

```swift
// Conda environment for metagenomics tools
let env = CondaEnvironment(
    name: "lungfish-metagenomics",
    packages: [
        CondaPackage(name: "kraken2", version: "2.1.3", channel: .bioconda),
        CondaPackage(name: "bracken", version: "2.9", channel: .bioconda),
        CondaPackage(name: "metaphlan", version: "4.1.1", channel: .bioconda),
        CondaPackage(name: "krakentools", version: "1.2", channel: .bioconda),
    ]
)
```

On first use, the system checks for the environment and offers to create
it. This is a one-time ~2 GB download.

Alternative: if the user has these tools in PATH (e.g., installed via
homebrew or their own conda), the system detects and uses those,
recording the version in provenance.

### 4.2 Execution Flow: "Classify Reads"

```
Input FASTQ
    |
    v
[kraken2]
    --db <selected_database>
    --threads <cpu_count - 1>
    --confidence 0.0           (default: sensitive)
    --minimum-hit-groups 2     (default: reduce false positives)
    --report <output>.kreport
    --output <output>.kraken
    --paired (if PE)
    --gzip-compressed (if .gz)
    <reads>
    |
    v
Output:
    .kraken   (per-read classification, tab-delimited)
    .kreport  (summary report by taxon)
```

### 4.3 Execution Flow: "Profile Community"

```
Input FASTQ
    |
    v
[kraken2] (same as classify)
    |
    v
[bracken]
    -d <database>
    -i <kreport>
    -o <output>.bracken
    -w <output>.bracken.kreport
    -r <read_length>           (auto-detected from FASTQ stats)
    -l S                       (default: species level)
    -t 10                      (default: min 10 reads threshold)
    |
    v
Output:
    .bracken          (re-estimated abundances)
    .bracken.kreport  (corrected kreport format)
```

### 4.4 Execution Flow: "Profile (Marker Genes)"

```
Input FASTQ
    |
    v
[metaphlan]
    --input_type fastq
    --bowtie2db <metaphlan_db>
    --nproc <cpu_count - 1>
    -o <output>.metaphlan_profile
    --unclassified_estimation
    <reads>
    |
    v
Output:
    .metaphlan_profile   (relative abundance table)
```

### 4.5 Default Parameters by Use Case

| Parameter               | Sensitive (default) | Balanced       | Precise         |
|------------------------|--------------------:|---------------:|----------------:|
| `--confidence`          | 0.0                | 0.2            | 0.5             |
| `--minimum-hit-groups`  | 2                  | 3              | 5               |
| Bracken `-t` threshold  | 10                 | 50             | 100             |
| Bracken `-l` level      | S (species)        | S (species)    | G (genus)       |

These are presented as a single **Precision** slider with three detents,
not as individual parameters (unless Advanced mode is expanded).

### 4.6 Parameter UI: Basic Mode

```
+----------------------------------------------------------+
|  Analysis Settings                                       |
+----------------------------------------------------------+
|                                                          |
|  Precision:                                              |
|  Sensitive ----[O]------------ Balanced --- Precise      |
|  Finds more organisms;         Fewer false positives;    |
|  may include false positives   may miss rare taxa        |
|                                                          |
|  Threads: [===========O===] 10 / 12                      |
|                                                          |
|  [v] Advanced Settings                                   |
|                                                          |
|  [Cancel]                              [Run Analysis]    |
+----------------------------------------------------------+
```

### 4.7 Parameter UI: Advanced Mode (Expanded)

```
+----------------------------------------------------------+
|  [^] Advanced Settings                                   |
+----------------------------------------------------------+
|                                                          |
|  --- Kraken2 ---                                         |
|  Confidence threshold: [0.0____]                         |
|    Range: 0.0 (most sensitive) to 1.0 (most precise)    |
|    Higher values require more k-mer evidence per read.   |
|                                                          |
|  Minimum hit groups: [2______]                           |
|    Number of groups of consecutive k-mers that must      |
|    match. Increasing reduces false positives for short   |
|    reads.                                                |
|                                                          |
|  Memory mapping: [v] (uses mmap instead of loading DB)   |
|    Slower but uses much less RAM. Required when DB       |
|    exceeds available RAM.                                |
|                                                          |
|  --- Bracken (for "Profile" mode only) ---               |
|  Read length: [150___] bp (auto-detected)                |
|    Must match a Bracken k-mer distribution file.         |
|    Available: 50, 75, 100, 150, 200, 250, 300           |
|                                                          |
|  Taxonomic level: [Species (S) v]                        |
|    D=Domain K=Kingdom P=Phylum C=Class O=Order           |
|    F=Family G=Genus S=Species                            |
|                                                          |
|  Minimum reads: [10_____]                                |
|    Taxa with fewer reads are redistributed to parents.   |
|                                                          |
|  --- MetaPhlAn (for "Marker" mode only) ---              |
|  Min clade size: [0______] bp                            |
|  Stat quantile: [0.2____]                                |
|  Analysis type: [rel_ab v] (rel_ab | rel_ab_w_read_stats|
|                              | reads_map | clade_profiles|
|                              | marker_ab_table |         |
|                              | marker_pres_table)        |
|                                                          |
+----------------------------------------------------------+
```

Each parameter has an inline help tooltip (`questionmark.circle`)
explaining the biological impact, not just the flag name.

---

## 5. Results Visualization (Sunburst)

### 5.1 Taxonomy Data Model

Kraken2 `.kreport` files are parsed into a tree:

```swift
/// A node in the taxonomy tree.
public struct TaxonNode: Identifiable, Sendable {
    public let id: Int                    // NCBI taxonomy ID (taxid)
    public let name: String               // Scientific name
    public let rank: TaxonomicRank        // D/K/P/C/O/F/G/S
    public let depth: Int                 // Indentation level in kreport
    public var readsCladeDirect: Int      // Reads assigned directly to this taxon
    public var readsClade: Int            // Reads in this clade (self + all descendants)
    public var fractionClade: Double      // readsClade / totalReads
    public var fractionDirect: Double     // readsCladeDirect / totalReads
    public var children: [TaxonNode]      // Child taxa
    public weak var parent: TaxonNode?    // Pointer to parent (class, not struct)

    // Bracken-corrected values (nil if Bracken not run)
    public var brackenReads: Int?
    public var brackenFraction: Double?
}

public enum TaxonomicRank: String, Codable, Sendable, CaseIterable {
    case unclassified = "U"
    case root = "R"
    case domain = "D"       // also "superkingdom"
    case kingdom = "K"
    case phylum = "P"
    case `class` = "C"
    case order = "O"
    case family = "F"
    case genus = "G"
    case species = "S"
    case subspecies = "S1"

    var displayName: String { ... }
    var ringIndex: Int { ... }   // 0=root, 1=domain, ... 7=species
}
```

### 5.2 Sunburst Chart (CoreGraphics)

The sunburst is a native `NSView` subclass rendered with CoreGraphics
(no HTML, no WebKit). It draws concentric rings where each ring
represents a taxonomic rank and each arc segment represents a taxon.

```
                    +---------+
                   /  Species  \
                  /   segments  \
                 /_______________\
                /    Genus ring   \
               /___________________\
              /    Family ring      \
             /_______________________\
            /     Order ring          \
           /___________________________\
          /      Class ring             \
         /_______________________________\
        /       Phylum ring               \
       /___________________________________\
      /        Domain ring                  \
     /_______________________________________\
    |          Root (center dot)              |
     \_______________________________________/
```

#### Rendering Logic

```swift
/// Draws one ring of the sunburst chart.
func drawRing(
    in context: CGContext,
    center: CGPoint,
    innerRadius: CGFloat,
    outerRadius: CGFloat,
    startAngle: CGFloat,      // radians, cumulative from parent
    sweepAngle: CGFloat,      // proportional to fraction of parent
    node: TaxonNode,
    depth: Int
) {
    // 1. Draw the arc segment for this node
    let path = CGMutablePath()
    path.addArc(center: center, radius: innerRadius,
                startAngle: startAngle,
                endAngle: startAngle + sweepAngle, clockwise: false)
    path.addArc(center: center, radius: outerRadius,
                startAngle: startAngle + sweepAngle,
                endAngle: startAngle, clockwise: true)
    path.closeSubpath()

    context.addPath(path)
    context.setFillColor(color(for: node).cgColor)
    context.fillPath()

    // 2. Draw label if segment is wide enough
    if sweepAngle > minimumLabelAngle {
        drawLabel(node.name, along: path, in: context)
    }

    // 3. Recursively draw children
    var childStartAngle = startAngle
    for child in node.children {
        let childSweep = sweepAngle * child.fractionOfParent
        drawRing(in: context, center: center,
                 innerRadius: outerRadius,
                 outerRadius: outerRadius + ringWidth,
                 startAngle: childStartAngle,
                 sweepAngle: childSweep,
                 node: child, depth: depth + 1)
        childStartAngle += childSweep
    }
}
```

#### Color Schemes

Two color modes, toggled by a segmented control above the chart:

1. **By phylum** (default): Each phylum gets a distinct hue from a
   colorblind-safe palette (Okabe-Ito extended). All descendants inherit
   the phylum hue with increasing lightness at deeper ranks.

2. **By abundance**: Heat map from blue (rare) through yellow to red
   (dominant). Useful for spotting the most abundant organisms at a glance.

#### Interaction

| Action                    | Behavior                                             |
|--------------------------|------------------------------------------------------|
| Hover over segment        | Tooltip: name, rank, read count, percentage          |
| Click segment             | Zoom: that taxon becomes the new center, children expand to fill the ring |
| Click center circle       | Zoom out one level (or reset to root)                |
| Right-click segment       | Context menu: Extract reads, Copy taxon name, Show in NCBI |
| Scroll (pinch)            | Zoom in/out of ring detail                           |
| Cmd+click                 | Multi-select taxa (for combined extraction)          |

#### Hit Testing

```swift
override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    let dx = point.x - center.x
    let dy = point.y - center.y
    let radius = sqrt(dx * dx + dy * dy)
    let angle = atan2(dy, dx)  // normalize to [0, 2*pi)

    // Binary search rings by radius, then linear scan arcs by angle
    if let hit = hitTest(radius: radius, angle: angle) {
        if event.clickCount == 1 {
            zoomToTaxon(hit)
        }
    }
}
```

### 5.3 Table View (Companion)

A sortable `NSTableView` sits alongside the sunburst (right side or
below, user-resizable split). Columns:

| Column           | Width | Sort |
|-----------------|-------|------|
| Taxon Name       | flex  | alpha|
| Rank             | 60    | rank |
| Reads (clade)    | 80    | num  |
| Reads (direct)   | 80    | num  |
| % of Total       | 70    | num  |
| Bracken Est.     | 80    | num  |
| Bracken %        | 70    | num  |

The table and sunburst are linked: selecting a row highlights the
corresponding arc, and clicking an arc selects the table row.

### 5.4 Filter Bar

Above the table:

```
[magnifyingglass] Filter taxa... | Rank: [All v] | Min reads: [0____]
```

- Text filter matches taxon name (case-insensitive substring)
- Rank filter shows only a specific rank (e.g., "Species only")
- Min reads hides taxa below a threshold
- Filters apply to both table and sunburst rendering

---

## 6. Sequence Extraction

### 6.1 Extraction from Classification Results

When the user selects one or more taxa in the sunburst or table:

```
+----------------------------------------------------------+
|  Extract Reads                                           |
+----------------------------------------------------------+
|                                                          |
|  Selected taxon: Staphylococcus aureus (taxid: 1280)     |
|  Reads classified to this taxon: 12,847                  |
|  Including child taxa: 13,211 (+364 subspecies reads)    |
|                                                          |
|  Scope:                                                  |
|  (x) Include child taxa (recommended)                    |
|  ( ) Exact taxon match only                              |
|                                                          |
|  Output name: [S_aureus_reads_______________]            |
|                                                          |
|  [Cancel]                        [Extract Sequences]     |
+----------------------------------------------------------+
```

### 6.2 Extraction Pipeline

```
.kraken output file (per-read taxid assignments)
    |
    v
[extract_kraken_reads.py] (from KrakenTools)
    -k <kraken_output>
    -s <original_fastq_R1>
    -s2 <original_fastq_R2>      (if paired)
    -o <output_R1>
    -o2 <output_R2>              (if paired)
    -t <taxid>
    --include-children            (if scope = child taxa)
    --fastq-output
    |
    v
Extracted FASTQ files
    |
    v
[Create virtual FASTQ derivative]
    - Read ID list = extracted read IDs
    - Operation: .metagenomicsExtraction(taxid: 1280, taxonName: "S. aureus", includeChildren: true)
    - Appears in sidebar under parent FASTQ
```

### 6.3 Virtual FASTQ Integration

The extraction creates a new `FASTQDerivativeRequest` case:

```swift
extension FASTQDerivativeRequest {
    /// Metagenomics read extraction by taxonomy.
    case metagenomicsExtraction(
        krakenOutputPath: String,
        taxonIDs: [Int],
        includeChildren: Bool,
        taxonName: String    // for display label
    )
}
```

The derivative bundle stores:
- The read ID list (same as subsample derivatives)
- The taxonomy metadata in lineage

This integrates with the existing materialization lifecycle:
- Initially pointer-based (virtual) referencing the parent FASTQ
- Can be materialized to a standalone FASTQ on demand
- Appears in the sidebar with the taxon name as label

---

## 7. UI Wireframes

### 7.1 Main Metagenomics Results View

```
+=========================================================================+
| [<] SRR12345678 > Metagenomics Classification              [clock][^]  |
+=========================================================================+
|                                          |                              |
|     Color: [By Phylum | By Abundance]    | [magnifyingglass] Filter...  |
|                                          | Rank: [All v] Min: [0___]   |
|         ,---=====---.                    |-------------------------------|
|       /   Firmicutes  \                  | Taxon          Reads    %    |
|      / ,-----------. \                   |-------------------------------|
|     / / Bacillaceae \ \                  | [v] Bacteria   98,211  89.2% |
|    | | S. aureus     | |                 |   [v] Firmicutes 45,102 41.0%|
|    | |  12,847       | |                 |     Staphylococcaceae  13,211|
|    |  \             /  |                 |       S. aureus    12,847    |
|     \  `-----------'  /                  |       S. epidermidis  364    |
|      \  Proteobact.  /                   |     Bacillaceae    8,902     |
|       \             /                    |   [v] Proteobacteria  32,100 |
|        `---=====---'                     |     E. coli          21,300  |
|                                          |     ...                      |
|     [  Zoom: Root > Bacteria  ]          |-------------------------------|
|                                          | Selected: S. aureus (12,847) |
|                                          | [arrow.down.doc Extract]     |
|                                          | [square.and.arrow.up Export] |
+=========================================================================+
```

### 7.2 Database Manager Window

Accessible via menu: Tools > Manage Metagenomics Databases...

```
+=========================================================================+
| Metagenomics Database Manager                                    [X]   |
+=========================================================================+
| Installed                                                              |
|------------------------------------------------------------------------|
| [checkmark.circle.fill] Kraken2 Standard-16                           |
|   Version: 2024-09-04 | 16.2 GB | Verified 2 days ago                 |
|   ~/.lungfish/databases/kraken2/k2_standard16_20240904                 |
|   Bracken: 50bp, 75bp, 100bp, 150bp, 200bp, 250bp, 300bp              |
|   [Verify] [Move to...] [Delete]                                       |
|------------------------------------------------------------------------|
| [checkmark.circle.fill] Kraken2 Viral                                  |
|   Version: 2024-09-04 | 0.5 GB | Verified today                       |
|   ~/.lungfish/databases/kraken2/k2_viral_20240904                      |
|   [Verify] [Move to...] [Delete]                                       |
|------------------------------------------------------------------------|
| [externaldrive] Kraken2 PlusPF                                         |
|   Version: 2024-09-04 | 72 GB | /Volumes/BioData/...                  |
|   [exclamationmark.triangle] Volume "BioData" not mounted              |
|   [Relocate...] [Remove from list]                                     |
|------------------------------------------------------------------------|
| [circle.dashed] MetaPhlAn vOct22                                       |
|   Status: Downloading... 34% (11.2 / 33 GB)                           |
|   [==========--------] ETA: 12 min                                     |
|   [Cancel Download]                                                     |
|------------------------------------------------------------------------|
|                                                                        |
| [arrow.down.circle Download New...] [folder Add Existing...]           |
|                                                                        |
| Disk space: 89.2 GB available on Macintosh HD                          |
+=========================================================================+
```

### 7.3 Running Analysis (OperationCenter Integration)

Progress appears in the existing OperationCenter activity panel:

```
+--------------------------------------------------+
| [circle.hexagonpath] Metagenomics Classification  |
|   Kraken2: Classifying 2.4M reads...             |
|   [===================>------] 72%                |
|   Speed: 1.2M reads/min | ETA: 0:42              |
|   Database: Standard-16 | Threads: 10            |
|   [Cancel]                                        |
+--------------------------------------------------+
```

For Profile mode, a two-step progress:

```
+--------------------------------------------------+
| [chart.pie.fill] Metagenomics Profiling           |
|   Step 1/2: Kraken2 classification... [done]      |
|   Step 2/2: Bracken re-estimation...              |
|   [========================>-] 89%                |
|   [Cancel]                                        |
+--------------------------------------------------+
```

---

## 8. Data Model

### 8.1 New Types in LungfishWorkflow

```swift
// MARK: - MetagenomicsTool

/// Metagenomics tools managed by the system.
public enum MetagenomicsTool: String, Codable, Sendable {
    case kraken2
    case bracken
    case metaphlan
    case krakentools
}

// MARK: - DatabaseCollection

/// Pre-built database collections available for download.
public enum DatabaseCollection: String, Codable, Sendable, CaseIterable {
    case standard
    case standard8 = "standard-8"
    case standard16 = "standard-16"
    case plusPF = "pluspf"
    case plusPF8 = "pluspf-8"
    case plusPF16 = "pluspf-16"
    case viral
    case minusB
    case euPathDB46 = "eupathdb48"

    /// Human-readable display name.
    var displayName: String { ... }

    /// Approximate download size in bytes.
    var approximateSizeBytes: UInt64 { ... }

    /// Approximate RAM required for classification.
    var approximateRAMBytes: UInt64 { ... }

    /// Description of contents.
    var contentsDescription: String { ... }

    /// Base URL for downloading.
    var downloadURL: URL { ... }
}

// MARK: - MetagenomicsDatabase

/// A registered metagenomics database installation.
public struct MetagenomicsDatabase: Codable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public let tool: MetagenomicsTool
    public let collection: DatabaseCollection?
    public let version: String
    public let sizeBytes: UInt64
    public var location: DatabaseLocation
    public var lastVerified: Date?
    public var status: DatabaseStatus

    /// Available Bracken k-mer distribution files (read lengths).
    public var brackenReadLengths: [Int]?
}

public enum DatabaseLocation: Codable, Sendable {
    case local(path: String)
    case bookmark(data: Data, lastKnownPath: String)
}

public enum DatabaseStatus: String, Codable, Sendable {
    case ready
    case downloading
    case verifying
    case corrupt
    case volumeNotMounted
    case missing
}
```

### 8.2 New Types in LungfishIO

```swift
// MARK: - Kreport Parser

/// Parses a Kraken2 .kreport file into a TaxonNode tree.
public struct KreportParser {
    /// Parse a kreport file into a taxonomy tree.
    public static func parse(url: URL) throws -> TaxonTree

    /// Parse Bracken output and merge into existing tree.
    public static func mergeBracken(url: URL, into tree: inout TaxonTree) throws
}

/// Root of a parsed taxonomy tree with summary statistics.
public struct TaxonTree: Sendable {
    public let root: TaxonNode
    public let totalReads: Int
    public let classifiedReads: Int
    public let unclassifiedReads: Int
    public let unclassifiedFraction: Double

    /// Flattened list of all nodes for table display.
    public func allNodes() -> [TaxonNode]

    /// Find a node by taxid.
    public func node(taxid: Int) -> TaxonNode?

    /// All nodes at a specific rank.
    public func nodes(at rank: TaxonomicRank) -> [TaxonNode]
}
```

### 8.3 New FileFormat Cases

```swift
extension FileFormat {
    case kreport     // Kraken2 report
    case kraken      // Kraken2 per-read output
    case bracken     // Bracken re-estimated abundances
    case metaphlan   // MetaPhlAn profile
}
```

### 8.4 New ToolCategory Case

```swift
extension ToolCategory {
    case metagenomics  // icon: "circle.hexagonpath"
}
```

### 8.5 New OperationType Case

```swift
extension OperationType {
    case metagenomics = "Metagenomics"
}
```

---

## 9. Provenance Integration

Every metagenomics run records a full `WorkflowRun` via the existing
`ProvenanceRecorder`.

### 9.1 Classification Run Provenance

```json
{
  "id": "...",
  "name": "Metagenomics Classification",
  "appVersion": "Lungfish 1.3.0 (42)",
  "hostOS": "macOS 26.1 (arm64)",
  "startTime": "2026-03-22T14:30:00Z",
  "endTime": "2026-03-22T14:32:15Z",
  "status": "completed",
  "parameters": {
    "goal": { "type": "string", "value": "classify" },
    "precision": { "type": "string", "value": "sensitive" },
    "threads": { "type": "integer", "value": 10 }
  },
  "steps": [
    {
      "toolName": "kraken2",
      "toolVersion": "2.1.3",
      "command": [
        "kraken2", "--db", "/path/to/k2_standard16_20240904",
        "--threads", "10", "--confidence", "0.0",
        "--minimum-hit-groups", "2",
        "--report", "/path/to/output.kreport",
        "--output", "/path/to/output.kraken",
        "--paired",
        "/path/to/reads_R1.fastq.gz",
        "/path/to/reads_R2.fastq.gz"
      ],
      "inputs": [
        { "path": "reads_R1.fastq.gz", "sha256": "abc123...", "format": "fastq", "role": "input" },
        { "path": "reads_R2.fastq.gz", "sha256": "def456...", "format": "fastq", "role": "input" },
        { "path": "k2_standard16_20240904/", "role": "reference" }
      ],
      "outputs": [
        { "path": "output.kreport", "sha256": "...", "format": "kreport", "role": "report" },
        { "path": "output.kraken", "sha256": "...", "format": "kraken", "role": "output" }
      ],
      "exitCode": 0,
      "wallTime": 135.2,
      "peakMemoryBytes": 16200000000
    }
  ]
}
```

### 9.2 Profile Run Provenance (Two Steps)

The Bracken step records a `dependsOn` pointing to the Kraken2 step ID,
capturing the DAG:

```json
"steps": [
  {
    "id": "step-1-uuid",
    "toolName": "kraken2",
    "toolVersion": "2.1.3",
    "...": "..."
  },
  {
    "id": "step-2-uuid",
    "toolName": "bracken",
    "toolVersion": "2.9",
    "dependsOn": ["step-1-uuid"],
    "command": [
      "bracken", "-d", "/path/to/db",
      "-i", "/path/to/output.kreport",
      "-o", "/path/to/output.bracken",
      "-w", "/path/to/output.bracken.kreport",
      "-r", "150", "-l", "S", "-t", "10"
    ],
    "...": "..."
  }
]
```

### 9.3 Provenance Display

The results view includes a [clock] provenance button that shows:

```
+----------------------------------------------------------+
|  Analysis Provenance                              [X]    |
+----------------------------------------------------------+
|                                                          |
|  Run: Metagenomics Profiling                             |
|  Date: March 22, 2026 2:30 PM                            |
|  Duration: 2 min 15 sec                                  |
|  App: Lungfish 1.3.0                                     |
|  Host: macOS 26.1 (arm64)                                |
|                                                          |
|  Steps:                                                  |
|  1. kraken2 v2.1.3                                       |
|     DB: Standard-16 (2024-09-04)                         |
|     --confidence 0.0 --minimum-hit-groups 2              |
|     Wall time: 2m 10s | Peak RAM: 16.2 GB               |
|                                                          |
|  2. bracken v2.9                                         |
|     -r 150 -l S -t 10                                    |
|     Wall time: 5s                                        |
|                                                          |
|  Input: SRR12345678_R1.fastq.gz (sha256: abc123...)      |
|         SRR12345678_R2.fastq.gz (sha256: def456...)      |
|                                                          |
|  [square.and.arrow.up Export as JSON]                    |
|  [doc.on.clipboard Copy Commands]                        |
+----------------------------------------------------------+
```

---

## 10. Implementation Plan

### Phase 1: Foundation (2-3 weeks)

**LungfishWorkflow additions:**
- [ ] `MetagenomicsDatabaseRegistry` actor
- [ ] `DatabaseCollection` enum with download URLs and metadata
- [ ] `MetagenomicsDatabase` model with bookmark-based relocation
- [ ] Download integration with `OperationCenter` (resume support)
- [ ] Database verification (check hash.k2d, opts.k2d, taxo.k2d exist)

**LungfishIO additions:**
- [ ] `KreportParser` -- parse .kreport into `TaxonTree`
- [ ] `KrakenOutputParser` -- parse .kraken per-read assignments
- [ ] `TaxonNode` / `TaxonTree` data model
- [ ] `BrackenParser` -- merge Bracken output into tree
- [ ] New `FileFormat` cases: `.kreport`, `.kraken`, `.bracken`, `.metaphlan`

**CondaManager integration:**
- [ ] `lungfish-metagenomics` environment definition
- [ ] Auto-detect existing kraken2/bracken/metaphlan in PATH
- [ ] Tool version detection for provenance

### Phase 2: Classification Pipeline (1-2 weeks)

**LungfishWorkflow:**
- [ ] `MetagenomicsClassificationPipeline` -- orchestrates kraken2 execution
- [ ] `MetagenomicsProfilingPipeline` -- kraken2 + bracken
- [ ] Parameter presets (sensitive / balanced / precise)
- [ ] Paired-end detection from FASTQ bundle metadata
- [ ] Read length auto-detection for Bracken

**LungfishApp:**
- [ ] `MetagenomicsGoalPicker` -- step 1 sheet (classify / profile / extract)
- [ ] `MetagenomicsDatabasePicker` -- step 2 sheet with recommendation
- [ ] `MetagenomicsParameterPanel` -- step 3 with precision slider
- [ ] OperationCenter progress integration
- [ ] Provenance recording for all steps

### Phase 3: Sunburst Visualization (2-3 weeks)

**LungfishApp/Views/Metagenomics/:**
- [ ] `TaxonomySunburstView` -- CoreGraphics sunburst renderer
  - [ ] Arc segment drawing with proper anti-aliasing
  - [ ] Color schemes (by phylum, by abundance)
  - [ ] Zoom interaction (click to drill, click center to back)
  - [ ] Hover tooltips via `HoverTooltipView` (existing)
  - [ ] Hit testing (radius + angle lookup)
  - [ ] Text labels along arcs
  - [ ] Animation for zoom transitions
- [ ] `TaxonomyTableView` -- NSTableView with sortable columns
- [ ] `TaxonomyFilterBar` -- text filter + rank picker + min reads
- [ ] `MetagenomicsResultsViewController` -- split view: sunburst + table
- [ ] Bidirectional selection sync between sunburst and table

### Phase 4: Sequence Extraction (1 week)

**LungfishWorkflow:**
- [ ] `MetagenomicsExtractionPipeline` -- wraps extract_kraken_reads.py
- [ ] New `FASTQDerivativeRequest.metagenomicsExtraction` case
- [ ] Read ID list generation from kraken output + taxid filter

**LungfishApp:**
- [ ] Extraction sheet UI (scope picker, output name)
- [ ] Virtual FASTQ derivative creation
- [ ] Sidebar integration (extracted reads appear under parent)

### Phase 5: Database Management UI (1 week)

**LungfishApp/Views/Metagenomics/:**
- [ ] `DatabaseManagerWindowController` -- standalone window
- [ ] Database download sheet with RAM recommendation
- [ ] Move/relocate to external volume
- [ ] Add existing database from disk
- [ ] Verify database integrity
- [ ] Bookmark resolution for external volumes

### Phase 6: Export and Polish (1 week)

- [ ] Export taxonomy table as TSV/CSV
- [ ] Export sunburst as PDF/PNG
- [ ] Export filtered FASTQ (materialized)
- [ ] MetaPhlAn integration (alternative profiler)
- [ ] Provenance export as JSON and as shell script
- [ ] Accessibility: VoiceOver labels for sunburst segments
- [ ] Keyboard navigation in sunburst (arrow keys traverse tree)

---

## Appendix A: File Layout

```
Sources/
  LungfishWorkflow/
    Metagenomics/
      MetagenomicsDatabaseRegistry.swift
      MetagenomicsClassificationPipeline.swift
      MetagenomicsProfilingPipeline.swift
      MetagenomicsExtractionPipeline.swift
      DatabaseCollection.swift
      MetagenomicsDatabase.swift
  LungfishIO/
    Formats/
      Kraken/
        KreportParser.swift
        KrakenOutputParser.swift
        BrackenParser.swift
        TaxonNode.swift
        TaxonTree.swift
  LungfishApp/
    Views/
      Metagenomics/
        MetagenomicsGoalPicker.swift
        MetagenomicsDatabasePicker.swift
        MetagenomicsParameterPanel.swift
        MetagenomicsResultsViewController.swift
        TaxonomySunburstView.swift
        TaxonomyTableView.swift
        TaxonomyFilterBar.swift
        DatabaseManagerWindowController.swift
        DatabaseDownloadSheet.swift
    ViewModels/
      MetagenomicsAnalysisViewModel.swift
    Services/
      MetagenomicsService.swift
```

## Appendix B: Memory Budget Estimates

| Database      | RAM for classification | RAM for mmap mode  |
|--------------|----------------------|--------------------|
| Standard      | ~67 GB               | ~2 GB + disk I/O   |
| Standard-16   | ~16 GB               | ~2 GB + disk I/O   |
| Standard-8    | ~8 GB                | ~1 GB + disk I/O   |
| PlusPF        | ~72 GB               | ~2 GB + disk I/O   |
| PlusPF-16     | ~16 GB               | ~2 GB + disk I/O   |
| Viral         | ~0.5 GB              | ~0.2 GB            |

When mmap mode is used (the `--memory-mapping` flag), Kraken2 uses
the OS page cache instead of loading the entire hash table into RAM.
This is dramatically slower (5-10x) but allows using databases that
exceed available RAM. The UI recommends mmap mode automatically
when the database exceeds 80% of available RAM.

## Appendix C: Kraken2 Output Formats

### .kreport (tab-delimited, 6 columns)

```
 58.23  1234567  1234567  U  0         unclassified
 41.77   885432   2345    R  1         root
 41.72   884234   1234    R1 131567      cellular organisms
 39.88   845123    456    D  2           Bacteria
 ...
```

Columns:
1. % of total reads classified at or below this taxon
2. Number of reads classified at or below this taxon
3. Number of reads classified directly to this taxon
4. Rank code (U, R, D, K, P, C, O, F, G, S, -)
5. NCBI taxonomy ID
6. Scientific name (indented by rank depth)

### .kraken (tab-delimited, 5 columns)

```
C  read_1  562  150  562:120 0:30
U  read_2  0    150  0:150
```

Columns:
1. C (classified) or U (unclassified)
2. Read ID
3. Assigned taxonomy ID (0 if unclassified)
4. Read length
5. Space-delimited list of taxid:kmer_count pairs

## Appendix D: Security-Scoped Bookmarks for External Volumes

```swift
/// Create a bookmark when the user selects a database directory.
func createBookmark(for url: URL) throws -> Data {
    return try url.bookmarkData(
        options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
    )
}

/// Resolve a bookmark when accessing the database later.
func resolveBookmark(_ data: Data) -> URL? {
    var isStale = false
    guard let url = try? URL(
        resolvingBookmarkData: data,
        options: .withSecurityScope,
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
    ) else { return nil }

    if isStale {
        // Re-create bookmark with current mount point
    }

    guard url.startAccessingSecurityScopedResource() else { return nil }
    // Remember to call url.stopAccessingSecurityScopedResource() when done
    return url
}
```
