# Genotyping demo asset

The MHC genotyping chapters need a real, populated project to screenshot
against. It contains 30 MiSeq amplicon samples run all the way through
import and amplicon genotyping. That project is too large to commit as a
fixture, so it lives outside the repo and capture recipes reference it by
path instead.

## Where it is

Open **`~/Desktop/lge-docs/MHC MiSeq Cohort (de-identified).lungfish`**
for capture. It sits under `~/Desktop/lge-docs/` so that every project a
manual screenshot is taken from sits under one folder.

Capture recipes should reference the asset as:

```
{mhc_cohort_project}
```

with `{mhc_cohort_project}` defined as
`~/Desktop/lge-docs/MHC MiSeq Cohort (de-identified).lungfish`.
`write-recipe.py --fixture mhc-cohort` writes that placeholder.

## What was de-identified

The project is a rhesus macaque MHC amplicon cohort of 30 animals sequenced
on an Illumina MiSeq. The reads are real, but nothing in the project names
where they came from. The project name, every sample name, every bundle
name, and every file name are neutral. The samples are `Animal_01` through
`Animal_30`. The read headers carry placeholder instrument, run, flowcell,
and index fields. The reference bundle and the genotyping result were
rebuilt from the renamed reads with `lungfish-cli`, so every provenance
record inside the project points only at the de-identified paths. The
mapping from the original names is not kept anywhere in this repository.

Do not describe the cohort in prose in a way that names a laboratory, a
study, a sequencing run, an animal, or a date. Numbers from the data, such
as read depths, retained fractions, and allele counts, may be quoted.

## Why it is not committed

The project directory is roughly 500 MB on disk. It contains 30 FASTQ
bundles, a full IPD-MHC reference bundle, and a genotype result bundle with
its workbook state. That is far past the fixture-set size caps used
elsewhere in `docs/user-manual/fixtures/`. See `hg002-chr20/README.md`'s
50 MB fixture-set cap and 10 MB per-file cap for comparison. It stays local,
referenced by path.

## Contents

- **`Imports/`** holds 30 MiSeq paired FASTQ bundles (`.lungfishfastq`),
  named `Animal_01` through `Animal_30`, each imported as interleaved
  Illumina pairs with `illumina4` quality binning.
- **`Reference Sequences/ipd-mhc-mamu-2021-07-09.lungfishref`** is the
  IPD-MHC rhesus macaque (Mamu) allele library used for mapping and
  genotyping, 970 allele targets.
- **`Analyses/Amplicon genotyping results/amplicon-genotyping.lungfishgenotype`**
  is the single genotype result bundle, a genotyping-only run of all 30
  samples with the MiSeq amplicon workflow at its default settings
  (minimum supporting reads 1, no haplotype definition).
- **`Primer Schemes/`** is empty. No `.lungfishprimers` bundle is staged, so
  screenshots should not assume a populated primer scheme list.
- Root-level project state is `.project.db`, `metadata.json`, and the
  provenance records LGE writes as it works.

## Campaign decision on genotyping chapter scope

The genotyping chapters use this project strictly as a
**genotyping-only example**. They cover sample import and amplicon
genotyping through to result review and pivot export. The
haplotype-analysis section of those chapters is a **labeled
placeholder**. There is no MHC haplotype-analysis example in
this asset, and the chapters must not fabricate one. Mark that section
clearly as a placeholder pending a suitable example. Do not describe
haplotype analysis against screenshots of this project.
