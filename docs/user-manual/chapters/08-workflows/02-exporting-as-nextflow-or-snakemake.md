---
title: Exporting as Nextflow or Snakemake
chapter_id: 08-workflows/02-exporting-as-nextflow-or-snakemake
audience: analyst
prereqs: [01-foundations/08-provenance-and-reproducibility, 08-workflows/01-the-workflow-builder]
estimated_reading_min: 8
task: Export a completed run's provenance as Nextflow, Snakemake, or another target for sharing and external execution.
tags: [workflows, export, nextflow, snakemake, methods]
tools: [nextflow, snakemake]
entry_points:
  - "File > Export > Provenance > Nextflow Pipeline"
  - "File > Export > Provenance > Snakemake Workflow"
shots: []
planned_shots:
  - id: export-provenance-submenu
    caption: "The File > Export > Provenance submenu showing all six export targets."
  - id: nextflow-export-main-nf
    caption: "The generated main.nf opened in a text editor, with one process per recorded provenance step visible."
illustrations: []
glossary_refs: [methods-export, provenance, provenance-sidecar, reproducibility]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

A Lungfish analysis does not have to stay inside Lungfish. Once you have run a
pipeline and you are happy with it, the **File > Export > Provenance** submenu
emits the same work as a runnable artifact you can hand to a collaborator,
commit to a git repository, or feed to a cluster scheduler. The export is built
from the provenance records the app already keeps for every operation you ran,
not from a Workflow Builder graph. That distinction matters: you do not need to
have built a workflow in the Builder to export. Any sequence of operations you
have run leaves provenance, and that provenance is what the exporter renders.

Six targets are available. They sit on a spectrum from "executable on a
cluster" to "ready to paste into a paper". Pick the target that matches what
your collaborator, or your future self, needs to do with it.

| Target | Files emitted | Best for |
|---|---|---|
| Shell Script | `run.sh`, `provenance/` | Local re-run, debugging, or stepping through one command at a time |
| Python Script | `reproduce.py`, `provenance/` | A portable subprocess driver for Python-based environments |
| Nextflow Pipeline | `main.nf`, `nextflow.config`, `containers/manifest.json`, `provenance/` | Re-running on an HPC or cloud cluster with a Nextflow-aware scheduler |
| Snakemake Workflow | `Snakefile`, `config.yaml`, `provenance/` | Re-running under an existing Snakemake-based group convention |
| Methods Section | `methods.md`, `provenance/` | Pasting a tool-and-version paragraph into a paper |
| Full Provenance (JSON) | `provenance.json`, `provenance/` | The raw machine-readable provenance envelope for tooling |

The submenu draws a visual separator between the first four targets and the
last two, but all six render and all six work. Every export is a single folder,
and every export contains a `provenance/` subdirectory holding the provenance
records copied from the project, so the export is self-describing even after it
leaves your machine. The practical takeaway: when a collaborator asks
"how did you run this", export the run as Nextflow or Snakemake instead of
writing them an email.

## What you will learn

By the end of this chapter you will be able to choose among the six export
targets depending on your destination, generate an export from a project's
provenance, run an exported pipeline on a fresh machine, and edit the exported
pipeline for collaborators who want to swap inputs.

## Procedure: export a completed run as Nextflow

This walkthrough assumes you have run a pipeline whose provenance is in the
project, for example the VSP2 FASTQ chain from
[The Workflow Builder](01-the-workflow-builder.md). The exporter renders from
the recorded provenance of whatever operations ran, so the steps below apply to
any completed run, not only a Builder graph.

<!-- planned: export-provenance-submenu -->

1. With the project open, choose **File > Export > Provenance > Nextflow
   Pipeline**.
2. In the save dialog, name the export folder `run-nf` and pick a location
   outside the project (for example, `~/exports/`). Click **Export**.
3. Lungfish writes the export folder and reveals it in Finder.
4. Open `main.nf` in a text editor.
5. Open Terminal in the export folder and run `nextflow run main.nf`.

<!-- planned: nextflow-export-main-nf -->

The generated `main.nf` declares one Nextflow process per recorded provenance
step. Each process carries the exact command line Lungfish recorded for that
step, a pinned container reference when one was exported, and a `publishDir`
directive pointing at `params.outdir`. The accompanying `nextflow.config` is
deliberately minimal. It sets an error strategy and enables Docker:

