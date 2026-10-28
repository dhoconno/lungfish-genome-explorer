# NVD secondary and supplementary records

A tiny BAM for the NVD Unique Reads count (Phase 3.1 lane NVD). The reads are wholly synthetic and sit on one accession,
SYN0001.1, of 1000 bp. The folder has the shape of `mapped_reads` in an NVD run.

| File | Description |
|------|-------------|
| `S1.filtered.bam` | The mapped reads of sample S1 as the NVD pipeline leaves them, sorted, with no duplicate marks |
| `S1.filtered.bam.bai` | Its index |
| `source.sam` | The eight records, written by hand |

The eight records belong to six reads, all single-end.

| Read | Records |
|------|---------|
| r1 | primary at 101 |
| r2 | primary at 201, reverse strand |
| r3 | primary at 301 and a secondary record (flag 256) at 601 |
| r4 | primary at 401 (30M20S) and a supplementary record (flag 2048) at 701 (30H20M) |
| r5 and r6 | both primary at 501, forward strand, so markdup marks one of them a duplicate |

`samtools view -c` with samtools 1.24, run directly on `S1.filtered.bam` and then on a copy that went through the
import's markdup (`sort -n`, `fixmate -m`, `sort`, `markdup`).

| Mask | As written | After markdup | What it counts |
|------|-----------|---------------|----------------|
| none | 8 | 8 | every record |
| `-F 0x404` (1028) | 8 | 7 | mapped records that are not duplicates, so a read counts once for each place it aligns |
| `-F 0xD04` (3332) | 6 | 5 | mapped primary records that are not duplicates, so a read counts once |

`NvdUniqueReadsFlagsLiveConformanceTests` imports the folder with the managed samtools and expects the Unique Reads of
the one hit to be 5. The count was 7 before the mask moved from 0x404 to 0xD04.

Regenerate the BAM from this folder with:

```sh
samtools sort -o S1.filtered.bam source.sam
samtools index S1.filtered.bam
```
