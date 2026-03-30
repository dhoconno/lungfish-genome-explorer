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

## License

Test data from nf-core/test-datasets is MIT licensed.
