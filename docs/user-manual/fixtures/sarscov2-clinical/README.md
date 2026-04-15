# sarscov2-clinical

A SARS-CoV-2 clinical-isolate fixture set used by the pilot chapter
`chapters/04-variants/01-reading-a-vcf.md`. Reused across later chapters
covering alignment, variant calling, and classification baselines.

A clinical isolate is used deliberately rather than a wastewater sample.
Wastewater VCFs carry low-frequency variants, mixed lineages, and dropout
regions. These complications deserve their own chapter, not a reader's first
exposure to VCF.

## Source

The reference is NCBI GenBank MT192765.1 (Severe acute respiratory syndrome
coronavirus 2 isolate SARS-CoV-2/human/USA/PC00101P/2020, complete genome,
29,829 bp). This is a published single-isolate clinical sample from the United
States, 2020.

The paired-end FASTQ reads come from ENA/SRA run **ERR5069949**, an Illumina
NextSeq 500 sequencing run (149 bp, paired-end) of the same isolate. The reads
in this fixture are a heavily downsampled subset (about 100 read pairs) taken
from the nf-core/test-datasets `sarscov2` branch, preserved under MIT license
(see Citation). The downsampled size keeps the fixture compact enough to
commit, at the cost of low per-site read depth, which is why most variant
records carry the `LowQual` filter.

The alignments were produced by running `minimap2 -ax sr` (short-read preset,
v2.17) with the reads against `MT192765.1`, then sorted and indexed with
samtools 1.11. The variants were called by `bcftools mpileup` plus
`bcftools call` (htslib 1.11) from that BAM against the same reference, then
block-compressed with bgzip and indexed with tabix.

## License

All files redistribute under MIT, matching the upstream nf-core/test-datasets
license. Retained intact for redistribution in this repository.

## Citation

```bibtex
@misc{nfcore_test_datasets,
  author       = {{nf-core community}},
  title        = {nf-core/test-datasets: sarscov2},
  year         = {2020},
  howpublished = {\url{https://github.com/nf-core/test-datasets/tree/sarscov2}},
  note         = {MIT license}
}
```

Chapters using this fixture cite the block above via `fixtures_refs: [sarscov2-clinical]`.

## Size

| File | Size | Notes |
|---|---|---|
| reference.fasta | 30 KB | MT192765.1 (29,829 bp) |
| reference.fasta.fai | 27 B | samtools faidx |
| reads_R1.fastq.gz | 9.2 KB | paired-end R1 |
| reads_R2.fastq.gz | 9.2 KB | paired-end R2 |
| alignments.bam | 20 KB | sorted, indexed |
| alignments.bam.bai | 128 B | (index) |
| variants.vcf.gz | 1.3 KB | bcftools-called SNPs and indels |
| variants.vcf.gz.tbi | 126 B | tabix index |

Total well under the 50 MB fixture-set cap.

## Internal consistency

Reads align end-to-end to the reference with zero unaligned contigs: the
reference is the genome the reads came from. All variants in
`variants.vcf.gz` were called from `alignments.bam`; each REF allele matches
the base at that position in `reference.fasta`. Genotype fields are
diploid-style `0/1` or `1/1` by convention, appropriate for a single-isolate
clinical sample (near-100% allele frequencies). The chromosome name is the
GenBank accession `MT192765.1`, not `chrCOV19` or other aliases. Alignment
BAM, VCF, and FASTA all agree on this name.

## How to re-derive

The staged files in this directory are the canonical form. The upstream
pipeline used to produce them is:

```bash
# 1. Fetch the downsampled FASTQ from nf-core/test-datasets
curl -L https://raw.githubusercontent.com/nf-core/test-datasets/sarscov2/data/fastq/sarscov2_1.fastq.gz -o reads_R1.fastq.gz
curl -L https://raw.githubusercontent.com/nf-core/test-datasets/sarscov2/data/fastq/sarscov2_2.fastq.gz -o reads_R2.fastq.gz

# 2. Map to the MT192765.1 reference with minimap2 short-read preset
minimap2 -ax sr reference.fasta reads_R1.fastq.gz reads_R2.fastq.gz \
  | samtools sort -o alignments.bam -
samtools index alignments.bam

# 3. Call variants with bcftools, then bgzip and tabix
bcftools mpileup -Ou -f reference.fasta alignments.bam \
  | bcftools call -mv -Oz -o variants.vcf.gz
tabix -p vcf variants.vcf.gz
```

`fetch.sh` in this directory is a stub for reviewers who want to verify
provenance; the canonical artifacts are the committed files.

## Used by

`chapters/04-variants/01-reading-a-vcf.md` is the pilot chapter (variants).
Future chapters on alignment, classification, and assembly may reuse this
set.
