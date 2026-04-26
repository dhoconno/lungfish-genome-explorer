---
title: Calling variants from a BAM
chapter_id: 04-variants/02-calling-variants-from-a-bam
audience: bench-scientist
prereqs: [04-variants/01-reading-a-vcf]
estimated_reading_min: 10
shots:
  - id: primer-trim-dialog
    caption: "The Primer Trim dialog with the QIASeqDIRECT-SARS2 scheme selected."
  - id: variant-call-dialog
    caption: "The Call Variants dialog with iVar selected against the trimmed alignment."
  - id: variant-table-fresh-call
    caption: "The freshly produced VCF loaded in the variant browser."
glossary_refs: [VCF, REF, ALT, genotype, allele-frequency, variant-caller, primer-trim, primer-scheme, amplicon]
features_refs: [viewport.variant-browser, variants.call, bam.primer-trim]
fixtures_refs: [sarscov2-clinical]
brand_reviewed: true
lead_approved: false
---

## What it is

Variant calling is the step that turns aligned reads into a list of differences from the reference. A variant-caller walks every position the reads cover, compares the bases the reads carry to the base in the reference FASTA, and writes one VCF row for each position where the sample disagrees by enough to be worth reporting. Chapter 01 read a VCF that someone else produced. This chapter has you produce one yourself, from the same fixture, so that the table you opened before is no longer a black box.

A BAM file is the input. It is the binary, indexed form of a SAM alignment file: one record per read, recording where on the reference that read aligned, how well it aligned, and which bases differed from the reference along the way. The fixture's `alignments.bam` was produced by mapping about 100 read pairs from a SARS-CoV-2 clinical isolate against `MT192765.1`. The accompanying `alignments.bam.bai` is a position index that lets the app and the caller seek into the BAM without scanning it end-to-end. For the purposes of this chapter, the BAM is a given: the fixture ships it ready to use.

The arc of this chapter has four beats. First, you locate the fixture's BAM in a Lungfish project. Second, you trim primer-derived bases off the read ends with the QIASeqDIRECT-SARS2 primer scheme, because the fixture reads come from a tiled amplicon protocol and primer bases at read ends would inflate the allele frequencies the caller reports. Third, you run Call Variants with iVar against the trimmed alignment. Fourth, you compare the freshly produced VCF to the one chapter 01 dissected and confirm they describe the same variants.

So what should you do with this? Treat the BAM as a checkpoint. Once you have a sorted, indexed BAM and a primer scheme that matches it, variant calling is mechanical and you can run it whenever you need to.

## Why this matters

Reading a VCF someone handed you is a sanity check. Producing the VCF yourself is the only way to know which caller, which parameters, and which preprocessing steps are baked into the table you are looking at. For amplicon data specifically, the primer-trim step is not optional decoration. Primer-derived bases sit at fixed positions on every read from a given amplicon, and a caller cannot tell those bases apart from the sample's real sequence. Skipping the trim biases allele frequencies upward in a pattern that looks exactly like a real variant. Running the trim yourself, with a primer scheme you picked, is how you keep that bias out of the final call set.

Be honest about what this fixture can and cannot show. The BAM here covers the genome with about 100 read pairs, which translates to a per-site read depth (`DP`) usually in the single digits. That is deliberately small so the fixture stays committable. It also means every record the caller produces will carry `FILTER=LowQual`, exactly as in chapter 01. The point of the exercise is not to produce a confident clinical call set. It is to confirm that on the same inputs, with the same caller, you get the same VCF. Determinism is the property worth seeing for yourself.

## Procedure

