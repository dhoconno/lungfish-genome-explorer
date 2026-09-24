---
title: Running in CI
chapter_id: appendices/06-running-in-ci
audience: power-user
prereqs: [01-foundations/08-provenance-and-reproducibility, 08-workflows/03-running-external-workflows]
estimated_reading_min: 18
task: Run Lungfish Genome Explorer workflows on a continuous integration runner with no window, provision the tools the job needs, and keep the provenance as a build artifact.
tags: [ci, headless, github-actions, circleci, conda, provenance]
tools: [nextflow, snakemake]
entry_points:
  - "CLI: lungfish-cli run-headless"
  - "CLI: lungfish-cli workflow run"
  - "CLI: lungfish-cli tools update"
shots: []
illustrations: []
glossary_refs: [cache, conda, container, continuous-integration, dependency-set, environment-variable, exit-status, host-depletion, kraken2, nf-core, offline-pack, plugin-pack, provenance, provenance-sidecar, run-bundle, runner, workflow-engine, yaml]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

[Continuous integration](../../GLOSSARY.md#continuous-integration), usually shortened to CI, is a service that runs a set of commands on a fresh machine every time someone sends a change to a shared repository, the folder of files a version-control system such as Git tracks. The machine is called a [runner](../../GLOSSARY.md#runner). The CI service creates it for the job, lets it run the commands, reports whether each one succeeded, and then throws it away. Nothing installed on a runner survives to the next job unless you save it on purpose, so a job that passes shows the work does not depend on one person's laptop.

Lungfish Genome Explorer (LGE) can take part, because its command-line program runs with no window at all. This appendix covers running that program unattended on a runner, putting the tools it needs on the runner, and keeping the [provenance](../../GLOSSARY.md#provenance) records as the job's saved output. Everything here is typed, and nothing opens the LGE window.

A runner still needs whatever the analysis needs. A local Nextflow `.nf` file or a Snakemake `Snakefile` runs its tools from [conda](../../GLOSSARY.md#conda), the package manager LGE uses to install each bioinformatics tool into its own folder, called an environment. Only the built-in [nf-core](../../GLOSSARY.md#nf-core) pipeline reads the `--executor` flag, and its default of `docker` makes a [container](../../GLOSSARY.md#container) runtime a requirement on that route.

The two templates in this appendix are starting points to adapt. Every command in them was checked on its own, but no CI service ran either file, so expect to change the runner label and the paths before your first job passes. [Running External Workflows](../08-workflows/03-running-external-workflows.md) covers the same commands at a desk.

## Before you type anything

This section is optional, and nothing later in this manual needs it. The `lungfish-cli` program ships inside LGE, and [Finding the program](cli-reference.md#finding-the-program) shows how to run it.

A runner that only unpacked the application has no `lungfish-cli` on its search path, so a step that types the bare name fails. Both templates below store the full quoted path once in a variable named `LUNGFISH` and write `"$LUNGFISH"` in every command. The examples in the body of this appendix use the bare name for readability.

## What a job needs installed

The runner must run macOS 26 or later, because LGE's container support is built on Apple Containerization, which arrives with macOS 26. On GitHub Actions the operating system is chosen by the runner label on the `runs-on:` line, and the label is `macos-26`. Check it against GitHub's published list of runner images, since vendors rename labels.

A job then needs the tools its workflow calls. There are two ways to provide them.

### Install the tools and cache them

A [cache](../../GLOSSARY.md#cache) is a folder the CI service keeps between jobs so the next job skips the download. Installing and caching is the route to try first.

`lungfish-cli tools update --plan` prints the work pending against the pinned [dependency set](../../GLOSSARY.md#dependency-set), the exact tool versions one LGE release was built and tested against. Its first line names the target set, and each later line starts with the action LGE would take, such as `reinstall` or `preserve`, which means a tool you installed yourself is left alone. It exits 10 when work is pending and 0 when there is none, so a CI step that fails on any nonzero [exit status](../../GLOSSARY.md#exit-status) turns it into a check that the runner matches the pinned set before any scientific work starts. `--json` gives the same plan as JSON.

To do the work, run `lungfish-cli tools update --apply --yes --required-only`. `--yes` is required because the command changes nothing without confirmation. `--required-only` installs only what LGE cannot run without, so the job then adds each [plugin pack](../../GLOSSARY.md#plugin-pack) it needs with `lungfish-cli conda install --pack <id>`, replacing `<id>` with the pack's id. The ids and what each pack holds are listed in [The packs, and what is in them](../01-foundations/07-plugin-packs.md#the-packs-and-what-is-in-them).

Databases are installed apart from packs. `lungfish-cli conda db download <name>` fetches a catalogue database, such as `Viral` for the [Kraken 2](../../GLOSSARY.md#kraken2) classifier, and `lungfish-cli conda db list` prints the others. `lungfish-cli conda db install-managed <identifier>` fetches a managed database, such as `deacon-panhuman` for [host depletion](../../GLOSSARY.md#host-depletion), and `--list` prints the identifiers.

### Install from an offline pack

An [offline pack](../../GLOSSARY.md#offline-pack) is a copy of installed conda environments written to a folder, so it can be moved to a machine with no network. [Offline packs](#offline-packs) below describes it.

### Check the runner first

Two quick commands turn a confusing mid-pipeline failure into a clear early one. `lungfish-cli debug env --check-tools` prints the runner's macOS version, core count, memory, and architecture, and reports each tool as available or not found. `lungfish-cli debug container` reports whether Apple Containerization is ready. Any status other than ready closes the container route on that runner, so switch the workflow to a local `.nf` file or to the conda executor.

## Running the workflow

Use `lungfish-cli run-headless <workflow>` in a CI script. Its help calls it a thin alias for `workflow run --quiet`, so it accepts every flag of `workflow run` after the workflow argument and prints only what a script needs.

A [workflow engine](../../GLOSSARY.md#workflow-engine) reads a description of an analysis, works out which step must run before which, and runs them in order. LGE drives Nextflow and Snakemake. The workflow argument must be one of these.

| Workflow argument | Engine |
|---|---|
| A file ending in a lower-case `.nf` | Nextflow |
| A file whose name contains `snakefile` in any letter case | Snakemake |
| `nf-core/viralrecon` or `viralrecon` | The built-in nf-core pipeline, which takes exactly one `--input` samplesheet |

Writing a workflow file is covered in [Running External Workflows](../08-workflows/03-running-external-workflows.md). The example below is the Nextflow file inside `Examples/WorkflowPackages/hello-world-nextflow.lungfishflowpkg` in the LGE source repository on GitHub, which does almost no work. It is not installed with the app.

```bash
lungfish-cli run-headless hello-world-nextflow.lungfishflowpkg/main.nf \
  --results-dir ./nf-results \
  --expected-output ./nf-results/hello-world-nextflow.lungfishref \
  --bundle-root ./bundles
```

`--results-dir` names where the pipeline writes. `--expected-output` names one finished output LGE must find and give a provenance record, and it is repeated once per scientific output. `--bundle-root` names the folder that receives the [run bundle](../../GLOSSARY.md#run-bundle), a `.lungfishrun` folder LGE writes before it starts the engine, recording the pipeline, the executor, the inputs, every parameter, and the outputs that must receive provenance. The run exits 0 and prints one line, the path of that run bundle, which a later step can capture.

An executed run must name an output. Without `--expected-output` the command refuses with exit status 64 and says that every final scientific output needs a provenance record, and `--quiet` does not hide the refusal.

| Exit status | What it means for a job |
|---|---|
| 0 | The command succeeded. |
| 2 | A usage error, such as `tools update --apply` without `--yes`. Nothing ran. |
| 3 | A pack id was not recognised. Nothing was installed. |
| 10 | `tools update --plan` found pending work, which fails the step on purpose. |
| 4 | An expected output was not created. |
| 64 | A workflow error, such as a missing `--expected-output`, an unrecognised option, or a failed workflow step. |

`--expected-output` tells LGE where to look and does not make the pipeline write anything there. A path that does not match where the pipeline writes makes the command fail with exit status 4 and the message "Expected workflow output was not created", after the run bundle is written. Run the pipeline once at a desk with `--results-dir` set, list what appears, and point `--expected-output` at that.

Four more flags of `workflow run` matter in CI.

- `--executor` picks `docker`, `conda`, or `local` for an nf-core run, defaulting to `docker`, so a runner with no container runtime sets `conda`.
- `--dry-run` prints the workflow, results folder, executor, and parameters without checking or running anything, and needs no expected output, which makes it a fast check on a proposed change.
- `--prepare-only` writes the run bundle and the command preview without starting the engine, and also needs no expected output.
- `--resume` continues from the engine's last checkpoint, so it helps only when the engine's work folder survived in a cache.

Leave `--timeout` alone and use the CI service's own limit instead, such as `timeout-minutes:` in the GitHub template.

### Where LGE keeps its tools

Two [environment variables](../../GLOSSARY.md#environment-variable), named values the shell hands to every program it starts, move LGE's storage off the home folder. `LUNGFISH_STORAGE_ROOT` sets the folder for everything LGE manages, including conda environments, databases, and tool installs. `LUNGFISH_CONDA_ROOT` sets the conda folder alone. With only `LUNGFISH_STORAGE_ROOT` set, the conda folder sits inside that storage folder. With both set, `LUNGFISH_CONDA_ROOT` wins for the conda folder, so set it too when you want the environments apart from everything else. Databases are the bulk of the space. The Kraken 2 Viral database is about 0.5 GB, but Standard-8 takes 8 GB and Standard takes 67 GB, as `lungfish-cli conda db list` shows.

```bash
export LUNGFISH_CONDA_ROOT="$RUNNER_TEMP/lungfish-conda"
```

`$RUNNER_TEMP` is a value GitHub Actions supplies, naming the runner's scratch folder. The CircleCI template below uses `/tmp` instead. A job that fetches records from NCBI should also set `NCBI_API_KEY`, stored in the CI service's secret store rather than in the workflow file, because unkeyed requests from a shared CI address run into NCBI's rate limit quickly.

Before a step parses a command's output as JSON, check that the command really prints JSON. Several accept `--format json` and print text, which is a known defect, listed with its workaround in [Known defects in this release](troubleshooting.md#known-defects-in-this-release).

## Offline packs

An offline pack suits a job with no network access, or one where a full install is too slow to repeat. Build it on a machine that already has the pack installed.

```bash
lungfish-cli conda offline-export \
  --pack metagenomics \
  --output .ci/lungfish-conda-packs
```

`--output` names the folder the pack is written into, not the pack itself, so the command above creates `.ci/lungfish-conda-packs/metagenomics-conda-offline-pack`. Inside it, `offline-pack-manifest.json` lists the pack id, the source conda folder, the exporting command, and a checksum and byte size for every exported file. A `.lungfish-provenance.json` beside it records the export. `lungfish-cli conda export-pack` does the same job and also accepts a `.tar`, `.tgz`, or `.tar.gz` path to write one archive file instead.

Install the pack inside the job, pointing at the folder the export created.

```bash
lungfish-cli conda offline-install \
  .ci/lungfish-conda-packs/metagenomics-conda-offline-pack \
  --conda-root "$LUNGFISH_CONDA_ROOT" \
  --overwrite
```

`--overwrite` replaces environments that already exist. A job that restored a cache meets them at once, and without the flag its second run fails.

`offline-export` accepts the experimental packs, such as `gatk-core`, that `conda install --pack` refuses. An offline pack carries tools and not databases, so a classification job still downloads its database as shown above.

Do not cache a live conda folder that several jobs update. CI services run jobs of one workflow at the same time by default, and two jobs updating one conda folder at once can damage it in ways that are hard to see. An offline pack is a read-only copy with a manifest and a record, so it is the safer thing to move between machines.

## A GitHub Actions template

This file goes at `.github/workflows/lungfish-headless.yml` in your repository, and you create the `.github/workflows/` folder if it is missing. It is written in [YAML](../../GLOSSARY.md#yaml), a text format whose indentation shows which setting belongs inside which. Change the `LUNGFISH` path if the program sits elsewhere, the runner label if GitHub renamed it, and `pipeline.nf` and the `outputs` paths to match your repository. The `${{ }}` expressions are GitHub's own syntax, copied unchanged.

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

    steps:
      - uses: actions/checkout@v4

      - name: Provision the required tools
        run: |
          "$LUNGFISH" tools update --apply --yes --required-only
          "$LUNGFISH" conda install --pack metagenomics

      - name: Assert the runner matches the pinned dependency set
        run: '"$LUNGFISH" tools update --plan'

      - name: Preflight
        run: |
          "$LUNGFISH" debug env --check-tools
          "$LUNGFISH" debug container

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

`actions/checkout@v4` copies your repository onto the runner, and every job needs it first. The file has no cache step on purpose. Add caching once the job passes without it, following GitHub's cache documentation.

The `tools update --plan` step fails the job on exit 10, which is what makes it a check. The upload step carries `if: always()` so a failed run still keeps its logs and whatever provenance was written. It uploads the whole `outputs/` folder because a bundle's record is written inside the bundle, as [Keeping the provenance](#keeping-the-provenance) shows. The template sets 60 minutes, where GitHub's own default is 360, so time your own pipeline at a desk before you change it.

## A CircleCI template

CircleCI is another CI service, often chosen for a repository hosted outside GitHub. It picks the macOS version through an Xcode image, so `xcode: "26.0.0"` asks for a macOS 26 machine. Check that tag against CircleCI's current macOS image list. This template installs from an offline pack, so commit the pack to `.ci/lungfish-conda-packs` in your repository before the first job. The cache steps then only save the time of copying a large pack out of the repository on later runs, and the job works without them. Because it installs the pack rather than running `tools update --apply`, the `--plan` step checks that the committed pack still matches the pinned set, and fails the job when it does not.

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

LGE writes a [provenance](../../GLOSSARY.md#provenance) record beside every result, holding the command, the tool version, and a checksum of each file, and [Provenance and Reproducibility](../01-foundations/08-provenance-and-reproducibility.md#reading-the-results) shows how to read it. Keeping those records as saved job output is the reason to run LGE in CI rather than calling the tools by hand. The fields inside the sidecar are listed in [Provenance sidecars](file-formats.md#provenance-sidecars).

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

A step that looks for `*.lungfish-provenance.json` files beside the output finds nothing, so upload the whole results folder, as both templates do.

`lungfish-cli ops stats <folder>` walks a folder and summarises every record under it, printing the number of records, completed runs, and total wall time, then one row per operation. Peak RAM reads `unknown` for local workflow runs, which do not record it.

`lungfish-cli provenance verify` checks a signed record, and signing is off by default, so on an ordinary record it exits 64 and reports that the signature file is missing. Until you set up signing, check the record's `exitStatus` field and that the declared outputs exist. With the `jq` JSON reader that most runners carry, that is one line.

```bash
jq -e '.exitStatus == 0' outputs/result.lungfishref/.lungfish-provenance.json
```

## What fails, and why

Six failures account for most failed jobs.

| Symptom | Cause | Fix |
|---|---|---|
| The command is not found | The bare name `lungfish-cli` is not on the runner's search path. | Use the full quoted path, as both templates do. |
| Exit 64 saying an expected output is required | An executed run with no `--expected-output`. | Add one per scientific output, or use `--dry-run` or `--prepare-only` for a check. |
| Exit 4, "Expected workflow output was not created" | `--expected-output` does not match where the pipeline wrote. | Run once at a desk and point the flag at the real output. |
| Exit 3 with an unknown-pack error | The pack id is misspelled, or `conda install --pack` was given an experimental pack, which it refuses although `offline-export` accepts it. | Read the list the error prints, and see [Known defects in this release](troubleshooting.md#known-defects-in-this-release) for experimental packs. |
| A second cached run fails on existing environments | `conda offline-install` ran without `--overwrite`. | Add `--overwrite`. |
| The workflow file is not recognised | The file is named `pipeline.NF` rather than `pipeline.nf`. | Name pipeline files in lower case. |

[Troubleshooting](troubleshooting.md) lists other symptoms, and its known-defects list includes the command-line faults a script is most likely to meet.

## Next

See [CLI Reference](cli-reference.md) for every flag of the commands named here, and [Running External Workflows](../08-workflows/03-running-external-workflows.md) for writing and running workflow files at a desk.
