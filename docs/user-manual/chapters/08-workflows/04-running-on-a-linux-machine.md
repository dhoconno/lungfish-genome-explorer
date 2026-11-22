---
title: Running on a Linux Machine
chapter_id: 08-workflows/04-running-on-a-linux-machine
audience: analyst
prereqs: [03-reads/01-importing-fastq, 01-foundations/08-provenance-and-reproducibility]
estimated_reading_min: 21
task: Write a plan folder for a Linux machine or an HTCondor pool, run it there, and adopt the returned run into your project.
tags: [workflows, linux, htcondor, plan-folder, staging, staged-reads, adopt, batch, cluster]
tools: [clumpify, seqkit]
parameters_refs: [import.fastq-linux-plan]
entry_points:
  - "File > Import Center… (Cmd-Shift-I) > Sequencing Reads > Plan for a Linux Machine"
  - "File > Import Center… (Cmd-Shift-I) > Sequencing Reads > Linux Run Result"
  - "File > Import Center… (Cmd-Shift-I) > Sequencing Reads > RNA-seq Plan for a Linux Machine"
  - "File > Import Center… (Cmd-Shift-I) > Sequencing Reads > Single-cell Plan for a Linux Machine"
  - "File > Import Center… (Cmd-Shift-I) > Sequencing Reads > RNA-seq Linux Run Result"
  - "CLI: lungfish-cli import fastq --write-plan"
  - "CLI: lungfish-cli import fastq --adopt"
shots:
  - id: linux-plan-sheet
    caption: "The Plan for a Linux Machine sheet for the fixture's reads folder, with Staging folder, Threads per job, and Clumpify memory (GB) above the Optimize storage box, the Compression Tool popup, and Write Plan…."
  - id: linux-run-result-card
    caption: "The Sequencing Reads tab of the Import Center, with the Plan for a Linux Machine card that writes a plan and the Linux Run Result card that adopts a returned run."
  - id: adopted-run-runtime
    caption: "The Provenance tab of the Inspector on the adopted hg002-chr20 bundle, with Wall Time (Linux run) in Run Summary and the Steps ran on, Steps ran with, Leftover processes, and Reported by the launcher rows in Runtime."
illustrations: []
glossary_refs: [linux, plan-folder, staging-folder, staged-reads, adopt, htcondor, held-job, apptainer, ssh, container, docker, checksum, fastq, read, read-pair, interleaved-fastq, phred-score, clumpify, read-clumping, quality-binning, adapter, sample-sheet, tsv, json, terminal, shell, thread, process, exit-status, absolute-path, bundle, project, import-center, operations-panel, inspector, provenance, run-record, wall-time]
features_refs: [import.fastq-linux-plan, import.rnaseq-plan, import.rnaseq-adopt, provenance.inspector]
fixtures_refs: [linux-plan-fastq, hg002-chr20]
brand_reviewed: false
lead_approved: false
---

<!-- SCOPE: Writing a plan folder for a Linux machine or an HTCondor pool, running it there, and adopting the returned run into the project. -->

## What it is

