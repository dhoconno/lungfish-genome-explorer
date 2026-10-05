# Recorded fasterq-dump output

These files are what `fasterq-dump --split-3` from sra-tools 3.4.1 (the managed sra-tools environment) wrote on 2026-10-05 for two public runs, byte for byte. Tests script the SRA Toolkit with them through `SRAToolkitRecordedRunner`, so no test reaches the network.

| Run | Layout | Files | Reads |
|---|---|---|---|
| ERR12390094 | Paired, with spots that hold one read | `ERR12390094_1.fastq`, `ERR12390094_2.fastq`, `ERR12390094.fastq` | 129 pairs and 6 reads without a mate |
| ERR10019355 | Single-end | `ERR10019355.fastq` | 53 reads |

How they were made.

```sh
prefetch ERR12390094 -O work
fasterq-dump work/ERR12390094/ERR12390094.sra -O out -t out/tmp --split-3 --threads 1
```

The same command with `--split-files` wrote byte-identical files for these two runs and for ERR12389892, ERR12390031 and ERR11584358. ENA serves ERR12390094 as the same three files. Its pairs and its reads without a mate hold the same sequences and qualities as the files here. Only the header text differs, because ENA numbers the spots differently and writes `/1` and `/2` where fasterq-dump writes `length=`.
