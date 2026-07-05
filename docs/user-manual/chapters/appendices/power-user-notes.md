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

The workflow chapters left things out on purpose. To keep them readable for a bench scientist, we stripped the tool internals and the reproducibility fine print. This appendix is where all of that lives. Every fact here is correct and load-bearing if you script Lungfish, wrap it in a Snakemake or Nextflow pipeline, or validate its output for clinical or regulatory use. None of it is secret. The same details sit inside the provenance sidecar Lungfish writes for every operation. Reading them here is simply faster than reverse-engineering a sidecar after the fact.

A word on conventions. This appendix uses `bash` blocks for canonical commands, `json` blocks for sidecar excerpts, and tables for flag references. The numbers and flag values match the current Lungfish build (0.5.0-alpha11). Future versions may adjust the defaults, and when they disagree with this page, the provenance sidecar for a specific run is the truth.

## iVar variant calling internals

The iVar variant caller in Lungfish is a two-process pipeline. First `samtools mpileup` walks the alignment and reports what every read says at each position. That pileup pipes straight into `ivar variants`, which decides which departures from the reference are real. Both commands land in the provenance sidecar's `steps[]` array, one entry apiece.

### Canonical samtools mpileup flags

For iVar amplicon calling, Lungfish runs samtools mpileup with exactly these flags:

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

If you assemble your own CLI run and call iVar directly, the flag people forget is `-d 600000`. Leave it out and a 1000x amplicon quietly hits the default ceiling of 8000. Nothing errors, but your allele-frequency math is now computed against the wrong denominator.

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

The `-g` flag is the switch that turns on codon-merge. Without it, iVar reports one row per position and stops there. With it, each row also carries codon annotation columns, and the Lungfish converter reads those columns to fold adjacent within-codon SNPs into a single VCF row.

### Codon-merge mechanics

The converter reads two fields from each iVar TSV row: which codon the base belongs to, and what that codon spells. When two adjacent SNPs point at the same codon, it fuses them into one VCF row with a multi-base REF and ALT. Take the SARS-CoV-2 N gene: position 28881 G→A and position 28882 G→A both sit inside codon 203, so the merged row reads `28881  GG  AA` instead of two single-base entries.

Position 28883 G→C belongs to codon 204, so it keeps its own row. The rule has two parts. It is positional, in that the two changes must fall inside one codon boundary, and it is content-aware, in that both must read as alternates of the same codon's bases. What the rule is not is phase-aware. iVar has no idea whether the two changes ride the same physical molecule. Collapsing them into one row is a way to make the codon boundary visible in the table, nothing more. When you actually need phased haplotypes, run `lungfish variants phase` to build a GATK HaplotypeCaller plus WhatsHap command plan, or pick the GATK+WhatsHap phased lane in the BAM Variant Calling dialog once the `gatk-core` and `phasing` packs are installed.

## LoFreq variant calling internals

LoFreq earns its keep by modeling per-base error and correcting for multiple testing. Behind the single button in the dialog, Lungfish actually runs it in three moves: preparing indel qualities, recalibrating alignment qualities, and finally calling the variants.

### LoFreq indelqual preprocessing

```bash
lofreq indelqual --dindel -f reference.fasta in.bam -o indelqual.bam
```

The `--dindel` mode recomputes per-base indel-quality scores using LoFreq's port of the Dindel algorithm. Skip it and LoFreq under-calls indels on purpose. Its statistical model expects those per-base indel qualities to be there, and a BAM straight out of `samtools sort` simply does not carry them.

So a hand-built pipeline that jumps straight to `lofreq call-parallel` will report far fewer indels than the data holds, and it will do so without a word of warning. Lungfish runs indelqual in every LoFreq pipeline. Yours must too.

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

LoFreq's significance threshold moves with depth, because the Bonferroni correction scales with the number of positions tested. On a 5000x amplicon pileup the per-position p-value bar rises steeply. That is the reason a low-frequency call iVar happily reports at high depth can be the same call LoFreq turns away.

