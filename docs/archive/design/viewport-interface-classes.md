# Viewport Interface Classes

## Overview

Tool results in Lungfish share viewport layouts based on the *type of output*, not the specific tool that produced them. This enables rapid addition of new tools by reusing proven visualization patterns with tool-specific customizations.

## Interface Class 1: Taxonomy Browser (Classification Results)

**Used by:** Kraken2, EsViritu, TaxTriage, NAO-MGS, future classifiers

**Layout:**
```
+--------------------------------------------------+
| Summary Bar (metric cards)                       |
+--------------------------------------------------+
| Taxonomy Table    |  Detail Pane                  |
|                   |  - Coverage / Charts          |
| Taxon list with   |  - Statistics                 |
| read counts,      |  - Accession list             |
| sorted/filterable |                               |
+-------------------+-------------------------------+
| Action Bar (Export, BLAST, Selection info)        |
+--------------------------------------------------+
```

**Common features:**
- Taxonomy table (NSTableView, sortable columns, right-click BLAST)
- Summary bar with metric cards (total reads, unique taxa, top taxon, sample)
- Export to CSV/TSV
- BLAST verification context menu
- Action bar with export and selection info

**Tool-specific variations:**
| Tool | Detail Pane | Extra Features |
|------|------------|----------------|
| Kraken2 | Sunburst chart + hierarchical tree | Bracken abundance, extraction sheet |
| EsViritu | Detection table + BAM viewer | Assembly coverage, viral contigs |
| TaxTriage | Report PDF + Krona HTML | TASS confidence, multi-sample |
| NAO-MGS | Coverage plots + edit distance histogram | Fragment length dist, multi-sample heatmap |

**Base class:** `TaxonomyResultViewController`
- Provides: summary bar, taxonomy table, action bar, BLAST wiring, export
- Subclasses override: detail pane content, metric card configuration, table columns

## Interface Class 2: Alignment Viewer (Read Mapping Results)

**Used by:** minimap2, BWA-MEM2, Bowtie2, HISAT2, future aligners

**Layout:**
```
+--------------------------------------------------+
| Summary Bar (total reads, mapped %, reference)   |
+--------------------------------------------------+
| Reference Track (ruler + annotations)            |
+--------------------------------------------------+
| Read Pileup (alignment viewer)                   |
| ==========================================       |
| ====   ====   ====   ====   ====                 |
|   ====   ====   ====   ====                      |
+--------------------------------------------------+
| Coverage Depth Track                             |
+--------------------------------------------------+
| Mapping Statistics Panel                         |
+--------------------------------------------------+
```

**Common features:**
- Sorted indexed BAM display (reuse existing BAM viewport)
- Coverage depth track
- Mapping quality distribution
- Insert size distribution (paired-end)
- Flagstat summary (mapped/unmapped/duplicates)
- Reference sequence with annotations

**Tool-specific variations:**
| Tool | Specialty |
|------|-----------|
| minimap2 | Supports long reads, splice-aware, supplementary alignments |
| BWA-MEM2 | Short-read focused, paired-end emphasis |
| Bowtie2 | End-to-end vs local alignment mode indicator |
| HISAT2 | Splice junction visualization for RNA-seq |

**Base class:** `AlignmentResultViewController`
- Provides: BAM viewport integration, coverage track, stats panel
- Tool metadata shown in summary bar (aligner name, preset, version)
- Identical viewport — differences are in the BAM content, not the viewer

## Interface Class 3: Assembly Viewer (Assembly Results)

**Used by:** SPAdes, MEGAHIT, Flye, hifiasm, future assemblers

**Layout:**
```
+--------------------------------------------------+
| Summary Bar (contigs, N50, total length, GC%)    |
+--------------------------------------------------+
| Contig Table       |  Contig Detail               |
|                    |  - Sequence viewer            |
| Name, Length,      |  - Coverage depth             |
| Coverage, GC%      |  - Annotations (if aligned)  |
+--------------------+-----------------------------+
| Assembly Statistics Panel                        |
| - Nx plot, Length distribution, GC distribution  |
+--------------------------------------------------+
```

**Common features:**
- Contig/scaffold table (sortable by length, coverage, GC%)
- Assembly statistics (N50, L50, N90, total length, largest contig)
- Nx curve plot (cumulative length vs contig rank)
- Length distribution histogram
- GC content distribution
- FASTA sequence viewer for selected contig
- Export contigs (FASTA, GFA)

**Tool-specific variations:**
| Tool | Specialty |
|------|-----------|
| SPAdes | Assembly graph (GFA), scaffolds, error-corrected reads |
| MEGAHIT | Multiple k-mer intermediate assemblies |
| Flye | Repeat graph, long-read assembly stats |
| hifiasm | Haplotype-resolved assembly (primary + alternate) |

**Base class:** `AssemblyResultViewController`
- Provides: contig table, stats panel, Nx plot, sequence viewer
- Subclasses add: tool-specific views (assembly graph, haplotype toggle)

## Interface Class 4: Sequence Viewer (Read/Sequence Data)

**Used by:** FASTQ datasets, FASTA collections, imported reads

**Layout:**
```
+--------------------------------------------------+
| Summary Bar (read count, base count, quality)    |
+--------------------------------------------------+
| Sparklines (length, Q/position, Q score dist)    |
+--------------------------------------------------+
| Operations Sidebar |  Read/Sequence View          |
|                    |  - Raw sequence browser       |
| FASTQ operations   |  - Quality visualization     |
| (trim, filter,     |  - Read statistics            |
|  classify, etc.)   |                               |
+--------------------+------------------------------+
| Inspector (metadata, stats, ENA metadata)        |
+--------------------------------------------------+
```

