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
    caption: "Downloading the matching GFF3 annotations from NCBI."
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

By the end of this chapter you will have a Lungfish project that contains a SARS-CoV-2 reference genome, the matching gene annotations, an alignment of public sequencing reads against that reference, and a list of every position where those reads disagree with the reference. The list of disagreements is a VCF (Variant Call Format) file, opened in Lungfish's variant browser, with biological context attached to every row.

The example uses two real public accession numbers. The reference is `MN908947.3`, the original Wuhan-Hu-1 isolate from December 2019, 29,903 bases long. The reads are run `SRR36291587` from the NCBI Sequence Read Archive, an amplicon-sequenced clinical sample of an Omicron-lineage SARS-CoV-2 isolate. Total wall time on a recent Apple Silicon Mac is about five minutes, most of it the read download.

## Why this matters for SARS-CoV-2

A SARS-CoV-2 variant call set answers concrete biological questions. Which mutations does this isolate carry? Are any of them known immune-escape mutations in the spike receptor-binding domain? Which Pango lineage does this isolate belong to? Are there minority variants that suggest a mixed infection, a transmission bottleneck, or an emerging sublineage? Each of these questions starts with the table of disagreements you produce in this chapter.

The same procedure works for influenza, RSV, HIV, monkeypox, and any other virus with a public reference genome. The biology of each pathogen is different, but the file types, tools, and Lungfish workflow are the same. The chapter teaches the workflow on SARS-CoV-2 because the reference and reads are public, the protocol is well documented, and the resulting variants connect to widely-known lineage names.

## Vocabulary you will need

This chapter introduces or uses the following terms. Each term is defined briefly here and at greater length in the [glossary](../../GLOSSARY.md). Reference these as you read.

