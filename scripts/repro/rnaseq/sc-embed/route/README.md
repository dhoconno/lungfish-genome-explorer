# The cell-map route by script

This folder holds the script form of the cell-map route of Lungfish Genome Explorer (LGE) sub-phase 5.5, the first step of owner direction O173 (script, then CLI, then app). `embed.py` takes the matrix entries of a single-cell result and writes one row a cell with a UMAP position and a Leiden cluster. The CLI's `rnaseq cell-map compute` ships `embed.py` byte for byte (5.5 C3). The other files run it on the gate sets and score the claims.

## Files

| File | Purpose |
| --- | --- |
| `embed.py` | The route. It opens with the guard of ruling C2-PYFLAGS, checks the environment against its explicit lock, asserts the locked versions and then runs the named steps |
| `run.sh` | Runs every claim in a work folder and writes `claims.tsv`. A run that finished is never redone |
| `claims.py` | Scores the runs and writes one row a claim with its kind and verdict |
| `claims.tsv` | The verdicts of the last full run on the Mac Studio |
| `prep.py` | The inputs. It reads the matrix entries of an LGE result for the pin, draws the seeded 100,000-cell subsample of G3, and makes the GSE145926 Matrix Market copies from the deposited h5 files after it checks that every labelled cell is in its sample's h5 |
| `stage_pbmc_1k_v3.sh` | Stages 10x's pbmc_1k_v3 `outs/` folder for the pin and writes its SHA256SUMS |

## How to run it

```bash
bash scripts/repro/rnaseq/sc-embed/route/run.sh WORK            # every step
bash scripts/repro/rnaseq/sc-embed/route/run.sh WORK g2 claims  # some steps
```

`LGE_SC_ENV` names the environment (default `/Volumes/lge_scratch/lge/rnaseq/env-sc-embed`, built from `scripts/repro/rnaseq/env/explicit-sc-embed-osx-arm64.txt`). `LGE_RNASEQ` names the scratch root of the staged data, and `LGE_CLI` names the `lungfish-cli` that runs `import rnaseq` for the pin. The timed runs wait until no other worktree builds.

Every run has one form, which the CLI also uses.

```bash
env -i PATH=<env>/bin:/usr/bin:/bin HOME=$HOME TMPDIR=<run folder> \
  OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1 VECLIB_MAXIMUM_THREADS=1 NUMBA_NUM_THREADS=1 \
  PYTHONHASHSEED=0 NUMBA_CACHE_DIR=<run folder>/numba MPLCONFIGDIR=<run folder>/mpl XDG_CACHE_HOME=<run folder>/xdg \
  <env>/bin/python -s -B -P embed.py <arguments>
```

`-I` and `-E` are never used, because both make Python ignore `PYTHONHASHSEED`. The guard exits with status 3 and one line naming the failed check unless the hash seed is 0 (or `--allow-hash-seed N` names the nonzero seed, the report-only probe of the arguments table), the user site is off, the script folder is off `sys.path`, no bytecode is written, the environment is read, no `PYTHON*` variable other than `PYTHONHASHSEED` is set, every `sys.path` entry lies under `sys.prefix` and Python is 3.11 or later.

## The arguments

Every value is named on the command line, and `embed.py` has no default of its own. The route's values are these.

| Argument | Route value | Meaning |
| --- | --- | --- |
| `--sample`, `--matrix`, `--features`, `--barcodes`, `--gzip` | one set for each matrix entry | The paths and the gzip state come from the parent manifest's matrix entry. Each barcode is kept as given, with 10x's `-1` or STARsolo's bare form |
| `--cells` | `all` | Or a TSV of `sample` and `barcode` naming the cells kept |
| `--lock` | `explicit-sc-embed-osx-arm64.txt` | The environment must hold exactly the lock's packages with the lock's md5 sums |
| `--threads` | `1` | Must equal the five thread variables. scanpy's `settings.n_jobs` is always 1 |
| `--feature-type` | `Gene Expression` | Other feature types are left out before the gene filter |
| `--min-cells` | `3` | `sc.pp.filter_genes` |
| `--target-sum` | `10000` | `sc.pp.normalize_total`, whose total sums only the kept genes. It is not the Gene Expression colour of 5.5 G1 |
| `--n-top-genes`, `--hvg-flavor` | `2000`, `seurat` | `sc.pp.highly_variable_genes`, then a subset to those genes before `scale` |
| `--scale-max` | `10` | `sc.pp.scale`, zero-centred |
| `--n-comps`, `--svd-solver`, `--pca-seed` | `50`, `arpack`, `0` | `sc.pp.pca` |
| `--n-neighbors`, `--n-pcs`, `--knn-metric`, `--neighbors-seed` | `15`, `30`, `euclidean`, `0` | `sc.pp.neighbors` with the umap connectivities |
| `--knn-transformer` | `sklearn` | Exact brute-force kNN at every size (vote S-2). `scanpy-default` is a probe that is never the route |
| `--leiden-flavor`, `--leiden-iterations`, `--leiden-directed`, `--leiden-use-weights`, `--resolution`, `--leiden-seed` | `leidenalg`, `-1`, `true`, `true`, `1.0`, `0` | `sc.tl.leiden` (5.5 O9 (a)) |
| `--umap-min-dist`, `--umap-spread`, `--umap-init`, `--umap-maxiter`, `--umap-seed` | `0.5`, `1.0`, `spectral`, `umap-default`, `0` | `sc.tl.umap` with the seeded legacy layout. umap-learn runs 500 epochs at 10,000 cells or fewer and 200 above |
| `--allow-hash-seed N` | not given | A report-only probe that lets the guard accept a nonzero `PYTHONHASHSEED`. The record then says so |

