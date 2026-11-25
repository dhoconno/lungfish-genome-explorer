---
title: Running in CI
chapter_id: appendices/06-running-in-ci
audience: power-user
prereqs: [01-foundations/08-provenance-and-reproducibility, 08-workflows/03-running-external-workflows]
estimated_reading_min: 19
task: Run Lungfish Genome Explorer workflows on a continuous integration runner with no window, provision the tools the job needs, and keep the provenance as a build artifact.
tags: [ci, headless, github-actions, circleci, conda, provenance, time-limit]
tools: [nextflow, snakemake]
entry_points:
  - "CLI: lungfish-cli run-headless"
  - "CLI: lungfish-cli workflow run"
  - "CLI: lungfish-cli tools update"
shots: []
illustrations: []
glossary_refs: [cache, checksum, command-line-flag, conda, container, continuous-integration, dependency-set, docker, environment-variable, exit-status, glob, host-depletion, htcondor, kraken2, linux, nf-core, offline-pack, path, plan-folder, plugin-pack, provenance, provenance-sidecar, push, repository, required-setup-pack, run-bundle, runner, samplesheet, shell, symlink, terminal, tool-lock-manifest, wall-time, workflow-engine, yaml]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

[Continuous integration](../../GLOSSARY.md#continuous-integration), usually shortened to CI, is a service that runs a set of commands on a fresh machine every time someone sends a change, called a [push](../../GLOSSARY.md#push), to a shared [repository](../../GLOSSARY.md#repository), the folder of files a version-control system such as Git tracks. The machine is called a [runner](../../GLOSSARY.md#runner). The CI service creates it for the job, lets it run the commands, reports whether each one succeeded, and then throws it away. Nothing installed on a runner survives to the next job unless you save it on purpose, so a job that passes shows the work does not depend on one person's laptop.

Lungfish Genome Explorer (LGE) can take part, because its command-line program runs with no window at all. This appendix covers running that program unattended on a runner, putting the tools it needs on the runner, and keeping the [provenance](../../GLOSSARY.md#provenance) records as the job's saved output. Everything here is typed into the CI file or into [Terminal](../../GLOSSARY.md#terminal), which [Before you type anything](cli-reference.md#before-you-type-anything) introduces, and nothing opens the LGE window.

A runner still needs whatever the analysis needs. LGE installs each bioinformatics tool it wraps with [conda](../../GLOSSARY.md#conda), a package manager that puts every tool into its own folder, called an environment. The built-in [nf-core](../../GLOSSARY.md#nf-core) pipeline, [Viral Recon](../04-alignments/05-viral-recon-wizard.md), which analyzes SARS-CoV-2 amplicon reads, is different. It runs each of its steps inside a [container](../../GLOSSARY.md#container), and LGE runs those containers through [Docker](../../GLOSSARY.md#docker), so that route needs Docker running on the runner.

The two templates in this appendix are starting points to adapt. Every command in them was checked on its own, but no CI service ran either file, so expect to change the runner label, the `LUNGFISH` path, and the `pipeline.nf` and `outputs` paths before your first job passes. [Running External Workflows](../08-workflows/03-running-external-workflows.md) covers running the same workflows at a desk, meaning on your own Mac.

## Before you type anything

Everything on this page is typed. The `lungfish-cli` program ships inside LGE, and [Finding the program](cli-reference.md#finding-the-program) shows where it sits in the Stable and the Preview app, the two [release channels](../01-foundations/06-the-lungfish-project.md#release-channels).

A fresh runner holds no app, so a job must place it on the runner before its first `lungfish-cli` step, in `/Applications` for the path both templates use. Neither template below has that step, and [Getting LGE](../01-foundations/06-the-lungfish-project.md#getting-lge) and [Release channels](../01-foundations/06-the-lungfish-project.md#release-channels) say where the download comes from. A runner that only unpacked the application has no `lungfish-cli` on its [search path](../../GLOSSARY.md#path), the list of folders the [shell](../../GLOSSARY.md#shell) looks in for a program, so a step that types the bare name fails. A [symbolic link](../../GLOSSARY.md#symlink) to the program, a small file that points at it, makes the bare name work when you place the link in a folder already on the search path. The program follows the link back to its app, so it still finds that app's storage folder and its [tool lock manifest](../../GLOSSARY.md#tool-lock-manifest), the file that pins every tool version. Both templates below store the full quoted path once in a [variable](../../GLOSSARY.md#environment-variable) named `LUNGFISH` and write `"$LUNGFISH"` in every command. They name the Preview app, so change the path to `/Applications/Lungfish.app/Contents/MacOS/lungfish-cli` if the runner holds the Stable app. The examples in the body of this appendix use the bare name for readability.

## What a job needs installed

The runner must be an Apple Silicon Mac running macOS 26 or later, the same requirement as the app, because `lungfish-cli` is built for that system and will not start on an older one. On GitHub Actions the operating system is chosen by the runner label on the `runs-on:` line, and the label is `macos-26`. Check it against GitHub's [list of runner images](https://docs.github.com/en/actions/reference/runners/github-hosted-runners), since vendors rename labels. That list gives the standard `macos-26` runner 7 GB of memory, below the 16 GB the app asks for in [System requirements](../01-foundations/06-the-lungfish-project.md#system-requirements).

A step too large for a hosted runner, such as storing a whole genome's reads or counting RNA-seq reads, can run on a [Linux](../../GLOSSARY.md#linux) machine instead, Linux being the operating system most shared research computers run. LGE writes a [plan folder](../../GLOSSARY.md#plan-folder), a folder of plain files that one Linux machine or an [HTCondor](../../GLOSSARY.md#htcondor) pool of shared computers runs. LGE then checks each returned file before it imports the results into a project, as [Running on a Linux Machine](../08-workflows/04-running-on-a-linux-machine.md) shows.

A job that runs the nf-core Viral Recon pipeline also needs Docker running where the runner can reach it, because LGE runs that pipeline's containers through it, as [Tools that run in containers](../01-foundations/07-plugin-packs.md#tools-that-run-in-containers) explains. Hosted macOS runners often come without it, so check your service's runner image before you plan such a job, use a runner you manage yourself, which GitHub calls a self-hosted runner, or leave that pipeline out. A local `.nf` file (Nextflow) or Snakefile (Snakemake) needs Docker only if the workflow itself asks for containers.

A job then needs the tools its workflow calls. There are two ways to provide them.

### Install the tools and cache them

A [cache](../../GLOSSARY.md#cache) is a folder the CI service keeps between jobs so the next job skips the download. Installing is the route to try first, and the GitHub template installs fresh in every job. [Offline packs](#offline-packs) shows what is safe to cache.

`lungfish-cli tools update --plan` prints the work pending against the pinned [dependency set](../../GLOSSARY.md#dependency-set), the exact tool versions one LGE release was built and tested against. Its first line names the target set, and most later lines start with the action LGE would take, such as `install`, `reinstall`, or `preserve`. A `preserve` line means a tool you installed yourself is left alone. The last line gives the estimated download, or says `Nothing to do.` when no work is pending. It exits 10 when work is pending and 0 when there is none, so a CI step that fails on any nonzero [exit status](../../GLOSSARY.md#exit-status) turns it into a check that the runner matches the pinned set before any scientific work starts. `--json` gives the same plan as JSON.

To do the work, run `lungfish-cli tools update --apply --yes --required-only`. `--yes` is required because the command changes nothing without confirmation. `--required-only` installs only what LGE cannot run without, the [Required Setup pack](../../GLOSSARY.md#required-setup-pack) of about 2.7 GB, so the job then adds each [plugin pack](../../GLOSSARY.md#plugin-pack) it needs with `lungfish-cli conda install --pack <id>`, replacing `<id>` with the pack's id. [The packs, and what is in them](../01-foundations/07-plugin-packs.md#the-packs-and-what-is-in-them) lists each pack's id and tools, so look up each tool your workflow calls there, and a task chapter's Before you start names the pack its own tools need.

Databases are installed apart from packs. `lungfish-cli conda db download <name>` fetches a catalog database, such as `Viral` for the [Kraken 2](../../GLOSSARY.md#kraken2) classifier, and `lungfish-cli conda db list` prints the others. `lungfish-cli conda db install-managed <identifier>` fetches a managed database, such as `deacon-panhuman` for [host depletion](../../GLOSSARY.md#host-depletion), and `--list` prints the identifiers.

### Install from an offline pack

An [offline pack](../../GLOSSARY.md#offline-pack) is a copy of installed conda environments written to a folder or an archive file, so it can be moved to a machine with no network. [Offline packs](#offline-packs) below covers what matters on a runner.

### Check the runner first

Two quick commands turn a confusing mid-pipeline failure into a clear early one. `lungfish-cli debug env --check-tools` prints the runner's macOS version, core count, memory, and architecture, and reports each tool as available or not found on the shell's search path. It exits 0 either way, so it never stops a job. `lungfish-cli debug container` reports whether Docker can be reached, and exits with status 65 when it cannot, so a step that runs it fails the job before a Viral Recon run starts. A job that runs only local `.nf` files or Snakefiles without containers can leave it out.

## Running the workflow

Use `lungfish-cli run-headless <workflow>` in a CI script. Its help calls it a thin alias, a second name, for `workflow run --quiet`, so it accepts every [flag](../../GLOSSARY.md#command-line-flag) of `workflow run` after the workflow argument and prints only what a script needs.

A [workflow engine](../../GLOSSARY.md#workflow-engine) reads a description of an analysis, works out which step must run before which, and runs them in order. LGE drives Nextflow and Snakemake. The workflow argument must be one of these.

| Workflow argument | Engine |
|---|---|
| A file ending in a lower-case `.nf` | Nextflow |
| A file whose name contains `snakefile` in any letter case | Snakemake |
| `nf-core/viralrecon` or `viralrecon` | The built-in nf-core pipeline, which takes one `--input` [samplesheet](../../GLOSSARY.md#samplesheet), or one or more `--input` FASTQ bundles or files from which LGE builds the samplesheet |

Running a workflow file is covered in [Running External Workflows](../08-workflows/03-running-external-workflows.md), which also describes [what a workflow package holds](../08-workflows/03-running-external-workflows.md#what-a-workflow-package-holds). The example below is the Nextflow file inside `Examples/WorkflowPackages/hello-world-nextflow.lungfishflowpkg` in the LGE source repository on GitHub, which does almost no work. It is not installed with the app, and [Running External Workflows](../08-workflows/03-running-external-workflows.md#before-you-start) says where to get the repository.

```bash
lungfish-cli run-headless hello-world-nextflow.lungfishflowpkg/main.nf \
  --results-dir ./nf-results \
  --expected-output ./nf-results/hello-world-nextflow.lungfishref \
  --bundle-root ./bundles
```

`--results-dir` names where the pipeline writes. `--expected-output` names one finished output LGE must find and give a provenance record, and it is repeated once per scientific output. `--bundle-root` names the folder that receives the [run bundle](../../GLOSSARY.md#run-bundle), a `.lungfishrun` folder LGE writes before it starts the engine, recording the pipeline, the executor (how an nf-core run starts its tools), the inputs, every parameter, and the outputs that must receive provenance. The run exits 0 and prints one line, the path of that run bundle, which the same step can keep in a variable, as in `RUN_BUNDLE=$("$LUNGFISH" run-headless ...)`.

An executed run must name an output. Without `--expected-output` the command refuses with exit status 64 and says that every final scientific output needs a provenance record, and `--quiet` does not hide the refusal.

A run gets its data from `--input <path>`, repeated once per file or folder. A local workflow receives the paths as one parameter named `input`, joined by commas, and a path that does not exist ends the run with exit status 3. `--param name=value` adds any other parameter, and `--params-file <file>` loads them from a file read as JSON only, though its help says YAML too.

### Exit codes on a runner

A CI step fails when its command ends with any [exit status](../../GLOSSARY.md#exit-status) other than 0. [Exit status](cli-reference.md#exit-status) in the CLI Reference lists every value the program defines. These are the ones a CI job meets most often.

| Exit status | What it means for a job |
|---|---|
| 0 | The command succeeded. |
| 2 | A usage error, such as `tools update --apply` without `--yes`. Nothing ran. |
| 3 | An input error, such as a pack id that was not recognized. Nothing was installed. |
| 4 | An output error, including an expected output that was not created. |
| 10 | `tools update --plan` found pending work, which fails the step on purpose. |
| 64 | A workflow error, such as a missing `--expected-output`, an unrecognized option, or a failed workflow step. |
| 65 | `debug container` could not reach Docker. |
| 126 | A tool the command needs is missing, or an offline pack install failed. |
| 127 | The shell could not find `lungfish-cli` on its search path. |

`--expected-output` tells LGE where to look and does not make the pipeline write anything there. A path that does not match where the pipeline writes makes the command fail with exit status 4 and the message "Expected workflow output was not created", after the run bundle is written. Run the pipeline once at a desk with `--results-dir` set, list what appears with `ls -R`, and point `--expected-output` at that.

Four more flags of `workflow run` matter in CI.

- `--executor` applies to the nf-core run only. It reads `docker`, `conda`, or `local`, but the command refuses the last two, so only the default, `docker`, runs, as [`workflow run`](cli-reference.md#workflow-run) explains, and a runner without Docker cannot run that pipeline.
- `--dry-run` prints the workflow, results folder, executor, and parameters without running anything, and needs no expected output, so it is a fast way to see what a run would use, though it never opens a local workflow file and so does not show that the file runs.
- `--prepare-only` writes the run bundle and the command preview without starting the engine, and also needs no expected output.
- `--resume` continues from the engine's last checkpoint, so it helps only when the work folder, which `--workdir` names, survived in a cache, and not for a local Snakemake run.

### Time limits

No analysis step stops at a fixed time, so a step that never finishes runs until the CI service ends the job. Set the service's own limit, such as `timeout-minutes:` in the GitHub template. Leave `--timeout` off `workflow run`, because the nf-core run refuses it with exit status 3 and a local workflow ignores it.

To stop one command sooner, give it `--time-limit <minutes>`, which eight analysis commands take, among them `map`, `assemble`, and `kraken2 classify`, but not `workflow run` or `run-headless`. It stops any analysis step that runs longer than that many minutes, and the command then fails with a message saying the tool was stopped by its time limit. Each step gets the whole limit, so a command of several steps can run longer in total. [Global flags](cli-reference.md#global-flags) lists the eight.

### Where LGE keeps its tools

Two [environment variables](../../GLOSSARY.md#environment-variable), named values the shell hands to every program it starts, move LGE's storage off the home folder. `LUNGFISH_STORAGE_ROOT` sets the folder for everything LGE manages, including conda environments, databases, and tool installs. `LUNGFISH_CONDA_ROOT` sets the conda folder alone. With only `LUNGFISH_STORAGE_ROOT` set, the conda folder sits inside that storage folder. With both set, `LUNGFISH_CONDA_ROOT` wins for the conda folder, so set it too when you want the environments apart from everything else. Databases are the bulk of the space. In the Size column of `lungfish-cli conda db list`, the Kraken 2 Viral database is about 0.5 GB, Standard-8 is 8 GB, and Standard is 67 GB, and the RAM column gives the memory each needs.

```bash
export LUNGFISH_CONDA_ROOT="$RUNNER_TEMP/lungfish-conda"
```

`$RUNNER_TEMP` is a value GitHub Actions supplies, naming the runner's scratch folder. The CircleCI template below uses `/tmp` instead. A job that fetches records from NCBI should also set `NCBI_API_KEY`, stored in the CI service's secret store rather than in the workflow file, because unkeyed requests from a shared CI address run into NCBI's rate limit quickly.

Before a step parses a command's output as JSON, check that the command really prints JSON. Several accept `--format json` and print text, which is a known defect, listed with its workaround in [Known defects in this release](troubleshooting.md#known-defects-in-this-release).

## Offline packs

An offline pack suits a job with no network access, or one where a full install is too slow to repeat. [Install a pack without internet access](../01-foundations/07-plugin-packs.md#install-a-pack-without-internet-access) owns the route and names both spellings of each command, `conda export-pack` or `conda offline-export` to write the pack and `conda install --offline --from-bundle` or `conda offline-install` to install it. This section uses `offline-export` and `offline-install`. Build the pack on a machine that already has the pack [installed](../01-foundations/07-plugin-packs.md).

```bash
lungfish-cli conda offline-export \
  --pack metagenomics \
  --output .ci/lungfish-conda-packs
```

`--output` names the folder the pack is written into, not the pack itself, so the command above creates `.ci/lungfish-conda-packs/metagenomics-conda-offline-pack`. Inside it, `offline-pack-manifest.json` lists the pack id, the source conda folder, the exporting command, and a [checksum](../../GLOSSARY.md#checksum) and byte size for every exported file. A `.lungfish-provenance.json` in the same folder records the export.

Install the pack inside the job, pointing at the folder the export created.

```bash
lungfish-cli conda offline-install \
  .ci/lungfish-conda-packs/metagenomics-conda-offline-pack \
  --conda-root "$LUNGFISH_CONDA_ROOT" \
  --overwrite
```

`--overwrite` replaces environments that already exist. A job that restores a cached conda folder meets them at once, and without the flag its second run fails.

`offline-export` accepts the experimental packs, such as `gatk-core`, that `conda install --pack` refuses. An offline pack carries tools and not databases, so a classification job still downloads its database as shown above.

Do not cache a live conda folder that several jobs update. CI services run jobs of one workflow at the same time by default, and two jobs updating one conda folder at once can damage it in ways that are hard to see. An offline pack is a read-only copy with a manifest and a record, so it is the safer thing to move between machines.

## A GitHub Actions template

This file goes at `.github/workflows/lungfish-headless.yml` in your repository, and you create the `.github/workflows/` folder if it is missing. It is written in [YAML](../../GLOSSARY.md#yaml), a text format whose indentation shows which setting belongs inside which. Change the `LUNGFISH` path if the program sits elsewhere, the runner label if GitHub renamed it, and `pipeline.nf` and the `outputs` paths to match your repository. `pipeline.nf` stands for your own workflow file, such as one exported from a run you made in the app, as [Exporting as Nextflow or Snakemake](../08-workflows/02-exporting-as-nextflow-or-snakemake.md) shows. The `${{ }}` expressions are GitHub's own syntax, copied unchanged. The `on:` lines choose what starts the job. `pull_request` runs it when a proposed change is opened or updated, and `workflow_dispatch` adds a **Run workflow** button. For new data, use `push:` with a `paths:` list naming the data folder, or `schedule:` with a `cron:` line.

```yaml
name: lungfish-headless

on:
  pull_request:
  workflow_dispatch:

jobs:
  workflow:
    runs-on: macos-26
    timeout-minutes: 60
    env:
      LUNGFISH: "/Applications/Lungfish Preview.app/Contents/MacOS/lungfish-cli"
      LUNGFISH_CONDA_ROOT: ${{ runner.temp }}/lungfish-conda
      LUNGFISH_STORAGE_ROOT: ${{ runner.temp }}/lungfish-storage
      # NCBI_API_KEY: ${{ secrets.NCBI_API_KEY }}

    steps:
      - uses: actions/checkout@v4

      - name: Provision the required tools
        run: |
          "$LUNGFISH" tools update --apply --yes --required-only
          # An example. Use the pack your tools need.
          "$LUNGFISH" conda install --pack metagenomics
          # For example "$LUNGFISH" conda db download Viral

      - name: Assert the runner matches the pinned dependency set
        run: '"$LUNGFISH" tools update --plan'

      - name: Preflight
        run: '"$LUNGFISH" debug env --check-tools'

      - name: Run the workflow
        run: |
          "$LUNGFISH" run-headless pipeline.nf \
            --results-dir outputs \
            --expected-output outputs/result.lungfishref \
            --bundle-root outputs/bundles

      - name: Upload outputs and provenance
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: lungfish-outputs
          path: outputs/
```

`actions/checkout@v4` copies your repository onto the runner, and every job needs it first. The preflight step leaves out `debug container`, because `pipeline.nf` here runs without containers. Add it as a second line of that step for a job that runs the nf-core pipeline. The file has no cache step on purpose. Add caching once the job passes without it, following GitHub's cache documentation.

The `tools update --plan` step fails the job on exit 10, which is what makes it a check. The upload step carries `if: always()` so a failed run still keeps its logs and whatever provenance was written. An artifact is a file or folder a job saves to its run's page, and each run keeps its own until GitHub's retention period ends. It uploads the whole `outputs/` folder because a bundle's record is written inside the bundle, as [Keeping the provenance](#keeping-the-provenance) shows. The template sets 60 minutes, where GitHub's own default is 360, so time your own pipeline at a desk before you change it.

## A CircleCI template

CircleCI is another CI service. It picks the macOS version through an Xcode image, so choose a tag from CircleCI's [macOS image list](https://circleci.com/docs/guides/execute/using-macos/) whose macOS column reads 26 or later, and put it in place of `26.0.0`. This template installs from an offline pack, so commit the pack to `.ci/lungfish-conda-packs` in your repository before the first job. The cache steps then only save the time of copying a large pack out of the repository on later runs, and the job works without them. Because it installs the pack rather than running `tools update --apply`, the `--plan` step may find the required tools pending on a clean runner and fail the job with exit 10. If it does, add `tools update --apply --yes --required-only` before it, as the GitHub template does, which also installs Nextflow. CircleCI recommends a `workflows:` block, which this file leaves out, so add one that lists `lungfish-workflow`.

```yaml
version: 2.1

jobs:
  lungfish-workflow:
    macos:
      xcode: "26.0.0"
    environment:
      LUNGFISH: "/Applications/Lungfish Preview.app/Contents/MacOS/lungfish-cli"
      LUNGFISH_CONDA_ROOT: /tmp/lungfish-conda
      LUNGFISH_STORAGE_ROOT: /tmp/lungfish-storage
    steps:
      - checkout

      - restore_cache:
          keys:
            - lungfish-conda-packs-v1

      - run:
          name: Install the cached pack
          command: |
            "$LUNGFISH" conda offline-install \
              .ci/lungfish-conda-packs/metagenomics-conda-offline-pack \
              --conda-root "$LUNGFISH_CONDA_ROOT" \
              --overwrite

      - run:
          name: Assert the runner matches the pinned dependency set
          command: '"$LUNGFISH" tools update --plan'

      - run:
          name: Run the workflow
          command: |
            "$LUNGFISH" run-headless pipeline.nf \
              --results-dir outputs \
              --expected-output outputs/result.lungfishref \
              --bundle-root outputs/bundles

      - save_cache:
          key: lungfish-conda-packs-v1
          paths:
            - .ci/lungfish-conda-packs

      - store_artifacts:
          path: outputs
          destination: lungfish-outputs
```

## Keeping the provenance

LGE writes a [provenance](../../GLOSSARY.md#provenance) record beside every result file or inside every result bundle, holding the command, the tool version, and a checksum of each file, and [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read it. Keeping those records as saved job output is the reason to run LGE in CI rather than calling the tools by hand. The fields inside the sidecar are listed in [Provenance sidecars](file-formats.md#provenance-sidecars).

Where the [provenance sidecar](../../GLOSSARY.md#provenance-sidecar) lands depends on the output. For an expected output that is a bundle, such as the example's `.lungfishref`, the run's record is written inside the bundle.

```text
nf-results/
  hello-world-nextflow.lungfishref/
    .lungfish-provenance.json      <- the run's record, the one to check
    genome/
    manifest.json
    provenance/
      bundle.lungfish-provenance.json   <- the same run record, gathered per bundle
```

A step that looks for [`*.lungfish-provenance.json`](../../GLOSSARY.md#glob) files beside the output finds nothing, so upload the whole results folder, as both templates do, which also keeps the run bundles under `outputs/bundles`.

`lungfish-cli ops stats <folder>` walks a folder and counts the files named exactly `.lungfish-provenance.json`, printing how many it found, how many are completed runs, and their total [wall time](../../GLOSSARY.md#wall-time), then one row per operation. Peak RAM reads `unknown` for local workflow runs, which do not record it.

`lungfish-cli provenance verify` checks a signed record, and signing is off by default, so on an ordinary record it exits 3 and says the record carries no signature, which leaves nothing to verify. Signing starts when `LUNGFISH_PROVENANCE_SIGNING_KEY` holds a key, or `LUNGFISH_PROVENANCE_SIGNING_KEY_FILE` names its file, as [Signing a record](../01-foundations/08-provenance-and-reproducibility.md#signing-a-record) shows, so feed one from the service's secret store. Until you set up signing, check the record's `exitStatus` field, which is 0 for a run that worked. With the `jq` JSON reader that most runners carry, that is one line, and `-e` makes the step fail when the test is false.

```bash
jq -e '.exitStatus == 0' outputs/result.lungfishref/.lungfish-provenance.json
```

## What fails, and why

Seven failures account for most failed jobs.

| Symptom | Cause | Fix |
|---|---|---|
| The command is not found, exit 127 | The bare name `lungfish-cli` is not on the runner's search path. | Use the full quoted path, as both templates do. |
| Exit 64 saying an expected output is required | An executed run with no `--expected-output`. | Add one per scientific output, or use `--dry-run` or `--prepare-only` for a check. |
| Exit 4, "Expected workflow output was not created" | `--expected-output` does not match where the pipeline wrote. | Run once at a desk and point the flag at the real output. |
| Exit 3 with an unknown-pack error | The pack id is misspelled, or `conda install --pack` was given an experimental pack, which it refuses although `offline-export` accepts it. | Read the list the error prints. For an experimental pack, install it once at a desk as [Known defects in this release](troubleshooting.md#known-defects-in-this-release) shows, then move it with an [offline pack](#offline-packs). |
| Exit 65 from `debug container` | The runner has no Docker, or it is not running. | Use a runner with Docker for the nf-core pipeline, or drop that pipeline from the job. |
| A second cached run fails on existing environments | `conda offline-install` ran without `--overwrite`. | Add `--overwrite`. |
| The workflow file is not recognized | The file is named `pipeline.NF` rather than `pipeline.nf`. | Name pipeline files in lower case. |

[Troubleshooting](troubleshooting.md) lists other symptoms, and its known-defects list includes the command-line faults a script is most likely to meet.

## Next

The next appendix is [The AI Assistant](ai-assistant.md), which covers the Inspector's Assistant tab. See [CLI Reference](cli-reference.md) for every flag of the commands named here, and [Running External Workflows](../08-workflows/03-running-external-workflows.md) for running workflow files at a desk.
