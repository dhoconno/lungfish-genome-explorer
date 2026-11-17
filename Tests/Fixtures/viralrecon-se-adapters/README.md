# Single reads whose Viral Recon trim changes with the stored order

`SRR14639650-20000.fastq.gz` holds the first 20,000 reads of public run SRR14639650 (HiSeq 4000, 150 bp single reads), cut from the copy that ruling BIO-THREE-ROWS measured (`/Volumes/lge_scratch/lge/trust/PROBES-E/dl-SRR14639650/SRR14639650.fastq.gz`, 261,099 reads) and written with gzip level 9 and no time stamp. Script `cut.py` of lane VR-SE-ADAPTERS made it, with the order key of the ruling's `measure.py`.

The cut keeps the split of the whole file. The managed fastp 1.3.6 runs viralrecon 3.0.0's single-end argv (`conf/modules_illumina.config:75`, with `--thread 4`) on the reads in each order LGE stages single reads in (`SeededPairOrder`, seeds 1 to 3). The digest is the first 16 hex digits of the SHA-256 of fastp's output records, sorted.

| Argv | LGE seed | Adapter fastp used | Reads out | Digest |
|---|---|---|---|---|
| viralrecon's alone | 1 and 3 | GATCGTCGGACT... (guessed) | 3,451 | 51392df9d7562540 |
| viralrecon's alone | 2 | TCGGACTGTAGA... (guessed) | 5,011 | e906f28893ffd993 |
| viralrecon's with `--adapter_sequence` TruSeq Read 1 and the known-adapter FASTA | 1, 2 and 3 | named | 3,444 | b657ac53930a09a9 |

On the whole file seeds 1 and 3 give 43,228 reads and seed 2 gives 60,804, so the cut splits the same way. `ViralReconSingleEndAdaptersConformanceTests` runs the three seeds and expects one digest.
