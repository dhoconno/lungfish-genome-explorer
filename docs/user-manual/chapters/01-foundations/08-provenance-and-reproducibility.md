---
title: Provenance and Reproducibility
chapter_id: 01-foundations/08-provenance-and-reproducibility
audience: analyst
prereqs: [01-foundations/06-the-lungfish-project, 01-foundations/07-plugin-packs]
estimated_reading_min: 7
task: Read a Lungfish Genome Explorer provenance sidecar and export a workflow as a shell script, Nextflow, or Snakemake.
tags: [foundations, provenance, reproducibility, export, nextflow, snakemake, methods]
tools: []
entry_points:
  - "File > Export > Provenance"
  - "Operations Panel > expand row > Provenance"
shots: []
planned_shots:
  - id: provenance-sidecar-json
    caption: "A provenance sidecar JSON file open in the Inspector."
  - id: provenance-export-menu
    caption: "The Export Provenance submenu showing Shell, Nextflow, Snakemake, and Methods Section options."
illustrations: []
glossary_refs: [provenance-sidecar, methods-export, reproducibility]
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

For supported scientific workflows that create, import, transform, export, or wrap data, Lungfish Genome Explorer (LGE) records reproducibility [provenance](../../GLOSSARY.md#provenance) with the output. The [provenance sidecar](../../GLOSSARY.md#provenance-sidecar) is a JSON file written alongside the result that records the resolved tool name and version, the exact command that ran (with all paths and parameters substituted), the input files with checksums and sizes, the runtime identity (machine, OS, CPU, git revision), the per-step exit status and useful stderr, and the wall time. The alpha contract is strict for new scientific workflows: missing provenance is a defect, not an optional extra. Older paths are being audited; when the manual names a workflow it should also be possible to find the sidecar or bundle provenance it writes.

This chapter teaches three concrete things. First, where sidecars live and how to read one. Second, how to export a project's full provenance trail as a runnable Shell script, a Nextflow pipeline, a Snakemake workflow, or a methods-section paragraph for a paper. Third, what a sidecar does and does not capture. It captures the command and the inputs; it does not pin the conda environment hash by default, so cross-machine bit-identical reproduction also requires running with the same plugin pack version.

Provenance has practical use beyond reproducibility. The iVar variant-calling step in the [pilot chapter](../05-variants/01-calling-variants-from-amplicons.md) reads the primer-trim sidecar to auto-confirm that the BAM was already trimmed. Without the sidecar, the variant-calling dialog would ask the user to confirm primer trimming. With it, LGE reads the previous step's record and skips the question. So what should you do with this? Treat the sidecar as the canonical record of how a file was made, and reach for the export menu when a collaborator asks for a runnable copy of your workflow.

## What you will learn

By the end of this chapter you will be able to find the provenance sidecar for any output file, read the resolved command and tool version from a sidecar, export a project's workflow as a shell script that another analyst can run, and write a methods-section paragraph from the export. You will also know what the sidecar does not promise: bit-identical output across different conda environment versions or across different CPU architectures.

## Where sidecars live

A sidecar lives next to the file it describes, with the suffix `.lungfish-provenance.json` appended to the original filename. For a downloaded FASTA at `Downloads/MN908947.3.fasta`, the sidecar is `Downloads/MN908947.3.fasta.lungfish-provenance.json`. For files inside a bundle (a `.lungfishref` reference bundle, a `.lungfishprimers` primer scheme, an assembly bundle), per-file sidecars are gathered into a `provenance/` subdirectory at the bundle root, with one JSON per output and a roll-up `bundle.lungfish-provenance.json` that lists every contained file in step order.

The Operations Panel surfaces the same record. Expand any operation row and the right side shows a `Provenance` button. Clicking it opens the Inspector on the sidecar JSON for that operation's primary output. The button is the fast path; the on-disk JSON is the source of truth.

## The sidecar schema

A sidecar is a single JSON document at a stable `schemaVersion`. Real sidecars carry both legacy and current field names for backward compatibility, so the file you see on disk has more keys than the simplified example below. The example is a representative LGE-alpha-12 sidecar with the most informative fields shown; for the full set of keys, look at any `.lungfish-provenance.json` in a project's `Analyses/` or bundle `provenance/` folder.

```json
{
  "schemaVersion": 1,
  "workflowName": "variants.call.ivar",
  "toolName": "ivar",
  "toolVersion": "1.4.4",
  "tool": {
    "name": "ivar",
    "version": "1.4.4"
  },
  "argv": [
    "ivar", "variants", "-p", "variants",
    "-q", "20", "-t", "0.05", "-m", "10",
    "-r", "MN908947.3.fasta", "-g", "MN908947.3.gff3"
  ],
  "reproducibleCommand": "ivar variants -p variants -q 20 -t 0.05 -m 10 -r MN908947.3.fasta -g MN908947.3.gff3",
  "options": {
    "resolvedDefaults": {
      "minAF": 0.05,
      "minDepth": 10,
      "minQuality": 20
    }
  },
  "files": [
    {
      "path": "Reference Sequences/MN908947.3.lungfishref/MN908947.3.fasta",
      "checksumSHA256": "c7e1d3...",
      "fileSize": 30428
    },
    {
      "path": "Reference Sequences/MN908947.3.lungfishref/alignments/SRR36291587.trimmed.bam",
      "checksumSHA256": "9f4a82...",
      "fileSize": 16742391
    }
  ],
  "output": {
    "path": "Reference Sequences/MN908947.3.lungfishref/variants/SRR36291587.ivar.vcf.gz",
    "checksumSHA256": "ae8b91...",
    "fileSize": 4218
  },
  "runtimeIdentity": {
    "operatingSystemVersion": "macOS-26.4.1-arm64-arm-64bit",
    "executablePath": "/Users/me/.lungfish/conda/envs/ivar/bin/ivar",
    "condaEnvironment": "ivar",
    "containerImage": null,
    "processIdentifier": 48291,
    "gitRevision": "921ba202..."
  },
  "createdAt": "2026-04-18T14:22:08Z",
  "wallTimeSeconds": 11.3,
  "exitStatus": 0,
  "stderr": null
}
```

The keys read top to bottom as a story. `schemaVersion` declares the layout version. `workflowName`, `toolName`, and `toolVersion` (plus the structured `tool` object) identify the workflow and the tool that ran it. `argv` and `reproducibleCommand` are the two equivalent forms of the resolved invocation (the array form is canonical; the shell form is convenient for reading). `options.resolvedDefaults` records every parameter the user did not override, so a re-run with the same options produces the same record. `files[]` lists every input the step read, each with a SHA-256 checksum and byte size; `output` (or `outputs[]` for multi-output steps) records the result the same way. `runtimeIdentity` records the machine, OS, conda environment, and git revision in effect at run time. `createdAt`, `wallTimeSeconds`, `exitStatus`, and `stderr` close the run.

When LGE reads a sidecar later (for the auto-confirm behaviour in the iVar dialog, or for export), it walks the inputs to verify checksums match the files currently on disk. A mismatch downgrades the auto-confirm to a manual prompt and surfaces a warning in the operation row.

Helper and converter steps, migrations, and GUI-imported CLI outputs follow the same contract: each records its tool or workflow name and version, the exact argv or reproducible command, resolved defaults, runtime identity, input and output paths with checksums and sizes, exit status, wall time, and useful stderr where applicable. There are no second-class provenance steps in the alpha 12 contract.

## Signed sidecars

For audit workflows that need tamper evidence, LGE can write a signature
artifact next to `.lungfish-provenance.json`. In the local deterministic
Curve25519 signing provider used for offline labs and tests, a signed sidecar has two companion
files: `.lungfish-provenance.json.signature.json` and
`.lungfish-provenance.json.pub`. Verification recomputes the provenance
SHA-256, checks the public key digest in the signature envelope, and fails
clearly if the sidecar, signature, or public key is missing or if any bytes
changed after signing.

Configure signing in **Settings > General > Provenance Signing**. The
**Local** provider stores its private key in the macOS Keychain. CLI and
automation environments can instead set `LUNGFISH_PROVENANCE_SIGNING_KEY` or
`LUNGFISH_PROVENANCE_SIGNING_KEY_FILE`; when either is present, provenance
writers attach the local signature artifact after writing the JSON sidecar.
The **Cosign Plan** setting documents the intended sigstore/cosign workflow
for sites that already manage signing keys outside LGE: sign the sidecar
digest with cosign, keep the signature and public key beside the sidecar, and
verify those artifacts during intake. LGE's built-in verifier currently
checks the local sidecar format.

Use the CLI to verify a signed sidecar:

```bash
lungfish provenance verify Results/.lungfish-provenance.json
```

You can also point at a bundle or directory; LGE looks for the root
`.lungfish-provenance.json` first and then for a bundle roll-up under
`provenance/`. A missing signature reports the expected signature path, a
tampered sidecar reports a digest mismatch, and a mismatched public key
reports a public-key mismatch. Treat any verification failure as an audit
blocker until the sidecar is regenerated from the original workflow or the
signature artifact is restored from a trusted source.

## Export paths

Every LGE project carries a complete provenance graph: every output's sidecar plus the cross-references that link a sidecar's input to an earlier sidecar's output. `File > Export > Provenance` walks that graph from a selected leaf node back to the project's roots and emits the result in one of four formats.

| Format | Output | Best for |
|---|---|---|
| Shell | A single `run.sh` bash script with environment activation and ordered tool calls | Quick re-run on a similar machine; debugging an oncall failure |
| Nextflow | `main.nf` with one process per LGE step plus `nextflow.config` and a `containers/` manifest | Running on a cluster; scaling out across many samples |
| Snakemake | `Snakefile` with rules keyed on output paths plus `config.yaml` | Lab pipelines that already use Snakemake conventions |
| Methods Section | A plain-prose paragraph in Markdown, with tool names and versions inline | Methods sections in papers and clinical reports |

The Shell export is the most direct: it is a flat script that calls every tool in the order LGE ran them, with the exact parameters from each sidecar. Nextflow and Snakemake exports decompose the same graph into named processes or rules, so a downstream user can run a single sample or scale to many. The Methods Section export emits prose suitable for pasting into a paper, with parenthetical version numbers and a citation for each tool. It starts with an automatically-generated draft warning banner so the text gets a deliberate human review pass before submission.

All four exports include a `provenance/` directory with the original sidecars copied verbatim. A reviewer can re-run the script and then diff the new sidecars against the originals to see which steps reproduced bit-identically and which did not.

## Worked example: iVar variant call

Take the variant-calling step from the [variants chapter](../05-variants/01-calling-variants-from-amplicons.md). When that step finishes, LGE writes `variants/SRR36291587.ivar.vcf.gz.lungfish-provenance.json` next to the VCF inside the reference bundle. The sidecar for this step is structurally identical to the example above; the relevant fields are the resolved command, the trimmed BAM checksum, and the iVar tool version.

Selecting that VCF in the sidebar and choosing `File > Export > Provenance > Shell` produces a `SRR36291587-variants.zip` containing `run.sh`, an `inputs/` directory with the reference FASTA and the GFF, and a `provenance/` directory with every sidecar from the project's start to the variant call. The script body looks like this:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Activate the LGE-managed iVar environment.
# Plugin pack: variant-calling@0.3.2
source ~/.lungfish/conda/envs/ivar/bin/activate

# Step 1: download reference (from Downloads/MN908947.3.fasta sidecar)
curl -fsSL "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=nuccore&id=MN908947.3&rettype=fasta&retmode=text" \
  -o inputs/MN908947.3.fasta

# Step 2: download GFF
curl -fsSL "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=nuccore&id=MN908947.3&rettype=gff3&retmode=text" \
  -o inputs/MN908947.3.gff3

# Step 3: download reads from ENA
curl -fsSL "ftp://ftp.sra.ebi.ac.uk/vol1/fastq/SRR362/087/SRR36291587/SRR36291587_1.fastq.gz" -o inputs/SRR36291587_1.fastq.gz
curl -fsSL "ftp://ftp.sra.ebi.ac.uk/vol1/fastq/SRR362/087/SRR36291587/SRR36291587_2.fastq.gz" -o inputs/SRR36291587_2.fastq.gz

# Step 4: map
minimap2 -ax sr inputs/MN908947.3.fasta inputs/SRR36291587_1.fastq.gz inputs/SRR36291587_2.fastq.gz \
  | samtools sort -o SRR36291587.bam
samtools index SRR36291587.bam

# Step 5: primer trim
ivar trim -e -i SRR36291587.bam -b inputs/qiaseq-direct-sars2.bed -p SRR36291587.trimmed.unsorted
samtools sort -o SRR36291587.trimmed.bam SRR36291587.trimmed.unsorted.bam
samtools index SRR36291587.trimmed.bam
rm SRR36291587.trimmed.unsorted.bam

# Step 6: call variants (this is the step whose sidecar we exported from)
samtools mpileup -aa -A -d 600000 -B -Q 20 -q 0 -f inputs/MN908947.3.fasta SRR36291587.trimmed.bam \
  | ivar variants -p variants -q 20 -t 0.05 -m 10 -r inputs/MN908947.3.fasta -g inputs/MN908947.3.gff3

# Convert iVar TSV to VCF.gz with LGE's helper script.
python provenance/scripts/ivar_to_vcf.py variants.tsv \
  | bgzip -c > SRR36291587.ivar.vcf.gz
tabix -p vcf SRR36291587.ivar.vcf.gz
```

The Methods Section export starts with `<!-- This is an automatically-generated draft. Read it before submitting. -->`, followed by a paragraph along the lines of: "Reads were mapped to MN908947.3 with minimap2 v2.28, sorted and indexed with samtools v1.21, primer-trimmed with iVar v1.4.4 against the QIAseq Direct SARS-CoV-2 primer scheme, and called against the same reference with iVar variants v1.4.4 at minimum allele frequency 0.05 and minimum depth 10, codon-annotated with the matching GFF3." The exact wording is templated from the workflow type and the tool versions in each sidecar; use [Tool Versions](../appendices/tool-versions.md#appendix-tool-versions) only as the release-level reference.

## Reproducibility checklist

Before you claim that a re-run reproduces an earlier result, verify each item on this list against the sidecars from both runs. The first three are necessary for any meaningful comparison; the last two are necessary for bit-identical output.

- LGE `toolVersion` is the same in both sidecars.
- Plugin pack name and version match between runs (recorded in the plugin-pack-aware sidecars produced by managed-tool workflows).
- Every input checksum in `files[]` matches between runs (SHA-256 over file contents).
- The `runtimeIdentity.operatingSystemVersion` architecture suffix matches (arm64 vs x86_64; some tools are not bit-identical across architectures).
- The CPU thread count recorded in the sidecar's options matches if the tool's output depends on thread count (SPAdes assembly is the common offender; iVar and bcftools are not).

If the first three match but the last two differ, expect logically equivalent output (same variants, same coverage) but not byte-identical files. If all five match and the output still differs, you have found a bug worth reporting.

## What provenance does not capture

The sidecar is honest about its scope. Three things it does not capture, listed so you can plan around them.

- The conda environment hash. LGE records the plugin pack name and version, which pins the environment recipe, but does not hash every package in the resolved environment. Two machines on the same plugin pack version will usually have identical environments, but conda's solver can pick different transitive dependencies if the upstream channel state has changed.
- The CPU architecture beyond `arm64` or `x86_64`. Some tools (notably any that use SIMD-vectorised math) produce different floating-point results on different microarchitectures even within a single architecture family.
- External network state. A re-run that fetches `MN908947.3` from NCBI assumes NCBI still serves that accession; the sidecar records the URL and the SHA-256 of what was fetched, but cannot guarantee the server returns the same bytes next year.

For workflows that need true bit-identical reproduction (clinical audit, regulatory submission), pair the provenance export with a containerised plugin pack image so the environment hash is fixed at the OCI layer. The containerization strategy chapter (coming soon) will cover that path.

## Why this matters

Provenance has four audiences in practice. Clinical labs need an audit trail that links a reported variant back to a specific tool version and a specific input checksum, for regulatory inspection. Researchers need methods sections that match what they actually ran, not a remembered approximation. Collaborators need a runnable artifact (Shell, Nextflow, or Snakemake) so a colleague at another institution can reproduce a result without a back-and-forth. Oncall engineers debugging a failed run need exit statuses and stderr to find which step broke and why.

LGE writes the sidecar regardless of which audience asked for it, which means the audit trail is always there when someone asks. The export menu is the surface that turns the trail into something portable.

## Next

Foundations is complete. Continue to one of the workflow parts:

- [Sequences](../02-sequences/) for sequence import, viewing, and download workflows
- [Reads (FASTQ)](../03-reads/) for read import, QC, trimming, and decontamination
- [Alignments](../04-alignments/) for mapping, alignment review, and primer trimming
- [Variants](../05-variants/) for variant calling and VCF interpretation
- [Classification](../06-classification/) for taxonomic classification of reads

The [Assembly](../07-assembly/) part covers de novo assembly workflows.
