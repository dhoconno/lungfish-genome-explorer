---
title: From Reads to Variants
chapter_id: 04-variants/01-reads-to-variants
audience: bench-scientist
prereqs: []
estimated_reading_min: 18
shots:
  - id: ncbi-download-dialog
    caption: "Downloading the SARS-CoV-2 reference from NCBI."
  - id: sra-download-dialog
    caption: "Downloading SRR36291587 from SRA."
  - id: mapping-wizard
    caption: "Mapping reads to MN908947.3 with minimap2."
  - id: primer-trim-dialog
    caption: "Primer-trimming with the QIASeqDIRECT-SARS2 scheme."
  - id: variant-call-dialog-ivar
    caption: "Calling variants with iVar against the primer-trimmed alignment."
  - id: variant-call-dialog-lofreq
    caption: "Calling variants with LoFreq against the un-trimmed alignment."
  - id: variant-tables-side-by-side
    caption: "Both VCF tracks open in the variant browser."
  - id: cross-caller-comparison
    caption: "Where iVar and LoFreq agree and where they disagree."
glossary_refs: [VCF, REF, ALT, genotype, allele-frequency, variant-caller, primer-trim, primer-scheme, amplicon, SRA, codon, strand-bias]
features_refs: [import.vcf, viewport.variant-browser, variants.call, bam.primer-trim, fetch.ncbi, fetch.sra, map]
fixtures_refs: [sarscov2-srr36291587]
brand_reviewed: true
lead_approved: false
---

## What it is

A variant call set is the short answer to a long question. The long question is "what does this sequenced sample carry that differs from the reference?" The short answer is a VCF file: one row per position where the sample disagrees, with the bases involved and how confident the caller is. This chapter walks the full path from two public accession numbers to that VCF, twice over, using two different callers, so you can see the same data interpreted two ways and read the difference.

The path has six ingredients. A reference genome (the `MN908947.3` SARS-CoV-2 Wuhan isolate, 29,903 bases) downloaded from NCBI. A sequencing run (`SRR36291587`, about 86,000 paired-end Illumina read pairs from a clinical sample prepared with QIAseq Direct primers) downloaded from the Sequence Read Archive. A read mapper (`minimap2` with the short-read preset) that places each read on the reference and writes a sorted, indexed BAM. A primer-trim step (`ivar trim` driven by the QIASeqDIRECT-SARS2 primer scheme) that soft-clips the primer-derived bases off read ends so they do not look like real variants. And finally two variant callers: iVar against the primer-trimmed alignment, LoFreq against the un-trimmed alignment, each producing one VCF.

You finish the chapter with a Lungfish project that holds one reference, two alignment tracks (the raw mapping and the primer-trimmed version), and two variant tracks side by side in the variant browser. The two tracks describe the same sample, but they describe it through two different statistical lenses. The point of the chapter is not just to produce the call set. It is to read the agreement and disagreement between two callers and to leave you with a calibrated sense of which rows are findings and which rows are caller noise.

The whole workflow takes about five minutes on a recent Apple Silicon Mac, of which most is the SRA download. Lungfish drives every step from the Operations Panel, and the underlying CLI commands are the same ones the chapter author used to produce the committed reference VCFs you can check your output against. So what should you do with this? Treat the chapter as a calibration run. Once you have walked it once with these accessions, you can run the same procedure against your own reads with two clicks and one accession swap.

## Why this matters

Reading a VCF that someone else handed you is a sanity check. Producing the VCF yourself is the only way to know which caller, which parameters, and which preprocessing steps are baked into the table you are looking at. Variant calling is deterministic on the same inputs with the same caller. Different callers with different defaults can disagree on borderline calls. That disagreement is information. A position both callers agree on at high allele frequency is a finding you can take to a downstream analysis. A position one caller flags and the other ignores deserves a second look at the pileup.

