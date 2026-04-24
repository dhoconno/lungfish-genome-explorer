# Lungfish Genome Explorer - Comprehensive Development Plan

## Project Configuration
- **Licensing**: Open Source (MIT/Apache)
- **Collaboration Model**: Single-user per project
- **Assembly Support**: Built-in SPAdes/MEGAHIT + plugin extensibility
- **Primer Design**: Full Primer3 integration with PrimalScheme multiplex support
- **Platform**: macOS only (Apple Silicon M1+, no cross-platform)
- **Architecture**: Native ARM64, Rosetta 2 for x64 plugin tools
- **Containers**: Docker/Apptainer support for workflow tools

---

## Executive Summary

Build a next-generation macOS-native genome browser in Swift that combines:
- **IGV's strengths**: Fast track-based visualization, extensive format support, filesystem-based data access
- **Geneious's strengths**: Rich sequence editing, annotations, operations, and plugin ecosystem
- **Novel features**: Nextflow/Snakemake workflow integration, diff-based version history, NCBI/ENA data access

Target users: Researchers working with moderate-scale genomic data on laptop/desktop Macs.

---

## macOS Design Philosophy

### Apple Human Interface Guidelines Compliance
This app must be a **lovingly crafted native macOS experience**, not a cross-platform port.

#### Core Principles
- **Familiar**: Use standard macOS patterns users already know
- **Consistent**: Match system appearance, controls, and behaviors
- **Intuitive**: Leverage platform conventions for discoverability
- **Accessible**: Full VoiceOver and accessibility support

#### macOS-Specific Features to Leverage

**Window Management**
- Native `NSWindow` with proper resize/minimize/full-screen behavior
- Window tabs (Cmd+T for new tab, merge windows)
- Split view support for multi-document comparison
- Stage Manager compatibility
- Desktop widgets for quick project access

**System Integration**
- Spotlight indexing for project files and sequences
- Quick Look previews for genomic file formats
- Services menu integration (right-click actions)
- Share sheet for exporting sequences
- Handoff support (continue work on another Mac)
- Time Machine friendly project structure

**Native Controls**
- NSOutlineView for file browser (not custom tree)
- NSTableView with sorting/filtering
- NSSearchField with tokens and suggestions
- NSToolbar with customizable items
- NSTouchBar support for relevant controls
- Menu bar with full keyboard shortcuts

**Visual Design**
- SF Symbols for all icons
- System colors that adapt to Dark/Light mode
- Vibrancy and materials where appropriate
- Proper sidebar/inspector patterns
- Native popovers and sheets (not modal dialogs)

**Performance**
- Grand Central Dispatch for concurrency
- Metal for GPU-accelerated rendering
- Core Data/SwiftData for metadata (NOT sequence data)
- Efficient memory mapping via mmap()
- Background App Refresh for long operations

### Three-Pane Layout (macOS Native)
```
┌─────────────────────────────────────────────────────────────┐
│ Toolbar: Navigation │ Zoom │ Tools │ Search        [Window] │
├──────────────┬──────────────────────────────────────────────┤
│              │  Inspector/Detail Area                       │
│   Source     │  ┌────────────────────────────────────────┐  │
│   List       │  │  Document List (NSTableView)           │  │
│              │  │  - Name, Type, Size, Modified          │  │
│  (Sidebar)   │  └────────────────────────────────────────┘  │
│              │  ┌────────────────────────────────────────┐  │
│  NSOutline   │  │  Sequence Viewer                       │  │
│  View        │  │  (Custom NSView with Metal rendering)  │  │
│              │  │                                        │  │
│              │  │  Tracks, annotations, reads...         │  │
│              │  └────────────────────────────────────────┘  │
├──────────────┴──────────────────────────────────────────────┤
│ Status Bar: Position │ Selection │ Progress                 │
└─────────────────────────────────────────────────────────────┘
```

### Platform Requirements
| Requirement | Specification |
|-------------|---------------|
| Minimum macOS | macOS 14 Sonoma |
| Architecture | Apple Silicon (M1/M2/M3+) native |
| x64 Support | Rosetta 2 for plugin tools only |
| Memory | 8GB minimum, 16GB+ recommended |
| Storage | SSD required for index performance |

### Container Support for Workflows

