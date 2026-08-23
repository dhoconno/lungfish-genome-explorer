# Low-complexity read filter: fastp vs bbduk benchmark

Date: 2026-08-23. Machine: Mac16,8 (14 cores, 48 GB). Readset: `Clinic002A-20260427_S38_L001.fastq.gz` (49,621,316 single-end Illumina reads, 1.4 GB gzipped) from project 32540, chosen because an ATC microsatellite in ON563414 collects ~600,000x depth from it (309,432 reads carry at least seven consecutive ATC repeats).

Both tools are already bundled (fastp 1.3.6, BBTools 40.02). Each ran with 8 threads on the same input; only the complexity filter was enabled (fastp adapter, quality, and length filters disabled).

| Tool and settings | Wall time | Peak RSS | Reads removed | ATC-repeat reads surviving |
| --- | --- | --- | --- | --- |
| fastp `--low_complexity_filter --complexity_threshold 30` | 33 s | 1.2 GB | 34,103 (0.07%) | 309,432 of 309,432 |
| bbduk `entropy=0.5 entropywindow=50 entropyk=5` | 71 s (cold), 30 to 40 s warm | 5.3 GB at `-Xmx8g`; fits in 4 GB | 913,960 (1.84%) | 65,250 |
| bbduk `entropy=0.6` (same window and k) | 29 s | 4 GB heap | 2,053,522 (4.14%) | 34,895 |
| bbduk `entropy=0.7` (same window and k) | 40 s | 4 GB heap | 2,805,174 (5.65%) | 17,435 |

## Decision

bbduk. fastp defines complexity as the fraction of bases that differ from the following base, so a perfect tandem repeat such as `ATCATCATC...` scores 100 percent and is never removed; it cannot address this readset at all. bbduk measures Shannon entropy of k-mers inside a sliding window, which is the measure that identifies tandem repeats and homopolymers. The speed and memory differences are modest once the Java heap is sized by `ManagedJavaHeapPolicy`.

Default for the new operation: entropy 0.6, window 50, k 5, with entropy adjustable (0.3 to 0.9) and window and k exposed as advanced settings.