For amplicon data specifically, the primer-trim step is not optional decoration. Primer-derived bases sit at fixed positions on every read from a given amplicon, and a caller cannot tell those bases apart from the sample's real sequence. Skipping the trim biases allele frequencies upward in a pattern that looks exactly like a real variant. The QIASeqDIRECT-SARS2 scheme bundled with Lungfish lists the start and end coordinates of every primer in the QIAseq Direct SARS-CoV-2 protocol; `ivar trim` reads that list and soft-clips the primer regions out of the pileup. You run two callers in this chapter on purpose: iVar consumes a primer-trimmed BAM (it disclaims any responsibility for amplicon bias if you give it an un-trimmed one), while LoFreq is happiest with a raw alignment because its statistical model expects a population of reads where read starts are randomly distributed. Feeding each caller the input it expects is part of what calling variants well looks like.

The choices that bake into a call set are not abstract. They live in the dialogs you click through. Picking the right caller for the data type matters: iVar is tuned for primer-trimmed amplicon data, LoFreq for short-read viral data more generally, Medaka for long-read Nanopore. Picking the right primer scheme matters: a wrong scheme leaves real primer bases in the pileup. The minimum allele frequency a caller will report matters: Lungfish's iVar dialog default of 5% means it will not report a variant supported by 2% of reads. LoFreq's permissive defaults will. Strand bias treatment matters: amplicon data is structurally strand-biased because primers point in fixed directions, so a strict strand-bias filter will reject genuine variants on the basis of the protocol you used to generate the reads.

The cross-caller comparison the chapter ends with is the practical payoff. When two callers with two different defaults agree on a position and an alternate base, the prior on that being a real variant is strong. When they disagree, the disagreement points at what kind of evidence each caller is looking for, and it tells you what kind of evidence the position has. That is the difference between trusting a tool and using one.

## Before you start

The chapter needs two Lungfish plugin packs, the read-mapping pack (for `minimap2` and `samtools`) and the variant-calling pack (for `ivar`, `lofreq`, `bcftools`, `tabix`, and `bgzip`). Install both at once from the shell:

```text
lungfish conda install read-mapping variant-calling
```

The first install pulls about 250 MB into `~/.lungfish/conda` and takes a couple of minutes. After that the tools are available to every Lungfish project on the machine, and the install is idempotent, so re-running the command costs only a hash check. To verify provisioning, run `lungfish conda list` and confirm both pack names appear with status `installed`.

Disk and time budget for the chapter itself: about 250 MB of temporary storage during the run (the SRA reads decompress to roughly 21.7 MB compressed plus 86 MB uncompressed, and the BAM lands around 16 MB after primer-trim), and about five minutes of wall clock on a recent Apple Silicon Mac. The SRA download is by far the slowest step, and how slow depends on which mirror serves your request. ENA usually returns the FASTQs in under a minute; the SRA Toolkit fallback takes two to three minutes because it streams through `prefetch` and `fasterq-dump`. Lungfish tries ENA first and falls back automatically if ENA refuses, so you do not need to choose.

The chapter assumes Lungfish is installed and launched, that you have an active project window, and that you can read a VCF row at the level chapter zero introduced (CHROM, POS, REF, ALT, FILTER, the per-site INFO and FORMAT payloads). It does not assume you have called variants before. If a step in the procedure produces an error, the most common cause is a missing plugin pack. Re-run `lungfish conda install` and try the step again before debugging anything else.

## Procedure

1. Create a new Lungfish project to hold the workflow's outputs. From the Welcome window choose `Create Project`, or from the menu bar choose `File > New Project`. Name the project (`SARS-CoV-2 SRR36291587` is a sensible label) and save it under your `Documents` folder. Lungfish opens a new window titled with the project name. Then download the reference. Choose `File > Download from NCBI > Reference Sequence…` to open the NCBI download dialog. Type `MN908947.3` into the accession field, leave `Format` set to `FASTA`, and click `Download`. The dialog closes when the FASTA lands in the project's `Downloads/` folder. Lungfish prompts you to make a reference bundle out of it. Accept the default name and click `Create Bundle`. The reference appears in the left sidebar under `Reference Sequences > MN908947.3`. Behind the dialog the CLI ran `lungfish fetch ncbi MN908947.3 --fetch-format fasta` followed by `lungfish bundle create --fasta MN908947.3.fasta --compress`.

   <!-- SHOT: ncbi-download-dialog -->

