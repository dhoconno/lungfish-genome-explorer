# Test Fixtures

Shared test data files for Lungfish functional and integration tests.

## sarscov2/

A complete, internally consistent SARS-CoV-2 test dataset from
[nf-core/test-datasets](https://github.com/nf-core/test-datasets) (MIT License).

The reads align to the reference, variants were called from those reads, and
annotations match the genome — so you can test the full pipeline end-to-end.

| File | Format | Size | Description |
|------|--------|------|-------------|
| `genome.fasta` | FASTA | 30 KB | SARS-CoV-2 reference (MT192765.1, ~30 kb) |
| `genome.fasta.fai` | FAI | 27 B | samtools faidx index |
| `genome.gff3` | GFF3 | 2.7 KB | Gene annotations (orf1ab, S, M, N, etc.) |
| `genome.gtf` | GTF | 8 KB | Same annotations in GTF format |
| `test_1.fastq.gz` | FASTQ.GZ | 9.2 KB | Paired-end R1 (Illumina, ~200 reads) |
| `test_2.fastq.gz` | FASTQ.GZ | 9.2 KB | Paired-end R2 |
| `test.paired_end.sorted.bam` | BAM | 20 KB | Sorted alignment against genome.fasta |
| `test.paired_end.sorted.bam.bai` | BAI | 128 B | BAM index |
| `test.vcf` | VCF | 3.8 KB | Variant calls from the BAM |
| `test.vcf.gz` | VCF.GZ | 1.3 KB | bgzipped VCF |
| `test.vcf.gz.tbi` | TBI | 126 B | tabix index |
| `test.bed` | BED | 170 B | ARTIC primer positions |

**Total: ~85 KB** — small enough to commit to git.

## alignment/

Reusable multiple-sequence alignment fixtures.

| Path | Description |
|------|-------------|
| `sarscov2-mafft-e2e.lungfish/` | Project-style artifact with five SARS-CoV-2 genome records derived from `sarscov2/genome.fasta`, source/edit metadata, fixture-generation provenance, and a native MAFFT `.lungfishmsa` bundle for end-to-end alignment/import/viewer tests |

The first record in `Inputs/sars-cov-2-genomes.fasta` is the local
`MT192765.1` fixture sequence. Records B-E are deterministic synthetic
derivatives for testing only and are not biological observations.

## analyses/

Reusable imported-analysis fixtures for UI, integration, and sidebar tests.

| Path | Description |
|------|-------------|
| `spades-2026-01-15T13-00-00/` | Small SPAdes result fixture used to seed `Analyses/` in deterministic project fixtures |

## classifier-full-viewer/

A wholly synthetic, coordinate-sorted BAM/BAI pair for exercising classifier
evidence through the real detached alignment viewer. The fixture has one generic
120-base track, two primary records, and duplicate/secondary/supplementary/unmapped
records that verify the viewer's default `0xD04` filtering. `source.sam` and
`.lungfish-provenance.json` make the tiny binary fixture reproducible without a
mounted external volume or copied clinical data.

Regenerate it from the repository root with:

```sh
python3 scripts/testing/generate-classifier-full-viewer-fixture.py
```

## assembly-ui/

Small read fixtures used by deterministic assembly UI and XCUI coverage.

| Path | Description |
|------|-------------|
| `illumina/reads_R1.fastq` | Short paired-end Illumina R1 example |
| `illumina/reads_R2.fastq` | Short paired-end Illumina R2 example |
| `ont/reads.fastq` | ONT-style single-read example with nanopore header |
| `pacbio-hifi/reads.fastq` | PacBio HiFi example with `/ccs` header |

## ont/

| Path | Description |
|------|-------------|
| `nrg1-run/` | The Oxford Nanopore run folder of the 2026-10-26 GUI walk, copied from the Long Reads and Assembly demo project (`Practice Data/nrg1-ont-barcoded/ont-run`). `fastq_pass/` holds `barcode85` to `barcode91` (no `barcode88`) at two gzip chunks of 500 reads each, and `unclassified/` at one chunk of 204 reads. 990,786 bytes. The reads are human NRG1 amplicon reads from the public ENA runs ERR12259924 (barcode85 and unclassified), ERR12259925, ERR12259926, ERR12259928, ERR12259929 and ERR12259930, and the archive copies carry Q0 (`!`) on every base. `seqkit stats -a` on barcode85 gives 1,000 reads, 1,735,173 bases, min 148, max 3,994, median 1,861, N50 1,864 and GC 48.87%, and on `unclassified` 204 reads and 207,358 bases. `ONTImportStatisticsTests` reads it through the run folder, `fastq_pass` and one barcode folder |

## platform-headers/

Four-read FASTQ files, two gzip copies and four unaligned BAM files, one per read-header form the sequencing-platform detector knows (Illumina, Element, MGI, Ion Torrent, Oxford Nanopore and PacBio forms, plus conflicts). Real header forms with synthetic bases. `platform-headers/README.md` names the source of each form, and `PlatformHeaderFixtures` in LungfishTestSupport resolves the paths. About 380 KB.

## sidebar-scan/

One text snapshot per project that the sidebar-scan safety nets scan, with one sidebar row on each line. The projects are built in a scratch folder on every run, so these files hold expectations only. `ClassifierLayoutFixtures` builds the project of `classifier-layouts.txt`. With `analysis-naming.txt` and `analyses-seeds.txt`, that snapshot covers every classifier result layout that LGE writes today and the layouts the analysis run executor writes. Rewrite the snapshots with `LUNGFISH_UPDATE_SIDEBAR_SNAPSHOTS=1` and review the diff before committing.

## mapping/

Mapping results for the mapping viewport tests.

| Path | Description |
|------|-------------|
| `supplementary-one-contig/` | A mapping result whose sorted BAM has one reference sequence, one read group with a sample name, 10 primary mapped reads, 2 supplementary records and 1 unmapped read, with its `mapping-result.json` and the viewer track's stats database. idxstats and flagstat `mapped` count 12 reads where the record counts 10 |

The reads are wholly synthetic. `supplementary-one-contig/README.md` lists every count and says why the stats database names a folder that exists on no Mac. `make_fixture.py` rebuilds every file, checks each count and writes `.lungfish-provenance.json`. The viewport tests read the folder through `#filePath`, and `TestFixtures.mappingSupplementaryOneContig` resolves it for the integration tests.

Regenerate it from the repository root with:

```sh
python3 Tests/Fixtures/mapping/supplementary-one-contig/make_fixture.py Tests/Fixtures/mapping/supplementary-one-contig <empty scratch folder>
```

## nvd/

An NVD result shape for the Unique Reads count.

| Path | Description |
|------|-------------|
| `secondary-supplementary/` | One accession (`SYN0001.1`, 1,000 bp) and its sorted BAM with `.bai` (`S1.filtered.bam`, built by the managed samtools 1.24 from the hand-written `source.sam`). The BAM holds eight records of six single-end reads: one read with a secondary record, one with a supplementary record, and two reads at one position so that `samtools markdup` marks one of them. It carries no duplicate marks, as an NVD run leaves it. `samtools view -c -F 0x404` counts 8 and `-F 0xD04` counts 6 as written, and 7 and 5 after the markdup that the import runs |

The reads are wholly synthetic. `secondary-supplementary/README.md` lists every record. `NvdUniqueReadsFlagsLiveConformanceTests` imports the folder and expects 5 Unique Reads, and `ClassifierExtractionSecondarySupplementaryLiveConformanceTests` extracts from it and expects 5 reads, each once at its primary alignment.

## Usage in Tests

```swift
import Foundation

let fixtures = Bundle.module.url(forResource: "sarscov2", withExtension: nil, subdirectory: "Fixtures")!
let reference = fixtures.appendingPathComponent("genome.fasta")
let fastqR1 = fixtures.appendingPathComponent("test_1.fastq.gz")
let bam = fixtures.appendingPathComponent("test.paired_end.sorted.bam")
let vcf = fixtures.appendingPathComponent("test.vcf")
```

Or use the `TestFixtures` helper:

```swift
let ref = TestFixtures.sarscov2.reference
let reads = TestFixtures.sarscov2.pairedFastq  // (r1: URL, r2: URL)
```

## Adding New Fixtures

1. Keep files under 1 MB each (ideally under 50 KB)
2. Prefer SARS-CoV-2 or PhiX174 genomes (tiny, well-known)
3. Document in this README
4. Add accessor to `TestFixtures.swift`
5. Keep generated scientific fixtures repo-owned and record their complete,
   reproducible provenance in `.lungfish-provenance.json`

## License

Test data from nf-core/test-datasets is MIT licensed.
