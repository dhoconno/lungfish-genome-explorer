# GIAB Ashkenazi trio chromosome 20 slice fixture

The two parents of the Genome in a Bottle (GIAB) Ashkenazi trio, HG003
(father, NA24149) and HG004 (mother, NA24143), over the same 500 kb slice of
GRCh38 chromosome 20 as the `hg002-chr20/` fixture, with the matching GIAB
benchmark calls. Together with `hg002-chr20/` (HG002, the son) this gives the
joint-genotyping chapter a real three-sample family, so it can show what one
sample cannot: explicit `0/0` calls with depth, Mendelian consistency, and a
de novo candidate.

The son is not duplicated here. Chapters take HG002's reads, the reference
FASTA and the HG002 benchmark from `hg002-chr20/`, and HG003 and HG004 from
this folder. The Human Mapping and Variants demo project carries all three.

## Region

`chr20:10,000,000-10,500,000` (GRCh38), 500,001 bp, exactly as in
`hg002-chr20/`. The reference is `hg002-chr20/GRCh38.chr20.10.0-10.5Mb.fasta`
(sequence name `chr20_10.0-10.5Mb`). Both benchmark VCFs are renamed to that
sequence and shifted by subtracting 9,999,999, so fixture coordinates run
1 to 500,001 and line up with the reference and with the HG002 benchmark
without conversion. Fixture position + 9,999,999 = GRCh38 position.

## Sources

Same source, technology, read length, downsampling and method as
`hg002-chr20/fetch.sh`, so the three samples are comparable.

**Reads**

NIST/GIAB Illumina 2x250 bp PCR-free novoalign BAMs against GRCh38.

`https://ftp-trace.ncbi.nlm.nih.gov/ReferenceSamples/giab/data/AshkenazimTrio/HG003_NA24149_father/NIST_Illumina_2x250bps/novoalign_bams/HG003.GRCh38.2x250.bam`

`https://ftp-trace.ncbi.nlm.nih.gov/ReferenceSamples/giab/data/AshkenazimTrio/HG004_NA24143_mother/NIST_Illumina_2x250bps/novoalign_bams/HG004.GRCh38.2x250.bam`

`fetch.sh` reads only the region over HTTPS through samtools' remote-BAM
support (htslib range GETs against the 118 GB and 129 GB whole-genome BAMs,
which are never downloaded), downsamples with `samtools view -s 42.65`
(65 percent of read pairs kept, seed 42, the same as `hg002-chr20`),
name-sorts, and writes paired FASTQ. Singletons are dropped
(63 for HG003, 99 for HG004).

**Benchmark calls**

GIAB NISTv4.2.1 small-variant benchmarks for HG003 and HG004 against GRCh38.

`https://ftp-trace.ncbi.nlm.nih.gov/ReferenceSamples/giab/release/AshkenazimTrio/HG003_NA24149_father/NISTv4.2.1/GRCh38/HG003_GRCh38_1_22_v4.2.1_benchmark.vcf.gz`

`https://ftp-trace.ncbi.nlm.nih.gov/ReferenceSamples/giab/release/AshkenazimTrio/HG004_NA24143_mother/NISTv4.2.1/GRCh38/HG004_GRCh38_1_22_v4.2.1_benchmark.vcf.gz`

All four URLs and their `.bai` and `.tbi` companions answered `HTTP/1.1 200 OK`
on 2026-09-27. Tools: samtools 1.24, bcftools 1.24, htslib 1.24 from the
managed `~/.lungfish/conda/envs/` environments.

## License and citation

GIAB/NIST reference materials are U.S. government work in the public domain
with no usage restriction. Check your local jurisdiction if redistributing
outside the U.S.

Cite the same paper as `hg002-chr20/`:

```bibtex
@article{zook2019giab,
  author  = {Zook, Justin M. and McDaniel, Jennifer and Olson, Nathan D.
             and Wagner, Justin and Parikh, Hemang and Heaton, Haynes
             and Irvine, Sean A. and Trigg, Len and Truty, Rebecca
             and McLean, Cory Y. and De La Vega, Francisco M.
             and Xiao, Chunlin and Sherry, Stephen and Salit, Marc},
  title   = {An open resource for accurately benchmarking small variant
             and reference calls},
  journal = {Nature Biotechnology},
  year    = {2019},
  volume  = {37},
  pages   = {561--566},
  doi     = {10.1038/s41587-019-0074-6}
}
```

