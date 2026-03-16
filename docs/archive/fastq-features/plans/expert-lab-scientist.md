# Expert Lab Scientist Feedback: Lungfish FASTQ Workflow Analysis

**Author perspective:** Molecular biologist running amplicon sequencing, environmental metabarcoding, and occasional WGS projects. Daily user of Geneious Prime, periodic CLC Genomics Workbench user, and reluctant command-line user (cutadapt, minimap2, samtools, bbtools). macOS primary workstation.

---

## 1. Common Workflows and Where Lungfish Must Excel

### 1.1 Amplicon Sequencing (My Most Common Workflow)

This is the bread-and-butter workflow for our lab. We run 16S/18S/ITS amplicon panels on Illumina MiSeq with dual-indexed libraries.

**Typical steps:**
1. Import multiplexed FASTQ (already basecalled, often a single interleaved file or R1/R2 pair from the sequencer)
2. Demultiplex by dual-index barcodes (we use custom combinatorial indexing, not just i5/i7)
3. Primer trim -- this is where most tools fail us. We need linked adapter mode (cutadapt `--linked`) because our primers are anchored at the 5' end of each read, and the reverse complement of the partner primer may appear at the 3' end
4. Quality filter (Q20 sliding window is standard, but we sometimes need Q25 for low-biomass samples)
5. Length filter (amplicon-specific: 16S V4 should be 250-260 bp after trim, ITS is variable 200-600 bp)
6. Orient all reads in the same direction against a reference (important for downstream OTU/ASV calling)
7. Export clean FASTQ for DADA2, QIIME2, or direct mapping

**What I need from Lungfish:** The current `targetedAmplicon` recipe template is close but it conflates primer removal parameters with a generic recipe. In practice, every amplicon project has different primers, and I need to enter forward/reverse primer sequences per project, not per recipe. The recipe should be "Amplicon Standard" and the primer sequences should be project-level metadata.

### 1.2 Whole Genome Sequencing

Less frequent but higher stakes. Paired-end Illumina, typically 150 bp reads.

