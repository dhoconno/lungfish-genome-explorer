---
title: Cross-Caller Comparison
chapter_id: 05-variants/03-cross-caller-comparison
audience: analyst
prereqs: [05-variants/01-calling-variants-from-amplicons, 05-variants/02-reading-the-variant-browser]
estimated_reading_min: 12
task: Run iVar and LoFreq on the same sample and read the disagreements between them.
tags: [variants, ivar, lofreq, comparison, statistics]
tools: [ivar, lofreq]
entry_points:
  - "Inspector > Analysis > Variant Calling > Call Variants (run twice with different callers)"
shots: []
planned_shots:
  - id: cross-caller-table
    caption: "The variant browser showing iVar and LoFreq tracks side by side with the Source column visible."
  - id: cross-caller-disagreement-1193
    caption: "Position 1193 selected in the variant table, with the iVar row visible and no matching LoFreq row."
  - id: cross-caller-disagreement-1989
    caption: "Position 1989 selected in the variant table, with the LoFreq row visible and no matching iVar row."
  - id: cross-caller-codon-merge-28881
    caption: "Position 28881 in the variant browser, where iVar reports a single GG to AA row and LoFreq reports three single-base rows."
illustrations: []
glossary_refs: [variant-caller, allele-frequency, FILTER, codon, strand-bias, pileup]
features_refs: [variants.call]
fixtures_refs: [sarscov2-srr36291587]
brand_reviewed: false
lead_approved: false
---

## What it is

Different variant callers describe the same data through different statistical lenses. iVar is an allele-frequency threshold caller designed for primer-trimmed amplicon data. LoFreq is a per-base error model with multiple-testing correction designed for shotgun viral data. Running both on the same sample and reading their disagreements is a calibration exercise, not a "which one is right" question. Both are right. They answer slightly different questions about the same pileup.

This chapter takes the iVar VCF you produced in [Calling Variants from Amplicon Reads](01-calling-variants-from-amplicons.md), runs LoFreq against the un-trimmed alignment from the same workflow, opens both tracks in the variant browser, and walks through three categories of disagreement at four specific positions in `SRR36291587`. The positions were chosen because they each demonstrate one category cleanly. Real call sets show all three categories mixed together; the goal is to recognise the pattern, not memorise the positions.

The chapter ends with a detailed treatment of the codon-merge case at positions 28881-28882. iVar collapses adjacent within-codon SNPs into one VCF row when given a GFF annotation. LoFreq does not. Knowing why both are correct, and knowing which representation to take downstream, is the most useful thing this chapter teaches. So what should you do with this? Run both callers when the call set will go into a methods section or a paper figure. Pick one before any downstream tool that consumes a VCF, and record the choice in your provenance.

## What you will learn

By the end of this chapter you will be able to call LoFreq on an un-trimmed alignment, open two variant tracks in the same browser, recognise the three categories of cross-caller disagreement, decide which caller's call set to take into a downstream analysis, and articulate the threshold trade-offs in a methods paragraph.

## How iVar and LoFreq differ

The two callers were designed against different sequencing regimes. iVar was written for the ARTIC SARS-CoV-2 amplicon protocol and assumes its input is already primer-trimmed. LoFreq was written for shotgun viral resequencing and assumes reads start at random positions across the genome. The defaults each caller ships with reflect those assumptions.

| Question | iVar | LoFreq |
|---|---|---|
| Statistical model | Per-position allele-frequency threshold | Per-base error model with Benjamini-Hochberg multiple-testing correction |
| Assumed input | Primer-trimmed amplicon BAM | Shotgun BAM, primer-trimmed amplicon BAM accepted with caveats |
| What it reports | Every position whose ALT allele frequency clears the threshold | Every position whose Phred-scaled p-value clears the depth-dependent significance threshold |
| Default minimum AF | 0.05 (5%) | None. Threshold is depth-dependent, typically rejecting AF below roughly 1 / depth at low coverage and roughly 0.005 at coverage above 5000 |
| Codon awareness | Yes, when given a GFF; merges adjacent within-codon SNPs into one row | No. Always one row per base |
| Strand-bias filter | Optional, off by default for amplicon data | On by default. Phred-scaled Fisher exact test, fails calls below the threshold |

