# MiSeq MHC genotyping: root-cause findings (2026-09-02)

Project examined: `/Users/dho/Downloads/32566_MS267_Williams1.lungfish`
Run: `Analyses/Amplicon genotyping results/amplicon-genotyping_2.lungfishgenotype`

> **Correction after review (2026-09-02).** The user identified the proximate
> cause: these inputs were imported *without* the Illumina Amplicon Merge
> recipe, and the provenance shows no merge step. That is correct. The defect
> that remains is not the missing merge but the pipeline's **silent acceptance**
> of unmerged input: it ran to completion and produced a normal-looking
> workbook in which every DRB locus reported zero, with no warning. The fix
> therefore merges *and announces it*, naming the recipe that should have been
> used at import, and records `pairMergePerformedDuringRun` so a merge during
> the run can never be mistaken for a merged-on-import bundle.

> **Follow-up (2026-09-02).** The merge record first landed only in the sample
> manifest under `.amplicon-genotyping`, which success cleanup deletes, so a
> finished run kept no trace of it. The record now also goes into
> `<name>.retained-demux-stats.json` and the provenance envelope's
> `illuminaInputPreparation`, both of which survive the run. The stats file no
> longer carries the `sampleManifest` key that pointed at the deleted scratch
> path.

## Finding 1 (headline): zero DRB genotypes, because reads reach mapping unmerged

The Illumina inputs in this project are **unmerged interleaved R1/R2**, 251 bp each:

```
@M01472:...:20282 1:N:0:148
@M01472:...:20282 2:N:0:148
```

`ONTBarcodeDemuxGenotypingPipeline` maps these raw with `minimap2 -a -x sr`,
then `filter-demux-retained-bam.py` keeps an alignment only when
`reference_span_is_full()` holds: `reference_start == 0 and reference_end == ref_length`,
with `max_mismatches = 0`.

Reference amplicon lengths by locus (`sequence.fa.gz.fai`):

| Locus | Ref length | Single 251 bp read can span? |
|---|---|---|
| Mamu-A/B/E/F/G/I/AG | 156 | yes |
| Mamu-DQB1 | 154 | yes |
| Mamu-DPA1 | 173 | yes |
| Mamu-DPB1 | 192 | yes |
| Mamu-DQA1 | 204 | yes |
| **Mamu-DRB / DRB1 / DRB3 / DRB4 / DRB5 / DRB6** | **244** | **no** |

A 251 bp read *could* in principle cover 244 bp, but the sequenced insert is what
matters. Measured insert distribution for WD1 (bbmerge, 79,080 pairs):
median 198, mode 198, 75th pct 212, 90th pct 280. Most DRB inserts exceed what a
single mate covers from position 0 to 244 with zero mismatches, and adapter/quality
tails at the 3' end break the exact-match requirement.

**Empirical proof** (WD1 subset, 79,080 pairs, same reference, same filter):

| Pipeline | Passing alignments | DRB alignments |
|---|---|---|
| Unmerged (Lungfish today) | 58,742 | **0** |
| Merged with bbmerge (Colab) | 35,725 | **4,212** (DRB1 3,169; DRB5 1,041; DRB 2) |

Whole-run confirmation: `samtools idxstats` on
`amplicon-genotyping_2.retained.demuxed.bam` returns **zero** DRB-mapped reads
across all 30 animals, and the genotype CSV contains **zero** DRB rows.

The Colab notebook merges first (`bbmerge`, cell 33) before
`map_semiperfect` (cell 36), which is why it calls DRB.

`ONTBarcodeDemuxGenotypingError.unsupportedIlluminaInput` already says inputs must
be "already merged", but nothing enforces or performs it: a single interleaved
FASTQ resolves to exactly one file, passes the `resolvedFASTQs.count != 1` check,
and runs to completion producing a silently DRB-free result.

## Finding 2: workbook counts ~2x the browser, because mates are counted twice

`filter-demux-retained-bam.py` emits two per-genotype metrics:

- `passed_alignments` -- raw count of passing alignment records
- `passed_unique_reads` -- count of distinct query names (mates collapse)

With unmerged input each fragment contributes up to two records, so
`passed_alignments` is ~1.84x `passed_unique_reads`.

Measured for this run:

| Metric | A1*004g mean | Run total |
|---|---|---|
| `passed_alignments` (workbook) | 582.7 | 1,098,532 |
| `passed_unique_reads` (browser) | 316.3 | 594,881 |
| ratio | 1.84 | 1.85 |

This matches the reported 574 vs 315 exactly.

- Workbook: `load_genotype_counts()` reads `passed_alignments`;
  `PivotWorkbookBuilder.build` uses `$0.passedAlignments`.
- Browser: `GenotypeComparisonMatrixView` displays `passedUniqueReads`.

Merging fixes the ratio to 1.00 (measured above: 35,725 alignments / 35,725
distinct reads), but the two surfaces should agree on a single metric regardless.

## Finding 3: Min Reads / Min Percent are view-only, not exportable

`GenotypeResultDisplayState` holds `minimumReads` / `matrixMinimumReads`, and
`GenotypeViewportExportService` already forwards `--min-reads` to
`genotype export`. But the pivot path
(`GenotypeExportPivotXlsxSubcommand`) has no threshold options at all, so the
"current.xlsx" pivot always contains unfiltered background counts.