**Common features:**
- Read/sequence browser with raw text or formatted view
- Quality score visualization (per-position, distribution)
- Length distribution sparklines
- Read count and base count statistics
- Operations sidebar for FASTQ preprocessing

**Data type variations:**
| Type | Specialty |
|------|-----------|
| FASTQ | Quality scores, paired-end, operations panel |
| FASTA | Sequence only (no quality), annotation overlay |
| FASTA collection | Multi-sequence browsing, selection |

**Existing implementation:** `FASTQDatasetViewController` (FASTQ), `ViewerViewController` (FASTA)
- FASTA also serves as the **reference backbone** for Alignment and Variant viewers

## Interface Class 5: Variant Browser (Variant Calling Results)

**Used by:** VCF import, FreeBayes, LoFreq, GATK, iVar, future callers

**Layout:**
```
+--------------------------------------------------+
| Summary Bar (variants, SNPs, indels, samples)    |
+--------------------------------------------------+
| Variant Table      |  Variant Detail              |
|                    |  - Allele frequencies         |
| CHROM, POS, REF,  |  - Sample genotypes           |
| ALT, QUAL, FILTER |  - Annotation (if available)  |
+--------------------+-----------------------------+
| Genome Context (ruler + variant track)           |
| [FASTA reference provides coordinate axis and    |
|  base-level context for variant interpretation]  |
+--------------------------------------------------+
```

**Already implemented** as the existing VCF viewport. Future variant callers
produce VCF files that are displayed using this same interface.

**FASTA as shared infrastructure:** The reference FASTA serves as the coordinate
backbone for both the Alignment Viewer (Class 2) and the Variant Browser (Class 5).
When a reference bundle is loaded, its sequence and annotations are available to
both alignment pileup rendering and variant context display.

## Implementation Strategy

### Protocol-Based Architecture

```swift
/// Base protocol for all result viewport controllers.
protocol ResultViewportController: NSViewController {
    /// The type of result this viewport displays.
    associatedtype ResultType

    /// Configure the viewport with result data.
    func configure(result: ResultType)

    /// The summary bar at the top of the viewport.
    var summaryBar: GenomicSummaryCardBar { get }

    /// Export the results to a file.
    func exportResults(to url: URL, format: ExportFormat) throws
}

/// Protocol for viewports that support BLAST verification.
protocol BlastVerifiable {
    /// Callback for BLAST verification requests.
    var onBlastVerification: ((TaxonNode, Int) -> Void)? { get set }
}

/// Protocol for viewports that display taxonomy data.
protocol TaxonomyDisplayable: ResultViewportController, BlastVerifiable {
    var taxonomyTable: NSTableView { get }
    var detailPane: NSView { get }
}
```

### Registration Pattern

```swift
/// Registry of viewport classes for different result types.
enum ViewportRegistry {
    static func controller(for resultType: ResultType) -> any ResultViewportController {
        switch resultType {
        case .sequenceData(let format):
            return sequenceController(for: format)
        case .classification(let tool):
            return taxonomyController(for: tool)
        case .alignment:
            return AlignmentResultViewController()
        case .assembly(let tool):
            return assemblyController(for: tool)
        case .variants:
            return VariantResultViewController()
        }
    }
}
```

### Adding a New Tool

To add a new tool that shares an existing viewport class:

1. Create the pipeline in `LungfishWorkflow` (e.g., `BowtieAlignmentPipeline`)
2. Create the wizard sheet (e.g., `BowtieMappingWizardSheet`) using dialog template
3. Register it in FASTQ Operations sidebar
4. Wire the result to the appropriate viewport class (e.g., `AlignmentResultViewController`)
5. Add CLI command
6. Done — no new viewport code needed

For tools needing custom detail panes, subclass the base viewport controller
and override just the detail pane section.

## File Organization

```
Sources/LungfishApp/Views/
  Results/
    Base/
      ResultViewportController.swift      # Protocol + base class
      GenomicSummaryCardBar.swift         # Reusable summary bar (already exists)
    Sequences/
      SequenceViewerController.swift      # Base FASTA/FASTQ viewer
      FASTQDatasetViewController.swift    # FASTQ-specific (operations, quality) [existing]
      FASTACollectionViewController.swift # Multi-FASTA browser [existing]
    Taxonomy/
      TaxonomyResultViewController.swift  # Base taxonomy browser
      Kraken2DetailPane.swift            # Kraken2 sunburst + tree
      EsVirituDetailPane.swift           # EsViritu detection table
      TaxTriageDetailPane.swift          # TaxTriage report/Krona
      NaoMgsDetailPane.swift             # NAO-MGS coverage + histograms
    Alignment/
      AlignmentResultViewController.swift # Base alignment viewer
    Assembly/
      AssemblyResultViewController.swift  # Base assembly viewer
    Variants/
      VariantResultViewController.swift   # VCF browser (existing)
```

## Cross-Class Relationships

FASTA reference sequences serve as shared infrastructure across multiple classes:

```
                    FASTA Reference
                    (sequence + annotations)
                         |
              +----------+----------+
              |          |          |
        Alignment    Variant    Assembly
        Viewer       Browser    Viewer
        (BAM         (VCF       (contigs aligned
         pileup)      context)   back to ref)
```

The `ViewerViewController` manages this by loading the reference bundle first,
then overlaying the appropriate result viewport as a child view controller.
This is why FASTA is both a standalone viewer (Class 4) and the backbone for
Classes 2, 3, and 5.
