---
title: Reading a VCF file
chapter_id: 04-variants/01-reading-a-vcf
audience: bench-scientist
prereqs: []
estimated_reading_min: 8
shots:
  - id: vcf-open-dialog
    caption: "The Open dialog filtered to VCF files."
  - id: vcf-variant-table
    caption: "A loaded VCF showing variants aligned to the reference."
glossary_refs: [VCF, REF, ALT, genotype, allele-frequency]
features_refs: [import.vcf, viewport.variant-browser]
fixtures_refs: [sarscov2-clinical]
brand_reviewed: false
lead_approved: false
---

## What it is

A VCF file (Variant Call Format) is a tab-separated text file that records positions where a sequenced sample differs from a reference genome. Each row describes one position, what base or bases the reference has there, what the sample has instead, and how confident the variant caller (the program that compared the reads to the reference) is about that claim.

It sits alongside two other file types you have probably already met. A FASTA file answers "what are the bases of the reference genome?" A BAM file answers "which sequencing reads cover which positions of the reference?" A VCF answers where a sample differs from the reference, and with what confidence.

Here is a small annotated excerpt, using three records from the fixture you will open in a moment:

```text
#CHROM       POS    ID  REF  ALT  QUAL     FILTER   INFO          FORMAT  test
MT192765.1   197    .   G    T    7.30814  LowQual  DP=1;...      GT:PL   1/1:36,3,0
MT192765.1   18807  .   T    C    136      LowQual  DP=6;...      GT:PL   1/1:166,15,0
MT192765.1   24103  .   A    G    30.4183  LowQual  DP=2;...      GT:PL   1/1:60,3,0
```

Reading left to right: `CHROM` is the name of the reference sequence the variant sits on (here the GenBank accession `MT192765.1`, the single contig of the SARS-CoV-2 reference), `POS` is the 1-based position along that sequence, `REF` is the base present in the reference at that position, `ALT` is the base observed in the sample, `QUAL` is a caller-assigned confidence score (higher is more confident), and `FILTER` is a tag a caller or post-processing step attaches when the record fails a quality rule. `INFO` holds a semicolon-separated bag of per-site tags. The single most useful tag for a new reader is `DP`, the raw read depth at that position: `DP=1` means one read covered the site, `DP=6` means six reads did.

The practical next step after understanding the shape of the file is to open one in Lungfish and read it in context.

## Why this matters

Variants are where raw reads stop being data and start being interpretation. Reading a VCF by eye is how you sanity-check what a caller has concluded before you trust its output downstream, whether that output feeds a lineage assignment, a resistance report, or a comparison against another sample. A caller is an automated process; checking its VCF is how you keep a human in the loop.

## Procedure

1. Open the reference FASTA first, so the variant browser has a coordinate axis to place records against. From the menu bar, choose `File > Open`, then select `fixtures/sarscov2-clinical/reference.fasta`.
2. Open the VCF through the same menu: `File > Open`, then select `fixtures/sarscov2-clinical/variants.vcf.gz`. With a reference already active, Lungfish filters the Open dialog to variant-family extensions (`.vcf`, `.vcf.gz`), which makes the VCF easy to find.

<!-- SHOT: vcf-open-dialog -->

3. Lungfish opens the VCF in the variant browser as a sortable, filterable table. Column headers can be clicked to sort, and a row click centers the genome context pane on that coordinate.

<!-- SHOT: vcf-variant-table -->

## Interpreting what you see

The loaded table shows nine rows, all on `MT192765.1`, and every one of them carries `FILTER=LowQual`. That uniform flag is expected, and it is the story of this fixture: `LowQual` means the caller flagged each record as low-confidence, and here the reason is direct. The fixture reads are a heavily downsampled subset of about 100 read pairs, so most sites have a raw read depth (`DP`) between 1 and 6. That is well below a reasonable confidence threshold for production variant calling, which is why every record is flagged. On a full-depth sample the same caller would clear the filter on most of these positions and the rows would read as confident calls.

Two visual groups stand out in the table. Eight rows are single-base substitutions (SNPs), with a one-character `REF` and a one-character `ALT`, for example `G>T` at position 197. One row, at position 10506, is an indel: its `REF` is a 37-base stretch and its `ALT` is only the first 5 bases of that stretch, which describes a 32-base deletion. In general, a long `REF` with a short `ALT` is a deletion and a short `REF` with a long `ALT` is an insertion.

The `FORMAT` and sample columns add one more dimension. Seven rows show genotype `GT=1/1` (homozygous alternate) and one shows `GT=0/1` (heterozygous). Viral callers conventionally use diploid-style notation (two alleles per site) even though a viral genome carries only one copy of each position, and for a single-lineage clinical isolate the expected genotype at a real variant site is `1/1`: the alternate allele dominates the reads. The single `0/1` record sits at the indel at position 10506 with `DP=3`, and at that depth `0/1` is most easily read as noise rather than a genuine mixed call. The `INFO` field carries two more tags worth knowing when `DP` alone does not explain a `LowQual` flag: `DP4`, which splits the read count into reference-forward, reference-reverse, alternate-forward, and alternate-reverse, and mapping-quality summaries, which report how confidently the reads aligned to this position.

The takeaway for this fixture is that the uniform `LowQual` flag is the right signal. The data is deliberately small, so the caller is honest about how much it can conclude. Learning to read that filter column, and to relate it back to `DP` and the genotype, is the core skill the chapter wants to leave you with.

## Next steps

The next chapter in this manual (coming with sub-project 2) walks through calling variants from a BAM file yourself, where you choose the caller and its quality filters. For now, reading `INFO`, `FILTER`, and `GT` carefully is enough to understand what a caller has already concluded about each site in a VCF someone has handed you.
