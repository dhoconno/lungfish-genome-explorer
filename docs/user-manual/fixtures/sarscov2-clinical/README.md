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
States, 2020. The reads are derived from nf-core/test-datasets sarscov2
paired-end FASTQ (MIT license; see Citation). Alignments and variants are
derived from those reads aligned to MT192765.1 with minimap2, samtools, and
bcftools.

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

See `fetch.sh` for the reproducibility commands (samtools, bcftools, and
minimap2 versions pinned to the Lungfish app's bundled versions). The staged
files in this directory are the canonical form. `fetch.sh` exists for
reviewers who want to verify reproducibility.

## Used by

`chapters/04-variants/01-reading-a-vcf.md` is the pilot chapter (variants).
Future chapters on alignment, classification, and assembly may reuse this
set.
