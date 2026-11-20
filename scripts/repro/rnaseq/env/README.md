# RNA-seq reproduction environment

This folder holds the requests for the six conda environments that the RNA-seq reproduction scripts of Lungfish Genome Explorer (LGE) use. The main environment (`env`) holds the aligners, counters and statistics tools. A second, small environment (`env-star273a`) holds STAR 2.7.3a, which the exact-class STAR GeneCounts checks of GSE152418 and GSE304256 need. A third environment (`env-r-sva`) is the main environment with the Bioconductor package sva added, which needs older edgeR and limma releases than the main one holds. A fourth environment (`env-r-dream`) is a small R environment with the Bioconductor package variancePartition, which brings the dream mixed models. A fifth environment (`env-r-seurat`) is a small R environment with Seurat from conda-forge, which the single-cell template of the LGE export calls. A sixth environment (`env-sc-embed`) holds the Python single-cell stack of the cell-map route, scanpy 1.11.5 with leidenalg and python-igraph (sub-phase 5.5, decisions C4 and C10). The owner approved the main environment as direction O176. All six live on the external drive and stay separate from the tools that LGE manages for itself. Building and using them changes nothing in the base conda environment, in `~/.condarc` or under `~/.lungfish`.

## Which environment to use

| What the script needs | Environment | Reason |
| --- | --- | --- |
| Anything that loads sva, such as `ComBat_seq`, `ComBat`, `sva` or `svaseq` | `env-r-sva` | sva is installed only there. The main environment cannot hold it without moving edgeR and limma |
| A result that must come from edgeR 4.8.2 and limma 3.66.0 | `env-r-sva` | The main environment holds edgeR 4.10.7 and limma 3.68.5 |
| Anything that loads variancePartition, such as `dream` or `voomWithDreamWeights`, or a model with a random term such as one animal sampled on several days | `env-r-dream` | variancePartition is installed only there. It holds edgeR 4.8.2 and limma 3.66.0, the releases of `env-r-sva`, and it has no DESeq2 and no sva |
| The cell-map route, `scripts/repro/rnaseq/sc-embed/route/embed.py`, and anything that loads leidenalg or python-igraph | `env-sc-embed` | It is the only environment with leidenalg and python-igraph. It holds the numpy, OpenBLAS, numba, scipy and scikit-learn builds of `env`, and `env` stays unchanged because it pins the Phase 5 results |
| Anything that loads Seurat, such as `CreateSeuratObject` in the single-cell template of the export | `env-r-seurat` | Seurat is installed only there. It holds R 4.5.3 and the R Matrix package, which reads the matrix files, and no Bioconductor package, aligner or counter |
| STAR 2.7.3a counts and its genome index | `env-star273a` | Call its `bin/STAR` by full path, because the other two environments hold a newer STAR |
| Everything else, which covers alignment, quantification, counting, DESeq2, edgeR, limma, tximport, apeglm, pROC, rpart and single-cell work other than Seurat | `env` | It is the default. The staging scripts also take `fasterq-dump` from it |

The two R environments hold the same build of every other package, DESeq2 1.50.2, R 4.5.3 and Python 3.11.18 among them, and the same aligners and counters. Only edgeR and limma differ, and `env-r-sva` adds sva and the six packages that sva needs. A script that runs in both environments gives the same DESeq2 result, but an edgeR or limma result can differ between them. Write down which environment made each result.

The R environment with dream is smaller. It holds R 4.5.3, Python 3.11.18, edgeR 4.8.2 and limma 3.66.0 of the same builds as `env-r-sva`, and it holds neither DESeq2 nor an aligner or counter.

The R environment with Seurat is smaller still. It holds R 4.5.3 of the same build as the three other R environments and r-matrix 1.7_6 of the same build as `env` and `env-r-sva`. It has no Python, no Bioconductor package (so no DESeq2, edgeR or limma) and no aligner or counter.

## Files

| File | Purpose |
| --- | --- |
| `environment.yml` | The request for the main environment, with the two channels and the packages the owner asked for |
| `explicit-osx-arm64.txt` | The 422 packages of the main environment as built, with md5 sums, from `micromamba env export --explicit --md5` |
| `env-star273a.yml` | The request for the STAR 2.7.3a environment |
| `explicit-star273a-osx-64.txt` | The 3 packages of the STAR 2.7.3a environment as built, with md5 sums |
| `env-r-sva.yml` | The request for the R environment with sva, which is `environment.yml` plus `bioconductor-sva` |
| `explicit-r-sva-osx-arm64.txt` | The 429 packages of the R environment with sva as built, with md5 sums |
| `env-r-dream.yml` | The request for the R environment with dream, which holds R, variancePartition, edgeR, limma and the packages that dream uses for a random term |
| `explicit-r-dream-osx-arm64.txt` | The 213 packages of the R environment with dream as built, with md5 sums |
| `check-r-dream.R` | The check of the R environment with dream, which prints package versions, runs the dream example of variancePartition and fits a small count table with a random term |
| `env-r-seurat.yml` | The request for the R environment with Seurat, which holds R, Seurat and the R Matrix package from conda-forge |
| `explicit-r-seurat-osx-arm64.txt` | The 251 packages of the R environment with Seurat as built, with md5 sums |
| `env-sc-embed.yml` | The request for the cell-map environment. Each package of the 5.5 C10 line is pinned to the version and build that `explicit-osx-arm64.txt` holds, and python-igraph and leidenalg are added |
| `explicit-sc-embed-osx-arm64.txt` | The 139 packages of the cell-map environment as built on the Mac Studio, with md5 sums, from `micromamba env export --explicit --md5` (sha256 `f127cc050d5b1ff7e381ca8a56b703ced7e949c07a8f2badb59edd1029da97ea`) |
| `explicit-sc-embed-linux-64.txt` | The 167 packages of the same request solved for linux-64 as text with `--dry-run`. Nothing was built from it. It serves the tier C report of 5.5 T2 and backlog row SC-LINUX-ROUTE (sha256 `9e93841ef7f93ad7fcab98f4217441e9b2844bbd755db3ebbe050c601f599ba7`) |
| `smoke.sh` | The smoke test, which takes the main environment path and the fixture folder as arguments and finds the STAR 2.7.3a environment and the R environment with sva beside the main one |
| `README.md` | This file |