```groovy
process {
    errorStrategy = 'terminate'
}
docker.enabled = true
```

There are no `standard` or `slurm` profiles, so do not pass `-profile`. To
target a specific scheduler you edit `nextflow.config` yourself and add an
executor or a profile block. The export also writes `containers/manifest.json`,
a JSON list of the tool name, version, image, and digest for every step that
ran in a container, so an auditor can see which image produced each output. The
`provenance/` subdirectory is copied next to the pipeline so anyone inspecting
the export can trace, for any output, which inputs and which tool version
produced it.

## Interpretation: what the export captures, and what it does not

The export is honest about what it is. It captures what Lungfish recorded. It
does not capture everything your operating system controls.

What the export captures, by reading the provenance records:

- The ordered list of operations, with each step's inputs, outputs, and
  recorded command line.
- The tool name and version string for steps that ran as recorded operations
  (for example, a resolved `2.28-r1209` rather than just `minimap2`).
- A container image and digest for each step that ran in a container, written
  into `containers/manifest.json`.
- Input file checksums where available, so a downstream re-run can verify that
  the inputs match.
- The Lungfish app version and host in effect when the operations ran.

Two honest limits are worth stating plainly. First, the export records the tool
versions that ran, but some derived steps are reconstructed rather than
recorded. In particular, a reference acquisition that was never captured as its
own operation is synthesized into the export with a tool version of `unknown`.
If you are citing exact versions in a methods section, check that the steps you
are citing carry a real version string and not `unknown`. Second, what the
export cannot control:

- Remote registry availability for container images. Lungfish records the image
  digest, but moving an image to another machine is still your responsibility if
  that machine cannot reach your registry.
- The exact host CPU microarchitecture. Tools that compile SIMD paths at install
  time may take a different code path on a collaborator's machine.
- Reads that originated from an SRA download. The export references the
  accession; it does not bundle the FASTQ. A collaborator needs network access
  to NCBI or ENA, or a local cache.

If your collaborator needs the strongest possible reproducibility, pair the
export with a container artifact. The VSP2 FASTQ walkthrough does not produce a
reference bundle, so the example below uses an illustrative
`<reference>.lungfishref`; substitute whichever bundle your own run consumed:

```bash
lungfish bundle export <reference>.lungfishref \
  --format container \
  --output reference.oci.tar \
  --plugin-pack read-mapping \
  --plugin-pack variant-calling
```

The command writes a reproducible OCI-layout tarball. In builds that cannot
invoke Docker or Apple Containers, Lungfish still writes a deterministic OCI
layout with `oci-layout`, `index.json`, manifest, config, layer tar, pinned
plugin-pack metadata, and `.lungfish-provenance.json`. The provenance records
the exact argv, input and output paths, checksums where available, plugin pack
identities, exit status, wall time, runtime user and host, and image digest.
The Nextflow export's container references then use that image digest instead of
resolving tools from a registry at run time.

For conda-based collaborators, also export the lockfile:

```bash
lungfish conda lock --pack read-mapping --output locks/read-mapping-lock.yml
lungfish conda install --from-lockfile locks/read-mapping-lock.yml
```

The lockfile recreates the same pinned environment before running the workflow.

## Procedure: hand off to a collaborator on a different OS

The export is a plain folder. It travels through any channel you would use for
a small code repository.

1. Initialise a git repository inside the export folder with `git init &&
   git add . && git commit -m "Initial export"`.
2. Push to a shared host (GitHub, an institutional GitLab, or a bare repository
   on a shared filesystem).
3. The collaborator clones the repository, installs Nextflow (`curl -s
   https://get.nextflow.io | bash`), and runs `nextflow run main.nf`.

If the collaborator is on Linux and you exported from macOS, the export itself
is portable: `main.nf`, `nextflow.config`, `containers/manifest.json`, and
`provenance/` are all plain text. The portability question is the underlying
tools, not the pipeline. Because `nextflow.config` enables Docker, the cleanest
path on the collaborator's side is to run the recorded container images. If the
collaborator is on a cluster without internet access on compute nodes, ship the
OCI tarball alongside the export and point the config at the local image.