### LoFreq strand-bias filter

LoFreq attaches a strand-bias score to every row (`SB` in the INFO field) and filters on it with a default Phred-scaled cutoff. Amplicon data trips this filter for a structural reason: primers pin reads to fixed positions, so the strand balance is lopsided by design, and LoFreq reads that lopsidedness as suspicious. The Lungfish convention is to hand LoFreq the un-trimmed BAM, where the asymmetry is uniform across the genome, rather than the primer-trimmed BAM, where soft-clipping leaves a residual skew the SB filter rejects. Shotgun viral data has no primers to trim, and there the SB filter is well calibrated.

## Provenance sidecar schema

Every operation that produces a file drops a `*.lungfish-provenance.json` sidecar beside it. Bundle-level operations add a `bundle.lungfish-provenance.json` at the bundle root that ties the per-step sidecars together. The schema holds steady across Lungfish versions. New fields only ever get added, never renamed or removed, so an old reader keeps working.

```json
{
  "schema_version": 2,
  "workflow": "variants.call.ivar",
  "version": "0.5.0-alpha11",
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

The `steps[]` array breaks a multi-process pipeline back into one entry per process. The `inputs[]` and `outputs[]` arrays record a SHA-256 checksum and a byte size for every file they touch. When a later workflow picks up one of these outputs, it re-reads those `inputs[]` records and checks the checksums against what is actually on disk before trusting the file.

Recent Lungfish builds also stamp each step with `peakMemoryBytes` whenever
the runner can observe peak resident memory. In the app, an operation row
keeps its wall time and peak RAM for as long as it is visible in the
Operations Panel. The sidecars on disk are the record that outlasts the
session.

To add up what completed operations cost across a project or an exported
bundle, run:

```bash
lungfish ops stats /path/to/project-or-bundle
```

It walks every `.lungfish-provenance.json` sidecar it can find, skips the
failed and cancelled runs, and reports the completed run count, the total
wall time, the average wall time per operation name, and the single largest
peak-RAM figure any step recorded.

## Plugin pack environment pinning

A plugin pack is a versioned recipe for a per-tool conda environment. The pack version pins the recipe itself: which tools, which channel constraints, which versions they were compiled against. What it does not pin is every transitive dependency underneath. Reinstall the same pack version six months from now and the solver may hand you slightly different sub-dependencies, simply because the upstream channels have moved on.

For bit-identical reproduction across machines, pair the provenance sidecar with one of:

- An OCI image artifact from `lungfish bundle export <bundle> --format container --output <bundle>.oci.tar`
- A conda lockfile from `lungfish conda lock --pack <name> --output lockfile.yml`
- A Snakemake / Nextflow export with lockfile or container references included

Without one of these, "same plugin pack version" promises the same recipe but not the same resolved environment. Clinical validation should take the OCI path every time. Research work can usually get by on the pack version alone.

### Conda lockfiles

`lungfish conda lock --pack <name> --output lockfile.yml` writes a
conda-lock-compatible YAML file for a built-in plugin pack. Inside are the
pack ID, the channels, the platforms, a content hash, and one package record
for every pinned requirement. Reinstall from it with:

```bash
lungfish conda install --from-lockfile lockfile.yml
```

Both commands leave a `.lungfish-provenance.json` beside their output or
conda root. The lock provenance captures the exact command, the pack
identity, the resolved channels and platforms, the output path, the runtime
identity, the exit status, and the wall time. The install provenance captures
the lockfile it read, the conda root it wrote to, the environment names it
created, the command line, the exit status, and the wall time.

## Determinism and reproducibility caveats

Run the same Lungfish command twice on the same inputs and you get identical output only under specific conditions. Those conditions are spelled out here so nobody assumes bit-for-bit reproduction that the setup was never going to deliver.

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

When a workflow truly demands bit-identical output, as clinical and regulatory ones do, pin all three things at once: every tool to single-thread mode, the conda environment through OCI, and the input checksums. The provenance sidecar already records all three, so you can prove after the fact that they held.

### Cross-architecture determinism

Some tools ship platform-specific SIMD code paths, BWA-MEM2 and certain samtools builds among them, and those paths can diverge across Intel, Apple Silicon, and ARM Linux. The output stays logically equivalent but is no longer byte-for-byte identical. The `runtime.arch` field is there so a downstream auditor can spot when two runs came off different architectures.

### Cross-version determinism

A minor version bump can quietly change how a tool behaves. minimap2 has shifted soft-clip boundaries between releases, and samtools tightened indel realignment in 1.20 and up. The `tool.version` field in each sidecar is how a re-runner catches that drift. To rule it out entirely, install the same plugin pack version that produced the original run.

## Container support

Lungfish works with two container runtimes for pinned-environment execution.

| Runtime | Platform | When to use |
|---|---|---|
| Apple Containers | macOS 26+, arm64 | Default on supported Macs; lower overhead, native filesystem access |
| Docker | macOS, Linux, cross-platform | Portable across teams with mixed environments |

`lungfish bundle export <bundle> --format container --output <image>.oci.tar` builds a deterministic OCI-layout tarball. Inside sit the bundle payload files, the pinned plugin-pack metadata, and the standard OCI furniture: `oci-layout`, `index.json`, the manifest, the config, the layer tar, and a `.lungfish-provenance.json`. When a real image builder is on hand, the same CLI wraps it. When one is not, as in test and offline builds, the command still writes the real deterministic OCI layout rather than a documentation-only stand-in. Pair it with a Nextflow export and you have a pipeline that reproduces across machines and across years.

## Multi-threading and chunking

The global `--threads <n>` flag sets the default thread count for parallel operations, and any per-command flag overrides it. For a deterministic re-run, nail threads to a fixed number. Multi-threaded callers do not produce bit-identical output across different thread counts on every input.

Threading helps these operations: `lungfish map` (minimap2/BWA-MEM2), `lungfish bam primer-trim` (samtools sort+index), `lungfish variants call --caller lofreq` (`lofreq call-parallel`), `lungfish assemble` (SPAdes, MEGAHIT, Flye, Hifiasm), and `lungfish conda classify` (Kraken2). These stay single-threaded: `lungfish bundle create`, `lungfish import-fastq`, and `lungfish variants call --caller ivar` (the iVar call itself, though the mpileup feeding it can be threaded).

`lungfish fastq subsample` has no `--seed` flag, and it does not need one. The `--count` path picks an exact number of reads through a deterministic two-pass selection, so the same input and the same count return the same reads every time. The available options are `--proportion`, `--count`, `-o`/`--output`, `--force`, and `--compress`.

## The Operations Panel as a debug tool

Every row in the Operations Panel doubles as a debugging surface. Click one to expand it, and the disclosure lays out these fields:

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

When an operation fails, read the stderr disclosure first. When one succeeds but produces something you did not expect, read the command field next. And when you need to reproduce a step in a fresh shell, "Re-run as CLI" copies out the exact invocation Lungfish ran, ready to drop into a script.

## Pass-through arguments

No dialog exposes every flag of the tool underneath it. When you need one that is missing, drop to the CLI: `lungfish variants call --caller ivar --extra-args "--gff annotations.gff3 --pass_only"`. Whatever you pass to `--extra-args` is split and appended to the underlying command verbatim. Not every command accepts it, so check the per-command help first.

When a tool needs a flag Lungfish does not wrap at all, the escape hatch is to run the tool yourself with its conda environment activated:

```bash
source ~/.lungfish/conda/envs/ivar/bin/activate
ivar variants --my-new-flag-here
deactivate
```

This route skips Lungfish's provenance recording entirely. A later `lungfish bam adopt-mapping` will have no way to confirm the BAM came from the pipeline it expected. Use it sparingly.

## Next

See [CLI Reference](cli-reference.md) for the full command surface, [File Formats](file-formats.md) for bundle format details, and [Troubleshooting](troubleshooting.md) for failure modes.
