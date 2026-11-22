# RNA-seq bulk fixtures

Bulk RNA-seq salmon results of two public reference samples of the SEQC project, three libraries of each, so that a reader can import counts, name two groups with replicates and export a design for DESeq2, edgeR or limma without a sequencing run. The main set counts every run against the 92 ERCC spike-in sequences only, so each salmon folder is small and a table of 92 rows reads at a glance. Two older folders (`salmon-c1/` and `salmon-probe-c1/`) come from the Lungfish Genome Explorer (LGE) tests and stay as they were.

| Folder or file | What it holds | Bytes |
| --- | --- | --- |
| `salmon-seqc-ercc/` | Six salmon 2.11.0 folders named by run (`SRR896663`, `SRR896679`, `SRR896695`, `SRR896743`, `SRR896759`, `SRR896775`). Each keeps `quant.sf` (92 rows), `cmd_info.json`, `lib_format_counts.json` and `aux_info/meta_info.json`. `cut-reads.sha256` lists the SHA-256 and read count of each cut | 44,293 |
| `samples.tsv` | The sample sheet for `import rnaseq --samples`. Samples A_1 to A_3 are group A and B_1 to B_3 are group B, and the `run` column names each salmon folder | 429 |
| `tx2gene.tsv` | The table for `--tx2gene`, which makes gene sums. It has 92 rows and each ERCC sequence is its own gene | 2,046 |
| `make.sh` | Rebuilds `salmon-seqc-ercc/` from the six FASTQ pairs | 2,931 |
| `salmon-c1/` | Two older salmon folders (`SRR896663`, `SRR896743`) of whole runs counted against the human transcripts and the ERCC sequences. `quant.sf` keeps 395 rows | 41,130 |
| `salmon-probe-c1/` | `ERCC92.fa`, `ERCC92.gtf` and the first 6,000 read pairs of SRR896663. `make.sh` reads `ERCC92.fa` | 1,109,275 |

The folder serves chapter 11-rna-seq/02 (counting bulk reads), chapter 11-rna-seq/03 (reading and exporting bulk counts) and the RNA-seq tutorial.

## Source

The data are runs of the SEQC project (also called MAQC-III), GEO series GSE47774 and BioProject PRJNA208369. Sample A is Universal Human Reference RNA (UHRR) from Stratagene and sample B is Human Brain Reference RNA (HBRR) from Ambion. Both carry ERCC spike-in controls. The libraries were made at the BGI site, sequenced on an Illumina HiSeq 2000 (flowcell AC0AYTACXX, lane L01) as 2 x 100 bases, and the run of each library is one SRA run.

| Sample | SRA run | GEO sample | SRA experiment | Library index | Pairs in the run | Source of the cut |
| --- | --- | --- | --- | --- | --- | --- |
| A_1 | SRR896663 | GSM1156797 | SRX302130 | ATCACG | 5,728,703 | NCBI SRA file, converted |
| A_2 | SRR896679 | GSM1156813 | SRX302146 | ACAGTG | 4,720,566 | ENA FASTQ |
| A_3 | SRR896695 | GSM1156829 | SRX302162 | GATCAG | 5,691,880 | NCBI SRA file, converted |
| B_1 | SRR896743 | GSM1156877 | SRX302210 | CGATGT | 6,814,407 | ENA FASTQ |
| B_2 | SRR896759 | GSM1156893 | SRX302226 | GCCAAT | 6,651,723 | ENA FASTQ |
| B_3 | SRR896775 | GSM1156909 | SRX302242 | TAGCTT | 7,065,028 | ENA FASTQ |

LGE's reproduction scripts (`scripts/repro/rnaseq/`) downloaded the six runs in November 2026. Four came as ENA FASTQ from `https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR896/<run>/<run>_1.fastq.gz` and `<run>_2.fastq.gz`, and the md5 of every file equals the `fastq_md5` that ENA lists.

