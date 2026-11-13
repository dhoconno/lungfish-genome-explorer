# Single reads whose fastp adapter guess changes with read order

`SRR14639650-16000.fastq.gz` holds 16,000 single-end reads of public run SRR14639650 (HiSeq 4000, 150 bp), fetched from ENA. They are a seeded random sample (Python `random.Random(1)`) of the 235,691 reads that survive the import recipe's clumpify dedupe, kept in the dedupe's order. Script `small_split.py` of the trust session lane SE-NAMED-ADAPTERS made it.

It is the smallest sample found that splits. Below about 10,000 reads fastp detects no adapter in any order, and reads cut to 50 or 75 bases gave one guess in every order.

Numbers from the managed fastp 1.3.6 run directly with `-w 1 --disable_quality_filtering --disable_length_filtering`:

| Input order | Adapter | Reads out | Bases out |
|---|---|---|---|
| LGE seed-1 order of the file order, adapter guessed | TCGGACTGTAGAACTCTGAACGTGTAGATCTCGGTGGTCGCCGTATCATT | 15,913 | 1,393,740 |
| LGE seed-1 order of the reversed file, adapter guessed | GATCGTCGGACTGTAGAACTCTGAACGTGTAGA | 15,941 | 1,361,089 |
| file order or reversed, `-a` TruSeq Read 1 and the known-adapter FASTA | named | 15,941 | 1,360,663 |

`FastpSingleReadOrderConformanceTests` runs both orders through the single-read trim and expects the last row.
