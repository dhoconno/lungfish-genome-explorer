---
title: Reading Two Callers in One Table
chapter_id: 05-variants/03-cross-caller-comparison
audience: analyst
prereqs: [05-variants/01-calling-variants-from-amplicons, 05-variants/02-reading-the-variant-browser]
estimated_reading_min: 12
task: Run a second caller on the same sample and read the two call sets side by side in the aggregated variant table.
tags: [variants, ivar, lofreq, bcftools, comparison, source-column]
tools: [ivar, lofreq, bcftools]
entry_points:
  - "Inspector > Analysis > Variant Calling > Call Variants (run twice with different callers)"
shots: []
planned_shots:
  - id: cross-caller-source-column
    caption: "The aggregated variant table on a bundle with iVar and LoFreq tracks, sorted by Position, with the Source column distinguishing the rows."
  - id: cross-caller-disagreement-1193
    caption: "Position 1193 in the variant table: an iVar row with no matching LoFreq row at the same coordinate."
  - id: cross-caller-disagreement-1989
    caption: "Position 1989 in the variant table: a LoFreq row with no matching iVar row at the same coordinate."
  - id: cross-caller-codon-merge-28881
    caption: "The 28881 neighbourhood, where one merged iVar GG-to-AA row and a 28883 row sit alongside three single-base LoFreq rows."
illustrations: []
glossary_refs: [variant-caller, allele-frequency, FILTER, codon, strand-bias, pileup]
features_refs: [variants.call]
fixtures_refs: [sarscov2-srr36291587]
brand_reviewed: false
lead_approved: false
---

## What it is

Lungfish does not have a dedicated cross-caller comparison tool. There is no comparison view, no intersection or union export, and no codon-aware decomposition feature. What Lungfish does provide is the substrate you need to compare callers by eye: when a reference bundle carries more than one variant track, the variant browser loads them all into one table, and a `Source` column tags every row with the file it came from. This chapter teaches you to call a second caller on the same sample, read the two call sets side by side in that shared table, and reason about their disagreements yourself.

Different variant callers describe the same data through different statistical lenses. iVar is an allele-frequency threshold caller designed for primer-trimmed amplicon data. LoFreq is a per-base error model with multiple-testing correction designed for shotgun viral data. bcftools combines `mpileup` and `call` into a general genotype-likelihood caller that is useful as an orthogonal cross-check. Running more than one caller on the same sample and reading their disagreements is a calibration exercise, not a contest to decide which one is right. Each caller answers a slightly different question about the same pileup.

The chapter walks the iVar VCF you produced in [Calling Variants from Amplicon Reads](01-calling-variants-from-amplicons.md), runs LoFreq against the same workflow's alignment, and reads both tracks in the aggregated table at four positions in `SRR36291587` that show the patterns to look for. It closes with the codon-merge case at 28881-28882, where iVar collapses adjacent within-codon SNPs into one VCF row and LoFreq does not. That representational difference is the most useful thing this chapter teaches, because it determines whether a by-hand set intersection will line up. The practical takeaway: run iVar plus at least one orthogonal caller when the call set will go into a methods section, read them together in the table, and if you need a programmatic intersection or union, export each track and use external `bcftools isec`.

## What you will learn

Once you have finished, you can call LoFreq on an alignment in the same bundle, read two variant tracks together in the aggregated table, recognise the categories of cross-caller disagreement, decide which caller's call set to take into a downstream analysis, and run a defensible set intersection in external `bcftools` despite iVar's codon merging.

## How iVar, LoFreq, and bcftools differ

The callers were designed against different sequencing regimes. iVar was written for the ARTIC SARS-CoV-2 amplicon protocol and assumes its input is already primer-trimmed. LoFreq was written for shotgun viral resequencing and assumes reads start at random positions across the genome, but it runs on an amplicon BAM as well, which is exactly the cross-check this chapter uses it for. bcftools is a general short-read caller you steer with command-line options. The defaults each caller ships with reflect those assumptions.

| Question | iVar | LoFreq | bcftools |
|---|---|---|---|
| Statistical model | Per-position allele-frequency threshold | Per-base error model with multiple-testing correction | Genotype-likelihood model from `mpileup` evidence |
| Assumed input | Primer-trimmed amplicon BAM | Shotgun BAM; amplicon BAM accepted with caveats | General short-read BAM |
| What it reports | Positions whose ALT allele frequency clears the threshold | Positions whose Phred-scaled p-value clears a depth-dependent significance threshold | Sites selected by `bcftools call -mv` from the pileup |
| Default minimum AF | 0.05 (5%) | None; the threshold is depth-dependent and falls as coverage rises | None by default; set ploidy and other knobs through extra arguments |
| Codon awareness | Yes, when given a GFF; merges adjacent within-codon SNPs into one row | No; one row per base | No; one row per called site |