| SRA run | md5 of `_1.fastq.gz` | md5 of `_2.fastq.gz` |
| --- | --- | --- |
| SRR896679 | `70feac9cc7a19b768ae2cc94b2db8928` | `d3efd94f8342ae5ac7b36d8b8f3cdbc8` |
| SRR896743 | `f5df1193622de95667b3ae15e22525bb` | `8f5747f30a0cc262dc32c734cc9aafde` |
| SRR896759 | `d01fe7a881665faca1c590f1bc467812` | `3ec4bcc4cacb6fca6e70b18db6a0c12f` |
| SRR896775 | `295242dc32b9cf083f9b446ea149e244` | `cd9a8d7cdbe97ec2a5daaf78a4218061` |

SRR896663 and SRR896695 came from NCBI's normalised SRA files at `https://sra-pub-run-odp.s3.amazonaws.com/sra/<run>/<run>`. The md5 of each file equals the one NCBI lists (`9977a6853b31bbcc721b4ef55dd5a4eb` for SRR896663 and `852ea079d0cf2591424ad26a156f0641` for SRR896695), and its spots equal ENA's read count. They were converted with `fasterq-dump --split-files`. The cut of each is the same reads as ENA's file. On 2026-11-21 the first 24,000,001 bytes of each ENA file were requested (four requests, each a line of the project's event log) and the sequence and quality lines of the first 200,000 reads equal the cut's.

```sh
curl -r 0-24000000 https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR896/SRR896663/SRR896663_1.fastq.gz
curl -r 0-24000000 https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR896/SRR896663/SRR896663_2.fastq.gz
curl -r 0-24000000 https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR896/SRR896695/SRR896695_1.fastq.gz
curl -r 0-24000000 https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR896/SRR896695/SRR896695_2.fastq.gz
```

Only the read names differ. The conversion writes `@SRR896663.1 FCC0AYTACXX:1:1101:1460:1869 length=100` where ENA writes `@SRR896663.1 FCC0AYTACXX:1:1101:1460:1869/1` and `/2`.

`ERCC92.fa` and `ERCC92.gtf` of `salmon-probe-c1/` are whole files of `ERCC92.zip` (SHA-256 `8d5f23e997248084cc210061f07f1a51c2f1bf49ea07ee08a9f78bf6ff074807`) from Thermo Fisher, `https://assets.thermofisher.com/TFS-Assets/LSG/manuals/ERCC92.zip`. The 92 sequences are GenBank records, and the transcript ids of the GTF are their accessions (for example `DQ459430`). Its gene ids are the ERCC names (`ERCC-00002`). The index is built from `ERCC92.fa`, whose names are the ERCC names, so every `quant.sf` names a sequence `ERCC-00002` and not `DQ459430`, and `tx2gene.tsv` maps each name to itself.

The tool is salmon 2.11.0, the bioconda build `salmon-2.11.0-hfc06a8d_0`. LGE's RNA-Seq Analysis pack pins the same build (`bioconda::salmon=2.11.0=hfc06a8d_0`).

## How the folders were made

`make.sh` cuts the first read pairs of each run, builds the index and counts. The folders of `salmon-seqc-ercc/` were made on 2026-11-21 with 1,000,000 pairs, which is the third argument. Without it the script takes 200,000.

```sh
bash make.sh <folder with the six FASTQ pairs> <new work folder> 1000000
```

For each run the script runs these three commands, where `<mate>` is 1 and 2.

```sh
salmon index -t salmon-probe-c1/ERCC92.fa -i ercc92_index -k 31 -p 4
gzip -dc <run>_<mate>.fastq.gz | head -n 4000000 | gzip -n -6 > reads/<run>_<mate>.fastq.gz
salmon quant -i ercc92_index -l A -1 reads/<run>_1.fastq.gz -2 reads/<run>_2.fastq.gz -p 1 -o quant/<run>
```

The index is built once, before the first run. The script stops if the two mates of a cut name different reads, and it writes `cut-reads.sha256`, which holds the SHA-256 of the uncompressed bytes of each cut and its read count. salmon chose the library type `IU` for every run.