**Docker Desktop for Mac**
- Detect Docker installation
- Pull bioinformatics images (biocontainers)
- Run containerized tools via workflow system
- Volume mounting for project data

**Apptainer (Singularity)**
- Support for HPC-style containers
- Convert Docker images to SIF format
- Run without root privileges
- Integrate with Nextflow/Snakemake

---

## Team Structure (20 Specialists)

Role definition files are in the `roles/` directory:

### Core Development Team
1. **Swift Architecture Lead** - `roles/01-swift-architect.md`
2. **UI/UX Lead - HIG Expert** - `roles/02-ui-ux-lead.md`
3. **Sequence Viewer Specialist** - `roles/03-sequence-viewer.md`
4. **Track Rendering Engineer** - `roles/04-track-rendering.md`

### Bioinformatics Core
5. **Bioinformatics Architect** - `roles/05-bioinformatics-architect.md`
6. **File Format Expert** - `roles/06-file-formats.md`
7. **Sequence Assembly Specialist** - `roles/07-assembly-specialist.md`
8. **Alignment & Mapping Expert** - `roles/08-alignment-expert.md`

### Primer & PCR Team
9. **Primer Design Lead** - `roles/09-primer-design.md`
10. **PCR Simulation Specialist** - `roles/10-pcr-simulation.md`
11. **PrimalScheme Expert** - `roles/11-primalscheme.md`

### Data & Integration
12. **NCBI/Database Integration Lead** - `roles/12-ncbi-integration.md`
13. **ENA Integration Specialist** - `roles/13-ena-integration.md`
14. **Workflow Integration Lead** - `roles/14-workflow-integration.md`

### Plugin & Extensibility
15. **Plugin Architecture Lead** - `roles/15-plugin-architect.md`
16. **Visual Workflow Builder** - `roles/16-workflow-builder.md`

### Data Management
17. **Version Control Specialist** - `roles/17-version-control.md`
18. **Storage & Indexing Lead** - `roles/18-storage-indexing.md`

### Quality & Testing
19. **Testing & QA Lead** - `roles/19-testing-qa.md`
20. **Documentation & Community Lead** - `roles/20-docs-community.md`

---

## Core Architecture

### Technology Stack
| Component | Technology | Rationale |
|-----------|------------|-----------|
| Language | Swift 5.9+ | Native macOS performance, memory safety |
| UI Framework | AppKit primary + SwiftUI | AppKit for complex views, SwiftUI for settings/dialogs |
| Window System | NSWindowController, NSSplitViewController | Native macOS window management |
| Rendering | Core Graphics + Metal | GPU acceleration for track rendering |
| Data Persistence | File-based (JSON/GFF3/FASTA) + SwiftData | Avoids Geneious database corruption issues |
| Concurrency | Swift async/await + actors | Modern, safe concurrency |
| C Libraries | htslib bindings via Swift C interop | BAM/CRAM/VCF support |
| Icons | SF Symbols | Native, scalable, Dark Mode aware |
| Containers | Docker/Apptainer | Plugin tool execution |
| Build | Xcode 15+, Swift Package Manager | Native toolchain |

---

## Module Structure

```
LungfishGenomeBrowser/
├── LungfishCore/           # Core data models, services
│   ├── Models/             # Sequence, Annotation, Alignment, Document
│   ├── Services/           # NCBI, ENA, data loading
│   ├── Versioning/         # Diff engine, version history
│   ├── Translation/        # Codon tables, amino acid translation
│   └── Storage/            # Document storage, project management
├── LungfishIO/             # File format handling
│   ├── Formats/            # FASTA, FASTQ, BAM, VCF, GFF, BigWig, GenBank
│   ├── Compression/        # Zstandard, gzip, BGZF
│   └── Index/              # FAI, BAI, CSI, TBI, R-tree
├── LungfishUI/             # Rendering and track system
│   ├── Rendering/          # Track, ReferenceFrame, TileCache, MetalRenderer
│   ├── Tracks/             # SequenceTrack, FeatureTrack, AlignmentTrack
│   └── Renderers/          # Specialized renderers
├── LungfishPlugin/         # Plugin system
│   ├── Protocols/          # Plugin type definitions
│   └── Manager/            # Discovery, loading, lifecycle
├── LungfishWorkflow/       # Workflow integration
│   ├── Nextflow/           # Runner, schema parser
│   ├── Snakemake/          # Runner, config parser
│   └── VisualBuilder/      # Graph model, canvas, exporters
└── LungfishApp/            # macOS application
    ├── Views/              # Main UI components
    └── ViewModels/         # State management
```