The callers also disagree about what a row means. An iVar row claims the alternate allele frequency is at least the threshold. A LoFreq row claims the alternate allele is significantly more frequent than the local sequencing error rate. A bcftools row is a genotype-likelihood call from the pileup. Those are different claims, and a position can satisfy one and not the others.

The practical consequence is a predictable disagreement structure. iVar reports rows in the 5% to a few-percent band that LoFreq's depth-dependent model rejects at high coverage. LoFreq reports rows below 5% at deep coverage that iVar's fixed threshold never sees. And both report the same high-frequency variants, sometimes with different filter outcomes. In practice, treat the two call sets as two perspectives on the same evidence rather than two competitors. A by-eye read of the aggregated table is enough to characterise the overlap; a programmatic intersection or union is an external `bcftools isec` step, covered at the end of this chapter.

## A note on caller availability

Of the viral callers, iVar, LoFreq, Medaka, and Clair3 install with the `variant-calling` pack you set up in [Calling Variants from Amplicon Reads](01-calling-variants-from-amplicons.md). bcftools lives in a different pack, `lungfish-tools`. That is the Required Setup pack you already installed to create or open a project (it bundles bcftools, samtools, htslib, and nextflow), so bcftools is almost certainly present already. If it is somehow missing, this command restores it:

```bash
lungfish conda install --pack lungfish-tools
```

LoFreq is in `variant-calling`, so the worked example below, which uses LoFreq as the second caller, needs nothing beyond the pack from the previous chapter.

## Procedure

The procedure has three phases. Phase one runs LoFreq against an alignment in the same bundle and produces a second variant track (steps 1-2). Phase two opens the aggregated table (step 3). Phase three walks four positions that show the disagreement patterns (step 4).

This procedure assumes you already have the project from [Calling Variants from Amplicon Reads](01-calling-variants-from-amplicons.md) open, with the iVar variants track in the sidebar under `MN908947.3 > Variants`. If you do not, run that chapter first or load its fixture. {{ fixtures_refs.sarscov2-srr36291587 | cite }}

### Step 1. Choose the alignment for LoFreq

Many amplicon analysts run LoFreq on the un-trimmed alignment, because LoFreq's strand-bias filter can reject primer-trimmed reads on the residual strand asymmetry that soft-clipping leaves behind. Lungfish does not couple LoFreq to a particular track: it will run on any eligible BAM in the bundle, trimmed or not. Running on the un-trimmed track is an operator convention, not an app requirement.

In the sidebar, expand `MN908947.3 > Alignments`. You should see two alignment tracks: `minimap2 Mapping` from the original mapping step, and `minimap2 Mapping - Primer-trimmed (QIASeqDIRECT-SARS2)` from the primer-trim step. Click the un-trimmed `minimap2 Mapping` track. The Inspector fills with its metadata.

### Step 2. Run LoFreq

In the Inspector's `Analysis` section, select `Variant Calling` and click `Call Variants`. The Variant Calling dialog opens with `LoFreq` already selected by default, so you can leave the tool sidebar as it is.

The `Inputs` section shows the selected alignment. The `This BAM has already been primer-trimmed` acknowledgement matters only for iVar and stays unchecked here. LoFreq has no options pane of its own: its panel reads only "LoFreq is ready to run directly on the selected bundle alignment track." The only controls that reach LoFreq are the shared `Minimum Allele Frequency` and `Minimum Depth` thresholds and the free-text `Extra arguments` box. Lungfish does not supply LoFreq a minimum-coverage, minimum-base-quality, or significance flag of its own; to set one of LoFreq's internal knobs, type it into `Extra arguments` exactly as LoFreq expects it (for example, `--min-cov 50`). Name the output track `LoFreq variants` and click `Run`.

<!-- planned: cross-caller-source-column -->

Behind the dialog, Lungfish runs `lofreq call-parallel --pp-threads N -f <reference> -o <out> <bam>`, inserting anything from `Extra arguments` immediately after `call-parallel`, before the `--pp-threads`/`-f`/`-o` flags and the positional BAM. LoFreq emits a VCF directly; the pipeline sorts the records and then bgzips and tabix-indexes the result. A new variant track named `LoFreq variants` appears under `MN908947.3 > Variants` next to the iVar track. The Operations Panel row carries the LoFreq version, the input BAM checksum, and the resolved command line.

