---
title: Running Freyja
chapter_id: 06-classification/07-running-freyja
audience: analyst
prereqs: [06-classification/01-what-is-classification, 05-variants/01-calling-variants-from-amplicons]
estimated_reading_min: 7
task: Build or run a Freyja lineage-demixing command plan for wastewater SARS-CoV-2 samples.
tags: [classification, freyja, wastewater, lineage, provenance]
tools: [freyja]
entry_points:
  - "Tools > Plugin Manager… > wastewater-surveillance"
  - "CLI: lungfish freyja demix"
shots: []
illustrations: []
glossary_refs: [provenance]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

This chapter is about building and running a Freyja command plan for wastewater
SARS-CoV-2 samples. For the upstream variant and depth tables Freyja consumes,
see [Consensus and Lineage](../05-variants/05-consensus-and-lineage.md). For
the native classifiers that answer "what is present?", see
[What Is Read Classification](01-what-is-classification.md).

Freyja estimates SARS-CoV-2 lineage mixtures from wastewater sequencing data by
demixing: it solves for the blend of known lineages whose expected mutation
profiles best explain the variant frequencies in front of it. It is not a
general metagenomic classifier. Kraken2, EsViritu, TaxTriage, and NAO-MGS
answer "what organisms are present?" Freyja answers a narrower one: "given this
SARS-CoV-2 variant and depth summary, what lineage mixture best explains the
sample?"

Lungfish exposes Freyja as a command-plan workflow. A dry run writes the exact
`freyja demix` command, the resolved options, the input and output file records,
the pack identity, the tool version, and the Lungfish provenance sidecar. Add
`--execute` once the `wastewater-surveillance` pack is installed and you want
Lungfish to run the command on the spot.

In practice, install the `wastewater-surveillance` pack, point `freyja demix`
at a matched variant and depth table from the same sample, and dry-run it
first to capture the command before you add `--execute`.

## What you will learn

The tasks ahead: install the `wastewater-surveillance` pack, assemble the
variant and depth inputs Freyja needs, write a reproducible `freyja demix`
command plan, run it with `--execute`, and cite the provenance sidecar in a
methods section.

## Inputs

Freyja demixing picks up after mapping and variant summarization. It needs two
files:

| Input | Meaning |
|---|---|
| Variants | The variant table Freyja should demix. |
| Depths | The depth table matching the same sample and reference. |

Keep the two files from the same sample and the same reference build. Pair a
variant table from one run with depths from another and the command still
executes, but the lineage estimates mean nothing.

## GUI path

Open `Tools > Plugin Manager…` and select the `wastewater-surveillance` pack to
install or verify Freyja before you run a command plan from the CLI. There is no
Freyja menu item. The GUI's job here is installing the pack. The demixing
itself runs from the command line below. Freyja stays off the FASTQ/FASTA
Operations menu because that menu is reserved for direct data operations.

## CLI path

The default mode is dry-run command planning:

```bash
lungfish freyja demix \
    --variants sample.variants.tsv \
    --depths sample.depths.tsv \
    --output-dir freyja-sample-001 \
    --sample sample-001
```

That creates:

| File | Contents |
|---|---|
| `freyja-command-plan.json` | The reproducible Freyja command plan. |
| `.lungfish-provenance.json` | Lungfish operation provenance for the wrapper output. |

To execute the command through Lungfish, install the pack and add `--execute`:

```bash
lungfish conda install --pack wastewater-surveillance
lungfish freyja demix \
    --execute \
    --variants sample.variants.tsv \
    --depths sample.depths.tsv \
    --output-dir freyja-sample-001 \
    --sample sample-001
```

Advanced Freyja arguments pass through with `--extra-args`:

```bash
lungfish freyja demix \
    --variants sample.variants.tsv \
    --depths sample.depths.tsv \
    --output-dir freyja-sample-001 \
    --extra-args "--eps 1e-6"
```

## Provenance

Both dry-run and execute modes write provenance. The sidecar records the
workflow name (`lungfish freyja demix`), the Lungfish version, the exact command
line, the resolved defaults, the pack identity (`wastewater-surveillance`), the
tool version, the input and output paths, checksums and file sizes when the
files exist, the exit status, the wall time, and stderr when execution turns up
useful diagnostic text.

For methods sections, cite the `.lungfish-provenance.json` sidecar from the
output directory rather than retyping the command from memory.

The practical takeaway: keep the demixing reproducible. Run the dry run to
lock the command and its resolved defaults, add `--execute` only once the pack
is in place, and read the lineage proportions as an estimate of the mixture
in that sample, not a single called lineage.