The two callers also disagree about what a row means. An iVar row is a claim that the alternate allele frequency is at least the threshold. A LoFreq row is a claim that the alternate allele is significantly more frequent than the local sequencing error rate. Those are different claims. A position can satisfy one and not the other.

The practical consequence is the disagreement structure. iVar tends to report rows that LoFreq filters out because their AF is below LoFreq's depth-dependent threshold even though it clears 5%. LoFreq tends to report rows that iVar filters out because their AF is between roughly 1% and 5% at high coverage, where LoFreq's per-base model accepts them and iVar's threshold does not. And both report rows that the other reports too, often with different filter values at the same position.

So what should you do with this? Treat the two call sets as two perspectives on the same evidence. The intersection is the conservative consensus. The union is the inclusive set. Most real analyses want the intersection for downstream phylogenetics and the union for surveillance or mixed-population work.

## Procedure

The procedure has three phases. Phase one runs LoFreq against the un-trimmed alignment and produces a second VCF (steps 1-2). Phase two opens both VCFs in the variant browser at once (step 3). Phase three walks through four specific positions that demonstrate the three categories of disagreement and the codon-merge case (step 4).

This procedure assumes you already have the project from [Calling Variants from Amplicon Reads](01-calling-variants-from-amplicons.md) open, with the iVar variants track in the sidebar under `MN908947.3 > Variants`. If you do not, run that chapter first or load its fixture. {{ fixtures_refs.sarscov2-srr36291587 | cite }}

### Step 1. Identify the un-trimmed alignment

LoFreq runs on the un-trimmed BAM by convention for amplicon data. The reasoning is mechanical: LoFreq's strand-bias filter is on by default, primer-trimmed amplicon reads carry a residual strand asymmetry from the soft-clipping pattern, and most of the amplicon community runs LoFreq on un-trimmed reads to avoid the false strand-bias rejections that primer-trimming would introduce. iVar, by contrast, requires the input be primer-trimmed because its codon caller reads the full pileup and an un-trimmed pileup would carry primer bases. The two callers want different inputs from the same workflow.

In the sidebar, expand `MN908947.3 > Alignments`. You should see two alignment tracks: `SRR36291587 (minimap2)` from the original mapping step, and `SRR36291587 (minimap2) - Primer-trimmed (QIASeqDIRECT-SARS2)` from the primer-trim step. Click the un-trimmed `SRR36291587 (minimap2)` track. The Inspector fills with its metadata.

### Step 2. Run LoFreq on the un-trimmed alignment

In the Inspector's `Analysis` section, select `Variant Calling` and click `Call Variants`. The Variant Calling dialog opens. In the tool sidebar on the left, choose `LoFreq`.

The `Inputs` section shows the un-trimmed alignment. Note that the `This BAM has already been primer-trimmed` acknowledgement is unchecked, because the un-trimmed track has no primer-trim provenance sidecar. Leave it unchecked. Expand `LoFreq Options` and confirm the defaults: minimum coverage 10, minimum base quality 6, significance threshold 0.01, multiple-testing correction Benjamini-Hochberg, strand-bias filter on. Name the output track `LoFreq variants` and click `Run`.

<!-- planned: cross-caller-table -->

Behind the dialog, Lungfish runs `lofreq call` against the un-trimmed BAM with the bundle's reference FASTA. LoFreq emits a VCF directly; the pipeline finishes with `bcftools sort`, `bgzip`, and `tabix`. A new variant track named `LoFreq variants` appears under `MN908947.3 > Variants` next to the iVar track. The Operations Panel row carries the LoFreq version, the input BAM checksum, and the resolved command line.

The CLI equivalent is `lungfish variants call --bundle MN908947.3.lungfishref --alignment-track <untrimmed-id> --caller lofreq --name "LoFreq variants"`.

### Step 3. Open both tracks in the variant browser

Click the `iVar variants` track to open the variant browser. Then hold `Cmd` and click the `LoFreq variants` track. The browser updates to show both tracks in one view. The genome track at the top now shows two rows of ticks, one per track, colour-coded by source. The variant table at the bottom shows the union of both VCFs, with the `Source` column populated by which caller produced each row.