## Where things live

| Path | Holds |
| --- | --- |
| `/Volumes/lge_scratch/lge/rnaseq/env` | The main environment, 3.4 GB |
| `/Volumes/lge_scratch/lge/rnaseq/env-star273a` | The STAR 2.7.3a environment, 9 MB |
| `/Volumes/lge_scratch/lge/rnaseq/env-r-sva` | The R environment with sva, 3.4 GB as listed. About 92,500 of its files are hard links into the package cache, so it adds only about 285 MB on the drive |
| `/Volumes/lge_scratch/lge/rnaseq/env-r-dream` | The R environment with dream, 1.4 GB as listed. 32,263 of its 33,473 files are hard links into the package cache, so the folder itself adds only about 56 MB. The packages that were new to the cache added about 0.7 GB there, 149 MB of it as downloaded archives |
| `/Volumes/lge_scratch/lge/rnaseq/env-r-seurat` | The R environment with Seurat, 1.5 GB as listed. 31,702 of its 32,260 files are hard links into the package cache, so the folder itself adds only about 35 MB. The 97 packages that were new to the cache added about 0.8 GB there, 202 MB of it as downloaded archives |
| `/Volumes/lge_scratch/lge/rnaseq/env-sc-embed` | The cell-map environment, about 0.8 GB as listed, mostly hard links into the package cache. It was built with `micromamba create -p <path> -f env-sc-embed.yml --no-rc --override-channels -c conda-forge --strict-channel-priority --platform osx-arm64` and can be rebuilt from `explicit-sc-embed-osx-arm64.txt` |
| `/Volumes/lge_scratch/lge/rnaseq/conda-pkgs` | The package cache, set with `CONDA_PKGS_DIRS` so the internal disk stays free |
| `/Volumes/lge_scratch/lge/rnaseq/conda-pkgs-osx64` | A second cache for the STAR 2.7.3a environment, so osx-64 packages never mix with the osx-arm64 ones. Almost all of its 0.9 GB is repodata |
| `/Volumes/lge_scratch/lge/rnaseq/installer-arm64` | A native arm64 micromamba 2.10.0 that builds the environment |
| `/Volumes/lge_scratch/lge/rnaseq/mamba-root` | The micromamba root prefix |
| `/Volumes/lge_scratch/lge/rnaseq/fixtures/hbr_uhr` | The HBR and UHR chromosome 22 test set, with `SOURCES.tsv` listing each URL, size and sha256 |

## Why a separate micromamba

The base miniconda at `<conda root>` is an Intel (osx-64) install that runs under Rosetta. Its `mamba` 0.5.1 fails at start against conda 23.3.1, and its conda would solve for osx-64 with the slow classic solver. So a native arm64 micromamba from conda-forge builds the environment. That micromamba was installed once, by asking the base conda for the osx-arm64 subdir. The command does not change the base environment.

```bash
CONDA_SUBDIR=osx-arm64 CONDA_PKGS_DIRS=/Volumes/lge_scratch/lge/rnaseq/conda-pkgs \
  <conda root>/bin/conda create -y -p /Volumes/lge_scratch/lge/rnaseq/installer-arm64 \
  --override-channels -c conda-forge --strict-channel-priority micromamba
```

## Create the environment

Run this from the repository root. The solve takes about 10 seconds. The install downloads 795 MB and takes about 2 minutes. The flags `--no-rc` and `--override-channels` keep `~/.condarc` and the `defaults` channel out of the solve.

```bash
export MAMBA_ROOT_PREFIX=/Volumes/lge_scratch/lge/rnaseq/mamba-root
export CONDA_PKGS_DIRS=/Volumes/lge_scratch/lge/rnaseq/conda-pkgs
MM=/Volumes/lge_scratch/lge/rnaseq/installer-arm64/bin/micromamba

$MM create -y -p /Volumes/lge_scratch/lge/rnaseq/env \
  -f scripts/repro/rnaseq/env/environment.yml \
  --no-rc --override-channels -c conda-forge -c bioconda \
  --strict-channel-priority --platform osx-arm64
```