**Typical steps:**
1. Import paired FASTQ (R1 + R2, or interleaved)
2. Adapter trim (auto-detect is fine for Illumina TruSeq/Nextera -- fastp handles this well)
3. Quality trim (Q20 sliding window from 3' end)
4. Optional: PE merge for overlapping fragments
5. Export for mapping (minimap2/bwa) or hand off to a dedicated assembly pipeline

**What I need from Lungfish:** The `illuminaWGS` recipe is reasonable. But I rarely do WGS entirely within one tool. I need clean export to BAM/SAM or at minimum clean paired FASTQ that I can feed to an aligner. The key value Lungfish provides here is QC visualization and confident trimming before I move to command-line tools.

### 1.3 Metagenomics / Environmental Samples

Shotgun metagenomics from soil, water, gut samples.

**Typical steps:**
1. Import FASTQ
2. Quality filter (aggressive: Q20+ with minimum length 100 bp)
3. Remove host contamination (human, mouse, or plant depending on sample type) -- this requires a reference genome
4. Remove PhiX spike-in (standard Illumina QC)
5. Export for Kraken2/MetaPhlAn/HUMAnN

**What I need from Lungfish:** The contaminant filter with PhiX mode is a good start, but custom reference mode is essential. I need to point to a host genome FASTA and have Lungfish map-and-remove matching reads. This is where reference management becomes critical (see Section 3).

### 1.4 Quick QC and Parameter Tuning

This is actually my most frequent use of any FASTQ tool -- I just want to look at the data before deciding what to do.

**Typical steps:**
1. Open FASTQ, get immediate stats: read count, length distribution, quality distribution, adapter content, GC content
2. Decide on trimming parameters based on what I see
3. Apply trimming
4. Compare before/after: did my quality distribution improve? How many reads did I lose?
5. Iterate if needed (maybe I was too aggressive, or not aggressive enough)

**What I need from Lungfish:** The sparkline quality/length distributions in `FASTQDatasetViewController` are promising. But the before/after comparison is critical. I need to see the original and processed datasets side by side, or overlaid on the same plot. Geneious does this well with its "Trim Summary" panel.

---

## 2. Pain Points with Current Tools

### 2.1 What Makes Geneious Intuitive

Geneious gets three things right that command-line tools do not:

1. **Document lineage is visible.** When I trim a sequence list in Geneious, the trimmed result appears as a child document in the project tree. I can always trace back to the original. The parent-child relationship is explicit and visual.

2. **Operations are non-destructive by default.** Trimming in Geneious annotates trim regions on reads; it does not rewrite the file. I can undo, adjust, re-trim. Only when I explicitly "Export" do I get a new file. This is profoundly different from command-line tools where every operation overwrites or creates a new file.

3. **Batch operations work on selected documents.** I select 12 barcode folders, right-click, "Trim Reads," configure once, apply to all. The results land next to each input. No scripting, no loops, no file path management.

**Where Geneious fails:** It is slow on large files (>1M reads), its primer trim is limited compared to cutadapt, and its demultiplexing is rudimentary. These are exactly the areas where Lungfish can differentiate.

### 2.2 Where I Lose Track of Files

The single biggest pain point in command-line workflows is file provenance. After a typical amplicon run:

```
project/
  raw/
    multiplexed.fastq.gz
  demux/
    barcode01.fastq.gz
    barcode02.fastq.gz
    ...
  trimmed/
    barcode01_trimmed.fastq.gz
    barcode02_trimmed.fastq.gz
  filtered/
    barcode01_trimmed_filtered.fastq.gz
    ...
  oriented/
    barcode01_trimmed_filtered_oriented.fastq.gz
    ...
```

By the third processing step, file names are absurdly long, I have 4x the storage footprint, and if I change one parameter upstream I have to re-run everything downstream manually. There is no metadata connecting `barcode01_trimmed_filtered_oriented.fastq.gz` back to the original except the name convention I invented.

**What Lungfish should do differently:** The virtual subset / pointer-based derivative system is exactly the right idea. I should never have to think about intermediate files. The processing history should be metadata attached to the dataset, not encoded in filenames.

### 2.3 Reference Sequence Management

This is a surprisingly painful problem. I have:
- Primer FASTA files (per project, but some primers are reused across projects)
- Host genomes for contamination removal (shared across all projects of a given type)
- Amplicon reference databases (SILVA, UNITE, Greengenes -- updated annually)
- Custom reference sequences for orientation

In Geneious, I organize these into a "References" folder in each project, but then I end up duplicating the human genome FASTA across 15 projects. In command-line workflows, I keep a central `~/references/` directory, but then paths break when I move to a different machine.

**What Lungfish should do:** Provide a shared reference library at the application level (like Geneious's "Service Data") with project-level linking. When I set up a project, I should be able to say "use the human genome from the shared library for contamination removal" without copying a 3 GB file into each project. Primers, however, should be project-level because they are specific to each experiment.

### 2.4 Batch Operations I Commonly Need

In order of frequency:
1. **Apply the same processing recipe to all demultiplexed barcodes** (this is the `BatchProcessingEngine` use case -- critical, use it every sequencing run)
2. **Re-run a recipe with modified parameters on all barcodes** (e.g., "the Q20 trim was too aggressive, re-do at Q15")
3. **Export all processed barcodes as individual FASTQ files** (for handoff to downstream tools)
4. **Generate a combined QC report across all barcodes** (for the methods section of a paper, and for identifying failed barcodes)
5. **Rename barcodes to sample names** (barcode01 means nothing; "Soil_pH4_Rep1" means everything)

---

## 3. What I Need from Lungfish: Specific Design Recommendations

### 3.1 Processed File Organization: Tree, Not Flat List

A tree structure is essential. Flat lists become unmanageable after demultiplexing:

```
multiplexed.fastq
  |-- [Demultiplex: 16 barcodes]
       |-- barcode01 (Soil_pH4_Rep1)
       |   |-- [Primer Trim: 515F/806R]
       |   |   |-- [Quality Trim: Q20 w4]
       |   |       |-- [Length Filter: 250-260]
       |   |           |-- [Orient: SILVA 138]
       |   |               --> 12,847 reads (ready for export)
       |-- barcode02 (Soil_pH4_Rep2)
       |   |-- [same pipeline...]
       ...
```

Each node in the tree should show:
- Operation name and key parameters
- Read count (input and output, or just output with pass rate)
- Whether it is virtual (pointer-based) or materialized (actual FASTQ on disk)

I should be able to collapse/expand branches, select any node to view its statistics, and compare any two nodes.

**Critical detail:** The tree should group by barcode first, then by processing steps. NOT the other way around. I think about "barcode01's processing history," not "all files produced by the quality trim step." (Though a transposed view for QC comparison across barcodes would also be valuable.)

### 3.2 When I Need Actual FASTQ Files vs. Statistics

Most of the time, I only need statistics within Lungfish:
- After demultiplexing: I need read counts per barcode and barcode assignment quality
- After trimming: I need before/after quality distributions and read loss percentage
- After filtering: I need pass/fail counts

I only need actual FASTQ files in two situations:
1. **Export for downstream tools** (DADA2, Kraken2, mapping). This is the terminal step, and I want a one-click "Export all final-stage barcodes as individual .fastq.gz files."
2. **Debugging a problem** (e.g., "why did barcode07 lose 80% of reads at the length filter?"). In this case, I want to browse individual reads, see their quality profiles, and maybe search for a specific sequence.

**Implication for Lungfish:** The virtual/pointer derivative system is correct for intermediate steps. Only materialize FASTQ when the user explicitly requests export. This saves enormous amounts of disk space and avoids the filename chaos problem.

### 3.3 Reference Sequence Organization

Two-tier system:

**Application-level Reference Library:**
- Host genomes (human, mouse, chicken, Arabidopsis -- large files, shared across projects)
- Adapter sequences (Illumina TruSeq, Nextera, ONT -- bundled with the app)
- Spike-in references (PhiX -- bundled)
- Taxonomic databases (SILVA, UNITE -- user-installed, updated periodically)

**Project-level References:**
- Primer sequences (stored as literal strings in project metadata, not as separate files)
- Custom orientation references (small FASTA, specific to this amplicon target)
- Custom barcode schemes (CSV mapping barcodes to samples)

The project should reference library items by stable ID, not by file path. If I update SILVA 138 to SILVA 139 in the library, it should not silently change existing projects -- those should keep pointing to 138 until I explicitly update.

### 3.4 Metadata Visible at a Glance

For each FASTQ dataset (whether raw, derivative, or barcode), I need to see without clicking into it:

**Always visible in the sidebar/tree:**
- Sample name (user-assigned, editable)
- Read count
- Status indicator (processing, complete, error, needs-attention)

**Visible on hover or in a summary row:**
- Mean quality score
- Mean read length
- Processing lineage (e.g., "Primer Trim > Q20 Trim > Length Filter")
- File size (actual if materialized, estimated if virtual)

**Visible in the detail panel:**
- Full quality distribution (histogram or density plot, not just mean)
- Length distribution
- GC content distribution
- Per-base quality heatmap (like FastQC's per-base quality plot)
- Adapter content profile (pre/post trimming)
- Processing parameters (every parameter used for every step, in order)
- Timestamp of each processing step

### 3.5 Before/After Comparison

This is a first-class feature, not an afterthought. When I apply a trim operation, I want:

1. **Overlay plots:** Quality distribution of the original dataset overlaid with the trimmed dataset, using different colors (blue = before, orange = after). Same for length distribution.
2. **Summary statistics table:** Side by side -- total reads, mean quality, mean length, min/max length, % reads removed, % bases removed.
3. **Read-level diff (optional, for debugging):** For a sampled subset, show which reads were removed or shortened, and why.

The current sparkline approach in `FASTQDatasetViewController` is a good foundation. Extend it to support dual-trace overlays.

---

## 4. Workflow Preferences

### 4.1 Wizard vs. Power User: Both, With a Smart Default

For new users or new project types: a wizard that walks through standard workflows is helpful. "What kind of sequencing? Amplicon / WGS / Metagenomics / Other." Then suggest a recipe with sensible defaults.

For experienced users (me, after the first week): skip the wizard entirely. Let me select a saved recipe, optionally modify parameters, and run. Or let me build a pipeline step by step in a "pipeline builder" view, then save it as a recipe for next time.

**Critical UX point:** Never make me click through a wizard for a workflow I have already done. The recipe system in `ProcessingRecipe.swift` is the right abstraction. Let me save, name, tag, and reuse recipes. Let me share recipes with lab members (export as `.recipe.json`).

The built-in recipes (`illuminaWGS`, `ontAmplicon`, `targetedAmplicon`) are a good start, but they need one important addition: **recipe templates with placeholders.** The "Targeted Amplicon" recipe should not hardcode primer sequences. It should have placeholder fields that I fill in when I apply it to a specific project. Think of it like a form: the recipe defines the steps and their order, but some parameters (primer sequences, reference paths, barcode CSV) are "ask me at runtime."

### 4.2 Reproducibility: Essential, Not Optional

Reproducibility is not a nice-to-have feature. It is a requirement for publication.

**What I need:**
1. **Automatic logging of every parameter for every operation.** I should never have to reconstruct what I did. If I ran quality trim at Q20 with window size 4, that should be recorded permanently.
2. **Processing provenance as exportable metadata.** When I submit a paper, I need a methods paragraph that says "Reads were demultiplexed using dual-index barcodes (max Hamming distance 1), primers were removed using cutadapt v4.4 with linked adapter mode (forward: GTGYCAGCMGCCGCGGTAA, reverse: GGACTACNVGGGTWTCTAAT, error rate 12%, minimum overlap 12), quality trimmed with a sliding window of 4 bases at Q20 threshold, and length filtered to retain reads between 250-260 bp."
3. **Recipe versioning.** If I modify a recipe, I should be able to see what changed and when. Not git-level version control, but at minimum: "Modified on 2026-03-14: changed quality threshold from Q20 to Q25."

The `ProcessingRecipe` struct stores `createdAt` and `modifiedAt`, which is a start. But it needs a changelog or version history.

### 4.3 Export Processing Parameters for Methods Sections

This is a specific, high-value feature that almost no bioinformatics GUI provides well.

**Ideal implementation:**
- A "Generate Methods Text" button that produces a publication-ready paragraph
- Include tool names and versions (e.g., "fastp v0.23.4," "cutadapt v4.4," "bbtools v39.06")
- Include all non-default parameters
- Optionally include read count statistics at each step (for supplementary materials)

**Example output:**
> Raw reads (n=1,247,832) were demultiplexed into 16 samples using dual-index barcode matching (Lungfish v1.0, max edit distance 1, trim barcodes enabled). PCR primers (515F: 5'-GTGYCAGCMGCCGCGGTAA-3', 806R: 5'-GGACTACNVGGGTWTCTAAT-3') were removed using cutadapt v4.4 in linked adapter mode (error rate 0.12, minimum overlap 12 bp, anchored). Quality trimming was performed with fastp v0.23.4 (sliding window 4 bp, minimum quality Q20, 3' direction). Reads outside the expected amplicon length range (250-260 bp) were discarded. Surviving reads were oriented against the SILVA 138.1 SSU reference database. After all filtering steps, a mean of 52,411 reads per sample (range: 31,204-78,532) were retained for downstream analysis.

This single feature would save me 30 minutes per manuscript and eliminate transcription errors. I would pay for this feature alone.

---

## 5. Additional Observations on the Current Codebase

### 5.1 The Virtual/Pointer Derivative System Is the Right Architecture

The `FASTQDerivativeOperation` system that tracks operations as metadata rather than always producing new files is fundamentally correct. This is how a modern bioinformatics GUI should work. Geneious does something similar internally (trim annotations on reads), and it is one of the main reasons Geneious feels fast and non-destructive.

**Suggestion:** Make the virtual vs. materialized distinction invisible to the user by default. They should not need to know or care whether a derivative is a pointer file or a real FASTQ. The only time it matters is at export time ("Materialize and export as .fastq.gz").

### 5.2 Demultiplexing Needs Sample Name Assignment Early

The current flow seems to be: demultiplex first, get barcode labels, then optionally rename. This should be inverted for the common case.

**Better flow:**
1. User provides a sample sheet (CSV: barcode, sample_name, optional metadata columns)
2. Demultiplex uses the sample sheet for barcode-to-sample mapping
3. Results immediately appear with sample names, not barcode IDs
4. If no sample sheet is provided, fall back to barcode labels (with a prompt to add sample names later)

The `FASTQSampleBarcodeAssignment` type exists but it feels like an afterthought. It should be the primary input to demultiplexing.

### 5.3 Batch Processing Recipe Application

The `BatchProcessingEngine` actor is well-structured. Two enhancements:

1. **Selective barcode processing.** Sometimes I want to re-run the pipeline on only 3 of 16 barcodes (the ones that failed QC). Let me select which barcodes to include rather than always processing all.

2. **Step-level resume.** If step 3 of 5 fails for barcode07 (e.g., out of disk space), I should be able to fix the problem and resume from step 3, not re-run steps 1-2 for all barcodes. The `stepFailed(barcode:stepIndex:underlying:)` error already captures this info; use it for resumability.

### 5.4 The Operations Panel Needs a Pipeline View

Right now, operations appear to be applied one at a time from the metadata drawer. For the common case (apply a multi-step recipe), I need a pipeline view that shows all steps in order, lets me configure each one, and runs them as a batch.

Think of it as a visual version of the `ProcessingRecipe.pipelineSummary`:

```
Quality Trim (Q20, w4) --> Adapter Trim (auto) --> Length Filter (250-260) --> Orient (SILVA)
     [edit]                    [edit]                   [edit]                  [edit]
                                                                              [Run Pipeline]
```

Each step should be draggable to reorder, removable, and individually configurable. The pipeline view should show estimated processing time and disk space requirements.

---

## 6. Summary of Priorities

Ranked by impact on my daily work:

1. **Before/after comparison** -- overlaid quality/length distributions after any processing step
2. **Tree-based lineage view** -- see the full processing history of every barcode at a glance
3. **Batch recipe application with sample names** -- process all barcodes, named by sample sheet
4. **Methods text export** -- generate publication-ready processing descriptions
5. **Shared reference library** -- stop duplicating host genomes across projects
6. **Pipeline builder view** -- visual recipe construction with drag-and-drop step ordering
7. **Recipe templates with runtime placeholders** -- separate "what to do" from "with what sequences"
8. **Selective re-run** -- re-process specific barcodes or resume from a failed step
9. **Per-base quality heatmap** -- FastQC-style visualization for diagnosing systematic quality issues
10. **Export all final-stage barcodes** -- one-click export of all processed data for downstream tools