## Files

| File | Size | sha256 |
| --- | --- | --- |
| `HG003.chr20.10.0-10.5Mb_R1.fastq.gz` | 7.8 MB (7,795,940 B) | `390173f6…c8290` |
| `HG003.chr20.10.0-10.5Mb_R2.fastq.gz` | 8.5 MB (8,492,834 B) | `18b640db…c511` |
| `HG004.chr20.10.0-10.5Mb_R1.fastq.gz` | 8.6 MB (8,553,096 B) | `5ec5cdce…28b9` |
| `HG004.chr20.10.0-10.5Mb_R2.fastq.gz` | 9.2 MB (9,186,968 B) | `03d3ee10…7d6d` |
| `HG003.chr20.10.0-10.5Mb.benchmark.vcf.gz` (+ `.tbi`) | 43 KB | `11482594…8e91` |
| `HG004.chr20.10.0-10.5Mb.benchmark.vcf.gz` (+ `.tbi`) | 37 KB | `b59f6e5c…4b95` |

Full checksums are in `sha256sums.txt`. Every file is under the 10 MB
per-file cap and the set is 34.1 MB, under the 50 MB per-set cap, but the
four FASTQ files follow `hg002-chr20/` into the pinned manual-media repo
rather than git, because no test reads them. `fetch-media.sh` places them
back here. The two benchmark VCFs, their indexes, this README, `fetch.sh`
and `sha256sums.txt` are committed.

## Read counts

| Sample | Read pairs | Reads | Mapped to the slice | Mean depth |
| --- | --- | --- | --- | --- |
| HG002 (`hg002-chr20/`) | 45,574 | 91,148 | 99.77% | 44.7x |
| HG003 | 40,797 | 81,594 | 99.72% | 39.9x |
| HG004 | 44,856 | 89,712 | 99.75% | 44.0x |

Mapping figures come from `lungfish-cli map --paired --mapper minimap2
--preset sr` against the fixture reference (Preview CLI 2026.9.49, minimap2
2.31). `samtools flagstat` reports 81,657 and 89,748 records for HG003 and
HG004 because 63 and 36 reads also carry a supplementary alignment.

## Benchmark records inside the slice

| Sample | Records | Sample column |
| --- | --- | --- |
| HG002 | 961 | `HG002` |
| HG003 | 1,090 | `HG003` |
| HG004 | 939 | `HG004` |

The benchmarks were NOT derived from the fixture reads. They come
independently from NIST's benchmark pipeline. Treat them as ground truth,
never as "calls from these reads". Merging the three benchmarks position by
position and running `bcftools +mendelian2` on the 531 positions all three
carry a call at gives 0 Mendelian errors, as expected of a benchmark.

## Internal consistency of the joint-genotyping run

The `docs-campaign` results brief for this lane records a full run through
`lungfish-cli gatk haplotype-caller` (GVCF mode, one per sample) and
`lungfish-cli gatk joint-genotype` (CombineGVCFs then GenotypeGVCFs, GATK
4.6.2.0). In short: the cohort VCF holds 1,433 rows for the three samples
against 1,026 for HG002 alone; 813 rows carry an explicit `0/0` with depth
in at least one sample; `bcftools +mendelian2` counts 1,385 consistent
sites and 25 Mendelian errors (all at low-GQ indel or repeat sites); and one
confident de novo candidate remains at fixture position 429,138 (GRCh38
chr20:10,429,137), a `0/1` in HG002 with both parents `0/0` at GQ 99 and 81,
which the HG002 benchmark carries as `0/1` and neither parent's benchmark
contains.

## Regenerating

```bash
bash docs/user-manual/fixtures/giab-trio-chr20/fetch.sh   # rebuilds the files here
```

`fetch.sh` needs the managed `samtools`, `bcftools` and `htslib` environments
under `~/.lungfish/conda/envs/` (or `LUNGFISH_CONDA_ROOT`). Set `CACHE` to keep
the remote index caches and intermediate BAMs outside the fixture folder.
