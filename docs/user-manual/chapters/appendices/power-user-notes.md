---
title: Power User Notes
chapter_id: appendices/power-user-notes
audience: power-user
prereqs: []
estimated_reading_min: 18
task: Look up tool internals, canonical flags, and reproducibility caveats stripped from bench-scientist chapters.
tags: [reference, power-user, mpileup, ivar, lofreq, indelqual, provenance, determinism, reproducibility]
tools: []
entry_points: []
shots: []
illustrations: []
glossary_refs: []
features_refs: []
fixtures_refs: []
brand_reviewed: false
lead_approved: false
---

## What it is

This appendix collects the tool-internals and reproducibility caveats that were intentionally removed from the bench-scientist workflow chapters to keep them readable. The content here is correct and load-bearing for power users who script Lungfish, build Snakemake or Nextflow pipelines around it, or validate Lungfish output for clinical or regulatory use. Everything in this appendix is also implicit in the provenance sidecars that Lungfish writes for every operation, but having it documented in one place is faster than reverse-engineering from a sidecar.

The conventions: this appendix uses `bash` code blocks for canonical commands, `json` blocks for sidecar excerpts, and tables for flag references. Numbers and flag values match the current Lungfish build (0.4.0-alpha.11); future versions may adjust defaults, and the truth is whatever the provenance sidecar records for a specific run.

## iVar variant calling internals

The iVar variant-calling step in Lungfish wraps a two-process pipeline: `samtools mpileup` produces a per-position pileup, which is piped into `ivar variants`. Both steps' commands are recorded in the provenance sidecar's `steps[]` array.

### Canonical samtools mpileup flags

Lungfish runs samtools mpileup with these flags for iVar amplicon variant calling:

```bash
samtools mpileup \
    -aa \
    -A \
    -d 600000 \
    -B \
    -Q 20 \
    -q 0 \
    -f reference.fasta \
    primer-trimmed.bam
```

| Flag | Meaning | Why |
|---|---|---|
| `-aa` | Output absolutely every position, including zero-coverage | Pileup must cover every base for iVar to emit a complete consensus |
| `-A` | Keep anomalous read pairs (orphans, mate-unmapped) | Amplicon pairs frequently look anomalous after primer trim; dropping them loses real evidence |
| `-d 600000` | Raise depth cap from 8000 (default) to 600000 | High-coverage amplicons routinely exceed 8000x; the default silently truncates |
| `-B` | Disable BAQ (Base Alignment Quality) | BAQ assumes shotgun random fragmentation; on amplicon data BAQ degrades calls near primers |
| `-Q 20` | Minimum base quality 20 | Filters low-Phred bases; iVar's threshold is also 20 |
| `-q 0` | Minimum mapping quality 0 | Keeps all primary alignments; mapping quality is filtered downstream |
| `-f <ref>` | Reference FASTA | Required for iVar's reference-aware calling |

If you build a CLI run that calls iVar directly, omitting `-d 600000` is the most common mistake: a 1000x amplicon at 8000x cap silently caps at 8000 and your AF math becomes wrong.

### Canonical ivar variants flags

```bash
ivar variants \
    -p variants \
    -q 20 \
    -t 0.05 \
    -m 10 \
    -r reference.fasta \
    -g annotations.gff3
```

| Flag | Meaning | Lungfish default |
|---|---|---|
| `-p <prefix>` | Output prefix (writes `variants.tsv`) | `variants` |
| `-q <int>` | Minimum quality score | 20 |
| `-t <float>` | Minimum allele frequency threshold | 0.05 (overridable in the dialog) |
| `-m <int>` | Minimum read depth | 10 |
| `-r <fasta>` | Reference FASTA | bundle reference |
| `-g <gff>` | GFF3 annotations (enables codon-aware output) | bundle annotations if present |

The `-g` flag is what triggers codon-merge. Without it, iVar emits per-position rows. With it, iVar's TSV gets per-position rows plus codon annotation columns; the Lungfish converter then merges adjacent within-codon SNPs into one VCF row.

### Codon-merge mechanics

The Lungfish iVar TSV-to-VCF converter examines each iVar TSV row's codon-position and codon-content fields. When two adjacent SNPs share the same codon coordinates, the converter merges them into a single VCF row with multi-base REF and ALT. Position 28881 G→A and position 28882 G→A in the SARS-CoV-2 N gene fall inside codon 203; the merged row reads `28881  GG  AA` rather than two single-base rows.