1. Reuse the project from chapter 01 (or create a new one and import `reference.fasta` via `File > Import Center… > Reference Sequences`). Click the reference entry in the sidebar so its metadata fills the middle pane: importing alignments requires an active reference bundle. Open `File > Import Center…`, select `Alignments` in the left rail, click `Import…`, and choose `fixtures/sarscov2-clinical/alignments.bam`. The BAM imports against the active reference. The Inspector on the right grows new sections (`Alignment Summary`, `Read Display`, `Read Filters`, `Consensus`, `Duplicate Handling`) confirming the import landed.
2. Open the alignment Inspector and click `Primer-trim BAM…`. In the `Primer scheme` picker, choose the built-in `QIASeqDIRECT-SARS2` scheme. Expand `Advanced Options` only if you want to inspect the iVar defaults (`Minimum read length after trim` 30, `Minimum quality` 20, `Sliding window width` 4, `Primer offset` 0); leave them as shipped. The output track name auto-populates as `<source-track-name> • Primer-trimmed (QIASeqDIRECT-SARS2)`; leave it as is.

<!-- SHOT: primer-trim-dialog -->

3. Click `Run`. The Operations Panel registers the trim and runs `ivar trim` followed by `samtools sort` and `samtools index`. When it finishes, a new alignment track appears in the sidebar carrying the `Primer-trimmed (QIASeqDIRECT-SARS2)` suffix. Select that new track.
4. Click `Call Variants…` in the Inspector's `Duplicate Handling` section. The Call Variants dialog opens. In the tool sidebar on the left, choose `iVar`. The `Inputs` section shows the trimmed alignment track you just produced. Because Lungfish recognises the track's primer-trim provenance sidecar, the `This BAM has already been primer-trimmed for iVar.` acknowledgement is auto-checked and disabled, with a caption that reads `Primer-trimmed by Lungfish on <date> using QIASeqDIRECT-SARS2.`.
5. Click `Run`. The CLI runs `samtools mpileup` piped into `ivar variants --output-format vcf`, normalises the output with `bcftools sort`, compresses it with `bgzip`, and indexes it with `tabix`. When the run completes, a new variant track appears in the sidebar. Select it.

<!-- SHOT: variant-call-dialog -->

<!-- SHOT: variant-table-fresh-call -->

## Interpreting what you see

Open the freshly called VCF beside the fixture's `variants.vcf.gz` from chapter 01 and compare them row by row. The chromosome name is the same (`MT192765.1`), the positions are the same, the REF and ALT alleles are the same, and the `FILTER` column reads `LowQual` on every row in both files. This is the payoff: variant calling is deterministic on the same inputs. With the same BAM, the same reference, and the same caller settings, anyone can re-derive the same VCF.

The two callers are not identical, so a few details differ in shape even when the calls agree. The fixture's reference VCF was produced with `bcftools mpileup` plus `bcftools call`; the VCF you just produced is iVar's native output. The columns that differ are the per-site `INFO` and `FORMAT` payloads, not the variant set itself. iVar's `LowQual` flag fires when the supporting read count or allele-frequency support falls below the iVar default thresholds, which on a fixture this small means every record. iVar also writes an explicit `AF` (allele-frequency) tag for each call, defined as the fraction of reads at the site that carry the alternate base. The primer-trim step you ran in step 3 is what makes that `AF` value trustworthy: without trimming, primer-derived bases at read ends would push `AF` toward 1.0 at amplicon edges, regardless of what the sample actually carries.

The `DP` values you see should sit in the same single-digit range chapter 01 described, and the genotypes will read as `1/1` for the substitution rows, with the same low-confidence indel at position 10506. If a row in your fresh VCF carries a slightly different `DP` or `AF` than the chapter 01 file, that is a real signal: it means the primer-trim step soft-clipped one or two bases out of the pileup at that position. That is the trim doing its job.

## Next steps

When the alignment chapter under `03-alignments/` lands, it will walk through producing the BAM you used here, starting from the FASTQ reads. Until then, the natural next step is to rerun this same procedure against a deeper dataset of your own. With a per-site `DP` in the dozens or hundreds, most of the rows that read `LowQual` here will clear the filter and read as confident calls, and the `AF` column will start to carry the information it is designed to carry.