| Sample | SRA run | Pairs counted | Share of the 1,000,000 | ERCC rows with reads | Rows with 10 or more reads |
| --- | --- | --- | --- | --- | --- |
| A_1 | SRR896663 | 9,430 | 0.94 % | 47 | 23 |
| A_2 | SRR896679 | 9,355 | 0.94 % | 43 | 22 |
| A_3 | SRR896695 | 9,366 | 0.94 % | 51 | 22 |
| B_1 | SRR896743 | 14,260 | 1.43 % | 52 | 26 |
| B_2 | SRR896759 | 13,873 | 1.39 % | 47 | 26 |
| B_3 | SRR896775 | 13,521 | 1.35 % | 51 | 27 |

## License

The reads are public data of NCBI GEO and SRA. NCBI's policy page (`https://www.ncbi.nlm.nih.gov/home/about/policies/`) says that NCBI itself places no restrictions on the use or distribution of the data in its databases, and that it does not accept data when the submitter has requested restrictions on reuse or redistribution. The same page notes that submitters may claim patent or copyright, so keep the citation below with any copy. The six new folders hold counts and run statistics and no reads. The only reads here are the 6,000 pairs of `salmon-probe-c1/`.

The 92 ERCC sequences are public GenBank records, and the GTF's transcript ids (such as `DQ459430`) are their accessions. Thermo Fisher's `ERCC92.zip` holds only these two files and no licence text. They hold sequence names, sequences, lengths and accessions, and LGE ships them on that basis, as `Tests/Fixtures/rnaseq/README.md` does. Credit: `ERCC92.fa` and `ERCC92.gtf`, Thermo Fisher Scientific, `https://assets.thermofisher.com/TFS-Assets/LSG/manuals/ERCC92.zip`.

`make.sh`, `samples.tsv`, `tx2gene.tsv` and `cut-reads.sha256` were written by LGE and are under LGE's MIT licence.

## Citation

```bibtex
@article{seqc2014,
  author  = {{SEQC/MAQC-III Consortium}},
  title   = {A comprehensive assessment of RNA-seq accuracy, reproducibility and information content by the Sequencing Quality Control Consortium},
  journal = {Nature Biotechnology},
  year    = {2014},
  volume  = {32},
  number  = {9},
  pages   = {903--914},
  doi     = {10.1038/nbt.2957},
  note    = {GEO series GSE47774, BioProject PRJNA208369}
}

@article{baker2005ercc,
  author  = {Baker, S. C. and others},
  title   = {The External RNA Controls Consortium: a progress report},
  journal = {Nature Methods},
  year    = {2005},
  volume  = {2},
  pages   = {731--734},
  doi     = {10.1038/nmeth1005-731}
}

@article{patro2017salmon,
  author  = {Patro, Rob and Duggal, Geet and Love, Michael I. and Irizarry, Rafael A. and Kingsford, Carl},
  title   = {Salmon provides fast and bias-aware quantification of transcript expression},
  journal = {Nature Methods},
  year    = {2017},
  volume  = {14},
  pages   = {417--419},
  doi     = {10.1038/nmeth.4197}
}
```

## Size

The set is 1,200,104 bytes (1.1 MB) in 40 files. The largest file is `salmon-probe-c1/SRR896663_1.fastq.gz` at 510,026 bytes, and no file nears the 10 MB cap. The six new salmon folders with `cut-reads.sha256` are 44,293 bytes in 25 files. `SHA256SUMS` lists the SHA-256 and the path of every file but itself and this README.

## Internal consistency

The six `quant.sf` files list the same 92 sequences in the same order (`ERCC-00002` to `ERCC-00171`), so the importer takes them as one table. The sum of `NumReads` in each file equals the pairs that run counted. Each cut keeps both mates in the same order, which `make.sh` checks, and `cut-reads.sha256` lets a rebuild confirm that it cut the same reads.