To get exactly the packages that were built instead of solving again, create from the explicit file.

```bash
$MM create -y -p /Volumes/lge_scratch/lge/rnaseq/env \
  --file scripts/repro/rnaseq/env/explicit-osx-arm64.txt --no-rc
```

## Create the STAR 2.7.3a environment

The exact-class STAR GeneCounts checks of GSE152418 and GSE304256 need STAR 2.7.3a (panel tally R2, question 6). bioconda has no osx-arm64 build of it. It has two osx-64 builds, and the solver takes the newer one, `h1f6ca2e_1`, built in February 2025. Both run on Apple silicon under Rosetta 2, which must be installed (`softwareupdate --install-rosetta`). So STAR 2.7.3a lives in its own folder and the main environment stays native. The same native micromamba solves for osx-64 when it is given `--platform osx-64`. The build downloads 3 MB and takes a few seconds. It uses its own package cache.

```bash
export MAMBA_ROOT_PREFIX=/Volumes/lge_scratch/lge/rnaseq/mamba-root
export CONDA_PKGS_DIRS=/Volumes/lge_scratch/lge/rnaseq/conda-pkgs-osx64
MM=/Volumes/lge_scratch/lge/rnaseq/installer-arm64/bin/micromamba

$MM create -y -p /Volumes/lge_scratch/lge/rnaseq/env-star273a \
  -f scripts/repro/rnaseq/env/env-star273a.yml \
  --no-rc --override-channels -c conda-forge -c bioconda \
  --strict-channel-priority --platform osx-64
```

To get exactly the packages that were built, create from the explicit file.

```bash
$MM create -y -p /Volumes/lge_scratch/lge/rnaseq/env-star273a \
  --file scripts/repro/rnaseq/env/explicit-star273a-osx-64.txt --no-rc
```

Call this STAR by its full path and do not put the folder ahead of the main environment on `PATH`, because both hold a program named STAR. Any later `micromamba install` into this folder needs `--platform osx-64` again.

```bash
/Volumes/lge_scratch/lge/rnaseq/env-star273a/bin/STAR --version
```

This prints `2.7.3a`. A genome index from one STAR is not read by the other. STAR 2.7.3a writes index format 2.7.1a and STAR 2.7.11b writes 2.7.4a. Each one stops at the start when it is given the index of the other, so build one index per version.

## Create the R environment with sva

The panel tally R2 asked for four more R packages, sva, rpart, apeglm and pROC. Lane ENV-3 put rpart, apeglm and pROC into the main environment with `--freeze-installed`. That installed 13 packages and changed none of the 409 that were there. sva could not follow. bioconda has two osx-arm64 builds of it, 3.54.0 for R 4.4 and 3.58.0 for R 4.5. The R 4.5 build pins `bioconductor-edger` to 4.8.x and `bioconductor-limma` to 3.66.x, while the main environment holds edgeR 4.10.7 and limma 3.68.5. Adding sva there would have downgraded both, so sva has a folder of its own.

The request is `environment.yml` plus `bioconductor-sva`, so the folder holds every other tool of the main environment as well. The solver moves edgeR to 4.8.2 and limma to 3.66.0 and adds 7 packages (see the table under Versions). The solve takes about 10 seconds. Every package was already in the shared cache, so nothing was downloaded, and linking the 429 packages took about 7 minutes at low priority on a busy Mac.

```bash
export MAMBA_ROOT_PREFIX=/Volumes/lge_scratch/lge/rnaseq/mamba-root
export CONDA_PKGS_DIRS=/Volumes/lge_scratch/lge/rnaseq/conda-pkgs
MM=/Volumes/lge_scratch/lge/rnaseq/installer-arm64/bin/micromamba

$MM create -y -p /Volumes/lge_scratch/lge/rnaseq/env-r-sva \
  -f scripts/repro/rnaseq/env/env-r-sva.yml \
  --no-rc --override-channels -c conda-forge -c bioconda \
  --strict-channel-priority --platform osx-arm64
```

To get exactly the packages that were built, create from the explicit file.

```bash
$MM create -y -p /Volumes/lge_scratch/lge/rnaseq/env-r-sva \
  --file scripts/repro/rnaseq/env/explicit-r-sva-osx-arm64.txt --no-rc
```

Call its R by the full path, and do not put its `bin` folder and the `bin` folder of the main environment on `PATH` together, because both hold a program named Rscript. The smoke test checks that every package it loads there comes from the library of this folder.

```bash
/Volumes/lge_scratch/lge/rnaseq/env-r-sva/bin/Rscript --vanilla my_script.R
```

## Create the R environment with dream

The edgeR, limma voom and dream template fits a model with a random term, such as one animal sampled on several days, through `dream` of the Bioconductor package variancePartition (ruling ADJ-BIO-51 item 3). No other environment holds it. The bioconda build of variancePartition 1.40.2 for R 4.5 requires limma 3.66.x, while the main environment holds limma 3.68.5. So variancePartition has a folder of its own, as sva has. Its edgeR is 4.8.2, because edgeR 4.10.7 requires limma 3.68.5. The two releases are the ones of `env-r-sva`.