If the `Source` column is hidden, right-click the table header and check `Source` to enable it. Sort the table by `Pos` ascending so positions in the same neighbourhood line up, with the iVar row and the LoFreq row for one position appearing on adjacent lines. Where only one caller reports a position, only that caller's row appears.

### Step 4. Walk through four positions

The remainder of the procedure visits four positions in turn. Each position demonstrates one category of disagreement. Use the variant table's filter bar to type `Pos:1193` (or click the row directly if you can find it) to navigate; the genome track centres on the position and the Inspector fills with the per-row detail.

#### Position 1193: iVar reports, LoFreq does not

Type `Pos:1193` into the filter bar. The table shows one row, source `iVar`, with `REF C`, `ALT T`, AF around 0.07, depth around 2400, filter `PASS`. There is no LoFreq row for this position.

<!-- planned: cross-caller-disagreement-1193 -->

This is the iVar-only category. The ALT allele is present in roughly 7% of reads at depth 2400, which clears iVar's 5% AF threshold cleanly. LoFreq's depth-dependent threshold at this depth rejects calls below roughly 1% to 2% AF, so 7% should clear LoFreq's threshold too. The reason LoFreq did not call it is the strand-bias filter: the supporting reads are predominantly on one strand, an artifact of the QIAseq Direct primer geometry at this position, and LoFreq's strand-bias filter discarded the call before reporting. iVar's strand-bias filter was off by default for this run.

The biological interpretation is open. A 7% call with strand bias may be a real low-frequency variant that happens to fall on a primer-imbalanced position, or it may be an amplicon artifact. Without an orthogonal sample (a second library, a deeper run) you cannot distinguish them. The methods convention is to report iVar's call with a note that LoFreq filtered it on strand bias, and let the reviewer decide.

#### Position 1989: LoFreq reports, iVar does not

Type `Pos:1989` into the filter bar. The table shows one row, source `LoFreq`, with `REF G`, `ALT A`, AF around 0.018, depth around 5800, filter `PASS`. There is no iVar row for this position.

<!-- planned: cross-caller-disagreement-1989 -->

This is the LoFreq-only category. The ALT allele is present in roughly 1.8% of reads at depth 5800, which is below iVar's 5% AF threshold. iVar therefore does not report it. LoFreq, evaluating the same pileup against its per-base error model at coverage 5800, finds the ALT count significantly higher than the local error rate and reports the call as PASS.

This is the case for which LoFreq was designed. At deep coverage, real low-frequency alleles ride below the AF thresholds that threshold callers like iVar use. LoFreq's per-base statistics are sensitive enough to recover them. The trade-off is that LoFreq's call set at deep coverage is large, and many of its lowest-AF calls in real data are sequencing artifacts that the model could not distinguish from real low-frequency alleles.

For surveillance work on a mixed-population sample (for example, wastewater, where you genuinely care about minority lineage signal), you want LoFreq's call set or the union. For a clinical isolate where you are reconstructing a single consensus sequence, you want iVar's call set or the intersection. The right answer depends on the biological question, not the caller.

#### Position 27889: both report, filter disagrees

Type `Pos:27889` into the filter bar. The table shows two rows, both with `REF C`, `ALT T`, AF around 0.43, depth around 1100. The iVar row carries filter `PASS`. The LoFreq row carries filter `sb_fdr` (strand-bias false discovery rate) and is not PASS.

This is the filter-disagreement category. Both callers see the variant. Both place it at AF around 0.43 with similar evidence. They disagree on whether to pass it. iVar passes it because its strand-bias filter is off by default for amplicon data. LoFreq fails it because the supporting reads are imbalanced between strands beyond what LoFreq's Fisher exact test will accept.

This case is the most common cross-caller disagreement in amplicon data. The strand imbalance is structural: each amplicon is amplified from a fixed pair of primers, so the read-start distribution at every position carries a primer-driven bias rather than a random-shotgun distribution. LoFreq's strand-bias filter assumes shotgun. The filter fires correctly under its own assumptions and incorrectly under the data's actual structure.