Position 28883 G→C is in codon 204, so it stays on its own row. The merge is positional (within-codon coordinate boundary) plus content-aware (both rows must read as alternates of the same codon's bases). The merge is not phase-aware: iVar does not know whether the two changes are on the same molecule. The single-row representation makes the codon boundary visible in the table; for haplotype-phased calls you need a tool that consumes phased BAMs (HaplotypeCaller, WhatsHap), which Lungfish does not currently wrap.

## LoFreq variant calling internals

LoFreq's strength is per-base error modeling with multiple-testing correction. Lungfish runs LoFreq through three steps that the user does not see in the dialog: indel-quality preparation, alignment-quality recalibration, and the variant call itself.

### LoFreq indelqual preprocessing

```bash
lofreq indelqual --dindel -f reference.fasta in.bam -o indelqual.bam
```

The `--dindel` mode recomputes per-base indel-quality scores using LoFreq's port of the Dindel algorithm. Without this step LoFreq under-calls indels by design: its statistical model assumes per-base indel quality is present, and BAM files from `samtools sort` do not carry it.

If you build a hand-written CLI pipeline that calls `lofreq call-parallel` directly without indelqual, your indel call rate will be silently low. Lungfish runs indelqual in every LoFreq pipeline; a manual pipeline must too.

### LoFreq call-parallel flags

```bash
lofreq call-parallel \
    --pp-threads 4 \
    --no-default-filter \
    -f reference.fasta \
    -o variants.vcf.gz \
    indelqual.bam
```

| Flag | Meaning |
|---|---|
| `--pp-threads <n>` | Parallel-pile threads. Defaults to 4; raise for high-coverage runs. |
| `--no-default-filter` | Skip LoFreq's built-in filter pass. Lungfish runs its own filter normalization downstream. |
| `-f <ref>` | Reference FASTA |
| `-o <vcf.gz>` | Output VCF (bgzipped) |

LoFreq's significance threshold is depth-dependent (Bonferroni correction over tested positions). On a 5000x amplicon pileup, the per-position p-value threshold rises sharply, which is why low-AF iVar calls at high depth are rejected by LoFreq.

### LoFreq strand-bias filter

LoFreq emits a per-row strand-bias score (`SB` in the INFO field) and applies a default Phred-scaled filter. On amplicon data, primer placement creates structural strand asymmetry that LoFreq's default flags as suspect. The Lungfish convention for amplicon data is to feed LoFreq the un-trimmed BAM (where strand asymmetry is uniform across the genome) rather than the primer-trimmed BAM (where soft-clipping introduces residual asymmetry that the SB filter rejects). For shotgun viral data, primer-trim does not apply and the SB filter is well-calibrated.

## Provenance sidecar schema

Every operation that produces a file writes a `*.lungfish-provenance.json` sidecar. Bundle-level operations write a `bundle.lungfish-provenance.json` at the bundle root that links per-step sidecars. The schema is stable across Lungfish versions; new fields are added only as additive extensions.

```json
{
  "schema_version": 2,
  "workflow": "variants.call.ivar",
  "version": "0.4.0-alpha.11",
  "command": "ivar variants -p variants -q 20 -t 0.05 -m 10 -r ref.fasta -g annotations.gff3",
  "inputs": [
    {
      "path": "Reference Sequences/MN908947.3.lungfishref/genome/reference.fasta",
      "sha256": "c7e1d3b2a8...",
      "bytes": 30428,
      "role": "reference"
    },
    {
      "path": "Reference Sequences/MN908947.3.lungfishref/tracks/SRR36291587.trimmed.bam",
      "sha256": "9f4a8242d1...",
      "bytes": 16742391,
      "role": "alignment"
    }
  ],
  "outputs": [
    {
      "path": "Reference Sequences/MN908947.3.lungfishref/variants/iVar variants.vcf.gz",
      "sha256": "ae8b91f3c4...",
      "bytes": 4218
    }
  ],
  "runtime": {
    "host": "tarpon.local",
    "user": "alice",
    "os": "macOS 26.1 (Tahoe)",
    "arch": "arm64",
    "cpu_threads": 8,
    "started_at": "2026-04-18T14:22:08Z",
    "wall_time_seconds": 11.3,
    "exit_status": 0,
    "stderr_path": "provenance/logs/variants.call.ivar.stderr"
  },
  "tool": {
    "name": "ivar",
    "version": "1.4.4",
    "plugin_pack": "variant-calling",
    "plugin_pack_version": "0.3.2",
    "conda_env": "/Users/alice/.lungfish/conda/envs/ivar"
  },
  "steps": [
    {
      "command": "samtools mpileup -aa -A -d 600000 -B -Q 20 -q 0 -f reference.fasta SRR36291587.trimmed.bam",
      "tool_version": "samtools 1.21",
      "exit_status": 0,
      "wall_time_seconds": 8.1
    },
    {
      "command": "ivar variants -p variants -q 20 -t 0.05 -m 10 -r reference.fasta -g annotations.gff3",
      "tool_version": "ivar 1.4.4",
      "exit_status": 0,
      "wall_time_seconds": 3.2
    }
  ]
}
```

The `steps[]` array decomposes a multi-process pipeline into one entry per process. The `inputs[]` and `outputs[]` arrays carry SHA-256 checksums and byte sizes for every file. When a workflow consumes a sidecar's output later, it reads the same `inputs[]` records and verifies the checksums match what is on disk.

Recent Lungfish builds also preserve `peakMemoryBytes` on a step when the
runner can observe peak resident memory. Operation rows in the app retain
wall time and peak RAM while they are visible in the Operations Panel, and
the persisted provenance sidecars are the long-term record.

To summarize completed operation cost across a project or exported bundle,
run:

```bash
lungfish ops stats /path/to/project-or-bundle
```

The command recursively scans `.lungfish-provenance.json` sidecars,
ignores failed and cancelled runs, and reports completed run count, total
wall time, average wall time by operation name, and the largest peak RAM
value recorded by any step.

## Plugin pack environment pinning

Plugin packs are versioned recipes for per-tool conda environments. The pack version pins the recipe (which tools, which channel constraints, which compiled-against versions) but does NOT pin every transitive dependency. A re-install of the same pack version six months from now may resolve to slightly different transitive package versions if upstream channels have moved.

For bit-identical reproduction across machines, pair the provenance sidecar with one of:

- An OCI image artifact from `lungfish bundle export <bundle> --format container --output <bundle>.oci.tar`
- A conda lockfile from `lungfish conda lock --pack <name> --output lockfile.yml`
- A Snakemake / Nextflow export with lockfile or container references included

Without one of these, "same plugin pack version" guarantees the same recipe but not the same resolved environment. Clinical validation workflows must use the OCI path; research workflows can usually rely on the pack version alone.

### Conda lockfiles

`lungfish conda lock --pack <name> --output lockfile.yml` writes a
conda-lock-compatible YAML file for a built-in plugin pack. The lockfile
contains the pack ID, channels, platforms, content hash, and one package
record per pinned requirement. Reinstall with:

```bash
lungfish conda install --from-lockfile lockfile.yml
```

Both commands write `.lungfish-provenance.json` next to their output or conda
root. The lock provenance records the exact command, pack identity, resolved
channels and platforms, output path, runtime identity, exit status, and wall
time. The install provenance records the lockfile input, destination conda
root, installed environment names, command line, exit status, and wall time.

## Determinism and reproducibility caveats

A re-run of the same Lungfish command on the same inputs is deterministic only under specific conditions. The caveats are documented here so power users do not assume bit-identical reproduction without the right setup.

### Per-tool determinism

| Tool | Deterministic? | Conditions |
|---|---|---|
| `samtools sort` | Yes | Always; sorts are stable |
| `samtools index` | Yes | Always |
| `minimap2` | Mostly | Multi-threading can produce non-bit-identical CIGAR strings on a small fraction of reads. Pin `--threads 1` for strict determinism. |
| `bwa-mem2` | Mostly | Same caveat as minimap2 |
| `samtools mpileup` | Yes | Deterministic given the same BAM |
| `ivar variants` | Yes | Single-threaded; deterministic given the same TSV |
| `lofreq call-parallel` | Mostly | Threading affects chunk boundaries; deterministic with `--pp-threads 1` |
| `medaka` | No | GPU/CPU floating-point ordering produces minor variation |
| `spades` / `flye` / `hifiasm` | No | Multi-threaded assembly graphs traversed non-deterministically |

For workflows that demand bit-identical reproduction (clinical, regulatory), pin every tool to single-thread mode, pin the conda environment via OCI, and pin the input checksums. The provenance sidecar records all three.

### Cross-architecture determinism

Tools compiled with platform-specific SIMD paths (BWA-MEM2, some samtools builds) may take different code paths on Intel vs Apple Silicon vs ARM Linux, producing logically equivalent but non-bit-identical output. The arch field in `runtime.arch` lets a downstream auditor flag this.

### Cross-version determinism

Tool minor-version updates occasionally adjust internals (minimap2 has shifted soft-clip boundaries between versions; samtools has tightened indel-realignment in 1.20+). The provenance sidecar's `tool.version` field lets a re-runner detect drift. To guarantee a re-run uses the exact same tool versions, install the same plugin pack version that produced the original run.

## Container support

Lungfish supports two container runtimes for pinned-environment execution.

| Runtime | Platform | When to use |
|---|---|---|
| Apple Containers | macOS 26+, arm64 | Default on supported Macs; lower overhead, native filesystem access |
| Docker | macOS, Linux, cross-platform | Portable across teams with mixed environments |

The `lungfish bundle export <bundle> --format container --output <image>.oci.tar` command produces a deterministic OCI-layout tarball with bundle payload files, pinned plugin pack metadata, `oci-layout`, `index.json`, manifest, config, layer tar, and `.lungfish-provenance.json`. When a real image builder is available, the same CLI surface can wrap that runtime; test and offline builds still emit the deterministic OCI layout rather than a documentation-only placeholder. Pair this with a Nextflow export to get a reproducible pipeline that survives across machines and time.

## Multi-threading and chunking

The global `--threads <n>` flag sets the default thread count for parallel operations. Per-command flags override the global. For deterministic re-runs, fix threads to a specific number; multi-threaded callers are not bit-identical across thread counts on every input.

Operations that benefit from threading: `lungfish map` (minimap2/BWA-MEM2), `lungfish bam primer-trim` (samtools sort+index), `lungfish variants call --caller lofreq` (`lofreq call-parallel`), `lungfish assemble` (SPAdes, MEGAHIT, Flye, Hifiasm), `lungfish classify` (Kraken2). Operations that are single-threaded: `lungfish bundle create`, `lungfish import-fastq`, `lungfish variants call --caller ivar` (the iVar call itself, though mpileup upstream is multi-threadable).

For reservoir-sampling subset operations (`lungfish fastq subsample --count`), pass `--seed <int>` to make the draw reproducible.

## The Operations Panel as a debug tool

Every operation row in the Operations Panel is a debugging surface. Click the row to expand. The disclosure has these fields:

| Field | What it shows |
|---|---|
| Status | running, completed, failed, cancelled |
| Started / finished | UTC timestamps |
| Wall time | Duration |
| Command | Exact resolved CLI invocation |
| Steps | Per-process commands and exit statuses (multi-step pipelines) |
| Stderr | Last 100 lines of the operation's stderr |
| Provenance | Path to the sidecar JSON |
| Re-run as CLI | Button that copies the command to the clipboard |

For a failed operation, the stderr disclosure is the first place to look. For a completed operation that produced unexpected output, the command field is the second. For a debugging session that needs to reproduce a step in a different shell, "Re-run as CLI" gives you the exact invocation Lungfish ran, suitable for piping into a script.

## Pass-through arguments

Most Lungfish dialogs do not expose every flag of the underlying tool. To pass arbitrary flags through, use the CLI: `lungfish variants call --caller ivar --extra-args "--gff annotations.gff3 --pass_only"` (the `--extra-args` value is split and appended to the underlying command verbatim). Not every command supports `--extra-args`; check the per-command help.

For tools that need flags Lungfish does not yet wrap, the workaround is to run the tool directly with its conda environment activated:

```bash
source ~/.lungfish/conda/envs/ivar/bin/activate
ivar variants --my-new-flag-here
deactivate
```

This bypasses Lungfish's provenance recording, so a downstream `lungfish bam adopt-mapping` will not be able to verify the BAM came from the expected pipeline. Use sparingly.

## Next

See [CLI Reference](cli-reference.md) for the full command surface, [File Formats](file-formats.md) for bundle format details, and [Troubleshooting](troubleshooting.md) for failure modes.