The request is short. It holds R 4.5.3 at the build of the other two R environments, variancePartition, edgeR, limma, the packages that dream uses for a random term (lme4, lmerTest, pbkrtest, BiocParallel and Biobase) and the readers data.table and jsonlite. It has no aligner, counter, DESeq2 or sva. Python 3.11 is in the request for one reason. The nlopt library, which lme4 needs through nloptr, came as a Python 3.15 build in the first solve, and that added Python 3.15.2 and numpy 2.5.4. The solve takes about 6 seconds. The install downloaded 149 MB and took about 1 minute at low priority.

```bash
export MAMBA_ROOT_PREFIX=/Volumes/lge_scratch/lge/rnaseq/mamba-root
export CONDA_PKGS_DIRS=/Volumes/lge_scratch/lge/rnaseq/conda-pkgs
MM=/Volumes/lge_scratch/lge/rnaseq/installer-arm64/bin/micromamba

nice -n 15 $MM create -y -p /Volumes/lge_scratch/lge/rnaseq/env-r-dream \
  -f scripts/repro/rnaseq/env/env-r-dream.yml \
  --no-rc --override-channels -c conda-forge -c bioconda \
  --strict-channel-priority --platform osx-arm64
```

To get exactly the packages that were built, create from the explicit file. A dry run of this command resolves 213 packages with 0 B to download.

```bash
$MM create -y -p /Volumes/lge_scratch/lge/rnaseq/env-r-dream \
  --file scripts/repro/rnaseq/env/explicit-r-dream-osx-arm64.txt --no-rc
```

Call its R by the full path, and do not put its `bin` folder on `PATH` together with the `bin` folder of another environment, because each of them holds a program named Rscript. Run the check of this environment from the repository root.

```bash
/Volumes/lge_scratch/lge/rnaseq/env-r-dream/bin/Rscript --vanilla scripts/repro/rnaseq/env/check-r-dream.R
```

The check prints the version of 12 packages and requires each one to load from the library of this folder. It then runs the example of `dream` from variancePartition, which uses `SnowParam` with 4 socket workers. Last it fits a small count table of 8 animals on 3 days through edgeR, limma voom, `voomWithDreamWeights` and `dream` with a random term for the animal, and it repeats 5 genes with Kenward-Roger degrees of freedom. The last line it prints is `DREAM_ENV_OK`. A pass took 27 seconds with the packages in the file cache and 89 seconds on the first run after the build, at low priority on a busy Mac. The example alone took 11 to 13 seconds. The smoke test does not look at this environment.

## Create the R environment with Seurat

The Seurat template that `lungfish-cli rnaseq export` writes for a single-cell result (lane RS-SC-HANDOFF) reads the matrix files with `Matrix::readMM` and then builds its object with Seurat. The main environment holds scanpy and the R Matrix package but no Seurat, and neither does any other environment, so Seurat has a folder of its own (data job D1-SEURAT, session rnaseq-5-1-next).

The request is short. It holds R 4.5.3 at the build of the other R environments, `r-seurat` and `r-matrix`. Its one channel is conda-forge, because Seurat and every package it needs are built there. The R pin was allowed, and the solver took Seurat 5.5.1 and added 248 packages to the three requested ones, among them SeuratObject 5.4.0. It added no Python, so the request has no Python line, which `env-r-dream` needed. The solve takes about 2 seconds. The install downloaded 97 packages, 202 MB, and the whole create took 67 seconds at low priority, while the load average of the Mac rose from 9 to 57.

```bash
export MAMBA_ROOT_PREFIX=/Volumes/lge_scratch/lge/rnaseq/mamba-root
export CONDA_PKGS_DIRS=/Volumes/lge_scratch/lge/rnaseq/conda-pkgs
MM=/Volumes/lge_scratch/lge/rnaseq/installer-arm64/bin/micromamba

nice -n 15 $MM create -y -p /Volumes/lge_scratch/lge/rnaseq/env-r-seurat \
  -f scripts/repro/rnaseq/env/env-r-seurat.yml \
  --no-rc --override-channels -c conda-forge \
  --strict-channel-priority --platform osx-arm64
```

To get exactly the packages that were built, create from the explicit file. A dry run of this command resolves 251 packages with 0 B to download.

```bash
$MM create -y -p /Volumes/lge_scratch/lge/rnaseq/env-r-seurat \
  --file scripts/repro/rnaseq/env/explicit-r-seurat-osx-arm64.txt --no-rc
```

Call its R by the full path, and do not put its `bin` folder on `PATH` together with the `bin` folder of another environment, because each of them holds a program named Rscript. The smoke of this environment loads Seurat and Matrix and prints the Seurat version.

```bash
/Volumes/lge_scratch/lge/rnaseq/env-r-seurat/bin/Rscript --vanilla -e 'library(Seurat); library(Matrix); cat(as.character(packageVersion("Seurat")), "\n")'
```

It prints `5.5.1` on its last line, after the messages that loading Seurat prints. One of them comes from SeuratObject and names Matrix (see Things to know). The smoke test `smoke.sh` does not look at this environment.