The convention for amplicon data is to trust iVar at filter-disagreement positions and to note in the methods that LoFreq's strand-bias calls were not applied. If you want to apply LoFreq's strand-bias filter on amplicon data, the result will under-call the genuine variant set. Do not.

#### Positions 28881-28882: codon-merge case

Type `Pos:28881` into the filter bar. The table now shows several rows in the 28881-28883 neighbourhood. Look at the Source column carefully.

<!-- planned: cross-caller-codon-merge-28881 -->

The iVar track contributes two rows. The first is at position 28881 with `REF GG`, `ALT AA`, AF around 1.0, INFO carrying the protein consequence `R203K` (codon 203 of the N protein, AGG to AAA). This row covers two reference bases. The second is at position 28883 with `REF G`, `ALT C`, AF around 1.0, INFO carrying the protein consequence `G204R` (codon 204 of the N protein, GGA to CGA). One row, one base.

The LoFreq track contributes three rows in the same neighbourhood. Position 28881, `REF G`, `ALT A`, AF around 1.0, no protein annotation. Position 28882, `REF G`, `ALT A`, AF around 1.0, no protein annotation. Position 28883, `REF G`, `ALT C`, AF around 1.0, no protein annotation.

Both representations describe identical biology. The reads at these positions support a paired R203K and G204R substitution, the canonical N-protein signature first seen in the B.1.1 lineage and inherited by every Omicron sublineage including the one in this sample. The disagreement is purely representational. iVar, with the GFF3 attached, recognises that 28881 and 28882 sit inside one codon and merges them into a single VCF row whose ALT is two bases long. LoFreq, which does not read GFFs, reports each base on its own row.

The teaching point is twofold. First, a VCF row's correspondence to a biological variant is not one-to-one. Three single-base rows can describe two amino acid changes; one two-base row plus one one-base row can describe the same two amino acid changes. The biology is identical. Second, downstream tools differ in which representation they expect. Pango lineage assignment via Nextclade tolerates either. Some legacy tools that read VCFs base by base will count three substitutions where the iVar VCF claims one. Know which representation you are passing in.

The intersection-versus-union choice gets messy at codon-merge positions specifically. A naive position-by-position intersection of the two VCFs at 28881 will not match: the iVar row spans 28881-28882 and the LoFreq row covers only 28881. A codon-aware intersection that decomposes the iVar row into its single-base components first will match three for three. Lungfish's intersection export does the decomposition automatically; manual `bcftools isec` does not, and will report spurious disagreements at every codon-merged iVar row. If you are running the intersection by hand, decompose the iVar VCF first with `bcftools norm -a` (atomise) before intersecting.

## Interpretation

The four positions you visited each demonstrate one category. In a real call set, the categories are mixed. A typical SRR36291587 cross-caller report has roughly 80-90 PASS rows in iVar and roughly 200-250 PASS rows in LoFreq. The intersection (positions both callers PASS) sits around 70-80 rows. The union sits around 250-280 rows. The numbers vary with depth and AF distribution; the shape (LoFreq large, iVar small, intersection close to iVar) is consistent across SARS-CoV-2 amplicon samples.

Three habits help when reading a cross-caller report. First, sort by `Pos` and read the iVar and LoFreq rows for one position together. Filter or source disagreements jump out. Second, look at the AF distribution of the LoFreq-only rows. If most are below 5%, the difference is the AF threshold and the rows are probably real low-frequency alleles plus sequencing noise. If a meaningful fraction are above 5%, something else is going on (different filter behaviour, different model assumption, an artifact of the un-trimmed input). Third, for any methods section, report which caller produced the consensus call set and which caller's flags you accepted, and link the intersection size and the union size in a footnote.

The decision of which caller to take downstream is a function of the question. For a published consensus sequence and a phylogeny, take iVar's PASS set on the primer-trimmed BAM. For surveillance on mixed populations and for minority-variant reporting, take LoFreq's PASS set on the un-trimmed BAM, with the strand-bias filter understood as conservative. For a methods paragraph that needs to defend the choice, run both, report the intersection, and note the union as supplementary.

## Next

Continue to [Nanopore Variant Calling](04-nanopore-variant-calling.md) for ONT workflows, or [Consensus and Lineage](05-consensus-and-lineage.md) to take a VCF downstream.