The CLI equivalent is `lungfish variants call --bundle MN908947.3.lungfishref --alignment-track <untrimmed-id> --caller lofreq --name "LoFreq variants"`. To add a bcftools cross-check instead, run the same command with `--caller bcftools --extra-args "--ploidy 1"` and name the output track `bcftools variants`; the extra argument is inserted into the `bcftools call` stage.

### Step 3. Open the aggregated table

Click either variant track in the sidebar to open the variant browser. Because the bundle now carries two variant tracks, the table fills with the rows from both at once; you do not load the second track by hand. The genome track at the top shows the variants, and the variant table below shows every row from both files, with the `Source` column populated by which file each row came from.

If the `Source` column is hidden, right-click the table header and check `Source` to show it. Sort the table by `Position` ascending so positions in the same neighbourhood line up: the iVar row and the LoFreq row for one coordinate appear on adjacent lines, except where iVar's codon merge spans two bases, which the 28881 walkthrough below covers. Where only one caller reports a position, only that caller's row appears. Read the callers apart from the `Source` text, not from the tick color on the genome track, so the comparison still works in print, at small sizes, and for a colorblind reader.

### Step 4. Walk through four positions

The remainder of the procedure visits four positions. Each shows a pattern worth recognising. These positions and their numbers are illustrative landmarks for this isolate, taken from the chapter fixture; they are not values the app guarantees, and a real call set mixes all the patterns together. To navigate, click the row in the table, or type a `Position=` clause into the filter bar (for example `Position=1193`). The colon syntax some tools use (`Pos:1193`) is not a valid operator here, and the column is `Position`, not `Pos`. The genome track centres on the position and the Inspector fills with the per-row detail.

#### Position 1193: iVar reports, LoFreq does not

Filter to `Position=1193`. In the fixture the table shows one row, source iVar, with `REF A`, `ALT G`, an allele frequency around 0.12 at a depth near 1500, filter `PASS`. There is no LoFreq row at this coordinate.

<!-- planned: cross-caller-disagreement-1193 -->

This is the iVar-only pattern. The alternate allele sits around 12% of reads, well above iVar's 5% threshold, so iVar reports it. LoFreq did not produce a row here. The biological interpretation of a low-frequency amplicon call is open: it may be a real within-host variant, or an amplicon artefact at a primer-imbalanced position. Without an orthogonal sample (a second library, a deeper run) you cannot settle it from the call alone. The methods convention is to report iVar's call and note that LoFreq did not corroborate it.

#### Position 1989: LoFreq reports, iVar does not

Filter to `Position=1989`. In the fixture the table shows one row, source LoFreq, with `REF A`, `ALT G`, an allele frequency around 0.005 at a depth near 2000, filter `PASS`. There is no iVar row at this coordinate.

<!-- planned: cross-caller-disagreement-1989 -->

This is the LoFreq-only pattern, and the case LoFreq was designed for. The alternate allele is present in well under 1% of reads, far below iVar's 5% threshold, so iVar never reports it. LoFreq, evaluating the same pileup against its per-base error model at this depth, finds the alternate count significantly higher than the local error rate and passes the call. The trade-off is that LoFreq's call set at deep coverage is large, and many of its lowest-frequency calls in real data are sequencing artefacts the model cannot distinguish from genuine rare alleles.

For surveillance on a mixed-population sample (wastewater, where minority lineage signal is the point) you want LoFreq's call set or the union. For a clinical isolate where you are reconstructing one consensus sequence, you want iVar's call set or the intersection. The right answer depends on the biological question, not the caller.

#### Position 27889: both report, frequencies differ

Filter to `Position=27889`. In the fixture both callers report this position with `REF C`, `ALT T`. The iVar row sits near 0.99 allele frequency; the LoFreq row sits near 0.61 at a similar depth, and both carry filter `PASS`. The two callers agree the variant is real but estimate its frequency differently, because they count and weight the supporting reads differently at a primer-driven strand distribution.

This is the agreement-with-a-caveat pattern. When two callers PASS the same coordinate but disagree on the number, take the disagreement as a measurement-uncertainty flag rather than a contradiction: the variant is there, and its true within-host frequency is somewhere in the range the two callers bracket. For a consensus call this position is unambiguous either way; for minority-variant reporting, report the range and the method.