---

## Data Models

### Sequence Representation
```swift
struct Sequence: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let alphabet: SequenceAlphabet  // .dna, .rna, .protein
    private let storage: SequenceStorage  // 2-bit encoding for DNA

    var length: Int
    subscript(range: Range<Int>) -> SequenceView  // Efficient subsequence
    func translate(frame: ReadingFrame, codonTable: CodonTable) -> AminoAcidSequence?
}
```

### Annotation System
```swift
struct SequenceAnnotation: Identifiable, Codable {
    let id: UUID
    var type: AnnotationType  // gene, CDS, exon, primer, restriction, etc.
    var name: String
    var intervals: [AnnotationInterval]  // Supports discontinuous features
    var strand: Strand
    var qualifiers: [String: AnnotationQualifier]
    var color: Color?
}
```

### Document Container
```swift
class GenomicDocument: ObservableObject, Identifiable {
    let id: UUID
    var name: String
    var filePath: URL
    var documentType: DocumentType
    var metadata: DocumentMetadata
    var annotations: [SequenceAnnotation]
    var history: VersionHistory  // Diff-based version control
}
```

---

## File Format Support

### Sequence Formats
| Format | Extensions | Index | Notes |
|--------|------------|-------|-------|
| FASTA | .fa, .fasta, .fna | .fai | Memory-mapped for large files |
| FASTQ | .fq, .fastq | - | Quality scores preserved |
| GenBank | .gb, .gbk | - | Full annotation preservation |
| 2bit | .2bit | Built-in | UCSC format |

### Alignment Formats
| Format | Extensions | Index | Notes |
|--------|------------|-------|-------|
| BAM | .bam | .bai, .csi | Via htslib |
| CRAM | .cram | .crai | Reference-based compression |
| SAM | .sam | - | Text format |

### Annotation Formats
| Format | Extensions | Index | Notes |
|--------|------------|-------|-------|
| GFF3 | .gff, .gff3 | Tabix | Parent-child relationships |
| GTF | .gtf | Tabix | Gene prediction format |
| BED | .bed | Tabix | Simple features |
| VCF | .vcf | .tbi | Variants |
| BigBed | .bb | R-tree | Large annotation sets |

### Signal/Coverage
| Format | Extensions | Index | Notes |
|--------|------------|-------|-------|
| BigWig | .bw | R-tree | Zoom level support |
| bedGraph | .bedgraph | - | Simple coverage |

### Compression Support
- **gzip** (.gz) - Standard
- **BGZF** - Block-gzip for random access
- **Zstandard** (.zst) - Modern, efficient compression

---

## Rendering Pipeline

### Reference Frame (from IGV)
Key parameters from `ReferenceFrame.java`:
- `binsPerTile = 700` - Pixels per tile
- `maxZoom = 23` - Maximum zoom levels
- `minBP = 40` - Minimum visible base pairs
- `scale` - Base pairs per pixel
- `origin` - Start position in bp

### Track System
```swift
protocol Track: Identifiable {
    var id: UUID { get }
    var name: String { get set }
    var height: CGFloat { get set }
    var displayMode: DisplayMode { get set }  // collapsed, squished, expanded

    func isReady(for frame: ReferenceFrame) -> Bool
    func load(for frame: ReferenceFrame) async throws
    func render(context: RenderContext, rect: CGRect)
}
```

### Track Types
1. **SequenceTrack** - Reference bases, translation frames
2. **FeatureTrack** - Annotations with row packing
3. **AlignmentTrack** - BAM/CRAM reads with coverage
4. **CoverageTrack** - Signal data (BigWig)
5. **VariantTrack** - VCF variants

### Tile-Based Caching
```swift
actor TileCache {
    struct TileKey: Hashable {
        let trackId: UUID
        let chromosome: String
        let tileIndex: Int
        let zoom: Int
    }
    // LRU eviction for rendered tiles
}
```

---

## Version Control System