2. Download the sequencing reads. Choose `File > Download from SRA…` to open the SRA download dialog. Type `SRR36291587` into the accession field. Leave `Layout` set to `Auto-detect` (Lungfish reads the run's metadata and concludes paired-end on its own). Click `Download`. The Operations Panel opens at the bottom of the window and shows progress as the FASTQs land. Lungfish tries the ENA mirror first and falls back to the SRA Toolkit if ENA refuses; you do not see that decision unless the fallback fires, in which case the operation row carries a `Falling back to SRA Toolkit (prefetch + fasterq-dump)…` note. When the operation finishes, two FASTQ files (`SRR36291587_1.fastq.gz` and `SRR36291587_2.fastq.gz`) appear in `Downloads/`. The CLI equivalent is `lungfish fetch sra download SRR36291587`.

   <!-- SHOT: sra-download-dialog -->

3. Map the reads to the reference. Click the `MN908947.3` reference in the sidebar so it becomes the active bundle. Choose `Tools > Map Reads…` to open the Mapping wizard. In the `Reads` section, click `Choose…` and select both FASTQs. Lungfish recognises the `_1` / `_2` suffix convention and pairs them automatically. In the `Mapper` row choose `minimap2`. In the `Preset` dropdown choose `Short read (sr)`, the right preset for paired Illumina data. Leave the sample name as the run accession. Expand `Advanced Options` if you want to inspect the defaults; leave them as shipped. Click `Run`. The Operations Panel runs `minimap2 -ax sr` piped into `samtools sort` and `samtools index`, and when it finishes a fresh alignment track named `SRR36291587 (minimap2)` appears in the sidebar under `MN908947.3 > Alignments`. The CLI equivalent of these last two steps is `lungfish map ... --paired --preset sr` followed by `lungfish bam adopt-mapping --bundle ... --mapping-result ...`, which the wizard ran for you.

   <!-- SHOT: mapping-wizard -->

4. Primer-trim the alignment. Click the new `SRR36291587 (minimap2)` alignment track in the sidebar so its Inspector fills the right pane. In the Inspector's `Read Style` section, click `Primer-trim BAM…`. The Primer Trim dialog opens. In the `Primer scheme` picker, choose the built-in `QIASeqDIRECT-SARS2` scheme. Expand `Advanced Options` only if you want to inspect the iVar trim defaults (`Minimum read length after trim` 30, `Minimum quality` 20, `Sliding window width` 4, `Primer offset` 0); leave them as shipped. The output track name auto-populates as `SRR36291587 (minimap2) • Primer-trimmed (QIASeqDIRECT-SARS2)`; leave it as is. Click `Run`. The Operations Panel registers the trim and runs `ivar trim` followed by `samtools sort` and `samtools index`. When it finishes, a new alignment track with the `Primer-trimmed (QIASeqDIRECT-SARS2)` suffix appears in the sidebar. The CLI equivalent is `lungfish bam primer-trim --bundle ... --alignment-track ... --scheme QIASeqDIRECT-SARS2.lungfishprimers`.

   <!-- SHOT: primer-trim-dialog -->

You now have a project with one reference, two alignment tracks, and zero variant tracks. The next four steps run two callers against those alignments and load the results in the variant browser.

1. Call variants with iVar against the primer-trimmed alignment. Select the primer-trimmed track in the sidebar. In the Inspector, scroll to the `Duplicate Handling` section and click `Call Variants…`. The Call Variants dialog opens. In the tool sidebar on the left, choose `iVar`. The `Inputs` section shows the trimmed alignment track. Because Lungfish recognises the track's primer-trim provenance sidecar, the `This BAM has already been primer-trimmed for iVar` acknowledgement is auto-checked and disabled, with a caption that reads `Primer-trimmed by Lungfish on <date> using QIASeqDIRECT-SARS2`. Expand `iVar Options` to inspect the iVar tunables (minimum allele frequency 0.05, consensus allele frequency 0.75, merge AF distance 0.25, minimum ALT quality 20, ignore strand bias on); leave them as shipped. Name the output track `iVar variants` and click `Run`. The Operations Panel runs `samtools mpileup` piped into `ivar variants`, the Lungfish converter writes the iVar TSV out as VCF, then `bcftools sort`, `bgzip`, and `tabix` finish the chain. A new variant track named `iVar variants` appears under `MN908947.3 > Variants`. The CLI equivalent is `lungfish variants call --bundle ... --alignment-track ... --caller ivar --ivar-primer-trimmed --min-af 0.05 --name "iVar variants"`.

   <!-- SHOT: variant-call-dialog-ivar -->

2. Call variants with LoFreq against the un-trimmed alignment. Select the original `SRR36291587 (minimap2)` track in the sidebar (not the primer-trimmed one). LoFreq's statistical model assumes that read starts are distributed across the reference, which is true of random-fragment libraries but only loosely true of amplicon libraries. The convention in the field, and the one the chapter follows, is to feed LoFreq the un-trimmed alignment and to read its calls with primer placement in mind. Click `Call Variants…` again. In the tool sidebar choose `LoFreq`. The `Inputs` section shows the un-trimmed track. There is no primer-trim acknowledgement for LoFreq, only the standard `Reference` and `Output` rows. Name the output track `LoFreq variants` and click `Run`. The Operations Panel runs `lofreq call-parallel`, then the same `bcftools sort` / `bgzip` / `tabix` chain as before. A second variant track named `LoFreq variants` appears under `Variants`. The CLI equivalent is `lungfish variants call --bundle ... --alignment-track ... --caller lofreq --name "LoFreq variants"`.

   <!-- SHOT: variant-call-dialog-lofreq -->

3. Open both variant tracks in the variant browser. Click the `iVar variants` track in the sidebar to load the variant browser. The browser shows a genome track at the top and a sortable table at the bottom. Now Cmd-click the `LoFreq variants` track to add it to the same view; both tracks render together, color-coded, and the table grows a `Caller` column showing which row came from which track. By default the table applies a `Quality / QC: PASS` filter. Click the `PASS` chip to deselect it if you want to see the iVar rows that fall under the `ft` filter. Sort the table by `POS` ascending so positions in the same neighborhood line up.

   <!-- SHOT: variant-tables-side-by-side -->

4. Compare the two tracks. With both tracks loaded, the variant browser shows agreements and disagreements at a glance. Each row in the table carries a `Caller` column; agreements appear as paired rows at the same `POS`, disagreements as solo rows from one caller only. Scroll to the spike region around position 21618. Both callers report a single SNP there at allele frequency near 1.0. Scroll to position 28881. Both callers list three adjacent SNPs at 28881, 28882, and 28883, all at allele frequency near 1.0, three rows each. Note that both files describe the same biology in two different statistical languages. The next section walks through reading those two languages side by side.

   <!-- SHOT: cross-caller-comparison -->

## Interpreting what you see

Open the two tracks side by side and the first thing you should notice is how much they agree. Both callers find the high-confidence consensus variants you would expect for an Omicron-lineage SARS-CoV-2 isolate: the spike `C21618T` near the start of the gene, the run of substitutions and deletions in the spike receptor-binding domain (around positions 21632, 21764, 22578, 22674-22688), the synonymous pattern in nsp3 (positions 1931, 2790, 2954, 3037), and the cluster in the N gene at 28311-28312 and 28881-28883. Where both callers agree at allele frequency near 1.0, you can read the row as a confident finding and move on.

The disagreements fall into three categories, and each one teaches a different lesson.

The first category is rows iVar reports that LoFreq does not. Look at position 1193 (`A>G`), where iVar reports allele frequency 0.123 with depth 1531 and LoFreq is silent. Look at position 1730 (`G>A`), where iVar reports allele frequency 0.172 with depth 1241 and LoFreq is also silent. iVar reports variants whose allele frequency clears the Lungfish default `--min-af 0.05` threshold and whose ALT depth clears its quality threshold. LoFreq applies a per-site quality model and a multiple-testing correction; on high-depth amplicon pileups, the LoFreq Phred score can still fail to clear its dynamic threshold. Neither caller is wrong. iVar is reporting raw observations. LoFreq is reporting observations the model believes are more likely real than instrumentation noise. For amplicon data with very high local depth, LoFreq's threshold rises with depth, which is why these moderate-AF iVar rows do not appear in the LoFreq table.

The second category is rows LoFreq reports that iVar does not. Look at position 1989 (`A>G`), with LoFreq depth 2032 and allele frequency 0.005. Lungfish's iVar minimum frequency of 5% silently drops everything below that line. Look at position 12182 with LoFreq AF 0.006, and compare it with position 5235 where LoFreq reports AF 0.074 but iVar is still silent after primer trimming and its own quality model. The very-low-AF LoFreq calls (under 1%) are nearly always sequencing-error noise that LoFreq's permissive default reports anyway; you would filter them out in any real analysis. The higher-AF rows that only LoFreq reports deserve closer inspection because the difference can come from caller statistics, primer-trimmed coverage, or filters rather than one threshold alone. The trade-off is the chapter's point: iVar gives you a clean call set with a higher floor; LoFreq gives you a noisier call set that includes minority-haplotype evidence.

The third category is rows where both callers fire but disagree on allele frequency. Look at position 27889 (`C>T`). iVar reports allele frequency 0.991 at depth 884, while LoFreq reports allele frequency 0.609 at depth 1170. The two callers are looking at related but not identical evidence: iVar is working from the primer-trimmed BAM, and LoFreq is working from the original alignment. Primer trimming changes which bases contribute at amplicon edges, and each caller then applies its own pileup and quality model. Either number can be defensible in context. The disagreement is the signal worth reading.

The codon teaching moment lands at position 28881. The N-protein open reading frame puts positions 28881, 28882, and 28883 inside one codon, the codon that encodes amino acid 203 of the nucleocapsid. The iVar TSV-to-VCF converter, when handed a real GFF, would group those three SNPs into a single haplotype row with REF `GGG` and ALT `AAC`, because together they encode one amino acid change (R203K plus G204R, the classic B.1.1 / Omicron N-protein signature) rather than three. In the fixture VCF you have open, that merge did not happen: the iVar VCF header carries `##LungfishNote=GFF unavailable; codon merging skipped`, and the converter falls through to per-row transcription with three separate rows. Open the fixture's annotated reference (the same `MN908947.3.lungfishref` bundle) in a project that already has the GFF attached, and the iVar VCF you produce there will collapse the three rows into one. LoFreq will still emit three rows. This is the moment you realize that "one variant per row" is a presentation choice with biological consequences. Two callers can describe the same change. Whether they describe it as one row or three depends on whether they consult an annotation file before they write VCF.

The takeaway from cross-caller comparison is not that one caller is right and the other wrong. The takeaway is that "the call set" is not a single object. It is a function of caller, parameters, and preprocessing, and reading two callers' tables for the same sample is the most honest way to see which positions are findings and which are caller decisions.

## Next steps

The deeper chapters this one points at do not yet exist. A future alignment chapter under `03-alignments/` will walk through producing the BAM you used here at greater depth, including read-quality filtering and duplicate marking. A future variants chapter will cover Medaka for long-read Oxford Nanopore data and the consensus-genome workflow on top of these calls. A future amplicon chapter will go deeper on primer-scheme bundles and how to bring your own scheme into Lungfish.

The natural next step is to rerun this same procedure against your own reads. Swap the SRA accession for your own FASTQs (`File > Import…` instead of `File > Download from SRA…`), pick the primer scheme that matches the protocol you used, and run iVar and LoFreq the same way. The first time you do it the procedure feels long. The second time it is muscle memory. By the third sample you will read the cross-caller comparison the way you read a gel, fluently, with a calibrated sense of which patterns deserve a closer look.

The chapter cited the SARS-CoV-2 SRR36291587 fixture. {{ fixtures_refs.sarscov2-srr36291587 | cite }}
