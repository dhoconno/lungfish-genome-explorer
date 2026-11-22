# Linux plan fixture for the FASTQ route

A plan folder that `lungfish-cli import fastq --write-plan` wrote for a run on a Linux machine, and the folder that run returned. Chapter 08-workflows/04 uses it to show what a plan holds, what a Linux run leaves and how `import fastq --adopt` brings the result into a project. The reads are 10,000 read pairs of the `hg002-chr20/` fixture. One sample, `hg002-chr20`, goes through three steps (clump the pairs with BBTools clumpify, take statistics with seqkit, count the qualities), and the job returns one interleaved FASTQ of 20,000 reads.

| Folder or file | What it holds | Bytes |
| --- | --- | --- |
| `reads/` | `hg002-chr20_R1.fastq.gz` and `hg002-chr20_R2.fastq.gz`, the first 10,000 read pairs of `hg002-chr20/` | 1,674,916 and 1,813,908 |
| `plan/hg002-chr20-plan/` | The plan folder as the command wrote it, 10 files: `run.dag`, `sample.sub`, `lge-job.sh`, `jobs.tsv`, `run-local.sh`, `README.txt`, `staging-files.json` and, in `hg002-chr20/`, `plan.json`, `plan.tar` and `staging.json` | 41,623 |
| `returned/hg002-chr20-plan/` | The same folder after the run, with the files of `result/` copied next to `plan.json` as the plan's `README.txt` says. It adds `hg002-chr20/run-record.json` and `hg002-chr20/out/sample.fastq.gz`. This is the folder `import fastq --adopt` reads | 1,510,180 |
| `run-logs/` | What the run printed and wrote: `run-local.log`, `logs/hg002-chr20.out` and `.err` (both empty) and the step logs in `hg002-chr20/logs/` | 3,129 |
| `docker-standin.sh` | The small `docker` command that stood in for Docker inside the Linux container (see How it was run) | 782 |

The plan names a container image (`lge-tools-43a3079b8fb1.sif`, 633,806,848 bytes, SHA-256 `43a3079b8fb1c32777fc772e1739f4002ab82f53c928cb114278f0910215b8e4`) and the Linux executor of Lungfish Preview 2026.11.15 (`lungfish-executor`, 59,148,672 bytes, SHA-256 `814925494d236164d22735dc54410785c28b9b750e7044bec03ff8fed3dc661b`, built from LGE commit `218471029a71bf9f7edf2c5ce2f1ea033c187f0d`). Neither file is here, since each is far over the 10 MB cap.

The plan files hold the paths of the machine that wrote them. The staging folder is `/Volumes/lge_scratch/lge/docs-fx4/staging`, the reads were at `/Volumes/lge_scratch/lge/docs-fx4/reads/` and the executor at `/Volumes/lge_scratch/lge/docs-fx4/executor/`. These are folders of a scratch disk and hold no user name. Read the plan as an example and do not run it as it is. To run a plan of your own, write one with your own `--staging-folder`.

## Source

The reads are the first 10,000 of the 45,574 read pairs of `hg002-chr20/`. That fixture holds HG002 (NA24385) Illumina 2 x 250 reads of `chr20:10,000,000-10,500,000` (GRCh38) from the Genome in a Bottle (GIAB) BAM of the National Institute of Standards and Technology (`https://ftp-trace.ncbi.nlm.nih.gov/ReferenceSamples/giab/data/AshkenazimTrio/HG002_NA24385_son/NIST_Illumina_2x250bps/novoalign_bams/HG002.GRCh38.2x250.bam`). Its README says how they were cut. The two files here were cut on 2026-11-21 and keep both mates in the same order.

```sh
gzip -dc HG002.chr20.10.0-10.5Mb_R1.fastq.gz | head -n 40000 | gzip -n -9 > hg002-chr20_R1.fastq.gz
gzip -dc HG002.chr20.10.0-10.5Mb_R2.fastq.gz | head -n 40000 | gzip -n -9 > hg002-chr20_R2.fastq.gz
```

Their SHA-256 are `82312a60ab52a1d47c2cbdd99964d2c1c7b817d5a3fb688e7fe5feec5f20586b` (R1) and `c5aac6d6092c83f6ed5a9e86ad38cce1f839dcfbfbaec6f3d6eca9c1e7ff7250` (R2). The plan and the run record list the same two values.

The plan came from this command, run with the `lungfish-cli` of Lungfish Preview 2026.11.15. The executor folder held a copy of the executor and its `manifest.json`, so that the plan names a folder with no user name.

```sh
lungfish-cli import fastq reads/hg002-chr20_R1.fastq.gz reads/hg002-chr20_R2.fastq.gz \
  --write-plan hg002-chr20-plan --staging-folder /Volumes/lge_scratch/lge/docs-fx4/staging \
  --executor-manifest <executor folder>/manifest.json --platform illumina --threads 4 --clumpify-heap-gb 4
```

The command ended with exit 0 and wrote one plan for one sample. `--threads` and `--clumpify-heap-gb` are required with `--write-plan`, since a plan fixes both. The job asks for 4 CPUs, 12,288 MB of memory and 9 GB of disk (`sample.sub` and `run.dag`).

## How it was run

`run-local.sh` records the name of the machine it runs on. On a Mac that is the Mac's name, so the run was made in a Linux container, where the name is the container's. The container is the Docker image `lge-tools:43a3079b8fb1` (Debian 12, linux/amd64, image ID `sha256:4d1027a4dcd93e272ccbcaaf2a4c4e55d1db43b6160284a03de8957f38231560`), started with the host name `lge-linux` by Docker Desktop (engine 29.9.2) on an Apple silicon Mac, so the job ran as amd64 code under emulation. The plan folder was mounted at `/work/hg002-chr20-plan` and the staging folder, with the executor and the two read files staged at the paths `staging-files.json` lists, at `/data` read-only.

