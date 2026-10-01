# Provenance Export Fidelity Plan (2026-09-30)

> **For agentic workers:** TDD with small synthetic sidecar fixtures; targeted `swift test --filter` only.

**Goal:** Make `provenance export` (methods, Snakemake, Nextflow, shell, Python) and the Inspector lineage view usable by a scientist: one description per tool, honest version strings, no internal staging steps, portable paths and environments, and a lineage that starts at the reads.

**Reproduction:** `~/Desktop/lge-docs/screencast/HG002 chr20.lungfish` (copy of the "Human Mapping and Variants (with results)" demo), variant track `vc-7bcd2f90-...`.

## Root causes

1. **Methods repetition.** `ProvenanceExporter.exportMethods` writes one sentence and one table row per *step*; five bcftools invocations become five sentences. `WorkflowRun.primaryInputFiles` returns the inputs of every step with an empty `dependsOn` (pipelines rarely record `dependsOn`), so intermediates and duplicates are listed as inputs.
2. **Version strings.** Two layers. (a) Recording: `ViralVariantCallingPipeline` stamps internal staging steps with `WorkflowRun.currentAppVersion` (`Lungfish dev (0)` on the dev build that made the demo; now `Lungfish <ver> (dev)`), and `VariantsCommand`, `TranslateCommand`, `SearchCommand`, `ConvertCommand` record `toolVersion: "lungfish-cli <ver>"`, repeating the tool name inside the version. (b) Formatting: `exportMethods` prints `v\(toolVersion)` unconditionally, so `vLungfish dev (0)` and `vlungfish-cli 2026.9.52`. The managed-tool parenthetical (`1.24 (managed conda environment ...; package bioconda::...)`) is never parsed, so the package pin is unusable and the table is unreadable.
3. **Staging steps.** The variant pipeline records `lungfish-internal stage-alignment` (symlink) and `stage-reference` (decompress) as steps with argv, and every renderer treats a step with argv as replayable. `bcftools mpileup` and `bcftools call` are joined by a `pipe:stdout:bcftools-mpileup` pseudo-file, which the Snakefile renders as a literal output path.
4. **Portability.** The demo sidecars predate `PortablePath` (landed 2026-09-28; demo built 2026-09-27 and shipped as 2026.9.58 without a rebuild), so they carry the build machine's `/tmp/lge-demo-build/...` project path, `/var/folders/.../T/variants-UUID/workspace/...` scratch paths and the scratchpad conda prefix. Even a portable record resolves `@/...` and `<tool-root>/...` back to *this* machine's absolute paths on load, and the exporters write those absolute paths and executables verbatim. The Snakefile header says `--use-singularity`; nothing declares the conda environments the record already knows (`package bioconda::bcftools=1.24=h6bd33b9_2`).
5. **Lineage does not chain.** `ProvenanceExporter.expandProvenanceChain` follows input descriptors by absolute path through `ProvenanceRecorder.findProvenanceEnvelope`; a foreign absolute path resolves nothing, and there is no checksum matching. `ProvenanceInspectorViewModel.buildPresentState` shows only the selected record (`lineageRuns = [one run]`).
6. **Run Inputs show build-machine paths (coordinator finding).** Same cause as 4: legacy records hold another machine's project root and the reader does not re-root them.

## Design

### A. `ProvenanceExportPlan` (new, `Sources/LungfishWorkflow/Provenance/ProvenanceExportPlan.swift`)

A pure transform from the merged `WorkflowRun` to export-ready steps, shared by every renderer:

- **Tool identity.** `ProvenanceToolIdentityText.parse(toolName:toolVersion:)` → `(version, environment?)` where the version drops a leading `Lungfish `, `lungfish-cli ` or the tool's own name, and the parenthetical yields `environment` = conda env name, executable, package spec. Display rule: `v1.24` only when the version starts with a digit.
- **Staging collapse.** A step whose argv[0] is `lungfish-internal` and whose every output is byte-identical (same SHA-256) to one of its inputs is an alias step: each output path maps to its input path, transitively, and the step disappears from every export. `stage-reference --mode decompress-gzip` keeps a step but becomes `gzip -dc <in> > <out>`. Other `lungfish-internal` steps are in-app (not replayed, named in the header, as today for GUI steps).
- **Pipe merge.** A step with output `pipe:stdout:X` and the step with input `pipe:stdout:X` become one export step `A | B`, inputs and outputs unioned without the pipe.
- **Path mapping.** For each path: inside any `<name>.lungfish/` root (recorded or current) → project-relative tail; produced by a step and outside a project → `results/<name>` (parent folder added on collision); external input → pipeline parameter with the recorded path as default. Nextflow uses bare file names (it stages inputs by name). Executables: an absolute argv[0] whose basename is the tool becomes bare; `micromamba run -n X` prefixes are stripped, the env becomes the step's environment.
- **Environments.** Snakemake: `envs/<env>.yaml` per environment plus `conda:` per rule and header `snakemake --cores 8 --software-deployment-method conda`. Nextflow: `conda '<spec>'` per process and `conda.enabled = true`. Shell/Python: a header block with `micromamba create -n lge-<env> -c conda-forge -c bioconda <spec>` lines.

### B. Methods renderer

Groups export steps by tool in pipeline order; one paragraph sentence per tool listing its subcommands and recorded key parameters (`--ploidy 2`, min AF / depth from `bcftools view -i`, threads). Tool Versions table has one row per distinct tool with version, package pin and environment. Input Files lists only files no step produced, once each. LGE itself is named once in Reproducibility.

### C. Lineage (`ProvenanceLineageResolver`, new)

Given a sidecar, indexes every provenance sidecar in the enclosing project (bounded, cached, unreadable files skipped) by output SHA-256 and by path, then walks inputs upstream: path match first (after re-rooting), checksum match second. Cycle guard by sidecar path and envelope id; duplicate runs (`mapping-provenance.json` copies) deduplicated by envelope id and by step signature. `ProvenanceExporter.expandProvenanceChain` and `ProvenanceInspectorViewModel` both use it; the Inspector shows upstream runs first, roots at the top.

### D. Legacy path re-rooting on read (`PortablePath.rerootForeignProjectPaths`)

When a record inside project P holds an absolute path with a `<name>.lungfish/` component and the tail exists under P, the reader rewrites it to `P/tail`. Applied in `ProvenanceEnvelopeReader` and `MappingProvenance.load`. Write-time fix already exists (`PortablePath` sanitizer); shipped demos need a rebuild (reported, not done here).

### E. Recording fixes

`WorkflowRun.currentAppReleaseVersion` (bare version); internal steps and `lungfish-cli` steps record it as `toolVersion`.

## Tasks

- [ ] Failing tests: `ProvenanceExportFidelityTests` (methods grouping, version text, staging collapse, pipe merge, portability, conda env files), `ProvenanceLineageResolverTests` (chain by checksum, by re-rooted path, cycle, unreadable), `PortablePathRerootTests`, Inspector lineage test.
- [ ] Implement A, B, C, D, E; regenerate goldens; `snakemake -n` and `nextflow lint` on them.
- [ ] Manual chapter `08-workflows/02-exporting-as-nextflow-or-snakemake.md`: paths, `--software-deployment-method conda`, methods no longer repeats, lineage; lint strict.
- [ ] Real-data acceptance on the screencast copy; report.
