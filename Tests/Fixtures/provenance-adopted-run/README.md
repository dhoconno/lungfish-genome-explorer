# Adopted Linux run record

`Imports/SRR24403534.lungfishfastq/.lungfish-provenance.json` is the provenance record of a FASTQ bundle that the Mac adopted from a Linux run. `ProvenanceAdoptedRunTimeTests` and `ProvenanceLoadingWordsTests` in `LungfishAppTests` load it. It sits at its project-relative path, so a test can copy it into a temporary `.lungfish` project, where its `@/` paths resolve.

## Source

The file is the record of `Walk 88.lungfish/Imports/SRR24403534.lungfishfastq/` from the 2026-10-26 GUI walk, unchanged. That bundle was made by File > Import Center > Sequencing Reads > Linux Run Result on the batch folder `c5-x2`, a CHTC run of Phase C5. The record is 79,841 bytes with SHA-256 `8ac86d7c81ad2d275fad5c8aa910440661ab4f92b41f21f299c3d7fcd80f5448`. It names no home folder, no temporary folder and no account. The machine it names is the CHTC execute node, `oconnor2003.chtc.wisc.edu`.

Only the record is kept. The bundle's reads (114 MB) and its metadata are not, so every file the record lists reads as absent, and a test that loads it ignores the audit status.

## What it holds

A version 2 envelope of `lungfish import fastq --adopt`, signed by nobody (`signatures` is empty), with 16 steps.

| Steps | Tool | What they are | Wall time |
|---|---|---|---|
| 1 to 13 | `fastp`, `deacon`, `seqkit`, `pigz`, `clumpify.sh`, `bgzip` | The node steps, which ran on the Linux machine | 4 s to 98 s each |
| 14 | `lungfish-executor` | The quality-count step, which runs the executor binary as `run --plan` | 7.1 s |
| 15 | `lungfish-executor run` | The run itself, the launcher's record of the whole Linux run, with its site facts | 346.5 s, which is 5m 46s |
| 16 | `lungfish import fastq` | The adopt on the Mac | 0 s |

The envelope's own `wallTimeSeconds` is 0.0756, the adopt. The Run Summary used to show it as `Wall Time <1s`. The run's time is step 15's, and the adopt copies it there from the run record's `wallSeconds` (`ExecutorRunAdoption.executorStepExecution`). Step 14 shares the binary's name and is not the run, which is why a test of the Linux run's time must read 346.5 s and never 7.1 s.

## Reviewing a difference

The record is a pin of a real shape. Do not edit it. When the adopt writes a different shape, add the new record beside it and say why in the commit.