A container cannot start another one, and this container is already the image the job needs. So `docker-standin.sh` was mounted as `/usr/local/bin/docker`. It answers the three calls that `run-local.sh` makes (`docker image inspect`, `docker version` and `docker run`) and runs the job in place. The Docker named in the run record is the engine that hosts the container.

```sh
docker run --rm --platform linux/amd64 --name lge-fx4-run --hostname lge-linux \
  --volume <plan folder>:/work/hg002-chr20-plan --volume <staging folder>:/data:ro \
  --volume <folder of docker-standin.sh>/docker:/usr/local/bin/docker:ro \
  --workdir /work/hg002-chr20-plan lge-tools:43a3079b8fb1 \
  sh run-local.sh --runtime docker --image lge-tools:43a3079b8fb1 --data /data
```

`<folder of docker-standin.sh>/docker` is a copy of `docker-standin.sh` named `docker`. The script printed `hg002-chr20: started.`, then `hg002-chr20: finished. Its files are in hg002-chr20/result/.`, then `run-local.sh: every sample finished or was skipped.`, and ended with exit 0. The run record says the run began at 2026-11-22T01:18:45Z and ended at 01:19:02Z, so it took 17 seconds.

The run record holds these site facts: `Machine=lge-linux`, `Arch=x86_64`, `OpSysAndVer=debian12`, `ContainerRuntime=Docker`, `ContainerRuntimeVersion=29.9.2`, `ContainerImageID=sha256:4d1027a4dcd93e272ccbcaaf2a4c4e55d1db43b6160284a03de8957f38231560` and `Launcher=run-local.sh/1`. Its three steps all succeeded.

| Step | Tool | What it did | Wall time |
| --- | --- | --- | --- |
| `storage` | `clumpify.sh` 40.02 (BBTools), Java heap 4 GB, 4 threads | Read both files, clumped the pairs and wrote `out/sample.fastq.gz`, interleaved, with qualities binned to five steps. 20,000 reads in and 20,000 out | 13.2 s |
| `statistics` | `seqkit` 2.13.0 | `seqkit stats -a -T out/sample.fastq.gz` | 1.5 s |
| `quality-count` | `lungfish-executor` 2026.11.15 | Ran the executor's own quality count (step kind `qualityCount`) | 0.2 s |

The returned folder was made as the plan's `README.txt` says, by copying the files inside `result/` next to `plan.json`.

```sh
rsync -a hg002-chr20-plan/hg002-chr20/result/ returned/hg002-chr20-plan/hg002-chr20/
```

## License

The reads are public domain. NIST and GIAB distribute their reference materials as U.S. government work with no usage restriction, as the README of `hg002-chr20/` says. Check your local jurisdiction if you redistribute outside the U.S.

The plan files, `run-record.json`, `docker-standin.sh` and the logs were written by Lungfish Genome Explorer (LGE) and are under LGE's MIT licence. The payload `out/sample.fastq.gz` is the reads above, reordered by clumpify with binned qualities, and is public domain like them. The tools the plan names (BBTools, seqkit) are not shipped here.

## Citation

```bibtex
@article{zook2019giab,
  author  = {Zook, Justin M. and McDaniel, Jennifer and Olson, Nathan D. and Wagner, Justin and Parikh, Hemang and Heaton, Haynes and Irvine, Sean A. and Trigg, Len and Truty, Rebecca and McLean, Cory Y. and De La Vega, Francisco M. and Xiao, Chunlin and Sherry, Stephen and Salit, Marc},
  title   = {An open resource for accurately benchmarking small variant and reference calls},
  journal = {Nature Biotechnology},
  year    = {2019},
  volume  = {37},
  pages   = {561--566},
  doi     = {10.1038/s41587-019-0074-6}
}
```

## Size

The set is 5,044,538 bytes (4.8 MiB) in 33 files. The largest file is `reads/hg002-chr20_R2.fastq.gz` at 1,813,908 bytes, so no file nears the 10 MB cap and the set is far under the 50 MB cap. `SHA256SUMS` lists the SHA-256 and the path of every file but itself and this README.

## Internal consistency

The plan, the run record and the staging list name the same two read files with the same sizes and SHA-256, which equal the files in `reads/`. The plan and the returned folder hold the same plan files byte for byte. The returned folder adds `run-record.json` and the payload, and `run-record.json` gives the payload's SHA-256 (`bd1e10e6cbc8939737fbfb6f66ad14a64247a7d9e664da36f0227d82a522d98c`) and size (1,453,947 bytes), which equal those of `out/sample.fastq.gz`.

The input holds 10,000 pairs, which are 20,000 reads, and clumpify reports 20,000 reads in and 20,000 out. The output is interleaved and in clump order, so its first reads are not the first reads of the input, and its qualities are binned, so it is not the input byte for byte.

No file holds a user name, a host name or a home path. The machine name in the run record is the container's, `lge-linux`, and the paths inside the run are the container's (`/work/hg002-chr20-plan`). The only other paths are the scratch-disk folders named above.

## Check

These commands ran with the `lungfish-cli` of Lungfish Preview 2026.11.15. The adopt makes the project when none is at the path, and the check used an empty project folder. Run it in this folder.

```sh
lungfish-cli import fastq returned/hg002-chr20-plan --adopt --project demo.lungfish
```

It ended with exit 0 and printed `Adopted hg002-chr20 as hg002-chr20.lungfishfastq` and `Adopted    : 1`, `Not adopted: 0`. The project holds `Imports/hg002-chr20.lungfishfastq` with `hg002-chr20.fastq.gz`. The adopt copies the payload into the bundle and leaves `hg002-chr20/out/` where it is.