#### Positions 28881-28882: codon-merge case

Filter to `Position=28881`. The table shows several rows in the 28881-28883 neighbourhood. Read the `Source` column carefully.

<!-- planned: cross-caller-codon-merge-28881 -->

The iVar track contributes two rows. The first is at 28881 with `REF GG`, `ALT AA`, an allele frequency near 1.0; this row spans two reference bases and corresponds to codon 203 of the N protein (AGG to AAA, an R203K substitution). The second is at 28883 with `REF G`, `ALT C`, near 1.0, the first base of codon 204 (GGA to CGA, a G204R substitution). The amino-acid labels come from the Inspector deriving them against the bundle's GFF3; they are not stored in the VCF, whose only `INFO` key is `TYPE`.

The LoFreq track contributes three rows in the same neighbourhood: 28881 `G>A`, 28882 `G>A`, and 28883 `G>C`, each near 1.0 and each with no protein annotation. LoFreq does not read GFFs, so it reports each base on its own row.

Both representations describe identical biology: a paired R203K and G204R substitution, the canonical N-protein signature inherited by every Omicron sublineage including the one in this sample. The teaching point is twofold. First, a VCF row's correspondence to a biological variant is not one-to-one: three single-base rows and one two-base-plus-one-base pair can describe the same two amino-acid changes. Second, downstream tools differ in which representation they expect. Lineage callers such as Nextclade tolerate either; some tools that read VCFs base by base will count three substitutions where the iVar VCF claims one merged change. Know which representation you are passing in.

## Taking a programmatic intersection or union

Reading the table by eye is enough to characterise the overlap, but a methods section often wants the intersection (the conservative consensus) and the union (the inclusive set) as actual files. Lungfish does not compute these; the honest path is external `bcftools isec`. Export each track's VCF (the staged `.vcf.gz` lives in the bundle's variants area, and `lungfish variants query --output` will also write one), then run `bcftools isec` over the two files.

There is one real trap, and it is the codon-merge case above. A naive position-by-position intersection at 28881 will not match: the iVar row spans 28881-28882, while LoFreq's rows are at 28881 and 28882 separately. `bcftools isec` compares records by coordinate and allele, so it will report a spurious disagreement at every codon-merged iVar row. Decompose the iVar VCF into single-base records first:

```bash
bcftools norm -a -f MN908947.3.fasta ivar.vcf.gz -Oz -o ivar.atomized.vcf.gz
bcftools index ivar.atomized.vcf.gz
bcftools isec -p isec_out ivar.atomized.vcf.gz lofreq.vcf.gz
```

`bcftools norm -a` atomises the merged `GG>AA` row back into two single-base records so that the intersection lines up with LoFreq's per-base rows. Without that step the intersection under-reports the agreement at exactly the positions this chapter spends the most words on.

## Interpretation

In a real call set the patterns from step 4 are mixed. The shape to expect on SARS-CoV-2 amplicon data is consistent: iVar's PASS set is the smaller, anchored at and above 5% allele frequency; LoFreq's PASS set is larger, reaching down into the sub-percent band at deep coverage; and the two agree on essentially all of the high-frequency variants that define the consensus. Exact row counts vary with depth and the frequency distribution and are not values Lungfish promises.

Three habits help when reading two callers in one table. First, sort by `Position` and read the iVar and LoFreq rows for a coordinate together; a missing row or a frequency gap jumps out. Second, look at the frequency distribution of the LoFreq-only rows: if most are below 5%, the difference is just the threshold and the rows are a mix of real rare alleles and noise; if a meaningful fraction are above 5%, something else is going on and it is worth a closer look. Third, for any methods section, record which caller produced the consensus call set and which caller's flags you accepted, and if you ran `bcftools isec`, report the intersection and union sizes from its output.

The decision of which caller to take downstream is a function of the question. For a published consensus sequence and a phylogeny, take iVar's PASS set on the primer-trimmed BAM. For surveillance on mixed populations and for minority-variant reporting, take LoFreq's PASS set, understanding its strand-bias behaviour as conservative on amplicon data. For a methods paragraph that needs to defend the choice, run both, intersect with `bcftools isec` after atomising, and note the union as supplementary.

## Next

Continue to [Nanopore Variant Calling](04-nanopore-variant-calling.md) for ONT workflows, or [Consensus and Lineage](05-consensus-and-lineage.md) to take a VCF downstream.