A large read set can take hours to reorder and compress, and many labs have a shared Linux computer that could do that work while the Mac stays free. Lungfish Genome Explorer (LGE) can hand the heavy part of a [FASTQ](../../GLOSSARY.md#fastq) import to such a computer and take the result back. The Mac writes down exactly what to run, the Linux computer runs it, and the Mac checks what came back before it makes a read bundle. [Linux](../../GLOSSARY.md#linux) is the operating system that most shared research computers and computing clusters run.

For FASTQ reads the heavy part is the storage step that every import on the Mac also runs. BBTools [clumpify](../../GLOSSARY.md#clumpify) reorders the reads so that similar reads sit together and the file compresses smaller, a step called [read clumping](../../GLOSSARY.md#read-clumping). SeqKit then counts the reads and bases, and LGE counts the bases at quality 20 or better and at quality 30 or better. The RNA-seq and single-cell plan cards send counting work along the same route, and their chapters link back here for it.

### Plan folders, staging folders, and staged reads

A [plan folder](../../GLOSSARY.md#plan-folder) is an ordinary folder of text files that LGE writes on the Mac. It holds one folder per sample, named for the sample, with that sample's plan, and it holds the files that start the samples on Linux. A plan fixes every setting. It names every tool by version and build, and every file by its size and [checksum](../../GLOSSARY.md#checksum), a SHA-256 fingerprint of the file's exact bytes, so every machine that runs the plan runs the same programs on the same files. Writing a plan imports nothing and submits nothing.

The steps run inside a [container](../../GLOSSARY.md#container) image, one file of about 634 MB that packages every tool at its pinned version. A Linux program called `lungfish-executor`, which ships inside the app, runs the steps. Before any tool runs, it checks the size and checksum of each input against the plan. When the steps end, it writes a run record, `run-record.json`, that lists each step, each tool's version, each file's checksum, and how long each step took.

The jobs read their files from a [staging folder](../../GLOSSARY.md#staging-folder), a folder on the Linux side that every machine running the jobs can read. Its layout is fixed. The image goes in `images/`, the executor in `shared/` under a name that starts with its checksum, and each sample's reads in `batches/<plan folder>/<sample>/`. Each job returns its files to a `result/` folder inside its sample's folder there. The plan's `staging-files.json` lists every file the jobs read, with its size, its checksum, and, for each file but the image, the file on the Mac to copy.

[Staged reads](../../GLOSSARY.md#staged-reads) are reads that already sit in the staging folder, for example because a sequencing core delivered them to the cluster. A plan can name them by path, size, and checksum, and the Mac then never opens or copies them. For FASTQ reads this route exists only on the command line, and the RNA-seq plan sheets take staged reads too.

To [adopt](../../GLOSSARY.md#adopt) a returned run is to bring it into a project. LGE reads the plan the Mac wrote and the run record that came back, checks the size and checksum of every returned read file against the record, and only then writes one FASTQ [bundle](../../GLOSSARY.md#bundle) per sample, with the run's record as the bundle's [provenance](../../GLOSSARY.md#provenance).

### One Linux machine or an HTCondor pool

Every plan folder can run in two ways. On one machine, `run-local.sh` runs the samples inside the image, at most 10 samples at a time, through [Apptainer](../../GLOSSARY.md#apptainer) or [Docker](../../GLOSSARY.md#docker). Apptainer is container software for shared Linux computers that runs an image as an ordinary user, and Docker is the container software many desktop computers use. On a cluster, [HTCondor](../../GLOSSARY.md#htcondor) runs the plan. It is a scheduler that shares a group of computers, called a pool, among many users. You hand it jobs, here one job per sample, and it finds a free machine for each. `run.dag` and `sample.sub` are the files HTCondor reads, and they run the same plans that `run-local.sh` runs.

In practice, write the plan on the Mac, let the Linux side run the long step, and adopt what comes back, so the bundle records where and how its reads were processed.

## Why you would do this

The fixture holds 10,000 read pairs of HG002, the Genome in a Bottle reference sample, from 500 kb of human chromosome 20. A whole human genome sequenced deeply enough for variant calling usually runs to hundreds of millions of read pairs. Reordering that many reads takes hours, and an import on the Mac needs free disk of about five times a sample's read files while clumpify runs. A Linux computer with many cores and a large disk can do that work, and a pool can do it for many samples at once.

The route keeps what a Mac import gives you. The plan pins every tool, the run record lists every step and file, and the adopt refuses a returned file whose size or checksum differs from the record. The bundle that lands in the project carries the same kind of record a Mac import writes, plus where the steps ran, so a collaborator can see from the bundle alone that its reads were reordered on Linux with clumpify 40.02 and how long that took.

The fixture is small so that every step finishes in seconds and every file is small enough to open and read. The same steps apply unchanged to a full-size run.

## Choosing a tool

The choice is where the plan runs, and it rests on which computers you can reach and how many samples you have. Importing on the Mac stays the simplest choice for a few samples that fit its disk.

**Import on the Mac.** The Sequencing Read Files card of [Importing Sequencing Reads](../03-reads/01-importing-fastq.md) runs the same storage step on the Mac and makes the bundle at once, with nothing to copy. It suits a handful of samples, and it needs the free disk described above while clumpify runs.

**`run-local.sh` with Apptainer.** The plan's own launcher runs each sample in the image on one Linux machine, at most 10 samples at a time. Apptainer runs the image file as it is, and the launcher refuses an image whose checksum is not the plan's. It suits a lab server or one large machine, and it needs no scheduler.

**`run-local.sh` with Docker.** The same launcher runs each sample in a Docker image instead. Docker cannot run the image file directly, so the file must first be made into a Docker image for linux/amd64. The app does not do this, and the LGE source code holds a script for it, `scripts/linux/launcher-tier.sh`. The plan's README says a Mac with Docker can run `run-local.sh` too. On a Mac with Apple silicon, Docker then runs the image's x86-64 programs under emulation, which is slower.

**`run.dag` on an HTCondor pool.** HTCondor runs one job per sample on whichever pool machines are free, at most 10 jobs at once by default. It holds a job that fails to fetch or return its files, so you decide what happens to it. It suits a batch of many samples on a shared cluster. Its default machine requirement names an attribute, `HasCHTCStaging`, that only the pool LGE was tested on is known to set, so on another pool you write the plan on the command line with `--job-requirements`.

| Tool | Built for | Choose it when | Choose something else when |
|---|---|---|---|
| Import on the Mac | A few samples on one Mac | The reads fit the Mac's disk and time | The Mac lacks the disk or the hours |
| `run-local.sh` with Apptainer | One Linux machine | You have a login on a Linux server with Apptainer | You have many samples and a pool |
| `run-local.sh` with Docker | One machine with Docker | Docker is what the machine has | Apptainer is there, since it runs the image file as is |
| `run.dag` on HTCondor | A shared pool of machines | You have many samples and a pool login | You have one machine and no pool |

The fixture's run used `run-local.sh` with Docker inside a Linux container on a Mac, with a small stand-in for the `docker` command, so it needed no cluster, and its run record names the container, `lge-linux`, as the machine. With a Linux server of your own, choose Apptainer, and with a pool, choose HTCondor. A plan's steps run BBTools clumpify and SeqKit on either launcher, and their citations are under [Tools installed with every copy of LGE](../appendices/bibliography.md#tools-installed-with-every-copy-of-lge) in the Tool Bibliography.

## Before you start

You need LGE on a Mac, in a build that includes the Linux executor, which release builds do. A build without it keeps the sheet open with **Write Plan…** greyed out, and a line under the controls says the build has no Linux executor and cannot write a plan. Writing a plan needs no open project. Adopting a run needs one, as [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows. The plan's tools run in the image on the Linux side, not on the Mac.

On the Linux side you need these things:

- A login to the Linux machine, or to the pool's submit machine, through [SSH](../../GLOSSARY.md#ssh), the secure remote login that the `ssh` command in [Terminal](../../GLOSSARY.md#terminal) opens.
- An x86-64 Linux machine with Apptainer or Docker, or an HTCondor pool of x86-64 machines that run EL9 or later, version 9 of the Enterprise Linux family that includes Red Hat Enterprise Linux and Rocky Linux.
- A staging folder that every machine running the jobs can read, with room for the image, the executor, the reads, and the results.
- The tool image that `staging-files.json` names, a file called `lge-tools-<id>.sif`, in the staging folder's `images/`. LGE does not include it or download it, so ask the person who looks after your Linux machine or pool for it.

This chapter uses the `linux-plan-fastq` fixture from [the linux-plan-fastq fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/main/docs/user-manual/fixtures/linux-plan-fastq), whose README gives its source, license, and citation. Its `reads/` folder holds the first 10,000 read pairs of the hg002-chr20 fixture as `hg002-chr20_R1.fastq.gz` and `hg002-chr20_R2.fastq.gz`. Its `plan/hg002-chr20-plan/` is the plan as LGE wrote it, `returned/hg002-chr20-plan/` is the same folder after a run, and `run-logs/` holds what the run printed. The plan files hold the paths of the machine that wrote them, so read that plan as an example and write your own, with your own staging folder, before you run anything. The returned folder can be adopted as it is, so you can try the last procedure without a Linux machine.

The fixture's run took 17 seconds. Copying its files takes as long as your network needs for about 63 MB one way, most of it the executor, which stays in `shared/` for later plans, and 1.5 MB of results back.

## Procedure

### Write a plan folder with the Plan for a Linux Machine card

1. Choose **File > Import Center…** (Cmd-Shift-I) and click the **Sequencing Reads** tab, as [The Import Center](../01-foundations/06-the-lungfish-project.md#the-import-center) describes.

2. Click the **Plan for a Linux Machine** card. In the file panel, select the fixture's `reads` folder, which holds only the two read files, and click **Open**. The panel takes read files or one folder of them, and the Import Center closes.

3. In the **Plan for a Linux Machine** sheet, check the line under the title, which reads `Reads: reads` for the folder you chose. Type the [absolute path](../../GLOSSARY.md#absolute-path) of your staging folder into **Staging folder**, the full path from `/` on the Linux side, not on the Mac.

    <!-- SHOT: linux-plan-sheet -->

4. Type `4` into **Threads per job** and `4` into **Clumpify memory (GB)** to match the fixture's plan. Leave **Optimize storage (reorder reads for better compression)** ticked and **Compression Tool** on BBTools clumpify. [Settings](#settings) explains each control.

5. Click **Write Plan…**. In the panel that slides down, which reads "Name a new folder for the plan. Nothing is imported and nothing is submitted.", type `hg002-chr20-plan`, choose a folder on the Mac, and click **Write Plan**.

The [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel) shows the row `Plan for a Linux Machine: hg002-chr20-plan` while LGE writes, and the row ends with `Plan written to hg002-chr20-plan`. The new folder holds the files that [The plan folder and its README](#the-plan-folder-and-its-readme) describes. Open its `README.txt` in TextEdit. Every command for running the plan and bringing it home is in it, already filled in with your staging folder and the plan's name.

### Plan reads that are already on the Linux machine

Staged reads skip the copy from the Mac. The route runs on the command line, and you need the reads' paths, sizes, and checksums from the Linux side first.

1. Log in to the Linux machine with SSH. Run these lines there, with the absolute path of the folder inside the staging folder that holds the reads in place of `/absolute/folder`. They write `staged-reads.tsv`, a [TSV](../../GLOSSARY.md#tsv) file with one line per read file:

    ```sh
    printf 'file\tbytes\tsha256\n' > staged-reads.tsv
    for f in /absolute/folder/*.fastq.gz; do
      printf '%s\t%s\t%s\n' "$f" "$(stat -L -c %s "$f")" "$(sha256sum "$f" | cut -d ' ' -f 1)" >> staged-reads.tsv
    done
    ```

2. Copy `staged-reads.tsv` to the Mac. Beside it, write a [sample sheet](../../GLOSSARY.md#sample-sheet) named `samples.csv` with the columns `sample`, `r1`, and `r2`, where `r1` and `r2` give each read's absolute path on the Linux side. An optional `request_disk` column gives a sample's disk request in whole GB.

3. Write the plan on the Mac. Name the platform with `--platform`, because LGE reads none of the reads and cannot work it out:

    ```sh
    lungfish-cli import fastq --samplesheet samples.csv --staged-reads staged-reads.tsv \
      --platform illumina --write-plan "<plan folder>" --staging-folder "<staging folder>" \
      --threads 8 --clumpify-heap-gb 16
    ```

The README of a staged-reads plan adds one check before you submit. Each read must sit at its `stagingPath` with the size `staging-files.json` lists, and it must stay there until every job has run, because a missing read holds its job and that job leaves no run record.

### Copy the plan folder and stage the reads

1. Open `staging-files.json` in the plan folder. For each file that has a `source`, copy that Mac file to its `stagingPath` on the Linux side, with the copy program you already use to reach the machine, such as `scp` or `rsync`. For the fixture those are the executor, about 59 MB, which the app holds, and the two read files.

2. Leave a file in `shared/` alone when one with the listed size is already there. Its name starts with its checksum, so it is the same file, and the jobs of another plan may be reading it.

3. Check that the image named in the entry whose `role` is `image` is in `images/`, since it has no source on the Mac.

4. Copy the whole plan folder to the Linux machine that runs it, or to the pool's submit machine.

For `run-local.sh` the files can go into a data folder of your choosing instead, each at its `stagingPath` with the staging folder taken off the front, which gives the folders `shared/`, `batches/hg002-chr20-plan/`, and `images/` for Apptainer. A Docker run reads no `images/` folder. On a machine that can read the staging folder, the staging folder itself can be the data folder, and then nothing needs copying.

### Run the plan on one Linux machine with run-local.sh

1. Log in to the Linux machine with SSH and change to the copied plan folder with `cd`.

2. Run one of these, with your data folder in place of `<data folder>` and, for Docker, the name of the Docker image in place of `<image>`:

    ```sh
    sh run-local.sh --runtime apptainer --data "<data folder>"
    sh run-local.sh --runtime docker --image "<image>" --data "<data folder>"
    ```

3. Watch the progress lines. For the fixture they read as follows:

    ```text
    hg002-chr20: started.
    hg002-chr20: finished. Its files are in hg002-chr20/result/.
    run-local.sh: every sample finished or was skipped. Copy each <sample>/result/ to the Mac as README.txt says.
    ```

With Apptainer, the script runs `images/lge-tools-<id>.sif` from the data folder, once its checksum matches the plan's. With Docker, it runs the Docker image you name. `--jobs <n>` changes the limit of 10 samples at once, `--sample <name>` runs one sample, and `--scratch <folder>` moves each sample's work folder from `scratch/` in the plan folder to a disk with room for that sample's disk request.

Each sample leaves `<sample>/result/` with its run record, reports, and reads, and `<sample>/logs/` with its step logs, while `logs/<sample>.out` and `logs/<sample>.err` hold the job's own output. The script skips a sample that already has a `result/` folder, so running it again runs only the samples that returned nothing. Delete a sample's `result/` folder to run that sample again. The script ends with [exit status](../../GLOSSARY.md#exit-status) 0 when every sample finished or was skipped, 1 when one did not finish, and 2 when it refused before any sample started.

### Submit the plan to an HTCondor pool

1. Log in to the pool's submit machine with SSH and change to the copied plan folder with `cd`.

2. Submit the batch:

    ```sh
    condor_submit_dag run.dag
    ```

3. Follow the samples in `run.dag.status`, which HTCondor rewrites about once a minute in the plan folder with each sample's state.

At most 10 jobs run at once, from the line `MAXJOBS lge 10` in `run.dag`, so edit that number before you submit to change it. Each job asks for the CPUs and memory in `sample.sub` and the disk in `run.dag`. It returns its files to `batches/hg002-chr20-plan/<sample>/result/` in the staging folder and its step logs to `<sample>/logs/` in the plan folder. The jobs ask for machines that reach the staging folder, run EL9 or later, and are x86-64. On a pool whose machines do not set `HasCHTCStaging`, write the plan again on the command line with `--job-requirements '<expression>'`, which replaces that whole requirements line of `sample.sub`.

### Release a held HTCondor job

A [held job](../../GLOSSARY.md#held-job) is one HTCondor has stopped and set aside. It waits, and the batch does not finish until you deal with it. The plan already tells HTCondor how to release the two common kinds by itself, so those need nothing from you unless a job is held a third time.

1. See which sample is held, and why:

    ```sh
    condor_q -hold -af ClusterId ProcId DAGNodeName ExitCode HoldReasonCode NumHolds HoldReason
    ```

    Each line gives the job's two numbers, the sample's name, the run's exit code, the hold's code, how many times the job has been held, and HTCondor's reason. In `logs/<sample>.log`, "Job was evicted" followed by "Job was held" is one hold, not a move to another machine.

2. Leave a job held with code 12 and exit code 0, which finished its run and only failed to send its files back. Leave a job held with code 13 too, which could not fetch an input file and never ran, so its exit code reads undefined. HTCondor releases a job held for either reason by itself, at most twice.

3. A job held a third time stays held. If its reason says the transfer made no progress, release it yourself once the staging folder answers again:

    ```sh
    condor_release <ClusterId>.<ProcId>
    ```

4. For any other hold, fix what the reason names. Running the sample again replaces its run record, so copy the record aside first, then remove the job. HTCondor counts that sample as failed and goes on with the others:

    ```sh
    cp "<staging folder>/batches/hg002-chr20-plan/<sample>/result/run-record.json" "<sample>/run-record-<ClusterId>.json"
    condor_rm <ClusterId>.<ProcId>
    ```

5. When the other samples have finished, the run writes `run.dag.rescue001`, which lists the samples still to run. Run `condor_submit_dag run.dag` again from the plan folder, and HTCondor reads the rescue file and runs only those samples.

A hold whose reason says an output file could not be sent back means that sample's job returned no reads. Read its run record in the staging folder and its step logs in `<sample>/logs/` to see which step stopped. A job the executor refuses before its first step leaves only the record, and a job that `lge-job.sh` refuses leaves no record, so read `logs/<sample>.err` for it.

### Copy the returned run back to the Mac

The adopt reads one folder per sample, the `plan.json` your Mac wrote with the job's files beside it. So for every sample, the files inside its `result/` folder go into that sample's folder of the plan folder on the Mac, next to `plan.json`. The step is the same for both launchers, and only the source differs.

1. In Terminal on the Mac, change to the folder that holds `hg002-chr20-plan`.

2. Run the README's copy loop, with `<source>` replaced as the next paragraph says:

    ```sh
    for sample in $(grep -v '^#' hg002-chr20-plan/jobs.tsv | cut -f 1); do rsync -a <source>/"$sample"/result/ hg002-chr20-plan/"$sample"/; done
    ```

3. Check that `hg002-chr20-plan/hg002-chr20/` now holds `run-record.json` and `out/sample.fastq.gz` beside `plan.json`, and no `result/` folder.

After an HTCondor run, `<source>` is `<host>:<staging folder>/batches/hg002-chr20-plan`. After `run-local.sh`, it is `<host>:` followed by the plan folder's path on the machine that ran it. `<host>` is the name you give `ssh`, and a name from your SSH configuration file works. When the files are already on the Mac, `<source>` is that folder alone, with no `<host>:`. The slash after `result` matters, because it copies what is inside the folder rather than the folder itself. A host that needs `ssh -F <config file>` needs it in `rsync` too, so run `export RSYNC_RSH='ssh -F <config file>'` on its own line before the loop.

Copy nothing else. The adopt reads no log, and it must read the `plan.json` the Mac wrote, never a copy from the Linux side. A run of `run-local.sh` leaves `<sample>/logs/` beside `<sample>/result/`, which is why the loop copies what is inside `result/` and not the whole sample folder.

### Adopt the returned run with the Linux Run Result card

1. Open the [project](../../GLOSSARY.md#project) that should hold the bundles. For the fixture, a new empty project from **File > New Project** is enough.

2. Choose **File > Import Center…** (Cmd-Shift-I), click the **Sequencing Reads** tab, and click the **Linux Run Result** card.

    <!-- SHOT: linux-run-result-card -->

3. In the file panel, select the plan folder that holds the returned files and click **Open**. For the fixture that is `returned/hg002-chr20-plan`. One sample's folder works too.

4. Watch the row `Linux Run Result: hg002-chr20-plan` in the Operations Panel. It reads `Checking the returned folder…` while LGE checks every file, and it ends with `Imported hg002-chr20.lungfishfastq`. A batch of three samples ends with `Imported 3 samples`.

5. Find the new bundle `hg002-chr20` under `Imports` in the sidebar.

With no project open, choosing a folder brings up the alert "No Project Open". The adopt copies each sample's reads into its bundle and leaves the returned copy where it is, so the Mac needs room for the reads twice, unless the plan folder and the project sit on one APFS volume, where the copy shares the space of the original. Once the adopt has finished, `<sample>/out/` may be deleted. When no sample was refused, the `result/` folders in the staging folder may be removed too.

## Settings

These are the controls of the Plan for a Linux Machine sheet. The Linux Run Result card has no sheet and no settings, because the plan fixed every setting before the run. The sheet names no platform, recipe, or sample sheet, so a plan it writes is planned as short reads with no recipe, and the command line takes `--platform`, `--recipe`, `--samplesheet`, `--staged-reads`, and `--job-requirements` for the rest. The plan stores quality scores in steps of five, the [quality binning](../../GLOSSARY.md#quality-binning) an import uses unless told otherwise, as [Importing Sequencing Reads](../03-reads/01-importing-fastq.md#settings) explains.

**Staging folder:.** Gives the absolute path of the staging folder on the Linux side, which the plan writes into every file that names a place there. The field starts empty, because only you know where that folder is, and **Write Plan…** stays greyed out until it holds a path that starts with `/`. Change it for every Linux machine or pool you plan for, and write a new plan rather than editing an old one when the folder moves. On the command line this is `--staging-folder`.

**Threads per job:.** Sets how many [threads](../../GLOSSARY.md#thread), parallel workers, each sample's job uses on the Linux side, and each HTCondor job asks the pool for the same number of CPUs. The default is 8, and since a pool must find a machine with that many free CPUs, a larger number can make each job wait longer to start. Lower it to fit a smaller machine, and raise it when the machines you use give one job more cores. On the command line this is `--threads`.

**Clumpify memory (GB):.** Sets the Java heap, the working memory in GB that BBTools clumpify may use on the Linux side, and each HTCondor job asks for that much memory plus 8 GB for Java itself and the compressors around it. The default is 16 GB, a 24 GB request in all, and a smaller heap still works, because clumpify splits a sample that does not fit into more groups, as the line under **Compression Tool** says. Lower it when the machines you use have less memory to give one job. On the command line this is `--clumpify-heap-gb`.

**Optimize storage (reorder reads for better compression).** Turns read clumping on, so clumpify places reads that share sequence next to each other before the reads are compressed, and the stored file shrinks while its read order no longer matches the source files. It opens ticked, and a moment later LGE reads the first read headers and clears it for Oxford Nanopore, PacBio, and Unknown reads, because clumpify works well only on accurate reads. Clear it yourself when a later step needs the original read order, or tick it to reorder long reads anyway. On the command line this is `--no-optimize-storage`.

**Compression Tool:.** Picks the program that reorders the reads, offering BBTools clumpify and Trim Galore --clumpify, and it is greyed out while the Optimize storage box is clear. The default is BBTools clumpify, which reorders the reads without trimming or dropping any, and the sheet offers no Automatic choice, so the plan records the tool you see. Choose Trim Galore --clumpify only when you want the reads trimmed in the same step, because it also removes [adapter](../../GLOSSARY.md#adapter) sequence, trims low-quality ends, and drops short reads, as the line under the popup says. On the command line this is `--clumping-tool`.

## Reading the results

### The plan folder and its README

A plan folder holds these files. Each is plain text except `plan.tar`, so you can open any of the others in TextEdit.

| File | What it holds |
|---|---|
| `README.txt` | The commands for both ways to run the batch, for a held job, and for bringing the results home, written with the plan's own staging folder, name, and numbers |
| `staging-files.json` | Every file the jobs read, with its size in bytes, its checksum, its `stagingPath`, and, for each file but the image, its `source` on the Mac |
| `run.dag` and `sample.sub` | The HTCondor batch, with one `JOB` line per sample in `run.dag` and the job description they share in `sample.sub` |
| `jobs.tsv` and `run-local.sh` | The one-machine route, with one row per sample in `jobs.tsv` and the launcher that reads it |
| `lge-job.sh` | The small script both routes run to unpack a sample's plan and start the executor |
| `<sample>/` | The sample's `plan.json`, the packed copy `plan.tar` that its job carries, and `staging.json`, which names the image and the files the job reads |

For the fixture, `staging-files.json` lists four files. The image is 633,806,848 bytes, the executor 59,148,672 bytes, and the two read files 1,674,916 and 1,813,908 bytes. `sample.sub` asks for 4 CPUs, the **Threads per job** value, and 12,288 MB of memory, which is the 4 GB clumpify heap plus the 8 GB margin. `run.dag` asks for 9 GB of disk for the sample, a size the plan works out from the size of its reads, and a `request_disk` column in a sample sheet replaces it.

`hg002-chr20/plan.json` names the three steps by title. They are Store reads with `clumpify.sh` 40.02, Compute statistics with `seqkit` 2.13.0, and Count Q20 and Q30 bases, which the executor does itself. Its storage settings name `bgzip` at compression level 4, quality binning in steps of five, 4 threads, and the 4 GB heap.

### The returned folder and its run record

`returned/hg002-chr20-plan/hg002-chr20/` holds the plan's files plus `run-record.json` and `out/sample.fastq.gz`, a file of 1,453,947 bytes. The record's outcome is `succeeded`, its three steps all succeeded, and the run took 17 seconds.

The storage step read 20,000 reads and wrote 20,000 reads, the 10,000 [read pairs](../../GLOSSARY.md#read-pair) written as one [interleaved](../../GLOSSARY.md#interleaved-fastq) file, so clumpify reordered the reads and dropped none. Its log shows 5,327 clumps, sets of reads that share sequence, made in one group, which means clumpify sorted the whole sample at once. It needed only one group because its memory estimate of 133 MB fit within the 3,319 MB it had available, and a larger sample would have been split into more groups.

The statistics step counted 4,965,573 bases. The quality count then found 4,722,951 of those bases at Q20 or better and 4,575,212 at Q30 or better, which are 95.1 and 92.1 percent. Q20 is a [Phred score](../../GLOSSARY.md#phred-score) of 20, one wrong base in a hundred, and Q30 means one in a thousand.

### The adopted bundle and its Runtime section

Select the adopted bundle and click the **Provenance** tab of the [Inspector](../../GLOSSARY.md#inspector), as [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#procedure) shows. **Run Summary** shows **Wall Time (Linux run)**, the [wall time](../../GLOSSARY.md#wall-time) of the run on Linux, about 17 seconds for the fixture, in place of the moment the Mac took to write the record.

<!-- SHOT: adopted-run-runtime -->

**Runtime** adds **Steps ran on**, with the Linux kernel and processor type, **Steps ran with**, with the executor's build and checksum, and **Leftover processes**, which says what happened to any [process](../../GLOSSARY.md#process) a tool left running. Under **Reported by the launcher** come the facts the launcher passed in, which LGE shows as given and does not check. For the fixture they include the machine name `lge-linux`, the container runtime Docker, and the launcher `run-local.sh/1`. [Reading the results](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) in Provenance and Reproducibility explains every block of the [run record](../../GLOSSARY.md#run-record).

## What good looks like

A good run ends cleanly on the Linux side. `run-local.sh` prints a last line that begins `run-local.sh: every sample finished or was skipped.` and ends with exit status 0. On a pool, `run.dag.status` shows every sample done and the `condor_q -hold` line prints nothing.

The copy home leaves every sample's folder on the Mac with `plan.json`, `run-record.json`, and the reads under `out/`, and no `result/` folder. The adopt's row ends `Imported` with the bundle's name, or with a count of samples that equals the number of rows in `jobs.tsv` other than the header.

The run record says `succeeded` for the run and for every step. Its storage step reads as many reads in as out, 20,000 and 20,000 for the fixture, unless Trim Galore or a recipe removed some on purpose. In the bundle's Provenance tab, **Wall Time (Linux run)** shows the run's own time and **Steps ran on** names a Linux kernel.

### When the run or the adopt fails

The adopt checks every sample before it writes anything, and a batch is adopted whole. When any sample is refused, nothing is imported, and each refused sample is listed by name. These are four of the lines you may meet:

```text
<sample>: its job returned nothing. The folder holds no run-record.json.
<sample>: its job returned no reads. The payload <path> is missing from the folder.
<sample>: The job's files are in the folder result. Copy everything inside result into the folder <sample>, next to plan.json.
<sample>: The project already holds the bundle <bundle>.
```

The first means a job that was held or removed, or a copy that was never made, so go back to [Release a held HTCondor job](#release-a-held-htcondor-job) or to the copy. The second means the reads did not come home, so copy them again. The third means the copy put the `result/` folder itself into the sample's folder, so copy what is inside it instead. The fourth means the project already holds a bundle with that sample's name, so delete that bundle from the project and adopt the batch again.

When an adopt stops partway, because the disk filled or you clicked Cancel, the bundles it already made stay whole and the message names them. Delete them from the project and adopt the batch again.

On the Linux side, `run-local.sh` with exit status 1 means at least one sample did not finish. Read that sample's `logs/<sample>.err` and its step logs, then run the script again, since it reruns only the samples with no `result/` folder. Exit status 2 means it refused before any sample started, for example because a Docker run was given no `--image` or an Apptainer image's checksum is not the plan's, and the message says which.

## On the command line

The flags of `import fastq` are listed under [Importing into a project](../appendices/cli-reference.md#importing-into-a-project) in the CLI Reference. This block writes the fixture's plan on the Mac, runs it on one Linux machine with Apptainer, copies the results home, and adopts them. `PROJECT` is a project you made in LGE with **File > New Project**, `FIXTURE` is where you saved the fixture folder, and each placeholder in angle brackets stands for your own staging folder, data folder, host, and plan folder.

```bash
PROJECT="$HOME/Documents/Linux Runs.lungfish"
FIXTURE="$HOME/Downloads/linux-plan-fastq"

# On the Mac, write the plan beside the fixture's folders.
cd "$FIXTURE"
lungfish-cli import fastq reads/hg002-chr20_R1.fastq.gz reads/hg002-chr20_R2.fastq.gz \
  --write-plan hg002-chr20-plan --staging-folder "<staging folder>" \
  --platform illumina --threads 4 --clumpify-heap-gb 4

# On the Linux machine, inside the copied plan folder, once the files are staged.
sh run-local.sh --runtime apptainer --data "<data folder>"

# On the Mac again, copy each sample's result/ next to its plan.json, then adopt the batch.
for sample in $(grep -v '^#' hg002-chr20-plan/jobs.tsv | cut -f 1); do rsync -a "<host>:<plan folder on the Linux machine>"/"$sample"/result/ hg002-chr20-plan/"$sample"/; done
lungfish-cli import fastq hg002-chr20-plan --adopt --project "$PROJECT"
```

For the fixture the adopt prints `Adopted hg002-chr20 as hg002-chr20.lungfishfastq`, then `Adopted    : 1` and `Not adopted: 0`.

## Next

The next part, [What Is MHC Genotyping](../09-genotyping/01-what-is-mhc-genotyping.md), moves from where LGE runs a step to a study it supports from start to finish, calling the MHC alleles of macaques from amplicon reads.

The RNA-seq cards use the route this chapter describes. [Plan salmon or STAR counting for a Linux machine](../11-rna-seq/02-counting-bulk-reads.md#plan-salmon-or-star-counting-for-a-linux-machine) and [Plan a STARsolo count for a Linux machine](../11-rna-seq/04-single-cell-counts.md#plan-a-starsolo-count-for-a-linux-machine) give their own settings. To read the adopted bundle's reads, see [Quality Control for Reads](../03-reads/03-quality-control.md), and to read every block of its record, see [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md).