## Use the environment

Scripts can put the environment first on `PATH`, which is what `smoke.sh` does and is enough for every tool in it. To run one command with the full activation, use `micromamba run`.

```bash
export PATH=/Volumes/lge_scratch/lge/rnaseq/env/bin:$PATH

$MM run -p /Volumes/lge_scratch/lge/rnaseq/env STAR --version
```

Run R scripts with `Rscript --vanilla` so that a `.Rprofile` or `.RData` in the working folder is never read. Run Python with `python -I` on any script that touches downloaded data.

## Fixtures

The smoke test reads the HBR and UHR chromosome 22 set from the Griffith lab RNA-seq tutorial on genomedata.org. The fixture folder holds `ref/` with the chromosome 22 genome and annotation, `reads/` with the 12 FASTQ files from the tar, `downloads/` with the tar and `SOURCES.tsv` with every URL, size and sha256. Each download goes into its own new folder, because downloaded files are untrusted data.

| File | URL | Bytes | sha256 |
| --- | --- | --- | --- |
| `HBR_UHR_ERCC_ds_5pc.tar` | `https://genomedata.org/rnaseq-tutorial/HBR_UHR_ERCC_ds_5pc.tar` | 116602880 | `8850392715718f5d12503b0f9e5b157199a4439df829b52a468ed1bf0ad84c27` |
| `chr22_with_ERCC92.fa` | `https://genomedata.org/rnaseq-tutorial/fasta/GRCh38/chr22_with_ERCC92.fa` | 51751056 | `98acde4a57edaaba443206938ca1ebf8cf35bd2ea60548cccedf366ce3346296` |
| `chr22_with_ERCC92.gtf` | `https://genomedata.org/rnaseq-tutorial/annotations/GRCh38/chr22_with_ERCC92.gtf` | 30712117 | `f5ea9899f975a1bc2381994d1c429067e5b2ea1d73e5bcfabbb90bd81e49b5ff` |

The `http` form of the tar URL redirects to `https`. To fetch the set again, run this.

```bash
FX=/Volumes/lge_scratch/lge/rnaseq/fixtures/hbr_uhr
mkdir -p $FX/downloads $FX/ref $FX/reads
curl -L --fail -o $FX/downloads/HBR_UHR_ERCC_ds_5pc.tar https://genomedata.org/rnaseq-tutorial/HBR_UHR_ERCC_ds_5pc.tar
curl -L --fail -o $FX/ref/chr22_with_ERCC92.fa https://genomedata.org/rnaseq-tutorial/fasta/GRCh38/chr22_with_ERCC92.fa
curl -L --fail -o $FX/ref/chr22_with_ERCC92.gtf https://genomedata.org/rnaseq-tutorial/annotations/GRCh38/chr22_with_ERCC92.gtf
tar -xf $FX/downloads/HBR_UHR_ERCC_ds_5pc.tar -C $FX/reads
```

## Smoke test

```bash
bash scripts/repro/rnaseq/env/smoke.sh \
  /Volumes/lge_scratch/lge/rnaseq/env \
  /Volumes/lge_scratch/lge/rnaseq/fixtures/hbr_uhr
```

It prints the version of every tool, checks the sha256 of the four fixture files it reads, then runs one small real job each. STAR builds a chromosome 22 index and aligns one HBR replicate. STAR 2.7.3a from the second environment, which the script looks for beside the main one, must print `2.7.3a`, builds its own index and aligns the same pair. Its ReadsPerGene table must equal the one from the main STAR byte for byte. The variable `SMOKE_STAR273A` names another folder for that environment, or the word `skip` leaves those steps out. salmon indexes the transcripts that gffread writes and quantifies the same pair. featureCounts counts the STAR alignments. umi_tools extracts a UMI from the first 8 bases of 20,000 pairs, STAR aligns them and umi_tools removes duplicates. An R script loads DESeq2, edgeR, limma, tximport, apeglm, pROC and rpart, fits DESeq2 on a toy matrix, shrinks its fold changes with apeglm, draws a ROC curve with pROC, grows a small tree with rpart and reads the salmon result with tximport. fastp, seqkit, pigz and samtools run on the way. The R environment with sva, which the script looks for beside the main one, gets its own R script. That script requires every package to load from the library of that folder and edgeR 4.8.x with limma 3.66.x. It runs `ComBat_seq` and `svaseq` on a toy matrix with three batches, fits DESeq2 on the raw counts with the batch in the design and on the `ComBat_seq` counts, and runs apeglm, pROC, rpart and edgeR with limma voom. The variable `SMOKE_R_SVA` names another folder for that environment, or the word `skip` leaves those steps out. A full pass without the STAR 2.7.3a steps took about a minute and a half with 4 threads while another build ran on the same Mac. The first pass with them (36 steps, none failed) took about 10 minutes on a Mac whose load average stayed above 30 and whose drive was busy with downloads. The slow steps then were the two STAR indexes (60 s and 85 s) and the first import of umi_tools (85 s). The pass after the R extras were added (38 steps, none failed) took 5 minutes 29 seconds at low priority with `nice -n 15`, while the load average of the Mac ranged from about 17 to above 60. Its R environment with sva step took 14 s. The work folder goes under `/Volumes/lge_scratch/lge/rnaseq/smoke` and is removed after a pass unless `SMOKE_KEEP=1` is set. The fixture folder is never written to.