- **Reference genome.** The sequence Lungfish compares your reads against. For SARS-CoV-2 the standard reference is `MN908947.3`.
- **FASTQ.** A text file format that holds raw sequencing reads, each with a per-base quality score (the [Phred score](../../GLOSSARY.md#phred-score)). One sequencing run usually produces one or two FASTQ files.
- **Amplicon.** A region of a genome amplified by PCR, used as the unit of an amplicon-based sequencing protocol. SARS-CoV-2 amplicon protocols (such as ARTIC and QIAseq Direct) tile the whole genome with about 100 overlapping amplicons.
- **BAM.** A binary file that lists where each read mapped on the reference. Calling variants reads from a BAM, not from FASTQ.
- **VCF.** Variant Call Format, the table you produce in this chapter. One row per position where the sample disagrees with the reference, with the bases involved, the depth of evidence, and a confidence score.

A primer scheme is the set of primer coordinates that defines an amplicon protocol. In Lungfish a primer scheme is a `.lungfishprimers` bundle that lists where each forward and reverse primer lands on the reference.

Three more terms come up in the procedure. **Allele frequency** is the fraction of mapped reads at a position that carry the alternate base; values run from 0 (no reads support the alternate) to 1.0 (every read supports it). **Depth** is the number of reads covering a position. **Soft-clip** is the BAM convention for marking the ends of a read that did not align, without deleting them; primer trimming soft-clips the primer-derived bases out of the analyzable region.

## Choosing iVar

Three variant callers ship with Lungfish. They are designed for different sequencing regimes, and the right tool depends on what kind of data you have.

| If your data is | Use | Why |
|---|---|---|
| Illumina amplicon (this chapter) | **iVar** | Designed for primer-trimmed amplicon data; reports allele frequencies above a fixed threshold; codon-aware when given a GFF |
| Illumina shotgun viral or bacterial | LoFreq | Per-base error model with multiple-testing correction; assumes random read-start distribution |
| Oxford Nanopore amplicon or shotgun | Medaka | Long-read aware; trained against the Nanopore base-call error profile |

This chapter uses iVar because the reads come from an amplicon protocol (QIAseq Direct), they are paired-end Illumina, and we want every variant above 5% allele frequency reported in a single annotated VCF. The other two callers have their own chapters; iVar is the right starting point for amplicon Illumina viral data.

## Before you start

You need Lungfish installed and an empty project window open. You also need two plugin packs (collections of bioinformatics tools that Lungfish manages through `conda` environments under `~/.lungfish/conda`):

```bash
lungfish conda install --pack read-mapping variant-calling
```

The first install pulls about 250 MB and takes a couple of minutes. After that the tools are available to every Lungfish project on the machine. If a step in the procedure fails with a missing-tool error, run the install command again and try the step again. Re-running the command is safe: Lungfish recognizes already-installed packs and exits without re-downloading.

The chapter expects about 250 MB of free disk space during the run (the SRA reads decompress to roughly 86 MB, the BAM lands around 16 MB after primer trimming) and about five minutes of wall clock on a recent Apple Silicon Mac. The slowest step is the read download. Lungfish tries the European Nucleotide Archive (ENA) first, which usually returns the FASTQs in under a minute, and falls back to the NCBI SRA Toolkit if ENA refuses. The fallback is automatic; you do not have to choose.

This chapter does not assume any prior variant-calling experience. It does assume you can read a small terminal command and click through a dialog. If a term in the procedure is unfamiliar, check the vocabulary section above or follow the glossary link.

## Procedure

The procedure has eight steps grouped into three phases. The first phase gathers inputs (steps 1-3). The second phase processes the reads into a clean alignment (steps 4-5). The third phase calls and reads variants (steps 6-8).

### Step 1. Create the project

From the Welcome window choose `Create Project`, or from the menu bar choose `File > New Project`. Name the project `SARS-CoV-2 SRR36291587` and save it under your `Documents` folder. Lungfish opens a new window titled with the project name. The left sidebar shows the project's folder structure. The Inspector pane on the right is empty until you select something.

### Step 2. Download the reference and its annotations

Choose `Tools > Search Online Databases > Search NCBI…` to open the NCBI search dialog. Type `MN908947.3` into the accession field. Leave `Format` set to `FASTA` and click `Download`. The dialog closes when the FASTA file lands in the project's `Downloads/` folder. Lungfish then prompts you to make a reference bundle out of it.

Before you accept the bundle prompt, fetch the matching annotations. Open the NCBI search dialog again with `Tools > Search Online Databases > Search NCBI…`. Type `MN908947.3` again, this time set `Format` to `GFF3`, and click `Download`. The annotations file appears in `Downloads/` alongside the FASTA.

<!-- SHOT: ncbi-search-fasta -->

<!-- SHOT: ncbi-search-gff3 -->

Now accept the bundle prompt: name the bundle `MN908947.3` and check the box that says `Attach annotations`, which Lungfish auto-detects from the matching GFF3 in `Downloads/`. Click `Create Bundle`. The reference appears in the left sidebar under `Reference Sequences > MN908947.3`, and the Inspector shows `1 annotation track` next to the bundle metadata.

A General Feature Format (GFF) file is a tab-separated table that lists where genes and other functional elements live on a reference. The SARS-CoV-2 GFF3 from NCBI lists 24 features: each gene (`ORF1ab`, `S`, `E`, `M`, `N`, `ORF3a`, `ORF6`, `ORF7a`, `ORF7b`, `ORF8`, `ORF10`), each coding sequence inside those genes, the mature peptides cleaved out of `ORF1ab`, and a few stem-loop structures. The variant caller will use this file later to group adjacent SNPs that fall inside one codon.

Behind the dialogs, Lungfish ran:

```bash
lungfish fetch ncbi MN908947.3 --fetch-format fasta --save-to Downloads/MN908947.3.fasta
lungfish fetch ncbi MN908947.3 --fetch-format gff3 --save-to Downloads/MN908947.3.gff3
lungfish bundle create --fasta Downloads/MN908947.3.fasta --annotation Downloads/MN908947.3.gff3 --name MN908947.3 --output-dir "Reference Sequences" --compress
```

### Step 3. Download the sequencing reads

Choose `Tools > Search Online Databases > Search SRA…` to open the SRA download dialog. Type `SRR36291587` into the accession field. Leave `Layout` set to `Auto-detect` so that Lungfish reads the run's metadata and concludes paired-end on its own. Click `Download`. The Operations Panel opens at the bottom of the window and shows progress as the FASTQs land.

<!-- SHOT: sra-search-dialog -->

When the operation finishes, two FASTQ files (`SRR36291587_1.fastq.gz` and `SRR36291587_2.fastq.gz`) appear in `Downloads/`, paired by the `_1` / `_2` suffix Lungfish recognizes automatically. The Operations Panel row for the download is now green and carries a checksum and size for each file; click the row to see the full provenance record. If ENA refused and Lungfish fell back to the SRA Toolkit, the row notes `Falling back to SRA Toolkit (prefetch + fasterq-dump)…` for the record.

The CLI equivalent is `lungfish fetch sra download SRR36291587 --output-dir Downloads`.

### Step 4. Map the reads to the reference

Click the `MN908947.3` reference in the sidebar so it becomes the active bundle. Choose `Tools > FASTQ/FASTA Operations > Mapping…` to open the Mapping dialog. The dialog has three sections: `Reads`, `Reference`, and `Tool`.

In the `Reads` section, click `Choose…` and select both FASTQ files from `Downloads/`. Lungfish recognizes the `_1` / `_2` suffix convention and pairs them. The reference is already filled in. In the `Tool` section, set `Mapper` to `minimap2` and `Preset` to `Short read (sr)`, the right preset for paired Illumina data. Leave the sample name as the run accession. Click `Run`.

<!-- SHOT: mapping-dialog -->

Behind the dialog, Lungfish runs `minimap2 -ax sr` piped into `samtools sort` and `samtools index`. When the operation finishes, a fresh alignment track named `SRR36291587 (minimap2)` appears in the sidebar under `MN908947.3 > Alignments`.

Other mappers are available if your data calls for them. The Mapping dialog's `Mapper` dropdown also lists `BWA-MEM2`, `Bowtie2`, and `BBMap`. minimap2 is the default for short-read viral data because it is fast, well-supported on Apple Silicon, and produces alignments equivalent to BWA-MEM in benchmark comparisons. For long-read Nanopore data, choose `minimap2` with the `Map ONT (map-ont)` preset.

The CLI equivalent of step 4 is two commands: `lungfish map ... --paired --preset sr -o mapping/` followed by `lungfish bam adopt-mapping --bundle ... --mapping-result mapping/`.

### Step 5. Primer-trim the alignment

Click the new `SRR36291587 (minimap2)` alignment track in the sidebar so its Inspector fills the right pane. Find the Inspector's `Analysis` section and click `Primer-trim BAM…`. The Primer Trim dialog opens.

In the `Primer scheme` picker, choose the bundled `QIASeqDIRECT-SARS2` scheme. The scheme picker also lists any custom schemes you have imported into the project's `Primer Schemes/` folder; QIASeqDIRECT-SARS2 ships with Lungfish. Leave `Advanced Options` collapsed: the iVar trim defaults (`Minimum read length after trim 30`, `Minimum quality 20`, `Sliding window width 4`, `Primer offset 0`) are tuned for SARS-CoV-2 amplicon data and rarely need adjustment. The output track name auto-populates as `SRR36291587 (minimap2) - Primer-trimmed (QIASeqDIRECT-SARS2)`. Click `Run`.

<!-- SHOT: primer-trim-dialog -->

Primer trimming soft-clips the primer-derived bases off the ends of every read so that the variant caller does not see them. Without this step, every position where a primer overlaps the reference would look like a variant in 50% of the reads. With it, only the bases the polymerase synthesized contribute to variant calls.

The Operations Panel runs `ivar trim` followed by `samtools sort` and `samtools index`. When it finishes, a new alignment track with the `Primer-trimmed (QIASeqDIRECT-SARS2)` suffix appears in the sidebar. The track also carries a primer-trim provenance sidecar so the variant caller knows it was already trimmed.

The CLI equivalent is `lungfish bam primer-trim --bundle ... --alignment-track ... --scheme QIASeqDIRECT-SARS2.lungfishprimers --name primer-trimmed`.

### Step 6. Call variants with iVar

Click the primer-trimmed alignment track in the sidebar. In the Inspector's `Analysis` section, select `Variant Calling` and click `Call Variants…`. The Variant Calling dialog opens with three columns: a tool sidebar on the left, an `Inputs` section in the middle, and an `Output` section on the right. The left tool sidebar has `iVar`, `LoFreq`, and `Medaka` entries; choose `iVar`.

The `Inputs` section shows the primer-trimmed alignment track. Because Lungfish recognizes the track's primer-trim provenance sidecar, the `This BAM has already been primer-trimmed for iVar` acknowledgement is auto-checked and disabled, with a caption that reads `Primer-trimmed by Lungfish on <date> using QIASeqDIRECT-SARS2`. Expand `iVar Options` to inspect the tunables: minimum allele frequency `0.05`, consensus allele frequency `0.75`, merge AF distance `0.25`, minimum ALT quality `20`, ignore strand bias on. Leave them at their defaults for this chapter. Name the output track `iVar variants` and click `Run`.

<!-- SHOT: variant-call-dialog-ivar -->

Behind the dialog, Lungfish exports the bundle's GFF3 annotations into the working directory as `ivar-annotations.gff3`, then runs `samtools mpileup` piped into `ivar variants` with that GFF3 as the `-g` argument. iVar emits a TSV; the Lungfish converter reads that TSV and, because the GFF3 was passed, groups three adjacent SNPs that fall inside one codon into a single VCF row when the codon collapses into a single amino acid change. The pipeline finishes with `bcftools sort`, `bgzip`, and `tabix`. A new variant track named `iVar variants` appears under `MN908947.3 > Variants`.

The CLI equivalent is `lungfish variants call --bundle ... --alignment-track ... --caller ivar --ivar-primer-trimmed --min-af 0.05 --name "iVar variants"`.

### Step 7. Open the variant browser

Click the `iVar variants` track in the sidebar to open the variant browser. The browser shows a genome track at the top with each variant rendered as a tick, a reference panel below it that updates as you navigate, and a sortable variant table at the bottom of the window.

<!-- SHOT: variant-browser-overview -->

The variant table starts unfiltered, showing every row in the VCF. The columns include `Chrom`, `Pos`, `Ref`, `Alt`, `Qual`, `Filter`, `Source` (which caller produced the row, useful when you have multiple variant tracks open), and the per-row `INFO` and `FORMAT` fields. Sort the table by `Pos` ascending so positions in the same neighborhood line up. To focus on confident calls only, click the `Presets` toggle in the filter bar and select the `PASS` chip. Doing so hides any iVar rows that carry `ft` (failed threshold) filter flags.

The variant browser is the primary surface for reading and exporting variants. Selecting a row centers the genome track on that position and fills the Inspector with the per-variant detail, including INFO fields and any annotation context.

### Step 8. Read the codon-merged row at position 28881

Scroll the variant table to position `28881`. The SARS-CoV-2 N gene reading frame puts positions 28881 and 28882 inside the codon that encodes amino acid 203 of the nucleocapsid protein (`AGG > AAA`, an `R203K` substitution). Position 28883 is the first base of the next codon, the codon for amino acid 204 (`GGA > CGA`, a `G204R` substitution). With the GFF3 attached, iVar reports the within-codon pair at 28881-28882 as a single row with `REF GG`, `ALT AA`, and the protein consequence in the `INFO` field. Position 28883 appears on its own row with `REF G`, `ALT C`, because it lives in a different codon.

<!-- SHOT: variant-browser-codon-merge -->

This is the codon-merging behaviour the GFF3 enables. Without annotations attached, iVar would emit three separate one-base rows at positions 28881, 28882, and 28883. Both representations describe the same biology: the reads at those positions support `R203K` paired with `G204R`, the canonical N-protein signature first seen in the B.1.1 lineage and inherited by every Omicron sublineage including the one in this sample. The annotated representation makes the codon boundary visible in the table.

The codon-merge is the most useful lesson in this chapter. A VCF row's correspondence to a biological variant is not one-to-one without annotation context. With the GFF3 attached, iVar describes biology codon by codon; without it, iVar describes positions one base at a time. Lungfish chooses the annotation-aware representation when annotations are available.

## What does good look like

Before trusting the call set, check three things.

First, in the variant browser, count the rows with `Filter PASS`. For SRR36291587 with the defaults this chapter uses, expect roughly 80-90 PASS rows in the iVar VCF. A PASS-row count of zero or in the low single digits means the alignment is broken (no reads mapped, the wrong reference, or coverage too low). A count above 200 usually means the minimum allele frequency is set too low and the table is full of sequencing-error noise.

Second, click the iVar variants track in the sidebar and look at the Inspector's `Analysis` section. The provenance sidecar should show the primer-trim provenance (`QIASeqDIRECT-SARS2`, the trim date, the input alignment checksum) and the variant-calling provenance (the iVar version, the mpileup flags, the GFF3 input checksum). Provenance is your audit trail for everything the call set depends on.

Third, sample-check a few high-confidence PASS rows against a published SARS-CoV-2 lineage definition. Position `21618 C>T` (spike T19I), the cluster around `21632-22688` in the receptor-binding domain, and the synonymous run in `nsp3` at `1931, 2790, 2954, 3037` are all expected for an Omicron isolate. If those rows appear with allele frequencies near 1.0, the workflow worked.

## What this chapter did not cover

The pilot chapter focuses on iVar against amplicon Illumina data with the bundled QIASeqDIRECT-SARS2 primer scheme. Several adjacent topics need their own chapters and are not yet documented:

- **Cross-caller comparison.** Running iVar and LoFreq on the same sample and reading their disagreements is a separate exercise. It teaches more about caller statistics than this chapter has room for.
- **Long-read variant calling.** Medaka against Oxford Nanopore amplicon data uses a different model and needs different inputs. Same Lungfish dialog, different tool selection on the left sidebar.
- **Bringing your own primer scheme.** ARTIC and custom schemes are imported through the `Primer Schemes/` folder. The Primer Scheme Picker in the trim dialog automatically lists every scheme in that folder.
- **From VCF to consensus.** Producing a consensus FASTA, attaching it to the project, and submitting it for Pango lineage assignment with external tools is a downstream workflow.
- **Read quality control.** This chapter assumes the reads are clean. For real samples, run the FASTQ Quality Trim and Adapter Removal operations before mapping.

These chapters will land in the same `04-alignments/`, `05-variants/`, and `03-reads/` parts of the manual.

## Everything you just clicked, as a shell script

The whole workflow runs from the CLI as one script. This is identical to what the GUI did behind the dialogs, with every flag visible.

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