G3 runs at 20 PCs and resolution 0.8.

## What a run writes

| File | Holds |
| --- | --- |
| `cells.tsv` | `sample`, `barcode`, `x`, `y` and `cluster`, one row a cell in input order. The coordinates are round-trip float32 text, the shortest form that reads back to the same float (5.5 L4) |
| `variable_genes.tsv` | The feature id and name of each variable gene |
| `pca_variance_ratio.tsv` | The variance ratio of each principal component, as round-trip float32 text |
| `packages.tsv` | The name, version, build and channel of each package in the environment |
| `record.json` | Every parameter and seed, the steps in order, the interpreter's flags and `sys.flags`, the names of the variables the interpreter saw and the values of the 5.5 C2 variables, the CPU model, the OpenBLAS core type, numba's CPU name, the platform, the lock digest, each input file's sha256, the counts and the hashes of the four files above. It holds no time, host name or temporary path |
| `timings.json` | The seconds of each step. It is left out of every comparison |

The payload is `cells.tsv`, `variable_genes.tsv` and `pca_variance_ratio.tsv`. Two runs are equal when the three files have equal sha256 and the records are equal by bytes, or else the comparison names the keys that differ.

## The claims

`claims.tsv` gives each claim a kind. A gate must pass. A floor is one of the fixed floors of 5.5 T6 (ARI at least 0.40, AMI at least 0.60 and majority purity at least 0.65), which never move. A report row gives a number with no bar. Agreement with 10x's graph clusters and with published cell types is directional, and no row says that the route gives Cell Ranger's clusters.

| Claim | Input |
| --- | --- |
| G4, two runs at threads 1 are equal, and threads 1 against 4 as a report | G2 and G1 |
| G1 and G2 floors against 10x's graph clusters | 10x's filtered matrices of SC3pv3_GEX_Human_PBMC (5,140 cells) and pbmc_1k_v3 (1,222 cells) |
| The pin | `embed.py` on the `source/` matrix of the LGE result that `lungfish-cli import rnaseq` makes from the staged pbmc_1k_v3 `outs/` folder. Its row and the G2 row name the same `matrix.mtx.gz` sha256 |
| The STARsolo route chain, a report | The STARsolo GX `Gene` matrix of pbmc_1k_v3 (1,224 bare barcodes), scored over 10x's cells with each missing cell its own singleton |
| G3, a report | The 47 deposited matrices of GSE183579 (152,425 cells) against the cell types of `scripts/repro/rnaseq/gse183579/labels.py` |
| G5, a report | GSE145926 step A, the deposited h5 files of C143, C145, C51 and C52 one at a time, against the authors' `celltype`, joined on (sample, barcode) |
| Leiden flavors and seeds, reports | Both flavors on G1 for repeats, agreement and time, and Leiden seeds 1 to 9 against seed 0 on G2 |
| Naming the transformer, a gate | G2 and G1 with and without `transformer="sklearn"`, compared by bytes |
| Hash order, a report | G1 at `PYTHONHASHSEED` 0 against 1. The row reads "not valid" unless the probe's record shows guard "passed with --allow-hash-seed N", `PYTHONHASHSEED` equal to N and `hash_randomization` 1, and the route's record shows guard "passed", seed 0 and `hash_randomization` 0. A seed written `00` passes the guard and hashes as seed 0 |
| Time and peak, reports | G1, G3 and a seeded 100,000-cell subsample of G3 at threads 1 |

## Data and licences

The scripts are MIT. They commit no data. 10x's matrices and analysis archives, GSE183579's deposits and GSE145926's h5 files and label tables stay in scratch (rulings ARCH-LICENCE and LICENCE-2). The GSE145926 label table comes from `zhangzlab/covid_balf`, which states no licence, so the claims name its path and sha256 only.