## Versions

These are the 33 requested packages and piscem, which simpleaf needs. The environment holds 422 packages in all, 242 for osx-arm64 and 180 noarch.

| Package | Version | Build | Channel | Platform |
| --- | --- | --- | --- | --- |
| star | 2.7.11b | h2e74062_9 | bioconda | osx-arm64 |
| salmon | 2.11.0 | hfc06a8d_0 | bioconda | osx-arm64 |
| subread (featureCounts) | 2.1.1 | hba9b596_0 | bioconda | osx-arm64 |
| htseq | 2.1.2 | py311h9927c53_3 | bioconda | osx-arm64 |
| kallisto | 0.52.0 | h26a84f0_1 | bioconda | osx-arm64 |
| simpleaf | 0.31.0 | hf8f1f16_0 | bioconda | osx-arm64 |
| alevin-fry | 0.19.0 | hf8f1f16_0 | bioconda | osx-arm64 |
| piscem | 0.25.0 | ha012041_0 | bioconda | osx-arm64 |
| sra-tools | 3.4.1 | 2_osx_arm64 | bioconda | osx-arm64 |
| umi_tools | 1.1.6 | py311h9bd965f_0 | bioconda | osx-arm64 |
| samtools | 1.24 | h36b3a25_2 | bioconda | osx-arm64 |
| fastp | 1.4.0 | ha1d0559_0 | bioconda | osx-arm64 |
| gffread | 0.12.9 | h551ac6c_0 | bioconda | osx-arm64 |
| multiqc | 1.35 | pyhdfd78af_2 | bioconda | noarch |
| seqkit | 2.14.0 | h980baba_0 | bioconda | osx-arm64 |
| pigz | 2.8 | hfab5511_2 | conda-forge | osx-arm64 |
| python | 3.11.18 | hd05a0c4_0_cpython | conda-forge | osx-arm64 |
| pandas | 2.3.3 | py311hdb8e4fa_2 | conda-forge | osx-arm64 |
| numpy | 2.4.6 | py311hbd1492f_0 | conda-forge | osx-arm64 |
| scipy | 1.17.1 | py311h9a58382_1 | conda-forge | osx-arm64 |
| anndata | 0.12.19 | pyhd8ed1ab_0 | conda-forge | noarch |
| scanpy | 1.11.5 | pyhd8ed1ab_0 | conda-forge | noarch |
| pyyaml | 6.0.3 | py311hbd425f4_3 | conda-forge | osx-arm64 |
| r-base | 4.5.3 | h35b0bb1_4 | conda-forge | osx-arm64 |
| bioconductor-deseq2 | 1.50.2 | r45h97584a2_0 | bioconda | osx-arm64 |
| bioconductor-edger | 4.10.7 | r45h6cc0085_0 | bioconda | osx-arm64 |
| bioconductor-limma | 3.68.5 | r45h6cc0085_0 | bioconda | osx-arm64 |
| bioconductor-tximport | 1.38.2 | r45hdfd78af_0 | bioconda | noarch |
| bioconductor-tximeta | 1.28.3 | r45hdfd78af_0 | bioconda | noarch |
| r-data.table | 1.18.6.1 | r45hadbbe95_0 | conda-forge | osx-arm64 |
| r-jsonlite | 2.0.0 | r45h6168396_1 | conda-forge | osx-arm64 |
| r-rpart | 4.1.27 | r45hbe92478_0 | conda-forge | osx-arm64 |
| bioconductor-apeglm | 1.32.0 | r45h97584a2_0 | bioconda | osx-arm64 |
| r-proc | 1.19.1 | r45hc1ec562_0 | conda-forge | osx-arm64 |

Every requested package has an osx-arm64 build or is noarch, so the main environment runs natively. The noarch packages are pure Python or R and run natively. Only STAR 2.7.3a needs Rosetta 2, and it lives in its own environment.

The R environment with sva holds 429 packages, 247 for osx-arm64 and 182 noarch. Its request is `environment.yml` plus `bioconductor-sva`, and nine lines of its explicit file are not in the one of the main environment. Two lines hold older packages and seven are new. Every other package is the same build as in the main environment, among them R 4.5.3, DESeq2 1.50.2, apeglm 1.32.0, pROC 1.19.1 and rpart 4.1.27.

