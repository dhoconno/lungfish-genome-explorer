# supplementary-one-contig

A mapping result whose coordinate-sorted BAM holds one reference sequence, one read group with a sample name, 10 primary mapped reads, 2 supplementary records and 1 unmapped read. It stands in for a minimap2 run that kept supplementary alignments, which is the case of the 2026-10-26 walk finding WF-4. The mapping contig table showed an idxstats count of 12 mapped reads and zeros for depth, breadth, MAPQ and identity, where the record holds 10 reads and the measured values.

`MappingContigFallbackTests` in `Tests/LungfishAppViewTests` copies this folder into a temporary folder, adds the viewer bundle's `manifest.json` and empty genome files in code, and drives the mapping viewport with a stubbed summary builder.

## Files

| File | What it is |
|---|---|
| `fixture.sorted.bam` and `.bai` | The result's BAM, made by `make_fixture.py` with samtools |
| `mapping-result.json` | The record (schemaVersion 2) with one contig row, 10 mapped reads of 11, mean depth 1.0, breadth 0.91, median MAPQ 60 and mean identity 0.997 |
| `fixture.lungfishref/alignments/fixture-track.sorted.bam` and `.bai` | The viewer bundle's copy of the BAM |
| `fixture.lungfishref/alignments/fixture-track.stats.db` | The track's stats database as an import fills it from idxstats, flagstat and the header |
| `make_fixture.py` | Rebuilds every file above and checks each count before it keeps a file |

## Counts

Each count is checked by `make_fixture.py` with `samtools view -c`, `idxstats` and `flagstat`.

| Count | Value | Source |
|---|---|---|
| Records in the BAM | 13 | `samtools view -c` |
| Primary mapped reads | 10 | `samtools view -c -F 2308` |
| Primary records, mapped or not | 11 | `samtools view -c -F 2304` |
| Supplementary records | 2 | `samtools view -c -f 2048` |
| Unmapped reads | 1 | `samtools view -c -f 4` |
| idxstats mapped for the sequence | 12 | counts the supplementary records |
| flagstat `mapped` and `total` | 12 and 13 | count alignment records |
| flagstat `primary mapped` and `primary` | 10 and 11 | count reads, as the record does |

The record's depth and breadth come from `samtools coverage --ff UNMAP,SECONDARY,SUPPLEMENTARY,QCFAIL,DUP`, the pass `MappingSummaryBuilder` runs. The median MAPQ is read off the 10 primary reads. The identity is one minus the summed NM tags (3) over the 1,000 aligned bases of the primary reads.

## The stats database

`original_source_path` names `/Users/Shared/lungfish-fixtures/supplementary-one-contig/fixture.sorted.bam`, a folder that does not exist on any Mac. That is the state of a project that was moved or cloned after the mapping ran, which is how the walk met it. The viewport recognises the result's own BAM by the last two path components, here `supplementary-one-contig` and `fixture.sorted.bam`, so the test keeps the folder name when it copies the fixture.

## Rebuild

```sh
python3 Tests/Fixtures/mapping/supplementary-one-contig/make_fixture.py Tests/Fixtures/mapping/supplementary-one-contig <empty scratch folder>
```

The script writes the SAM text and an unsorted BAM into the scratch folder and deletes both. The sequences come from `random.Random(20261026)`, so a rebuild gives the same BAM content.
