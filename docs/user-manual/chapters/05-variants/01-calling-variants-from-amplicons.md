---
title: Calling Variants from Amplicon Reads
chapter_id: 05-variants/01-calling-variants-from-amplicons
audience: bench-scientist
prereqs: []
estimated_reading_min: 20
task: Call variants from amplicon Illumina reads of a viral genome.
tags: [amplicon, variant-calling, ivar, sars-cov-2, illumina]
tools: [ivar, minimap2, samtools, bcftools, tabix, bgzip]
shots:
  - id: ncbi-search-fasta
    caption: "Searching NCBI for the SARS-CoV-2 reference sequence."
  - id: ncbi-search-gff3
    caption: "Toggling Include GFF3 Annotations so the matching GFF3 is fetched and attached."
  - id: sra-search-dialog
    caption: "Downloading SRR36291587 reads from the SRA."
  - id: mapping-dialog
    caption: "Mapping reads to MN908947.3 with minimap2."
  - id: primer-trim-dialog
    caption: "Primer-trimming the alignment with the QIASeqDIRECT-SARS2 scheme."
  - id: variant-call-dialog-ivar
    caption: "The Variant Calling dialog with iVar selected."
  - id: variant-browser-overview
    caption: "The variant browser showing the iVar VCF track over the reference genome."
  - id: variant-browser-codon-merge
    caption: "Position 28881 in the variant browser, where iVar collapsed three SNPs into one row."
glossary_refs: [VCF, REF, ALT, allele-frequency, depth, variant-caller, primer-trim, primer-scheme, amplicon, codon, soft-clip, BAM, FASTQ, Phred-score, plugin-pack, reference-bundle, GFF, SRA, ENA]
features_refs: [fetch.ncbi, fetch.sra, map, bam.primer-trim, variants.call, viewport.variant-browser]
fixtures_refs: [sarscov2-srr36291587]
brand_reviewed: false
lead_approved: false
---

## What it is

Work through this chapter and your Lungfish project will hold four things: a SARS-CoV-2 reference genome, the matching gene annotations, an alignment of public sequencing reads against that reference, and a list of every position where those reads disagree with the reference. That list of disagreements is a VCF file, short for Variant Call Format, and you will read it in Lungfish's variant browser with biological context attached to every row.

Two real public accession numbers anchor the example. The reference is `MN908947.3`, the original Wuhan-Hu-1 isolate from December 2019, 29,903 bases long. The reads come from run `SRR36291587` in the NCBI Sequence Read Archive, an amplicon-sequenced clinical sample of an Omicron-lineage SARS-CoV-2 isolate. Start to finish, the run takes about five minutes on a recent Apple Silicon Mac, most of it spent downloading reads.

## Why this matters for SARS-CoV-2

A SARS-CoV-2 variant call set answers concrete biological questions. Which mutations does this isolate carry? Are any of them known immune-escape mutations in the spike receptor-binding domain? Which Pango lineage does it belong to? Do minority variants hint at a mixed infection, a transmission bottleneck, or an emerging sublineage? Every one of these questions starts with the table of disagreements you build in this chapter.

The same procedure works for influenza, RSV, HIV, monkeypox, and any other virus with a public reference genome. Each pathogen's biology differs, but the file types, the tools, and the Lungfish workflow stay the same. Why SARS-CoV-2 as the teaching case? The reference and reads are public, the protocol is well documented, and the variants you call map straight onto lineage names most readers already know.

This part of the manual is deliberately viral. Human germline work runs on
different machinery: GATK, diploid genotype assumptions, known-sites resources,
and cohort-scale joint genotyping. Those workflows live in
[Human Germline Variants](../06-human-germline-variants/01-haplotype-caller.md),
where the GATK chapters handle HaplotypeCaller execution and attachment on their
own, so the viral iVar path here stays focused.

## Vocabulary you will need

This chapter leans on a handful of terms. Each one is defined briefly here and at greater length in the [glossary](../../GLOSSARY.md). Keep them nearby as you read.