| Package | Version | Build | Channel | Platform | Against the main environment |
| --- | --- | --- | --- | --- | --- |
| bioconductor-sva | 3.58.0 | r45hcc2f086_0 | bioconda | osx-arm64 | Added |
| bioconductor-edger | 4.8.2 | r45h6cc0085_1 | bioconda | osx-arm64 | Older, the main environment has 4.10.7 |
| bioconductor-limma | 3.66.0 | r45hcc2f086_0 | bioconda | osx-arm64 | Older, the main environment has 3.68.5 |
| bioconductor-annotate | 1.88.0 | r45hdfd78af_0 | bioconda | noarch | Added, pulled in by sva |
| bioconductor-genefilter | 1.92.0 | r45hb40fde4_0 | bioconda | osx-arm64 | Added, pulled in by sva |
| r-mgcv | 1.9_4 | r45hc952b19_0 | conda-forge | osx-arm64 | Added, pulled in by sva |
| r-nlme | 3.1_170 | r45hf56971a_0 | conda-forge | osx-arm64 | Added, pulled in by sva |
| r-survival | 3.8_12 | r45hb5b23e3_0 | conda-forge | osx-arm64 | Added, pulled in by sva |
| r-xtable | 1.8_8 | r45hc72bb7e_0 | conda-forge | noarch | Added, pulled in by sva |

The R environment with dream holds 213 packages, 148 for osx-arm64 and 65 noarch. 140 lines of its explicit file are the same name, version and build as lines of the one of `env-r-sva`. The table lists the packages that dream uses and the two that the request pins.

| Package | Version | Build | Channel | Platform |
| --- | --- | --- | --- | --- |
| r-base | 4.5.3 | h35b0bb1_4 | conda-forge | osx-arm64 |
| python | 3.11.18 | hd05a0c4_0_cpython | conda-forge | osx-arm64 |
| bioconductor-variancepartition | 1.40.2 | r45hdfd78af_0 | bioconda | noarch |
| bioconductor-limma | 3.66.0 | r45hcc2f086_0 | bioconda | osx-arm64 |
| bioconductor-edger | 4.8.2 | r45h6cc0085_1 | bioconda | osx-arm64 |
| bioconductor-biocparallel | 1.44.0 | r45h97584a2_1 | bioconda | osx-arm64 |
| bioconductor-biobase | 2.70.0 | r45hcc2f086_0 | bioconda | osx-arm64 |
| r-lme4 | 2.0_6 | r45h45a6d21_0 | conda-forge | osx-arm64 |
| r-lmertest | 3.2_1 | r45hc72bb7e_0 | conda-forge | noarch |
| r-pbkrtest | 0.5.5 | r45hc72bb7e_1 | conda-forge | noarch |
| r-matrix | 1.7_5 | r45he92e77a_0 | conda-forge | osx-arm64 |
| r-mass | 7.3_66 | r45h4b407c4_0 | conda-forge | osx-arm64 |
| r-ggplot2 | 4.0.4 | r45h9cad52b_0 | conda-forge | noarch |
| r-nloptr | 2.2.1 | r45h9a0c4c3_2 | conda-forge | osx-arm64 |
| nlopt | 2.11.0 | np2py311h8498a85_2 | conda-forge | osx-arm64 |
| r-remacor | 0.0.20 | r45h169f911_1 | conda-forge | osx-arm64 |
| r-data.table | 1.18.6.1 | r45hadbbe95_0 | conda-forge | osx-arm64 |
| r-jsonlite | 2.0.0 | r45h6168396_1 | conda-forge | osx-arm64 |

Against `env-r-sva`, 23 packages of the same name have another version or build. 21 of them are the compiler and C++ library packages that R brings, at clang 23.1.4 against 22.1.8 in `env-r-sva`. The other two are r-ggplot2 4.0.4 against 4.0.3 and r-matrix 1.7_5 against 1.7_6. 50 packages are new. 43 of them are R and Bioconductor packages, among them variancePartition, lme4, lmerTest, pbkrtest and remaCor, and 7 are compiler packages and nlopt.

The R environment with Seurat holds 251 packages, 180 for osx-arm64 and 71 noarch, all from conda-forge. 136 lines of its explicit file are the same name, version and build as lines of the one of `env-r-dream`, and 97 of its packages have a name that `env-r-dream` lacks. The table lists the three requested packages and the ones that Seurat loads or calls first.

| Package | Version | Build | Channel | Platform |
| --- | --- | --- | --- | --- |
| r-base | 4.5.3 | h35b0bb1_4 | conda-forge | osx-arm64 |
| r-seurat | 5.5.1 | r45h1380947_0 | conda-forge | osx-arm64 |
| r-seuratobject | 5.4.0 | r45h1380947_0 | conda-forge | osx-arm64 |
| r-matrix | 1.7_6 | r45h3f89421_0 | conda-forge | osx-arm64 |
| r-sp | 2.2_3 | r45h4b407c4_0 | conda-forge | osx-arm64 |
| r-sctransform | 0.4.3 | r45he67d32b_0 | conda-forge | osx-arm64 |
| r-igraph | 2.3.4 | r45h32443fb_0 | conda-forge | osx-arm64 |
| r-irlba | 2.4.1 | r45hc32e2a6_0 | conda-forge | osx-arm64 |
| r-uwot | 0.2.5 | r45hc1ec562_0 | conda-forge | osx-arm64 |
| r-rcppannoy | 0.0.23 | r45h1380947_0 | conda-forge | osx-arm64 |
| r-reticulate | 1.47.0 | r45hc1ec562_0 | conda-forge | osx-arm64 |
| r-future | 1.82.0 | r45hacb3a79_0 | conda-forge | noarch |
| r-ggplot2 | 4.0.4 | r45h9cad52b_0 | conda-forge | noarch |
| r-data.table | 1.18.6.1 | r45hadbbe95_0 | conda-forge | osx-arm64 |
| r-jsonlite | 2.0.0 | r45h6168396_1 | conda-forge | osx-arm64 |

