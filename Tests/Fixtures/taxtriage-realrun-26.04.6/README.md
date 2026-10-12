# TaxTriage real runs on Nextflow 26.04.6

These are the standard output and trace files of two real TaxTriage runs, which lane Q15 of Phase 2.9
made at commit `bb9b32977`. Each ran jhuapl-bio/taxtriage v3.3.8 at revision
`e10bfebda32a62711f38a4e23ab03b61725a9675` on Nextflow 26.04.6 with `NXF_ANSI_LOG=false`, the docker
profile, the Kraken2 Viral database and `--remove-taxids 9606`. The inputs were the public SRA runs
SRR12486983 and SRR12486989 of the Pathogen Detection demo project.

| File | What it holds |
|---|---|
| `R1.stdout.txt` | Lines 61 to 123 of the standard output of R1, which pooled both samples in one run, verbatim with their colour escapes. The 46 lines that start with `[PROCESS` are the task lines, one for each task when Nextflow submits it |
| `R1.trace.txt` | The whole `trace.txt` of R1, 46 completed tasks |
| `R2b.stdout.txt` | Lines 61 to 105 of the standard output of R2b, which ran SRR12486989 alone, with its 29 task lines |
| `R2b.trace.txt` | The whole `trace.txt` of R2b, 29 completed tasks |

Line 61 is the first line that TaxTriage's own code prints after the parameter banner. The banner holds
paths of the Mac that made the runs, so it is left out. `NextflowProgressReaderTests` reads these files,
and the progress reader's rules for task lines and the bar rest on them (decisions W1 and W2).
