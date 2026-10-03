# Kraken2 read-pairing fixture

These three files are the merged reads and the unmerged pairs of the 100 SARS-CoV-2 read pairs in `Tests/Fixtures/sarscov2/test_1.fastq.gz` and `test_2.fastq.gz`. `KrakenReadSetConformanceTests` classifies them with the managed kraken2 and the Viral database. It checks that a merged read staged beside an empty mate gets the call of a single-end run, and that one combined run counts 23 pairs and 77 merged reads.

| File | Reads | What it holds |
|---|---|---|
| `merged.fastq` | 77 | Pairs that bbmerge joined into one read |
| `unmerged_R1.fastq` | 23 | R1 of the pairs bbmerge could not join |
| `unmerged_R2.fastq` | 23 | R2 of the same pairs, in the same order |

## How they were made

BBMerge 40.02 from the managed `bbtools` environment made them on 2026-10-03.

```sh
gzip -dc Tests/Fixtures/sarscov2/test_1.fastq.gz > r1.fq
gzip -dc Tests/Fixtures/sarscov2/test_2.fastq.gz > r2.fq
~/.lungfish/conda/envs/bbtools/bin/bbmerge.sh in1=r1.fq in2=r2.fq \
  out=merged.fastq outu1=unmerged_R1.fastq outu2=unmerged_R2.fastq
```

BBMerge reported 100 pairs, 77 joined, 0 ambiguous and 23 with no solution.