Only about one pair in a hundred comes from a spike-in. The SEQC paper gives 1 to 2.5 percent of reads for HiSeq 2000 libraries (Results, Fig. 4d; scripts/repro/rnaseq/seqc-gse47774/claims.tsv:10). These cuts count 0.94 to 1.43 percent of all pairs on an index of the ERCC sequences alone. At this depth 43 to 52 of the 92 sequences get a read and 22 to 27 get ten or more. The sequences that are rare in the spike-in mix have zero reads, so read no small fold change from them.

The SEQC paper puts ERCC Mix 1 in sample A and Mix 2 in sample B (Online Methods, RNA samples). Thermo Fisher's table of ERCC concentrations (not shipped here) gives each sequence's concentration in each mix. A check on 2026-11-21 divided each run's reads by its total, averaged the three runs of each group and took the log2 of A over B. The values follow log2(Mix 1 over Mix 2) with a Pearson correlation of 0.969 on the 29 sequences that have 10 or more reads in each group's three runs together, 0.994 on the 20 that have 30 or more and 0.999 on the 15 that have 100 or more. So the counts agree with the published design. With the two mixes swapped, the correlation is -0.969.

The folders of `salmon-c1/` were counted on whole runs (5,728,703 and 6,814,407 pairs) against another index of 227,339 targets and 194 decoys, and 84.3 and 85.8 percent of the pairs mapped. They share no transcript names with `salmon-seqc-ercc/`, so the two sets never import together and the importer says so (see Check). Their `cmd_info.json` and `lib_format_counts.json` keep the absolute volume paths of the machine that ran them, as salmon wrote them (`/Volumes/lge_scratch/lge/...`). They hold no user name, host name or home path. The new folders hold relative paths, since `make.sh` runs in its own work folder.

## Check

These commands ran in a scratch project with the `lungfish-cli` of Lungfish Preview 2026.11.15. Each ended as written. Create the project folder first (`mkdir demo.lungfish`), since the commands do not create it, and run them in this folder.

```sh
lungfish-cli import rnaseq salmon-seqc-ercc/SRR896663 salmon-seqc-ercc/SRR896679 salmon-seqc-ercc/SRR896695 \
  salmon-seqc-ercc/SRR896743 salmon-seqc-ercc/SRR896759 salmon-seqc-ercc/SRR896775 \
  --project demo.lungfish --name "SEQC A and B on ERCC92" --samples samples.tsv
```

Exit 0. It prints `Imported 6 salmon folders and 92 features` and writes `demo.lungfish/Analyses/SEQC_A_and_B_on_ERCC92.lungfishrnaseq` with the sample sheet's six rows (run, species, origin and group).

With gene sums the same command takes `--tx2gene tx2gene.tsv` and another `--name`. It ends with exit 0, imports 92 features and adds `counts/genes.counts.tsv`. The design export then ends with exit 0 and writes `counts.tsv`, `genes.tsv`, `samples.tsv`, `deseq2.R` and `edger-limma-dream.R`.

```sh
lungfish-cli import rnaseq salmon-seqc-ercc/SRR896663 salmon-seqc-ercc/SRR896679 salmon-seqc-ercc/SRR896695 \
  salmon-seqc-ercc/SRR896743 salmon-seqc-ercc/SRR896759 salmon-seqc-ercc/SRR896775 \
  --project demo.lungfish --name "SEQC A and B on ERCC92 genes" --samples samples.tsv --tx2gene tx2gene.tsv
lungfish-cli rnaseq export demo.lungfish/Analyses/SEQC_A_and_B_on_ERCC92_genes.lungfishrnaseq \
  --output design --design group --contrast group:B:A
```

The two older folders import alone, and a mix of old and new folders is refused.

```sh
lungfish-cli import rnaseq salmon-c1/SRR896663 salmon-c1/SRR896743 --project demo.lungfish --name "SEQC C1 two runs"
lungfish-cli import rnaseq salmon-c1/SRR896663 salmon-seqc-ercc/SRR896743 --project demo.lungfish --name mixed
```

The first ends with exit 0 and `Imported 2 salmon folders and 395 features`. The second ends with exit 3 and `The salmon folders SRR896663 and SRR896743 list different transcripts, so they were not quantified on one index and cannot share one table.`