## Procedure: edit the export so a collaborator can swap inputs

The most common edit is "run this exact pipeline against my reads, not yours".
The exported `main.nf` exposes inputs at the top of the file as parameters,
one per recorded input file. The parameter names are derived from the input
filenames (each dot becomes an underscore and the name is sanitized), not from
semantic roles, so they look like this:

```groovy
params.srr12345678_1_fastq_gz = 'SRR12345678_1.fastq.gz'
params.srr12345678_2_fastq_gz = 'SRR12345678_2.fastq.gz'
params.outdir = './results'
```

A collaborator who wants to run the pipeline against their own reads overrides
the matching parameter by its real, mangled name:

```sh
nextflow run main.nf \
  --srr12345678_1_fastq_gz my_sample_1.fastq.gz \
  --srr12345678_2_fastq_gz my_sample_2.fastq.gz
```

Open `main.nf` to read the exact parameter names before overriding them, since
they depend on your input filenames. The Snakemake export uses the same
filename-derived keys in `config.yaml`, which a collaborator overrides via
`--config`. The shell and Python exports expose inputs as `INPUT_n` variables.
The methods-section export does not parameterise anything; it is prose.

## Interpretation: which target to pick

Pick **Nextflow Pipeline** when the collaborator already runs Nextflow, when
the destination is a cluster with a Nextflow-aware scheduler, or when you want
the export to live in a git repository that other tooling will discover. Note
that the generated `nextflow.config` carries no scheduler executor, so reaching
a cluster means editing the config to add one. Nextflow's resume semantics also
matter when steps are expensive: a failed run restarts from the failed process,
not from the beginning.

Pick **Snakemake Workflow** when the collaborator's group already uses
Snakemake. Lungfish's Snakemake export is a flat layout: a single `Snakefile`
plus a `config.yaml` in the export root, with no `workflow/` directory and no
per-rule conda environment files. Per-rule isolation is expressed with
`singularity:` directives that reference `docker://<image>`, so the intended run
command is `snakemake --cores 8 --use-singularity`. Configuration values live in
the flat `config.yaml`, overridable with `--config`.

Pick **Shell Script** when you want to debug the pipeline one command at a time,
or when the destination is a single workstation with no scheduler. The shell
export is also the easiest to read if you are trying to understand what Lungfish
did under the hood: each recorded command line is written in order, with `INPUT_n`
and `OUTDIR` variables at the top. **Python Script** is the same idea as a
portable subprocess driver (`reproduce.py`) for environments where a Python
entry point is more convenient than a shell script.

Pick **Methods Section** when you are writing a paper. The methods export emits
one Markdown paragraph naming each tool, its resolved version, and the
parameters that differed from defaults, in the order the operations ran. The
paragraph is suitable for pasting under a "Bioinformatics analysis" subhead. Use
the accompanying `provenance/` folder as the supplementary material that backs
the paragraph, and recheck any step whose recorded version is `unknown` before
asserting an exact version in print. **Full Provenance (JSON)** emits the raw
provenance envelope (`provenance.json`) for your own tooling, not for human
reading.

You can run more than one export from the same project. The exports are
independent folders and do not overwrite each other. A common pattern is
Nextflow for the cluster, Methods Section for the paper draft, and Shell for
your own debugging, all from the same provenance.

## Interpretation: signing and the transitive provenance chain

Two behaviours are worth knowing for an audit. First, when a signer is
configured, Lungfish cryptographically signs each generated export artifact,
writing a `.signature.json` and a `.pub` next to it, and verifies the signature
locally. An auditor can then confirm that an exported `main.nf` or `methods.md`
has not been altered since export. Second, the `provenance/` folder is more than
a copy of the final step. When the exporter expands the provenance chain it
walks input dependencies, including enclosing `.lungfishref` bundles and their
manifests, and copies each discovered record into `provenance/source/…`. So the
export bundles the upstream lineage, not just the last command, which is exactly
the transitive record a reproducibility reviewer wants.

## Next

This is the last chapter in [Workflows](.). See [the appendices](../appendices/)
for CLI reference, keyboard shortcuts, and the troubleshooting guide.