### Diff-Based Editing
Store edits as VCF-like deltas instead of full copies:
```
#CHROM  POS     REF     ALT     INFO
chr1    15234   A       G       TYPE=snp
chr1    20100   ACTG    A       TYPE=del
chr1    25000   C       CGTA    TYPE=ins
```

### Content-Addressable Storage
Git-like object store for edit history:
```
.lgb/history/objects/
├── aa/
│   └── bb1234...  # SHA-256 hash of edit delta
└── refs/
    ├── main       # Current state pointer
    └── tags/
```

---

## Assembly System

### Built-in Assemblers
Both SPAdes and MEGAHIT are supported out of the box without plugins.

#### SPAdes Integration
```swift
struct SPAdesOptions {
    var kmerSizes: [Int] = [21, 33, 55, 77]  // Auto or manual
    var coverageCutoff: CoverageCutoff = .auto
    var carefulMode: Bool = true  // Mismatch correction
    var metaMode: Bool = false  // Metagenomics mode
    var threads: Int = ProcessInfo.processInfo.activeProcessorCount
    var memoryLimit: Int = 16  // GB
}
```

#### MEGAHIT Integration
```swift
struct MEGAHITOptions {
    var kMin: Int = 21
    var kMax: Int = 141
    var kStep: Int = 12
    var minContigLen: Int = 200
    var threads: Int = ProcessInfo.processInfo.activeProcessorCount
    var memoryFraction: Double = 0.9
}
```

---

## Primer Design System

### Primer3 Integration
Full Primer3 integration with comprehensive parameter exposure including Tm, GC content, product size, and thermodynamic parameters.

### PCR Simulation Features
- In-silico PCR with mismatch tolerance
- Amplicon prediction from reference
- Off-target binding detection
- Multiplexed reaction simulation
- Gel electrophoresis visualization

### PrimalScheme Multiplex Support
- Visual tiling scheme display
- Pool balance optimization
- Dimer checking across pools
- Export to standard formats (BED, TSV)
- Integration with ARTIC-style workflows

---

## Plugin Architecture

### Multi-Language Plugin System

Unlike Geneious's Java/Groovy-only approach, we support **multiple plugin languages**:

| Language | Use Case | Binding Method | Ecosystem Access |
|----------|----------|----------------|------------------|
| **Python** | Data science, bioinformatics | Embedded Python (PythonKit) | BioPython, NumPy, Pandas |
| **Rust** | High-performance algorithms | Swift-Rust FFI via C ABI | rust-bio, needletail |
| **Swift** | Deep UI integration | Native | Full AppKit/SwiftUI access |
| **Command-line** | Existing tools | Process execution | Any CLI tool |

### Plugin Categories
1. **SequenceOperationPlugin** - Transform sequences (any language)
2. **AnnotationGeneratorPlugin** - Generate annotations (any language)
3. **AssemblerPlugin** - Assembly algorithms (Rust/Swift recommended)
4. **AlignmentPlugin** - Alignment algorithms (Rust/Swift recommended)
5. **ViewerPlugin** - Custom visualization (Swift only)
6. **DatabasePlugin** - Data sources (Python ideal)
7. **FormatPlugin** - Import/export formats (any language)
8. **WorkflowPlugin** - Nextflow/Snakemake integration (Python/CLI)

---

## Workflow Integration

### Nextflow Integration
- Parse `nextflow_schema.json` for native macOS parameter UI
- Run workflows via `nextflow run`
- Monitor execution progress with NSProgress
- Auto-import outputs
- Support `-profile docker` and `-profile apptainer`
- Integration with nf-core pipelines

### Snakemake Integration
- Parse config.yaml schemas
- Run via `snakemake` CLI
- DAG visualization (native macOS graph view)
- Container execution via `--use-singularity` or `--use-docker`

### Visual Workflow Builder
- Native macOS node canvas (not web-based)
- Drag-and-drop from SF Symbols palette
- Connect operations with data flow
- Export to Nextflow DSL2 or Snakemake rules

---

## Database Services

### NCBI Entrez
- **esearch** - Search nucleotide, protein, SRA databases
- **efetch** - Download GenBank format with full annotations
- **SRA** - Download via prefetch + fasterq-dump

### ENA Portal
- Search via Portal API
- Download EMBL format
- Preserve all annotations

---

## Project File Structure