- **Reference genome.** The sequence Lungfish compares your reads against. For SARS-CoV-2 the standard reference is `MN908947.3`.
- **FASTQ.** A text file format that holds raw sequencing reads, each with a per-base quality score (the [Phred score](../../GLOSSARY.md#phred-score)). One sequencing run usually produces one or two FASTQ files.
- **Amplicon.** A region of a genome amplified by PCR, used as the unit of an amplicon-based sequencing protocol. SARS-CoV-2 amplicon protocols (such as ARTIC and QIAseq Direct) tile the whole genome with about 100 overlapping amplicons.
- **BAM.** A binary file that lists where each read mapped on the reference. Calling variants reads from a BAM, not from FASTQ.
- **VCF.** Variant Call Format, the table you produce in this chapter. One row per position where the sample disagrees with the reference, with the bases involved, the depth of evidence, and a confidence score.

A primer scheme is the set of primer coordinates that defines an amplicon protocol. In Lungfish it takes the form of a `.lungfishprimers` bundle that records where each forward and reverse primer lands on the reference.

Three more terms come up in the procedure. **Allele frequency** is the fraction of mapped reads at a position that carry the alternate base; values run from 0 (no reads support the alternate) to 1.0 (every read supports it). **Depth** is the number of reads covering a position. **Soft-clip** is the BAM convention for marking the ends of a read that did not align, without deleting them; primer trimming soft-clips the primer-derived bases out of the analyzable region.

## Choosing iVar

The Variant Calling dialog offers five viral callers, LoFreq, iVar, Medaka, bcftools, and Clair3, plus two GATK germline options. Each was built for a different sequencing regime, so the right tool depends on the data in front of you. The dialog opens with LoFreq selected, so for this chapter you will click iVar yourself. The table below matches each available caller to the data it suits; the GATK options belong to human germline work and are introduced separately in the Part 06 chapters.

| If your data is | Choose | Why |
|---|---|---|
| Illumina amplicon (this chapter) | **iVar** | Designed for primer-trimmed amplicon data; reports allele frequencies above a fixed threshold; codon-aware when given a GFF |
| Illumina shotgun viral or bacterial | LoFreq | Per-base error model with multiple-testing correction; assumes random read-start distribution |
| Oxford Nanopore amplicon or shotgun | Medaka or Clair3 | Long-read aware; keyed to the Nanopore base-call error profile |
| A general orthogonal cross-check | bcftools | Genotype-likelihood model from `mpileup`; useful as a second opinion |

This chapter reaches for iVar because the data fits it three ways: the reads come from an amplicon protocol, QIAseq Direct, they are paired-end Illumina, and we want every variant above 5% allele frequency reported in a single annotated VCF. The other callers get their own treatment: Medaka and Clair3 in [Nanopore Variant Calling](04-nanopore-variant-calling.md), and LoFreq plus bcftools as cross-checks in [Reading Two Callers in One Table](03-cross-caller-comparison.md). For amplicon Illumina viral data, iVar is the right place to start.

## Before you start

You need Lungfish installed and an empty project window open. You also need two plugin packs. A plugin pack is a collection of bioinformatics tools that Lungfish manages through `conda` environments under `~/.lungfish/conda`:

```bash
lungfish conda install --pack read-mapping variant-calling
```

The first install pulls about 250 MB and finishes in a couple of minutes. From then on the tools are available to every Lungfish project on the machine. If a step later fails with a missing-tool error, run the install command again and retry the step. Re-running is safe: Lungfish recognizes packs it already has and exits without re-downloading.

Budget about 250 MB of free disk space for the run and about five minutes of wall clock on a recent Apple Silicon Mac. The SRA reads decompress to roughly 86 MB, and the BAM lands around 16 MB after primer trimming. The slowest step is the read download. Lungfish tries the European Nucleotide Archive, ENA, first, which usually returns the FASTQs in under a minute, and falls back to the NCBI SRA Toolkit if ENA refuses. The fallback is automatic; you never have to choose.

No prior variant-calling experience is assumed. What the chapter does assume is that you can read a short terminal command and click through a dialog. If a term in the procedure is unfamiliar, check the vocabulary section above or follow its glossary link.

## Procedure

Eight steps fall into three phases. The first phase gathers inputs, steps 1 through 3. The second processes the reads into a clean alignment, steps 4 and 5. The third calls and reads variants, steps 6 through 8.

### Step 1. Create the project

From the Welcome window choose `Create Project`, or from the menu bar choose `File > New Project`. Name it `SARS-CoV-2 SRR36291587` and save it under your `Documents` folder. Lungfish opens a new window carrying the project name. The left sidebar lays out the project's folder structure, and the Inspector pane on the right stays empty until you select something.

### Step 2. Download the reference and its annotations

Choose `Tools > Search Online Databases > Search NCBI…` to open the database search dialog. Set `Mode` to `Nucleotide` and leave `Include GFF3 Annotations` on, so the bundle carries the gene features the variant caller will need later. The GUI has no file-format menu: FASTA, GenBank, GFF3, and XML are a command-line concept, exposed through `lungfish fetch ncbi --fetch-format`. In the GUI you pick a Mode, decide whether to include annotations, and let Lungfish assemble the bundle.

Type `MN908947.3` into the search field and click `Search`. Select the matching record in the results list, and the primary button changes from `Search` to `Download Selected`.

<!-- SHOT: ncbi-search-fasta -->

<!-- SHOT: ncbi-search-gff3 -->

Click `Download Selected`. In one action Lungfish downloads the record and builds a `.lungfishref` reference bundle, the sequence, the annotation track, and a provenance sidecar already tucked inside. No separate import step, no "Create Bundle" prompt. When the Operations Panel row turns green, the reference appears in the left sidebar under `Reference Sequences > MN908947.3`, and the Inspector shows `1 annotation track` beside the bundle metadata.

A General Feature Format (GFF) file is a tab-separated table that records where genes and other functional elements sit on a reference. The SARS-CoV-2 GFF3 from NCBI lists 24 features: each gene (`ORF1ab`, `S`, `E`, `M`, `N`, `ORF3a`, `ORF6`, `ORF7a`, `ORF7b`, `ORF8`, `ORF10`), each coding sequence within those genes, the mature peptides cleaved out of `ORF1ab`, and a few stem-loop structures. The variant caller draws on this file later to group adjacent SNPs that fall inside one codon.

Behind the dialogs, Lungfish ran:

```bash
lungfish fetch ncbi MN908947.3 --fetch-format fasta --save-to Downloads/MN908947.3.fasta
lungfish fetch ncbi MN908947.3 --fetch-format gff3 --save-to Downloads/MN908947.3.gff3
lungfish bundle create --fasta Downloads/MN908947.3.fasta --annotation Downloads/MN908947.3.gff3 --name MN908947.3 --output-dir "Reference Sequences" --compress
```

### Step 3. Download the sequencing reads

Choose `Tools > Search Online Databases > Search SRA…` to open the SRA download dialog. Type `SRR36291587` into the accession field. Leave `Layout` at `Auto-detect`, so Lungfish reads the run's metadata and settles on paired-end by itself. Click `Download`. The Operations Panel opens at the bottom of the window and tracks progress as the FASTQs land.

<!-- SHOT: sra-search-dialog -->

When the operation finishes, two FASTQ files, `SRR36291587_1.fastq.gz` and `SRR36291587_2.fastq.gz`, appear in `Downloads/`, paired by the `_1` / `_2` suffix Lungfish recognizes automatically. The download row turns green and carries a checksum and size for each file; click it to read the full provenance record. If ENA refused and Lungfish fell back to the SRA Toolkit, the row notes `Falling back to SRA Toolkit (prefetch + fasterq-dump)…` for the record.

The CLI equivalent is `lungfish fetch sra download SRR36291587 --output-dir Downloads`.

### Step 4. Map the reads to the reference

Mapping in the GUI is a two-step selection, and neither step happens inside the wizard. First, in the sidebar, click the `SRR36291587` FASTQ bundle to select it; because the bundle already pairs `_1` and `_2`, the run will be paired-end. Then choose `Tools > FASTQ/FASTA Operations > Mapping…` and click the `minimap2` tool row. The mapping wizard opens already knowing both the reads, from your sidebar selection, and the mapper, from the row you clicked.

The wizard has five sections: `Reference`, `Preset`, `Read Group`, `Input Compatibility`, and `Advanced Settings`. Under `Reference`, choose `MN908947.3`. Under `Preset`, leave it at `Short-read`, the right preset for paired Illumina data, and the `Input Compatibility` readout below it should agree. Click `Run`.

<!-- SHOT: mapping-dialog -->

Behind the dialog, Lungfish runs `minimap2 -ax sr` piped into `samtools sort` and `samtools index`. When it finishes, a fresh alignment track named `minimap2 Mapping`, the mapper name plus "Mapping", appears in the sidebar under `MN908947.3 > Alignments`. You can rename it.

Other mappers wait in the same dialog if your data calls for them: `BWA-MEM2`, `Bowtie2`, and `BBMap` each have a tool row. minimap2 is the default for short-read viral data because it is fast, well-supported on Apple Silicon, and produces alignments equivalent to BWA-MEM in benchmark comparisons. For long-read Nanopore data, click the `minimap2` row and choose the `Map ONT (map-ont)` preset instead.

The CLI equivalent of step 4 is two commands: `lungfish map ... --paired --preset sr -o mapping/` followed by `lungfish bam adopt-mapping --bundle ... --mapping-result mapping/ --name "minimap2 mapping"` (the `--name` option is required).

### Step 5. Primer-trim the alignment

Click the new `minimap2 Mapping` alignment track in the sidebar so its Inspector fills the right pane. In the Inspector's `Analysis` section, click `Primer-trim BAM…`. The Primer Trim dialog opens.

In the `Primer scheme` picker, choose the bundled `QIASeqDIRECT-SARS2` scheme. The picker also lists any custom schemes you have imported into the project's `Primer Schemes/` folder, but QIASeqDIRECT-SARS2 ships with Lungfish. Leave `Advanced Options` collapsed. The iVar trim defaults (`Minimum read length after trim 30`, `Minimum quality 20`, `Sliding window width 4`, `Primer offset 0`) are tuned for SARS-CoV-2 amplicon data and rarely need touching. The output track name fills in as `minimap2 Mapping - Primer-trimmed (QIASeqDIRECT-SARS2)`. Click `Run`.

<!-- SHOT: primer-trim-dialog -->

Primer trimming soft-clips the primer-derived bases off the ends of every read, so the variant caller never sees them. Skip it, and every position where a primer overlaps the reference would masquerade as a variant in 50% of the reads. Keep it, and only the bases the polymerase actually synthesized contribute to variant calls.

The Operations Panel runs `ivar trim` followed by `samtools sort` and `samtools index`. When it finishes, a new alignment track carrying the `Primer-trimmed (QIASeqDIRECT-SARS2)` suffix appears in the sidebar, along with a primer-trim provenance sidecar that tells the variant caller the reads are already trimmed.

The CLI equivalent is `lungfish bam primer-trim --bundle ... --alignment-track ... --scheme QIASeqDIRECT-SARS2.lungfishprimers --name primer-trimmed`.

### Step 6. Call variants with iVar

Click the primer-trimmed alignment track in the sidebar. In the Inspector's `Analysis` section, select `Variant Calling` and click `Call Variants…`. The Variant Calling dialog opens in three columns: a tool sidebar on the left, an `Inputs` section in the middle, and an `Output` section on the right. The tool sidebar lists seven entries, `LoFreq`, `iVar`, `Medaka`, `bcftools`, `Clair3`, `GATK HaplotypeCaller`, and `GATK + WhatsHap Phased`, with `LoFreq` selected by default. Click `iVar` to switch.

The `Inputs` section shows the primer-trimmed alignment track. Lungfish recognizes the track's primer-trim provenance sidecar, so the `This BAM has already been primer-trimmed for iVar` acknowledgement comes pre-checked and disabled, its caption reading `Primer-trimmed by Lungfish on <date> using QIASeqDIRECT-SARS2`. Two controls sit in a shared `Thresholds` section that applies to whichever caller is selected: `Minimum Allele Frequency` (default `0.05`) and `Minimum Depth` (default `10`). The iVar-specific `iVar Options` section holds the rest: consensus allele frequency `0.75`, merge AF distance `0.25`, minimum ALT quality `20`, and `Ignore strand bias (recommended for amplicons)` on. Leave every one of these at its default for this chapter. Name the output track `iVar variants` and click `Run`.

<!-- SHOT: variant-call-dialog-ivar -->

Behind the dialog, Lungfish exports the bundle's GFF3 annotations into the working directory as `ivar-annotations.gff3`, then runs `samtools mpileup` piped into `ivar variants`, handing the minimum depth to `-m 10` and that GFF3 to `-g`. iVar emits a TSV. The Lungfish converter reads it and, because the GFF3 came along, folds adjacent SNPs inside one codon into a single VCF row wherever the codon collapses into a single amino-acid change. The pipeline closes by sorting the records, then bgzipping and tabix-indexing the VCF. A new variant track named `iVar variants` appears under `MN908947.3 > Variants`.

The CLI equivalent is `lungfish variants call --bundle ... --alignment-track ... --caller ivar --ivar-primer-trimmed --min-af 0.05 --name "iVar variants"`.

### Step 7. Open the variant browser

Click the `iVar variants` track in the sidebar to open the variant browser. At the top sits a genome track that draws each variant as a tick; below it a reference panel updates as you navigate; at the bottom of the window waits a sortable variant table.

<!-- SHOT: variant-browser-overview -->

The table starts unfiltered, showing every row in the VCF. Its columns are `ID`, `Chrom`, `Position`, `Ref`, `Alt`, `Quality`, `Filter`, and `Source`. That last column names the staged VCF file each row came from, which lets you tell tracks apart once a reference carries more than one. The table also promotes whatever per-row `INFO` keys the VCF defines into their own columns. Sort by `Position` ascending so positions in the same neighborhood line up. To keep only confident calls, click the `Presets` toggle in the filter bar and select the `PASS` chip. That hides any iVar rows carrying the `ft` filter flag, which iVar applies when a Fisher's exact test cannot separate the variant frequency from the local error rate.

The variant browser is the primary surface for reading and exporting variants. Select a row and the genome track centers on that position while the Inspector fills with the per-variant detail, INFO fields and any annotation context included.

### Step 8. Read the codon-merged row at position 28881

Scroll the variant table to position `28881`. The SARS-CoV-2 N gene reading frame drops positions 28881 and 28882 inside the codon for amino acid 203 of the nucleocapsid protein (`AGG > AAA`, an `R203K` substitution). Position 28883 opens the next codon, the one for amino acid 204 (`GGA > CGA`, a `G204R` substitution). With the GFF3 attached, iVar reports the within-codon pair at 28881-28882 as a single row with `REF GG` and `ALT AA`. Position 28883 stands on its own row with `REF G`, `ALT C`, because it lives in a different codon.

The amino-acid label lives nowhere in the VCF row itself. The iVar VCF carries only `TYPE=SNP` in its `INFO` column and keeps depth and allele frequency in the per-sample `FORMAT` fields (`ALT_FREQ`, plus `MERGED_AF`/`MERGED_DP` on a merged row), not in `INFO`. The `R203K` and `G204R` consequences on screen come from the Inspector re-deriving them against the bundle's GFF3 as you select the row, not from any field in the file. Hand this VCF to an external tool and it will find no amino-acid annotation inside.

<!-- SHOT: variant-browser-codon-merge -->

This is the codon-merging behaviour the GFF3 unlocks. Strip the annotations away and iVar would emit three separate one-base rows at positions 28881, 28882, and 28883. Both representations describe the same biology: the reads at those positions support `R203K` paired with `G204R`, the canonical N-protein signature first seen in the B.1.1 lineage and inherited by every Omicron sublineage, this sample's included. The annotated version simply makes the codon boundary visible in the table.

The codon-merge is the most useful lesson in this chapter. Without annotation context, a VCF row does not map one-to-one onto a biological variant. Attach the GFF3 and iVar describes biology codon by codon; leave it off and iVar describes positions one base at a time. When annotations are available, Lungfish takes the annotation-aware view.

## What does good look like

Before trusting the call set, check three things.

First, in the variant browser, count the rows marked `Filter PASS`. For SRR36291587 with this chapter's defaults, expect roughly 80-90 PASS rows in the iVar VCF. That is an expected range for this particular isolate, not a guaranteed output; your exact count rides on depth and the allele-frequency distribution. A count of zero or in the low single digits means the alignment is broken: no reads mapped, the wrong reference, or coverage too low. A count above 200 usually means the minimum allele frequency sits too low and the table has filled with sequencing-error noise.

Second, click the iVar variants track and read the Inspector's `Analysis` section. The provenance sidecar should show the primer-trim record (`QIASeqDIRECT-SARS2`, the trim date, the input alignment checksum) and the variant-calling record (the iVar version, the mpileup flags, the GFF3 input checksum). Provenance is your audit trail for everything the call set rests on.

Third, spot-check a few high-confidence PASS rows against a published SARS-CoV-2 lineage definition. Position `21618 C>T` (spike T19I), the deletion at `21632`, and the `nsp3` cluster at `1931, 2790, 2954, 3037` are all expected for an Omicron isolate. These are biological landmarks for this sample, not values the app guarantees. If those rows show up with allele frequencies near 1.0, the workflow worked.

## What this chapter did not cover

This chapter stays on iVar against amplicon Illumina data with the bundled QIASeqDIRECT-SARS2 primer scheme. Several neighbouring topics live elsewhere:

- **Reading two callers together.** Running LoFreq or bcftools alongside iVar and reading their disagreements in one table is covered in [Reading Two Callers in One Table](03-cross-caller-comparison.md).
- **Long-read variant calling.** Medaka and Clair3 against Oxford Nanopore data use a model keyed to the basecaller and take different inputs. Same Lungfish dialog, different tool selection on the left sidebar. See [Nanopore Variant Calling](04-nanopore-variant-calling.md).
- **Bringing your own primer scheme.** ARTIC and custom schemes are imported through the `Primer Schemes/` folder. The Primer Scheme Picker in the trim dialog automatically lists every scheme in that folder.
- **From reads to consensus.** Producing a consensus FASTA and submitting it for Pango lineage assignment with external tools is covered in [Consensus and Lineage](05-consensus-and-lineage.md). The iVar step here produces a VCF, not a consensus.
- **Read quality control.** This chapter assumes the reads are clean. For real samples, run the FASTQ Quality Trim and Adapter Removal operations before mapping.

## Everything you just clicked, as a shell script

The whole workflow collapses into one CLI script. It is identical to what the GUI ran behind the dialogs, with every flag now in plain sight.

```bash
#!/usr/bin/env bash
set -euo pipefail

# Setup: install plugin packs (idempotent)
lungfish conda install --pack read-mapping variant-calling

# Step 2: download reference and annotations
lungfish fetch ncbi MN908947.3 --fetch-format fasta --save-to MN908947.3.fasta
lungfish fetch ncbi MN908947.3 --fetch-format gff3 --save-to MN908947.3.gff3

# Step 3: download reads
lungfish fetch sra download SRR36291587 --output-dir .

# Step 2 (continued): make the reference bundle with annotations
lungfish bundle create \
    --fasta MN908947.3.fasta \
    --annotation MN908947.3.gff3 \
    --name MN908947.3 \
    --output-dir . \
    --compress

# Step 4: map reads
lungfish map SRR36291587_1.fastq SRR36291587_2.fastq \
    --reference MN908947.3.fasta \
    --paired --preset sr \
    --sample-name SRR36291587 \
    -o mapping/

lungfish bam adopt-mapping \
    --bundle MN908947.3.lungfishref \
    --mapping-result mapping/ \
    --name "minimap2 mapping"

# Step 5: primer-trim the alignment
TRACK_ID=$(jq -r '.alignments[0].id' MN908947.3.lungfishref/manifest.json)
lungfish bam primer-trim \
    --bundle MN908947.3.lungfishref \
    --alignment-track "$TRACK_ID" \
    --scheme QIASeqDIRECT-SARS2.lungfishprimers \
    --name primer-trimmed

# Step 6: call variants with iVar
TRIMMED_ID=$(jq -r '.alignments[] | select(.name == "primer-trimmed") | .id' \
    MN908947.3.lungfishref/manifest.json)
lungfish variants call \
    --bundle MN908947.3.lungfishref \
    --alignment-track "$TRIMMED_ID" \
    --caller ivar \
    --ivar-primer-trimmed \
    --min-af 0.05 \
    --name "iVar variants"
```

The chapter cited the SARS-CoV-2 SRR36291587 fixture. {{ fixtures_refs.sarscov2-srr36291587 | cite }}
