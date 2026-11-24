# merge-uncounted

`fixture.fastq` holds five interleaved read pairs of 40 bases, ten records in all. It is a copy of the fixture that the BIO-MERGE ruling used to measure what the app's Merge Overlapping Pairs wrote when it passed `--count-duplicates`.

| Pair | Insert | What bbmerge does |
|------|--------|-------------------|
| p1 | 60 bases, qualities Q38 down to Q19 on mate 1 and Q25 on mate 2 | Merges to one 60 base read with mean Q 29.83 |
| p2 | the same 60 bases as p1, Q30 on both mates | Merges to one 60 base read with mean Q 32.33 |
| p3 | another 60 bases, Q20 on both mates | Merges to one 60 base read with mean Q 21.67 |
| p4 | 150 bases, Q10 on both mates | Cannot merge, stays a pair |
| p5 | another 150 bases, Q10 on mate 1 and Q20 on mate 2 | Cannot merge, stays a pair |

The writer used a seeded random generator (seed 7) and the file is kept as written. The numbers that tests pin come from running `bbmerge.sh` on this file with the argument list that `lungfish-cli fastq merge` records, and they are `7` records, `2` mate pairs, mean Q `20.68`, Q20 `64.7%` and Q30 `28.2%` over `340` bases.

Used by `FASTQOperationCLIInvocationBuilderMergeConformanceTests` in `Tests/LungfishAppTests`.
