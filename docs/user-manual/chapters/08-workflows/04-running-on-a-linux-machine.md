---
title: Running on a Linux Machine
chapter_id: 08-workflows/04-running-on-a-linux-machine
audience: analyst
prereqs: [03-reads/01-importing-fastq, 01-foundations/08-provenance-and-reproducibility]
estimated_reading_min: 23
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
glossary_refs: [linux, plan-folder, staging-folder, staged-reads, adopt, htcondor, held-job, apptainer, ssh, container, docker, checksum, fastq, read, read-pair, interleaved-fastq, phred-score, clumpify, read-clumping, quality-binning, adapter, sample-sheet, tsv, json, terminal, shell, thread, process, exit-status, absolute-path, bundle, project, import-center, operations-panel, inspector, provenance, run-record, wall-time, fixture, bgzip]
features_refs: [import.fastq-linux-plan, import.rnaseq-plan, import.rnaseq-adopt, provenance.inspector]
fixtures_refs: [linux-plan-fastq, hg002-chr20]
brand_reviewed: false
lead_approved: false
---

<!-- SCOPE: Writing a plan folder for a Linux machine or an HTCondor pool, running it there, and adopting the returned run into the project. -->

## What it is

Reordering and compressing large sequencing files can take hours. Lungfish Genome Explorer (LGE) can do this work on a shared [Linux](../../GLOSSARY.md#linux) computer to keep your Mac free. Linux is an operating system like macOS or Windows. A [read](../../GLOSSARY.md#read) is a sequence of bases reported by a sequencing instrument. A [FASTQ](../../GLOSSARY.md#fastq) file stores each read's sequence and a quality score for each base.

LGE writes the instructions on the Mac, the Linux machine runs them, and LGE checks the returned files. The storage step can use BBTools [clumpify](../../GLOSSARY.md#clumpify) to group similar reads, a step called [read clumping](../../GLOSSARY.md#read-clumping). Similar reads give the compressor repeated sequences it can store more compactly.

A [Phred score](../../GLOSSARY.md#phred-score) expresses the estimated chance that a base was read incorrectly. SeqKit counts reads and bases, and LGE counts bases at or above each score below.

| Phred score | Estimated chance the base is wrong |
|---|---|
| 20 | About one in a hundred |
| 30 | About one in a thousand |

The RNA-seq and single-cell plan cards send counting work along the same route. [Counting Bulk RNA-seq Reads](../11-rna-seq/02-counting-bulk-reads.md) and [Single-Cell RNA-seq Counts](../11-rna-seq/04-single-cell-counts.md) give their own settings.

### Plan folders, staging folders, and staged reads

A [plan folder](../../GLOSSARY.md#plan-folder) holds instructions for the batch, or set of samples. Each sample has a folder with its plan and a packed copy, `plan.tar`. The plan fixes the settings and records each tool's version and build. It also records each file's size and [checksum](../../GLOSSARY.md#checksum), so jobs can check that they have the expected inputs. A checksum is a fingerprint of the file's bytes, here computed with SHA-256. Writing a plan imports and submits nothing.

The steps run in a [container](../../GLOSSARY.md#container), a package of programs and what they need to run. Its image is the file that stores those programs, about 634 MB for this plan. The app includes `lungfish-executor`, the Linux program that checks the size and checksum of each input before running any tool. After the steps end, it writes the [run record](../../GLOSSARY.md#run-record), `run-record.json`, which lists the steps, tool versions, file checksums, and how long each step took.

The [staging folder](../../GLOSSARY.md#staging-folder) is where jobs on Linux get their inputs. The plan's `staging-files.json` lists the inputs and where they go.

| File | Location within the staging folder |
|---|---|
| Tool image | `images/` for Apptainer or HTCondor |
| Executor | `shared/`, under a name that begins with the checksum |
| Sample reads to copy | `batches/<plan folder>/<sample>/` |

[Staged reads](../../GLOSSARY.md#staged-reads) are already in the staging folder. The plan names their paths, sizes, and checksums, so the Mac leaves them in place.

Each sample returns a `result/` folder. For HTCondor, look under `batches/<plan folder>/<sample>/` in the staging folder. For `run-local.sh`, look in the sample's folder in the copied plan folder.

To [adopt](../../GLOSSARY.md#adopt) a run is to import it into an LGE [project](../../GLOSSARY.md#project), which holds your imported data. LGE reads the Mac's plan and checks each returned read file's size and checksum against the run record before writing one FASTQ [bundle](../../GLOSSARY.md#bundle) per sample. The bundle holds the sample's reads and its [provenance](../../GLOSSARY.md#provenance), the record of how they were processed.

### One Linux machine or an HTCondor pool

A launcher starts jobs on Linux. On one machine, `run-local.sh` uses [Apptainer](../../GLOSSARY.md#apptainer) or [Docker](../../GLOSSARY.md#docker). Both run containers. Apptainer runs the image file as an ordinary user. Docker uses a converted image.

[HTCondor](../../GLOSSARY.md#htcondor) is a scheduler that shares a group of computers, called a pool, among users. It uses `run.dag` and `sample.sub` to find an eligible machine for each sample's job. Both launchers use the same sample plans.

## Why you would do this

A whole human genome sequenced for variant calling can yield hundreds of millions of read pairs. A [read pair](../../GLOSSARY.md#read-pair) consists of two reads from opposite ends of one DNA fragment. While clumpify runs, a Mac import needs free disk space of about five times the size of the sample's read files. Use a Linux machine for space or time, or a pool to process many samples across machines.

The [fixture](../../GLOSSARY.md#fixture) is a practice data set with 10,000 read pairs from 500 kb of human chromosome 20 in HG002, the Genome in a Bottle reference sample. Its adopted bundle shows that clumpify 40.02 reordered the reads on Linux and how long it took. For full-size runs, use the same procedure and check the disk request and [Settings](#settings) before submitting.

## Choosing a tool

Choose where the plan runs based on sample size, batch size, available disk space, and which computers you can use.

**Import on the Mac.** The Sequencing Read Files card runs the storage step and makes the bundle without a transfer. While clumpify runs, the Mac needs free disk space of about five times the size of the sample's read files. [Importing Sequencing Reads](../03-reads/01-importing-fastq.md) covers this route.

**`run-local.sh` with Apptainer.** The launcher runs the image file directly on one Linux machine. It refuses the file if its checksum differs from the plan's.

**`run-local.sh` with Docker.** Docker needs a linux/amd64 image converted from the tool image file. LGE's repository script, [`scripts/linux/launcher-tier.sh`](https://github.com/dhoconno/lungfish-genome-explorer/blob/main/scripts/linux/launcher-tier.sh), does this with its `image` command. It names the image `lge-tools:` plus the first 12 characters of the file's checksum. Pass that name to `run-local.sh` after `--image`. LGE does not convert the file.

**`run.dag` on an HTCondor pool.** HTCondor assigns one job per sample to available machines, with a default limit of 10 jobs at once, and holds jobs that fail to fetch or return files so you can decide what happens next. A requirements expression is a test of which machines can run a job. The default checks for `HasCHTCStaging`. The pool used to test LGE is known to set it. Before writing a plan for another pool, ask its administrator whether the machines set it. If they do not, use the expression the administrator gives you with `--job-requirements '<expression>'`. This replaces the entire requirements line in `sample.sub`.

| Tool | Built for | Choose it when | Choose something else when |
|---|---|---|---|
| Import on the Mac | A few samples on one Mac | The Mac has the space and time | You need Linux resources |
| `run-local.sh` with Apptainer | One Linux machine | Apptainer is available | You have many samples and a pool |
| `run-local.sh` with Docker | One machine with Docker | Docker is available | Apptainer can run the image file directly |
| `run.dag` on HTCondor | A shared pool | You have many samples and a pool login | You have one machine |

The fixture was a test on one Mac using `run-local.sh` with Docker. A Linux container stood in for a Linux machine and appears as `lge-linux` in the run record. Choose Apptainer if you have your own Linux server, or HTCondor if you have access to a pool. You can adopt the supplied results to practice. The Tool Bibliography lists BBTools clumpify and SeqKit under [Tools installed with every copy of LGE](../appendices/bibliography.md#tools-installed-with-every-copy-of-lge), with citations for both.

## Before you start

Use an LGE build with the Linux executor. Release builds include it. Without it, **Write Plan…** stays greyed out and the sheet explains why. You can write a plan without a project, but you need a project to adopt the run. [The Lungfish Genome Explorer Project](../01-foundations/06-the-lungfish-project.md#procedure) shows how to make one.

On Linux you need:

- A login to the machine you will use or to the pool's submit machine. Open [Terminal](../../GLOSSARY.md#terminal) from Applications > Utilities to type commands. For [SSH](../../GLOSSARY.md#ssh), a secure remote login, type `ssh <host>` with `<user name>@<machine name>` in place of `<host>` and press Return.
- An x86-64 Linux machine with Apptainer or Docker, or an HTCondor pool of x86-64 machines that run EL9 or later. EL9 is version 9 of Enterprise Linux, a family that includes Red Hat Enterprise Linux and Rocky Linux. The term x86-64 names a common server processor design. On that machine, `uname -m` prints `x86_64`. Use `apptainer --version`, `docker --version`, or `condor_version` to check which program is installed.
- A staging folder that every machine running jobs can read, with space for inputs and results.
- The tool image `lge-tools-<id>.sif` named in `staging-files.json`. LGE does not include or download it. Ask the person who looks after your Linux machine or pool for the file.

The `linux-plan-fastq` fixture comes from the [linux-plan-fastq fixture folder](https://github.com/dhoconno/lungfish-genome-explorer/tree/main/docs/user-manual/fixtures/linux-plan-fastq). Its README gives its source, license, and citation. To get it, choose **Code** and then **Download ZIP** on the repository page, then open the fixture's folder.

| Fixture contents | Use |
|---|---|
| `reads/` | The two read files |
| `plan/hg002-chr20-plan/` | Example plan with paths from the Mac that wrote it |
| `returned/hg002-chr20-plan/` | Supplied results you can adopt |
| `run-logs/` | Messages from the run |

Write your own plan with your staging folder before running the fixture. To practice without Linux, go straight to [Adopt the returned run with the Linux Run Result card](#adopt-the-returned-run-with-the-linux-run-result-card) and select `returned/hg002-chr20-plan`.

The fixture took 17 seconds to run. With the image in place, you transfer about 63 MB to Linux and 1.5 MB back. Most of the first transfer is the executor, which stays in `shared/` for later plans.

## Procedure

### Write a plan folder with the Plan for a Linux Machine card

1. Choose **File > Import Center…** (Cmd-Shift-I) and click the **Sequencing Reads** tab. [The Import Center](../01-foundations/06-the-lungfish-project.md#the-import-center) shows where to find it.

2. Click **Plan for a Linux Machine**. Select the fixture's `reads` folder and click **Open**. You can select read files or one folder of them. After you click **Open**, the Import Center closes.

3. Check that the **Plan for a Linux Machine** sheet shows `Reads: reads`. In **Staging folder**, enter the Linux folder's [absolute path](../../GLOSSARY.md#absolute-path), its full path from `/`. To find it, log in, use `cd <folder>` to change folders, and type `pwd` to show the current path. Use only letters, digits, `_`, `.`, and `-` in folder names.

    <!-- SHOT: linux-plan-sheet -->

4. Type `4` into **Threads per job** and `4` into **Clumpify memory (GB)** to match the fixture's plan. Leave **Optimize storage (reorder reads for better compression)** ticked and **Compression Tool** on BBTools clumpify. [Settings](#settings) explains each control.

5. Click **Write Plan…**. In the panel that slides down, which reads "Name a new folder for the plan. Nothing is imported and nothing is submitted.", type `hg002-chr20-plan`, choose a folder on the Mac, and click **Write Plan**. The plan folder's name follows the same rule.

The [Operations Panel](../01-foundations/06-the-lungfish-project.md#the-operations-panel) reports progress. It shows `Plan for a Linux Machine: hg002-chr20-plan` while LGE writes, then `Plan written to hg002-chr20-plan`. Open `README.txt` in TextEdit for commands filled in with your plan name and staging folder. [The plan folder and its README](#the-plan-folder-and-its-readme) describes the files LGE writes.

### Plan reads that are already on the Linux machine

If your FASTQ files are already staged on Linux, you can skip copying the reads from the Mac. Write the plan in Terminal with `lungfish-cli`, the LGE command-line program. The plan card does not accept staged FASTQ files. [Finding the program](../appendices/cli-reference.md#finding-the-program) shows how to start it.

1. In the Linux SSH window, replace `/absolute/folder` with the absolute path to the reads in the staging folder. The commands write `staged-reads.tsv` to your current folder, with a path, size in bytes, and checksum for each `*.fastq.gz` file. A [TSV](../../GLOSSARY.md#tsv) is a text file with columns separated by tabs. Note the folder path with `pwd` after running these lines:

    ```sh
    printf 'file\tbytes\tsha256\n' > staged-reads.tsv
    for f in /absolute/folder/*.fastq.gz; do
      printf '%s\t%s\t%s\n' "$f" "$(stat -L -c %s "$f")" "$(sha256sum "$f" | cut -d ' ' -f 1)" >> staged-reads.tsv
    done
    ```

2. In local Terminal on the Mac, run `scp <host>:<folder you were in>/staged-reads.tsv .` to copy the file to your current folder. Beside it, save a [sample sheet](../../GLOSSARY.md#sample-sheet) as `samples.csv`, with `sample,r1,r2` on the first line. Each later line lists a sample and the absolute Linux paths to its two FASTQ files, such as `S1,/absolute/folder/S1_R1.fastq.gz,/absolute/folder/S1_R2.fastq.gz`. Save it from a spreadsheet as CSV, a text file with comma-separated columns. The optional `request_disk` column gives the disk request in whole GB.

3. Write the plan on the Mac. LGE does not open staged reads, so name the sequencing technology with `--platform`. Use `--platform illumina` for the Illumina files in this example:

    ```sh
    lungfish-cli import fastq --samplesheet samples.csv --staged-reads staged-reads.tsv \
      --platform illumina --write-plan "<plan folder>" --staging-folder "<staging folder>" \
      --threads 8 --clumpify-heap-gb 16
    ```

Before submitting, follow the README's check. Each read file must match the listed size in `staging-files.json` and stay at its `stagingPath` until the jobs finish. A missing file holds its job before it can record a run.

### Copy the plan folder and stage the reads

1. Open `staging-files.json` in TextEdit to find where the jobs expect their inputs. With `scp` or `rsync`, copy each Mac file listed as a `source` to its `stagingPath` over SSH. For the fixture, copy the executor (about 59 MB) and both read files. Run `ssh <host> mkdir -p <folder of the stagingPath>` with the destination folder only. Run `scp "<source>" <host>:<stagingPath>` with the full path, including the file name.

2. Leave a file in `shared/` in place if it has the listed size. Another plan may be using it. Its name starts with the expected checksum, and `lungfish-executor` checks the file before running any tool.

3. For Apptainer or HTCondor, run `ls <staging folder>/images/` on Linux and check for the file whose `role` is `image`. For Docker, use the conversion in [Choosing a tool](#choosing-a-tool) to prepare the image.

4. Copy the whole plan folder to the Linux machine that runs it, or to the pool's submit machine, with `scp -r "<plan folder>" <host>:`.

For `run-local.sh`, either use the staging folder as `<data folder>` or recreate its layout in a data folder you choose. For example, `<staging folder>/shared/<name>` becomes `<data folder>/shared/<name>`. Keep `shared/` and `batches/hg002-chr20-plan/` in the layout. Add `images/` for Apptainer. Reuse files already at their listed paths and transfer any missing files. Copy the plan folder as in step 4.

### Run the plan on one Linux machine with run-local.sh

1. Log in with SSH and enter the copied plan folder with `cd <plan folder>`. If you need to disconnect during a long run, start `tmux` or `screen` before launching. These programs keep the terminal session running after you log out.

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

Use `--jobs <n>` to change the limit of 10 samples at once, `--sample <name>` to run one sample, or `--scratch <folder>` to move each sample's work folder.

Each sample writes its record, reports, and reads to `<sample>/result/` and step logs to `<sample>/logs/`. The job writes messages to `logs/<sample>.out` and `logs/<sample>.err`. The launcher skips samples with an existing `result/` folder.

Right after the script finishes, type `echo $?` to see its [exit status](../../GLOSSARY.md#exit-status), the number it returns on completion.

| Exit status | Meaning |
|---|---|
| 0 | Every sample finished or was skipped |
| 1 | At least one sample did not finish |
| 2 | The script refused before any sample started |

### Submit the plan to an HTCondor pool

1. Log in to the pool's submit machine with SSH and change to the copied plan folder with `cd <plan folder>`.

2. Submit the batch so HTCondor can assign each sample to an eligible machine:

    ```sh
    condor_submit_dag run.dag
    ```

3. Type `cat run.dag.status` in the plan folder to check progress. HTCondor updates the file about once a minute and calls each sample a node. Compare `NodesDone` with `NodesTotal`. A finished sample shows `NodeStatus = 5`.

You can log out after submitting while HTCondor keeps running. To check progress later, return to the plan folder on the submit machine and type `cat run.dag.status`. To change the limit of 10 jobs at once, edit `MAXJOBS lge 10` in `run.dag` on the Mac before copying the plan. Each job requests CPUs and memory from `sample.sub` and disk from `run.dag`. Look for results in `batches/hg002-chr20-plan/<sample>/result/` in the staging folder and step logs in `<sample>/logs/` in the plan folder.

### Release a held HTCondor job

A [held job](../../GLOSSARY.md#held-job) is a job HTCondor stopped. The batch waits until the hold is resolved.

1. See which sample is held, and why:

    ```sh
    condor_q -hold -af ClusterId ProcId DAGNodeName ExitCode HoldReasonCode NumHolds HoldReason
    ```

    `DAGNodeName` names the sample and `HoldReason` explains the hold. Use `ClusterId` and `ProcId` in the commands below. `ExitCode` reports how the run ended, `HoldReasonCode` gives the hold code, and `NumHolds` counts holds. In `logs/<sample>.log`, "Job was evicted" means HTCondor took the job off its machine. When "Job was held" follows, the two lines describe one hold.

2. Let HTCondor try to release holds that match the table. The plan allows at most two automatic releases for these holds.

    | Hold code | Exit code | What happened |
    |---|---|---|
    | 12 | 0 | The run finished, but the job could not send its files back |
    | 13 | undefined | The job could not fetch an input and never ran |

3. A job held a third time stays held. If the transfer made no progress, wait until the staging folder is accessible before releasing the job:

    ```sh
    condor_release <ClusterId>.<ProcId>
    ```

4. For other holds, fix the cause, such as a missing file at its `stagingPath`. If a run record exists, save it with `cp` before the next run replaces it. Then use `condor_rm` so HTCondor marks the sample failed and continues with the others:

    ```sh
    cp "<staging folder>/batches/hg002-chr20-plan/<sample>/result/run-record.json" "<sample>/run-record-<ClusterId>.json"
    condor_rm <ClusterId>.<ProcId>
    ```

5. Once the other samples finish, `run.dag.rescue001` lists the samples still to run. Run `condor_submit_dag run.dag` again from the plan folder to run just those samples.

A hold whose reason says an output file could not be sent back means that sample's job returned no reads. Check the staging folder for its record and `<sample>/logs/` for step logs. An executor refusal before the first step, such as a size or checksum mismatch, leaves only the record. A refusal by `lge-job.sh`, such as a missing `plan.tar`, leaves no record. Check `logs/<sample>.err` for that failure.

### Copy the returned run back to the Mac

LGE needs each sample's returned files beside the original `plan.json` on the Mac. Copy the contents of each `result/` folder into the matching sample folder. Leave the original `plan.json` in place. Adoption does not use the logs.

Choose the value for `<source>` before running the copy.

| Where you ran the plan | Value for `<source>` |
|---|---|
| HTCondor | `<host>:<staging folder>/batches/hg002-chr20-plan` |
| `run-local.sh` | `<host>:` followed by the path to the copied plan folder |
| Results already on the Mac | Path to the folder holding the sample folders |

Use the same `<host>` you pass to `ssh`, such as `<user name>@<machine name>` or a short name from your SSH configuration file. If your connection needs `ssh -F <config file>` to read a different configuration file, run `export RSYNC_RSH='ssh -F <config file>'` before the loop.

1. In Terminal on the Mac, change to the folder that holds `hg002-chr20-plan`. Type `cd` and a space, drag that folder from Finder onto the Terminal window, and press Return.

2. Replace the full `<source>` placeholder with your value and run the README's copy loop. Keep the slash after `result` to copy the folder's contents:

    ```sh
    for sample in $(grep -v '^#' hg002-chr20-plan/jobs.tsv | cut -f 1); do rsync -a <source>/"$sample"/result/ hg002-chr20-plan/"$sample"/; done
    ```

3. Check that `hg002-chr20-plan/hg002-chr20/` now holds `run-record.json` and `out/sample.fastq.gz` beside `plan.json`, and no `result/` folder.

### Adopt the returned run with the Linux Run Result card

1. Open the [project](../../GLOSSARY.md#project) where you want the bundles. For practice, make an empty project with **File > New Project**.

2. Choose **File > Import Center…** (Cmd-Shift-I), click the **Sequencing Reads** tab, and click the **Linux Run Result** card.

    <!-- SHOT: linux-run-result-card -->

3. Select the Mac plan folder you copied results into, or `returned/hg002-chr20-plan` for the supplied run, and click **Open**. You can also select one sample's folder.

4. Watch `Linux Run Result: hg002-chr20-plan` in the Operations Panel. The fixture shows `Checking 1 of 1: hg002-chr20…`, then `Adopting 1 of 1: hg002-chr20…`, and ends with `Imported hg002-chr20.lungfishfastq`. A batch of three shows progress such as `Checking 2 of 3: <sample>…` and ends with `Imported 3 samples`.

5. Find the new bundle `hg002-chr20` under `Imports` in the sidebar.

With no project open, choosing a folder brings up "No Project Open". Adoption needs room for both the returned reads and the project copy unless both folders are on the same APFS volume, a disk or part of a disk in Apple's file system. On that volume the copies share space. Two folders in your home folder usually share a volume.

After import succeeds, you can delete the returned `<sample>/out/` on the Mac because the bundle holds the reads. If every sample passed, you can also remove the staging folder's `result/` folders.

## Settings

The Linux Run Result card has no settings because the plan fixes them. The sheet writes plans for short reads, a few hundred bases or fewer, as from Illumina instruments. It sets no recipe, a named set of steps such as removing duplicate reads. The command line takes `--platform`, `--recipe`, `--samplesheet`, `--staged-reads`, and `--job-requirements`.

[Quality binning](../../GLOSSARY.md#quality-binning) replaces nearby quality scores with one stored score to make them easier to compress. The plan stores quality scores in steps of five (`fiveStep`), the quality binning that `lungfish-cli import fastq --help` gives as the default of `--quality-binning`, so Q10, Q20, and Q30 counts stay as sequenced.

**Staging folder.** Sets the absolute Linux path that the plan uses for staging. The field starts empty so you can supply your own path, and **Write Plan…** stays greyed out until the path starts with `/`. Use the folder for the machine or pool running the job, and write a new plan if it moves. On the command line this is `--staging-folder`.

**Threads per job.** Sets how many [threads](../../GLOSSARY.md#thread), or parallel workers, process each sample and how many CPUs each HTCondor job requests. The default is 8, and a larger request can take longer to schedule because one machine needs that many free CPUs. Lower it for a smaller machine or raise it when a job has more cores available. On the command line this is `--threads`.

**Clumpify memory (GB).** Sets the Java heap, the working memory in GB for BBTools clumpify, with each HTCondor job requesting an extra 8 GB for Java and compression. The default is 16 GB, a 24 GB request in all, and clumpify splits samples into more groups if they cannot fit in the heap. Lower it when a machine has less memory available per job. On the command line this is `--clumpify-heap-gb`.

**Optimize storage (reorder reads for better compression).** Groups similar reads for better compression, changing their order. It opens ticked, and a moment later LGE reads the first read headers and clears it for Oxford Nanopore, PacBio, and Unknown reads, because clumpify works well only on accurate reads. Clear it if you need the original read order or tick it to reorder long reads. On the command line this is `--no-optimize-storage`.

**Compression Tool.** Offers BBTools clumpify and Trim Galore --clumpify and stays greyed out while the Optimize storage box is clear. The default is BBTools clumpify, which reorders reads without trimming or dropping them. To trim reads during storage, choose Trim Galore --clumpify, which removes [adapter](../../GLOSSARY.md#adapter) sequence added during library preparation, trims low-quality ends, and drops short reads. On the command line this is `--clumping-tool`.

## Reading the results

### The plan folder and its README

Open the plan's text files in TextEdit. The `plan.tar` archive packs files together for the job to unpack.

| File | What it holds |
|---|---|
| `README.txt` | The commands for both ways to run the batch, for a held job, and for bringing the results home, written with the plan's own staging folder, name, and numbers |
| `staging-files.json` | Every file the jobs read, with its size in bytes, its checksum, its `stagingPath`, and, for each file the Mac has to copy, its `source` on the Mac (the image and any staged read have none) |
| `run.dag` and `sample.sub` | The HTCondor batch, with one `JOB` line per sample in `run.dag` and the job description they share in `sample.sub` |
| `jobs.tsv` and `run-local.sh` | The one-machine route, with one row per sample in `jobs.tsv` and the launcher that reads it |
| `lge-job.sh` | The small script both routes run to unpack a sample's plan and start the executor |
| `logs/` | An empty folder when the plan is written, where each job's own output goes as `<sample>.out` and `<sample>.err`, and where HTCondor also writes `<sample>.log` |
| `<sample>/` | The sample's `plan.json`, the packed copy `plan.tar` that its job carries, and `staging.json`, which names the image and the files the job reads |

For the fixture, `sample.sub` requests 4 CPUs from **Threads per job** and 12,288 MB of memory, the 4 GB heap plus 8 GB. In `run.dag`, the disk request is 9 GB. The plan takes three times the size of the reads, here 3.5 MB in all, rounds it up to 1 GB, and adds 8 GB for the image and the work files. A `request_disk` column in the sample sheet overrides the estimate.

`hg002-chr20/plan.json` lists Store reads with `clumpify.sh` 40.02, Compute statistics with `seqkit` 2.13.0, and Count Q20 and Q30 bases with the executor. The storage settings use [`bgzip`](../../GLOSSARY.md#bgzip), a gzip-compatible compressor, at level 4, with quality binning in steps of five, 4 threads, and a 4 GB heap. Higher levels compress more slowly and make smaller files. The sheet uses the default level.

### The returned folder and its run record

`returned/hg002-chr20-plan/hg002-chr20/` holds the plan's files plus `run-record.json` and `out/sample.fastq.gz`, a file of 1,453,947 bytes. The record's outcome is `succeeded`, its three steps all succeeded, and the run took 17 seconds.

The storage step counted 20,000 reads in and 20,000 out. It wrote 10,000 read pairs to one [interleaved](../../GLOSSARY.md#interleaved-fastq) file. In an interleaved FASTQ file, the two reads in a pair sit next to each other.

In `run-logs/hg002-chr20/logs/`, open `storage.2.stderr` to see 5,327 clumps, or sets of reads that share sequence. Clumpify sorted them in one group because its estimate of 133 MB fit within the reported 3,319 MB available from the 4 GB heap. Larger samples can need more groups.

The statistics step counted 4,965,573 bases. Each percentage below uses that total. Bases counted at Q30 also count at Q20.

| Quality threshold | Bases at or above the threshold | Share of all bases |
|---|---|---|
| Q20 | 4,722,951 | 95.1% |
| Q30 | 4,575,212 | 92.1% |

As a rule of thumb for Illumina reads, a Q30 share above roughly 80 percent is healthy. For lower shares, [What good looks like](../03-reads/03-quality-control.md#what-good-looks-like) in Quality Control for Reads explains what to check.

### The adopted bundle and its Runtime section

To check where processing ran and how long it took, select the bundle and click **Provenance** in the [Inspector](../../GLOSSARY.md#inspector), the panel for the selected item's details. In **Run Summary**, **Wall Time (Linux run)** shows [wall time](../../GLOSSARY.md#wall-time), the elapsed time from start to finish, about 17 seconds for the fixture. Click the arrow by **Runtime** to open it. [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#procedure) shows how to find these details.

<!-- SHOT: adopted-run-runtime -->

**Runtime** shows where the steps ran, what ran them, and how the launcher reported the run.

| Row | What it shows |
|---|---|
| **Steps ran on** | The Linux kernel (the core of the operating system) and processor type |
| **Steps ran with** | The executor's build and checksum |
| **Leftover processes** | What happened to each [process](../../GLOSSARY.md#process), or running program, a tool left behind |
| **Reported by the launcher** | Details LGE displays as given, such as the machine name `lge-linux` |

[Reading the results](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) in Provenance and Reproducibility explains each block of the record.

## What good looks like

`run-local.sh` prints a last line that begins `run-local.sh: every sample finished or was skipped.` and returns exit status 0. On a pool, `NodesDone` in `run.dag.status` equals `NodesTotal` and `condor_q -hold` prints nothing.

Before copying, check that each sample's `run-record.json` says `succeeded` for the run and each step, including samples the launcher skipped. With BBTools clumpify and no recipe that removes reads, expect the same read count in and out, 20,000 and 20,000 for the fixture. If Trim Galore or a recipe removed reads, check that the drop fits the processing you chose.

After adoption, the Operations Panel ends with `Imported` and the bundle name or the sample count. Compare a batch count with the rows in `jobs.tsv`, excluding the header. In **Provenance**, check **Wall Time (Linux run)** for the run time and **Steps ran on** for the Linux kernel.

### When the run or adopting fails

LGE checks every sample before writing bundles. If any sample fails these checks, LGE lists each refused sample by name and imports nothing. Check the message:

```text
<sample>: its job returned nothing. The folder holds no run-record.json.
<sample>: its job returned no reads. The payload <path> is missing from the folder.
<sample>: The job's files are in the folder result. Copy everything inside result into the folder <sample>, next to plan.json.
<sample>: The project already holds the bundle <bundle>.
```

If the record is missing, check whether the job was held or removed, whether it stopped before starting the executor, or whether you copied the results. [Release a held HTCondor job](#release-a-held-htcondor-job) explains where to look for early failures. If the reads are missing only on the Mac, copy them again. If they are also missing on Linux, rerun the sample. If the files are still inside `result/` on the Mac, move its contents beside `plan.json`.

If the project already holds a bundle with that sample's name, LGE refuses the batch. If you can discard that bundle, delete it from the project and adopt the batch again.

If the disk fills or you click Cancel during adoption, completed bundles stay whole in the project. The message lists them. To retry the whole batch in that project, delete those completed bundles and adopt again.

For `run-local.sh` exit status 1, read the failed sample's `logs/<sample>.err` and step logs. Before retrying a failed sample, delete its `result/` folder if it exists, since the script skips it otherwise. For exit status 2, read the message explaining why the script stopped before starting any sample.

## On the command line

Run the block in sections. Write the plan in Terminal on the Mac and stage the files as in the Procedure. Run Apptainer in the Linux SSH window, then return to the Mac to copy and adopt. Set `PROJECT` to the folder for a project you made with **File > New Project** and `FIXTURE` to the downloaded fixture folder. Replace each angle-bracket placeholder with your own value.

To adopt the supplied result without Linux, run the `PROJECT` and `FIXTURE` assignments and `cd "$FIXTURE"` on the Mac. Then run the last command with `returned/hg002-chr20-plan` in place of `hg002-chr20-plan`.

`lungfish-cli import fastq --help` lists every flag of `import fastq`, including `--write-plan`, `--staging-folder`, `--staged-reads`, `--job-requirements`, and `--adopt`.

```bash
PROJECT="$HOME/Documents/Linux Runs.lungfish"
FIXTURE="$HOME/Downloads/linux-plan-fastq"
cd "$FIXTURE"

# On the Mac, write the plan beside the fixture's folders.
lungfish-cli import fastq reads/hg002-chr20_R1.fastq.gz reads/hg002-chr20_R2.fastq.gz \
  --write-plan hg002-chr20-plan --staging-folder "<staging folder>" \
  --platform illumina --threads 4 --clumpify-heap-gb 4

# Copy the plan folder and the files staging-files.json lists to the Linux machine, as the Procedure shows.

# In the SSH window on the Linux machine, inside the copied plan folder, once the files are staged.
sh run-local.sh --runtime apptainer --data "<data folder>"

# On the Mac again, copy each sample's result/ next to its plan.json, then adopt the batch.
for sample in $(grep -v '^#' hg002-chr20-plan/jobs.tsv | cut -f 1); do rsync -a "<host>:<plan folder on the Linux machine>"/"$sample"/result/ hg002-chr20-plan/"$sample"/; done
lungfish-cli import fastq hg002-chr20-plan --adopt --project "$PROJECT"
```

For the fixture the command prints `Adopted hg002-chr20 as hg002-chr20.lungfishfastq`, then `Adopted    : 1` and `Not adopted: 0`.

## Next

Continue with [What Is MHC Genotyping](../09-genotyping/01-what-is-mhc-genotyping.md) to see how LGE calls macaque MHC alleles from amplicon reads.

To plan RNA-seq counts for a Linux machine, see [Plan salmon or STAR counting for a Linux machine](../11-rna-seq/02-counting-bulk-reads.md#plan-salmon-or-star-counting-for-a-linux-machine) and [Plan a STARsolo count for a Linux machine](../11-rna-seq/04-single-cell-counts.md#plan-a-starsolo-count-for-a-linux-machine), which give their own settings. [Quality Control for Reads](../03-reads/03-quality-control.md) helps you inspect the adopted reads. [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md) explains the bundle's record.
