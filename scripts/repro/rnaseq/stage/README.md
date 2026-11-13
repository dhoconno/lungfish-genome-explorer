# Staging RNA-seq data

These scripts download public RNA-seq data to the external drive, check every file and keep one shared ledger. They use only the Python standard library plus `aria2c` (curl is the fallback). Nothing here installs tools or touches controlled-access data.

| File | What it does |
|---|---|
| `stage.py` | Reads a TSV manifest, downloads each file, checks size and checksum, writes a sha256 sidecar and appends a ledger row |
| `stage_ena.py` | Turns an ENA `filereport` TSV into a manifest under `studies/<id>/raw/` with ENA's md5 values |
| `manifests/stage0-tenx.tsv` | The three 10x benchmark sets (pbmc_1k_v3, sc5p_v2_hs_PBMC_1k, hgmm_1k_v3) |
| `manifests/stage0-refs.tsv` | The human, mouse and rhesus references with the checksums from each source |

Tests are in `scripts/tests/test_repro_stage.py`. Run them from the repository root with `python3 -m unittest discover -s scripts/tests -p 'test_repro_stage.py' -v`.

## Layout on the drive

The root is `/Volumes/lge_scratch/lge/rnaseq`. Everything below it counts toward the cap.

| Path | Holds |
|---|---|
| `tenx/<dataset>/` | One 10x data set. FASTQ tar, filtered and raw matrices, metrics summary, web summary, molecule info |
| `refs/<species>/<source>-<release>/` | FASTA and annotation only, no indexes. For example `refs/human/ensembl-93/` and `refs/rhesus/refseq-GCF_003339765.1/` |
| `studies/<id>/raw/` | The reads of one study, with `manifest.tsv` from `stage_ena.py` |
| `MANIFEST.tsv` | The shared ledger |
| `logs/` | One log per staging run |

Next to every staged file `file.ext` sits `file.ext.sha256`, in the format `shasum -a 256 -c` reads. A download in progress is `file.ext.part` (and `file.ext.part.aria2`). It becomes `file.ext` only after the checks pass, so a file without `.part` is a verified file.

## Limits

`stage.py` refuses to start (exit code 2, nothing downloaded) when the root folder plus the new bytes would pass 1 TB (`--cap-bytes`, default 1,000,000,000,000) or when the drive would keep less than 500 GB free (`--min-free-bytes`, default 500,000,000,000). It checks the free space again before each file, because other lanes write to the same folder. The cap check before each file counts the bytes this run has already reserved, not what other runs have added since it started.

A destination outside the root is refused. A missing root is refused, so an unmounted drive never fills the internal disk.

## The manifest

One file per line, tab separated, with `#` comments and an optional header line starting with `url`.

| Column | Meaning |
|---|---|
| `url` | `https`, `http`, `ftp` or `file` url |
| `dest_path` | Path under the root, or an absolute path inside it |
| `checksum_type` | `md5`, `sha1`, `sha256`, `sha512`, `s3etag`, `bsdsum` or blank |
| `checksum` | The value from the source, blank when the source has none |
| `bytes` | Expected size, blank when unknown (a blank size is read from the server's `Content-Length`) |

Two types need a note. `s3etag` is the ETag that S3 buckets send. A plain ETag is the file's md5 and a multipart ETag (ending in a dash and a number) is rebuilt from the part md5s, trying the usual part sizes. `bsdsum` is the checksum in Ensembl's `CHECKSUMS` files, written as `07119 860562` (checksum and 1 KiB blocks). The system `sum` tool computes it and only the first number is compared. It is a weak 16 bit check, so a size match backs it up.

With `--etag`, a blank checksum is filled from the server's ETag when it looks like an md5. The 10x files are staged this way.

## The ledger

`MANIFEST.tsv` has a header and one row per staged file. `stage.py` takes an exclusive file lock to append, so lanes can append at the same time. A row for the same path and checksum is never written twice. Rows of other lanes are kept.

| Column | Meaning |
|---|---|
| `path` | Absolute path of the file |
| `url` | Where it came from |
| `bytes` | Size on disk |
| `checksum_type` | Always `sha256` from `stage.py` |
| `checksum` | sha256 of the staged file |
| `source_checksum_verified` | `yes` when the file matched the checksum from the source (ENA md5, GENCODE or NCBI md5, Ensembl sum, S3 ETag), `no` when the source gave none |
| `downloaded_at` | UTC time, `YYYY-MM-DDTHH:MM:SSZ` |
| `staged_by` | Lane name from `--staged-by` |

`stage.py --prune-ledger` drops the rows of files that no longer exist. Run it after deleting a dropped study.

## Staging a study from ENA

1. Make the manifest. `--fetch` asks the ENA portal for the filereport of the project or study accession. A saved filereport file works too.

   ```sh
   python3 -I scripts/repro/rnaseq/stage/stage_ena.py --fetch PRJNA123456 --study GSE123456 \
       --save-filereport /tmp/GSE123456.filereport.tsv
   ```

   The manifest lands in `studies/GSE123456/raw/manifest.tsv`. Use `--runs SRR1,SRR2` or `--runs @runs.txt` to keep some runs. Use `--files submitted` to take the files the submitter uploaded, for example the original R1, R2 and I1 files. Use `--max-bytes` to refuse an oversized study.

2. Look at the plan and the budget check.

   ```sh
   python3 -I scripts/repro/rnaseq/stage/stage.py /Volumes/lge_scratch/lge/rnaseq/studies/GSE123456/raw/manifest.tsv \
       --dry-run --staged-by R2-ABC
   ```

3. Download in the background and read the log.

   ```sh
   python3 -I scripts/repro/rnaseq/stage/stage.py /Volumes/lge_scratch/lge/rnaseq/studies/GSE123456/raw/manifest.tsv \
       --jobs 3 --staged-by R2-ABC > /Volumes/lge_scratch/lge/rnaseq/logs/GSE123456.log 2>&1 &
   ```

   Running the same command again skips files that are already staged and resumes the ones left as `.part`. A file that fails its size or checksum check is discarded and fetched again, up to two more times.

The log prints the size and speed of each file and a summary. The exit code is 0 when every file is staged, 1 when a file failed and 2 when the manifest or the budget was refused.

## Other sources

Write the manifest by hand or from the source's checksum file, as `manifests/stage0-refs.tsv` does. NCBI and GENCODE publish md5 files, Ensembl publishes `CHECKSUMS` with the `sum` values, and the 10x download host sends S3 ETags. Keep the source's own checksum file next to the data (the reference manifest stages them as `CHECKSUMS.fasta`, `MD5SUMS` and so on).

SRA run objects are not served by ENA as FASTQ with all read layouts. When a study needs the barcode read, take the SRA object url and convert it outside this script.

## Duplicates

`--link-duplicates` runs after staging. It scans the folders of the manifest (or the `--link-scope` folders) for staged files of at least 1 MiB with the same sha256 and size, keeps the oldest copy and turns each other copy into a relative symbolic link. Only files that are byte-identical as stored are linked, so a re-compressed gzip of the same sequence stays a separate file with its own source checksum.

## Safety

- Downloaded files are data. The scripts hash and size them and never run or source them. Python that reads downloaded files must run with `-I` from a script outside the data folder.
- A url that needs a login, a form or accepting terms is not staged. Stop and report it.
- `Ctrl-C` or `kill <pid>` of `stage.py` stops its aria2c and curl children and leaves the `.part` files for a resume. `stage.py` prints its pid on its first line.