```
my-project.lgb/
├── project.json              # Project manifest
├── .lgb/
│   ├── metadata.sqlite       # Searchable metadata only
│   ├── history/              # Version history (git-like)
│   └── index/                # Generated indices, cache
├── sequences/
│   ├── manifest.json         # Sequence registry
│   └── *.fa                  # Sequence files (or symlinks)
├── annotations/
│   ├── layers.json           # Annotation layer registry
│   └── *.gff3                # Annotation layers
└── exports/                  # Export staging
```

---

## Implementation Phases

### Phase 1: Foundation (8-10 weeks)
1. Set up Swift Package structure
2. Implement core data models (Sequence, Annotation, Document)
3. Build basic file readers (FASTA, GFF3, GenBank)
4. Create AppKit-based sequence viewer with base rendering
5. Implement three-pane UI shell

### Phase 2: Format Support (6-8 weeks)
1. Add htslib bindings for BAM/CRAM
2. Implement VCF reader
3. Add BigWig/BigBed support
4. Implement Zstandard compression
5. Build index management system

### Phase 3: Editing & Versioning (6-8 weeks)
1. Implement sequence editing (base selection, modification)
2. Build annotation editing UI
3. Create diff engine for version history
4. Implement content-addressable storage
5. Add undo/redo support

### Phase 4: Plugin System (4-6 weeks)
1. Define plugin protocols
2. Build plugin manager with dynamic loading
3. Create built-in plugins (restriction sites, ORF finder)
4. Develop plugin development SDK
5. Add translation operations

### Phase 5: Database Integration (4-6 weeks)
1. Implement NCBI Entrez service
2. Implement ENA Portal service
3. Build search/download UI
4. Add SRA download support
5. Ensure annotation preservation

### Phase 6: Workflow Integration (6-8 weeks)
1. Implement Nextflow runner
2. Implement Snakemake runner
3. Build parameter UI generator
4. Create visual workflow builder
5. Add workflow export (Nextflow/Snakemake)

### Phase 7: Polish & Testing (4-6 weeks)
1. Performance optimization
2. Memory profiling for large files
3. Comprehensive testing
4. Documentation
5. Beta testing

---

## Critical Implementation Files

| File | Purpose |
|------|---------|
| `LungfishCore/Models/Sequence.swift` | Core sequence with 2-bit encoding |
| `LungfishUI/Rendering/ReferenceFrame.swift` | Coordinate system (IGV pattern) |
| `LungfishIO/Formats/BAMReader.swift` | htslib bindings for alignments |
| `LungfishPlugin/Protocols/PluginProtocols.swift` | Plugin type definitions |
| `LungfishCore/Versioning/SequenceDiff.swift` | Diff engine for version control |
| `LungfishApp/Views/SequenceViewer/SequenceViewerView.swift` | AppKit sequence viewer |
| `LungfishWorkflow/Nextflow/NextflowRunner.swift` | Workflow execution |
| `LungfishCore/Services/NCBIService.swift` | NCBI data access |

---

## Decisions Confirmed

| Question | Decision |
|----------|----------|
| Assembly | Built-in SPAdes + MEGAHIT, extensible via plugins |
| Primer Design | Full Primer3 + PrimalScheme multiplex support |
| Collaboration | Single-user only |
| Licensing | Open source (MIT/Apache) |
| Cloud Storage | Local only (avoids Geneious-style corruption) |
| Geneious Import | Nice to have (defer to later phase) |

---

## First Implementation Sprint

### Week 1-2: Foundation
1. Create all 20 role files with detailed specifications ✓
2. Set up Swift Package structure with modules
3. Implement core `Sequence` model with 2-bit encoding
4. Build basic FASTA parser
5. Create three-pane UI shell

### Week 3-4: Core Features
1. Implement `SequenceAnnotation` model
2. Build GFF3 and GenBank parsers
3. Create AppKit sequence viewer component
4. Implement basic navigation (zoom, pan)
5. Add FASTQ reader with quality scores

---

## Notes

- This plan was developed through comprehensive analysis of IGV source code, Geneious devkit API, and industry research
- IGV reference: `igv/src/main/java/org/igv/`
- Geneious reference: `geneious/geneious-2026.0.2-devkit/`
- Role specifications: `roles/*.md`