The STAR 2.7.3a environment holds 3 packages, all for osx-64.

| Package | Version | Build | Channel | Platform |
| --- | --- | --- | --- | --- |
| star | 2.7.3a | h1f6ca2e_1 | bioconda | osx-64 |
| libcxx | 23.1.5 | h19cb2f5_0 | conda-forge | osx-64 |
| libzlib | 1.3.2 | hbb4bfdb_3 | conda-forge | osx-64 |

The STAR binary is an x86_64 Mach-O file. `otool -L` lists only the system `libz` and `libSystem` for it, so the two conda libraries are not used at run time.

## Things to know

| Topic | Note |
| --- | --- |
| Python and scanpy | Python is pinned to 3.11, so the solver chose the newest scanpy and anndata that still allow it. Newer scanpy releases need a newer Python. |
| R version | bioconda builds its Bioconductor packages for one R release at a time. The solver therefore chose R 4.5.3 and not the newer R in conda-forge. |
| samtools | The solver chose 1.24 because it found no 1.25 build that fits the rest of the set. |
| Gzipped reads | On macOS `zcat` looks for a `.Z` suffix. Give STAR `--readFilesCommand gunzip -c`. |
| featureCounts | It counts read pairs only with `-p --countReadPairs`. |
| simpleaf | Set `ALEVIN_FRY_HOME` and run `simpleaf set-paths` once. The smoke test does this in its work folder. It warns that macs3 is missing, which matters only for ATAC peak calling. |
| sra-tools | The smoke test prints the versions but does not fetch from NCBI. |
| aria2c | The Homebrew `aria2c` 1.37.0 on the Mac Studio is not part of the environment. |
| STAR 2.7.3a speed | It runs under Rosetta 2. On the chromosome 22 pair it built its index in 54 s against 31 s for the native STAR 2.7.11b and aligned in 10 s against 7 s, with 4 threads on a busy Mac. |
| STAR 2.7.3a counts | On HBR Rep1 (118,571 read pairs) the `ReadsPerGene.out.tab` of STAR 2.7.3a equals the one of STAR 2.7.11b byte for byte, 1,414 lines. This holds for this pair only. The smoke test repeats the comparison. |
| R extras | rpart, apeglm and pROC were added to the main environment after the first build with `--freeze-installed`. That installed 13 packages and changed no file of the 409 that were there, which includes the sra-tools files that the staging scripts use. sva is not in the main environment. sva 3.58.0 is the only bioconda build for R 4.5 and it needs edgeR 4.8.x and limma 3.66.x, so it lives in `env-r-sva`. |
| R environment with dream | Its request pins R 4.5.3 to the build of the other two R environments, because the solver takes build 6 without the pin, and it pins Python to 3.11, because the solver took a Python 3.15 build of nlopt without that line. variancePartition 1.40.2 requires limma 3.66.x and edgeR 4.10.7 requires limma 3.68.5, so the environment holds edgeR 4.8.2. The dream example ran with `SnowParam` and 4 socket workers. A `MulticoreParam` that forks was not tried |
| R environment with Seurat | Its request pins R 4.5.3 to the build of the other R environments, which conda-forge's Seurat allows, and names conda-forge as its one channel. The folder has no `python`, so `reticulate` finds no Python in it, and it holds only the packages that Seurat requires. The ones that Seurat only suggests, such as hdf5r, leiden and presto, are not installed. The check of lane D1-SEURAT read the two 200-cell pbmc_1k_v3 cuts of `Tests/Fixtures/rnaseq` with `Matrix::readMM` (gzip for Cell Ranger, plain for STARsolo), built a Seurat object of 200 cells and 1,353 genes from each and ran NormalizeData, FindVariableFeatures, ScaleData, RunPCA, FindNeighbors, FindClusters and RunUMAP (the R-native uwot) with no error. All 110 loaded namespaces came from the library of this folder |
| Seurat and Matrix | `library(Seurat)` prints a message from SeuratObject 5.4.0. It was built with Matrix 1.7.5, the folder holds Matrix 1.7.6 and the message recommends a reinstall, since the Matrix ABI may have changed. The Matrix release notes (`NEWS.Rd` in the Matrix package folder) list no change of the ABI version in 1.7-6, which went from 1 to 2 in 1.7-0, and the check above ran with no error. A request line `r-matrix=1.7_5` would make the two versions equal. A dry run of that install into the built folder showed one change, a downgrade of r-matrix 1.7_6 to 1.7_5 (build r45he92e77a_0, already in the cache), and the folder was left as built |
| Adding to the main environment | Install with `--freeze-installed` and read the dry run first (`--dry-run`). A line under Upgrade, Downgrade or Remove means a package would move. bioconda pins the Bioconductor family tightly, so one new package can force several others to change. |
