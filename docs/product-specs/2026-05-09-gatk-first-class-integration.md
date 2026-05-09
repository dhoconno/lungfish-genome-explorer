# 2026-05-09 GATK First-Class Integration Product Spec

**Status:** Product spec
**Source requirements:** `docs/issues/2026-05-09-docs-039-gatk-first-class-integration.md`
**Audience:** Research-tier human germline users running single-sample short-read HaplotypeCaller and small/medium cohort joint genotyping.
**Out of scope for this spec:** Clinical/IVD validation, somatic calling, CNV, structural variants, liftover, pedigree-aware workflows, VQSR, annotation tools such as Funcotator/VEP/snpEff, GATK RNA-seq calling, and broad GATK walker coverage.

## Product Goal

Add GATK4 as an opt-in, first-class Lungfish capability for research-tier human germline variant calling. The experience should let a user install the required tool/reference packs, call per-sample GVCFs from read-grouped BAM tracks, assemble cohorts, joint-genotype, hard-filter, select variants, export tables, inspect results, and carry complete reproducibility provenance through every output.

Existing viral variant workflows remain unchanged. GATK is additive and should not make viral users install a large human-germline toolchain.

## Build Principles

- Keep the first release narrow: five GUI-facing operations plus a wrapped CLI tier.
- Prefer curated reference packs over asking users to hand-assemble Broad resource bundles.
- Default HaplotypeCaller to GVCF mode because joint genotyping is the load-bearing workflow.
- Treat cohorts as the new product abstraction; do not introduce a `.lungfishgvcf` bundle type for per-sample GVCFs.
- Reject invalid inputs before running GATK when Lungfish can detect them: missing read groups, non-human/no-dictionary reference, mixed sequence dictionaries, malformed sample IDs, or incompatible known-sites.
- Every command and dialog writes complete final-location provenance.

## CLI Surface

Add a new top-level command group:

```bash
lungfish gatk <subcommand>
```

### Dialog-Tier Commands

```bash
lungfish gatk haplotype-caller \
  --bundle <reference-bundle> \
  --alignment-track <track-id> \
  --emit-ref-confidence GVCF|NONE \
  --ploidy 2 \
  --intervals <bed-or-interval-list-or-contig> \
  --pcr-indel-model NONE|CONSERVATIVE|AGGRESSIVE|HOSTILE \
  --threads 4 \
  --memory-gb <auto-or-number> \
  --output-name <name> \
  --extra-args "<verbatim-passthrough>"
```

Defaults: `--emit-ref-confidence GVCF`, `--ploidy 2`, no intervals, `--threads 4`, memory autoscaled to 80% physical RAM capped at 16 GB. `--pcr-indel-model` defaults from the library setting: `CONSERVATIVE` for PCR-amplified exome, `NONE` for PCR-free WGS. Assumption: the implementation will need an explicit library-type input if current mapping metadata cannot infer this reliably.

```bash
lungfish gatk joint-genotype \
  --bundle <reference-bundle> \
  --cohort <cohort-folder> \
  --intervals <bed-or-interval-list-or-contig> \
  --combine-strategy auto|combine-gvcfs|genomicsdb \
  --standard-min-confidence-threshold-for-calling 30.0 \
  --output-name <name> \
  --extra-args "<verbatim-passthrough>"
```

Defaults: `auto` routes cohorts of 50 samples or fewer to `CombineGVCFs` and cohorts above 50 to `GenomicsDBImport`, then always runs `GenotypeGVCFs`.

```bash
lungfish gatk filter \
  --vcf <input-vcf> \
  --preset best-practices-snp|best-practices-indel|best-practices-both|custom \
  --custom-snp-expression "..." \
  --custom-indel-expression "..." \
  --output-name <name>
```

Presets must match docs-039 exactly for SNP and indel hard filters.

```bash
lungfish gatk select \
  --vcf <input-vcf> \
  --sample <sample-id> \
  --type SNP|INDEL|MIXED \
  --intervals <bed-or-interval-list-or-contig> \
  --output-name <name>
```

```bash
lungfish gatk variants-to-table \
  --vcf <input-vcf> \
  --fields CHROM,POS,REF,ALT,QUAL,AF,DP \
  --output <tsv>
```

### Wrapped CLI Tier

```bash
lungfish gatk bqsr \
  --bundle <reference-bundle> \
  --alignment-track <track-id> \
  --known-sites <vcf-or-list> \
  --intervals <bed-or-interval-list-or-contig> \
  --output-name <name>

lungfish gatk markdup \
  --bundle <reference-bundle> \
  --alignment-track <track-id> \
  --output-name <name>

lungfish gatk validate-sam \
  --bundle <reference-bundle> \
  --alignment-track <track-id>

lungfish gatk leftalign \
  --vcf <input-vcf> \
  --bundle <reference-bundle> \
  --output-name <name>

lungfish gatk collect-metrics \
  --vcf <input-vcf> \
  --bundle <reference-bundle> \
  --known-sites <dbsnp-vcf> \
  --intervals <bed-or-interval-list-or-contig>
```

Every wrapped subcommand accepts `--extra-args` unless doing so would conflict with the program-wide `docs-021` policy. Pack selection is implicit: missing `gatk-core` produces a clear install message, not a raw executable-not-found error.

## Workflow and Service Architecture

### Command Layer

**Likely owners:**

- Create `Sources/LungfishCLI/Commands/GatkCommand.swift`
- Register the group in `Sources/LungfishCLI/LungfishCLI.swift`
- Reuse CLI output and provenance support from `Sources/LungfishCLI/Output/` and `Sources/LungfishCLI/Support/CLIProvenanceSupport.swift`

The CLI should construct typed request models and call workflow services. It should not build shell strings ad hoc in command handlers.

### Workflow Layer

**Likely owners:**

- Create `Sources/LungfishWorkflow/Variants/Gatk/` for request models, command builders, preflight, execution, cohort manifests, and hard-filter presets.
- Reuse `Sources/LungfishWorkflow/Native/NativeToolRunner.swift` for process execution.
- Reuse/extend `Sources/LungfishWorkflow/Conda/CondaManager.swift`, `PluginPack.swift`, and pack status services for `gatk-core`.
- Reuse `Sources/LungfishWorkflow/Variants/VariantSQLiteImportCoordinator.swift` and `Sources/LungfishIO/Bundles/VariantDatabase.swift` for imported hard-call and joint VCFs.

Core service boundaries:

- `GatkToolLocator`: resolves `gatk`, `bgzip`, `tabix`, and related dependencies from managed packs.
- `GatkCommandBuilder`: builds argv arrays for each wrapped command and exposes resolved defaults for provenance.
- `GatkPreflight`: validates read groups, reference dictionaries, interval files, known-sites indexes, sample IDs, and pack/reference availability.
- `GatkHaplotypeCallerPipeline`: stages inputs, runs HaplotypeCaller, indexes outputs, imports VCF/GVCF metadata, and writes sidecar.
- `GatkJointGenotypingPipeline`: scans cohorts, routes combine strategy, runs `CombineGVCFs` or `GenomicsDBImport`, runs `GenotypeGVCFs`, optionally chains filtering, and writes cohort sidecar.
- `GatkVariantFiltrationPipeline`, `GatkSelectVariantsPipeline`, `GatkVariantsToTablePipeline`: single-step wrappers with output attachment/import behavior.
- `CohortManifestStore`: owns cohort manifest read/write, sidecar checksum references, sample-name normalization maps, and source-project links.

### App Layer

**Likely owners:**

- Create `Sources/LungfishApp/Views/Variants/Gatk/`
- Wire menu/sidebar actions from `Sources/LungfishApp/App/MainMenu.swift` and existing variant-calling surfaces.
- Surface progress through `OperationCenter.shared.update()` and `OperationCenter.shared.log()`.
- Extend Inspector analysis sections under `Sources/LungfishApp/Views/Inspector/Sections/`.
- Extend variant result viewers under `Sources/LungfishApp/Views/Viewer/` as needed for multi-sample cohort VCFs.

Dialogs:

- `GatkHaplotypeCallerDialog.swift`: reference bundle, alignment track, ERC mode, ploidy, intervals, library/PCR setting, threads, memory, advanced extra args. Run disabled with clear reasons when preflight fails.
- `GatkJointGenotypeDialog.swift`: cohort picker, GVCF count, interval-set summary, combine strategy, threshold, allele-specific annotations, optional hard-filter chain.
- `GatkVariantFiltrationDialog.swift`: SNP, indel, joint presets and custom expression editor.
- `GatkSelectVariantsDialog.swift`: VCF picker, sample dropdown from header, type selector, intervals.
- `Tools > Export Variants as Table`: invokes `variants-to-table` without a full standalone sidebar tile.

### Cohort Model

Add a `Cohorts/` project folder convention. A cohort folder contains:

- `manifest.json`
- `samples/` entries for per-sample GVCFs, indexes, and provenance sidecars or links to source projects
- `joint-call.vcf.gz` and `.tbi` after joint genotyping
- `joint-call.sidecar.json`
- Optional GenomicsDB workspace under a predictable subdirectory when the routed strategy uses GenomicsDB

Cohort manifests record sample ID, normalized sample ID, source project, source GVCF path, GVCF checksum, source sidecar checksum, interval set, reference dictionary checksum, GATK version, BQSR known-sites checksums when applicable, and original display name.

## Plugin and Reference Packs

### Tool Pack

Create an opt-in `gatk-core` managed conda pack containing GATK4 and its direct runtime dependencies. Do not add GATK to the existing viral `variant-calling` pack.

Pack requirements:

- Installed by `lungfish conda install --pack gatk-core`
- Listed in Plugin Manager with subtitle "for human germline variant calling"
- Validated by `gatk --version` on first launch/install
- Reported by `lungfish conda info gatk-core` with installation date, version, size, and known-issues link
- Updated independently from the existing `variant-calling` pack

The chapter-level install command should be:

```bash
lungfish conda install --pack variant-calling gatk-core
```

### Reference Packs

Create optional reference packs, installed through Plugin Manager:

- Default: `human-grch38-gatk`
- Legacy: `human-grch37-gatk`

`human-grch38-gatk` contains:

- `Homo_sapiens_assembly38.fasta`, `.fai`, and `.dict`
- `Homo_sapiens_assembly38.dbsnp138.vcf.gz` and `.tbi`
- `Mills_and_1000G_gold_standard.indels.hg38.vcf.gz` and `.tbi`
- `wgs_calling_regions.hg38.interval_list`
- One canonical exome BED, with attribution and license review before shipping

Reference pack manifests must record upstream source, upstream hashes, Lungfish pack version, file sizes, install date, and verification status. The implementation must confirm hosting/CDN strategy before announcing the 4 GB class download in user-facing docs.

Add project folder convention `Intervals/`. Dropped `.bed` and `.interval_list` files appear in all GATK interval pickers; reference-pack intervals are available without manual copying.

## Provenance Additions

All GATK outputs must satisfy the global provenance requirements and add GATK-specific fields.

### Per-Sample HaplotypeCaller Sidecar

Required fields:

- `tools[]` entry with tool name `gatk-haplotype-caller`, GATK version, pack ID/version, command, argv, and resolved defaults.
- Inputs: reference FASTA/dictionary, BAM/BAI, alignment track ID, intervals if present, known-sites if used, checksums and file sizes.
- Options: ERC mode, ploidy, interval source, PCR indel model, threads, memory cap, extra args.
- Runtime: user, host, OS, conda environment path or identity, wall time, exit status, stderr summary.
- Outputs: GVCF or VCF, index, sidecar path, checksums, file sizes.

### Cohort Sidecar

Add:

- `cohort.gvcfs[]`: sample, normalized sample ID, source GVCF path, GVCF SHA-256, source sidecar SHA-256, reference dictionary SHA-256, GATK version.
- `cohort.combineStrategy`: selected strategy, auto threshold, routed strategy, GenomicsDB workspace path when applicable.
- `cohort.sampleNameMap`: original-to-normalized names when normalization changes user-visible sample IDs.
- `cohort.knownSites[]`: dbSNP/Mills/custom known-sites checksums when BQSR or metrics participate.

### Other GATK Sidecars

- VariantFiltration records filter expressions verbatim.
- SelectVariants records sample/type/interval selectors.
- BQSR records all known-sites VCF checksums.
- CollectVariantCallingMetrics writes metrics into the VCF/result sidecar and records dbSNP version/checksum.

Assumption: docs-039 references `docs/spec/provenance-schema.md`, but the current repository listing did not show `docs/spec/`. Implementation should create the schema location or update the issue if the canonical schema path differs.

## UI Surfaces

### Navigation

- A "GATK" group appears in the tool sidebar below existing variants once `gatk-core` is installed.
- Menu entries:
  - `Tools > Variant Calling > GATK HaplotypeCaller`
  - `Tools > Variant Calling > GATK Joint Genotype Cohort`
  - `Tools > Variant Calling > GATK VariantFiltration`
  - `Tools > Variant Calling > GATK SelectVariants`
  - `Tools > Export Variants as Table`
- Plugin Manager lists `gatk-core`, `human-grch38-gatk`, and `human-grch37-gatk`.

### Inspector and Variant Browser

- Inspector analysis sections surface GATK tool name/version, command line, ERC mode, ploidy, intervals, known-sites versions/checksums, and resolved pack/reference versions.
- The variant browser handles joint VCFs up to 50 samples in the first release, with a sample selector and row inspector access to GT/AF/DP fields.
- Scaling beyond 50 samples is owned by `docs-024` and is a follow-on unless implementation proves the current UI handles it without degradation.

### Operations Panel

- HaplotypeCaller progress must not block the main thread and must support cancel.
- Joint genotyping shows combine/import and genotype phases as expandable operation steps.
- Operation rows call both `OperationCenter.shared.update()` and `OperationCenter.shared.log()` where the existing app pattern requires both.

## Edge Cases and Guardrails

The implementation must handle these before release:

- Mixed reference dictionaries in a cohort: refuse at cohort assembly time.
- Existing partial GenomicsDB workspace: prompt to resume, restart, or rename; never reuse silently.
- Sample IDs with whitespace, slashes, apostrophes, or unsupported characters: normalize to `[A-Za-z0-9_.-]+`, record the map, and warn.
- Read-group `SM` mismatch with cohort sample name: refuse to add the GVCF.
- Mixed BQSR known-sites checksums: refuse joint genotyping unless a deliberate override exists.
- Exome-like coverage with no intervals: warn before running whole-reference HaplotypeCaller.
- Custom filter missing-value semantics: document caveats in expression-editor tooltips.
- Single-sample cohort: allow it.
- File descriptor limits for larger GenomicsDBImport: attempt to raise limits and record prior/current values when relevant.
- Mixed GATK major/minor versions among GVCFs: warn before joint genotyping.

## Test Plan

### Unit Tests

- `Tests/LungfishWorkflowTests/GatkHaplotypeCallerCommandLineTests.swift`: command construction and defaults.
- `Tests/LungfishWorkflowTests/GatkJointGenotypeRoutingTests.swift`: auto route at 49, 50, and 51 samples.
- `Tests/LungfishWorkflowTests/GatkVariantFiltrationPresetTests.swift`: exact SNP/indel hard-filter expressions.
- `Tests/LungfishCoreTests/CohortManifestTests.swift`: manifest round trip, sample normalization, sidecar references.
- `Tests/LungfishWorkflowTests/GatkPreflightTests.swift`: read-group, dictionary, known-sites, interval, and sample-name validation.

### CLI Tests

- `Tests/LungfishCLITests/GatkCLITests.swift`: smoke tests for every subcommand and clear missing-pack errors.
- Verify `--extra-args` records top-level `extra_args` and rejects conflicts with first-class flags.
- Verify provenance sidecars are written to final output locations.

### App Tests

- Dialog state tests for every GATK dialog under `Tests/LungfishAppTests/`.
- Menu wiring tests for GATK actions and `Tools > Export Variants as Table`.
- Inspector tests for the GATK analysis section.
- OperationCenter progress/log tests for per-sample and cohort runs.

### Integration Tests

- `Tests/Fixtures/human-na12878-chr22-subset/`: downsampled GIAB NA12878 chr22 fixture, truth VCF, confidence BED, and reference subset. Fixture licensing and size must be approved before committing.
- `Tests/LungfishIntegrationTests/GatkHaplotypeCallerFixtureTests.swift`: run HaplotypeCaller and assert header dictionary, record counts, and selected positions.
- `Tests/LungfishIntegrationTests/GatkJointGenotypingFixtureTests.swift`: three-sample joint call and concordance target where fixture supports it.
- `Tests/LungfishIntegrationTests/GatkBqsrFixtureTests.swift`: BQSR with bundled known-sites and ValidateSamFile.
- Larger human fixture remains artifact-server/download-on-demand only.

## Documentation and Help Plan

Manual updates are implementation work, not part of this spec-only branch. When implementation lands:

- Add human germline GATK chapters without renumbering chapters in this task.
- Add scope notes to existing viral variant chapters so users understand when to use GATK.
- Add reference-pack and installation instructions for `gatk-core` and `human-grch38-gatk`.
- Update plugin-pack tables, tool-version references, and help IDs:
  - `dialog.GatkHaplotypeCaller`
  - `dialog.GatkJointGenotype`
  - `dialog.GatkVariantFiltration`
  - `dialog.GatkSelectVariants`
  - `viewport.CohortBrowser`
  - `pack.gatk-core`
  - `pack.human-grch38-gatk`
- Document out-of-scope items explicitly: clinical/IVD, somatic, CNV, SV, pedigree, VQSR, annotation.

## Phased Milestones

### Phase 0: Prerequisites

- Ship full read-group mapping support from `docs-014`.
- Ship tool-version table/CLI from `docs-029`.
- Ship uniform `--extra-args` policy from `docs-021`.
- Confirm provenance schema path and update schema ownership.
- Confirm GATK package pin availability on bioconda and reference-pack hosting feasibility.

### Phase 1: Pack and Command Foundation

- Add `gatk-core` pack definition, install, validation, Plugin Manager listing, and `lungfish conda info`.
- Add `GatkCommand.swift` with missing-pack errors and command-builder unit tests.
- Add `GatkToolLocator`, `GatkCommandBuilder`, and `GatkPreflight`.
- Add provenance writers for single-step GATK operations.

### Phase 2: Single-Sample HaplotypeCaller

- Implement `lungfish gatk haplotype-caller`.
- Build HaplotypeCaller dialog and Inspector section.
- Attach per-sample GVCF/VCF outputs to the project.
- Add unit, CLI, app, and small fixture integration coverage.

### Phase 3: Reference Packs and Intervals

- Add `human-grch38-gatk` install/verify flow and reference-pack manifest.
- Add `Intervals/` project convention and interval picker support.
- Auto-attach dbSNP/Mills/WGS intervals where the selected reference pack provides them.
- Add custom known-sites file picker/CLI paths.

### Phase 4: Cohorts and Joint Genotyping

- Add `Cohorts/` project convention, sidebar model, and manifest store.
- Implement cohort assembly from per-sample GVCFs.
- Implement `joint-genotype` auto routing and dialog.
- Write cohort sidecar with per-sample checksum ancestry.
- Add cancellation and partial GenomicsDB workspace behavior.

### Phase 5: Filtering, Selection, and Exports

- Implement VariantFiltration presets and custom expressions.
- Implement SelectVariants and VariantsToTable.
- Wire `Tools > Export Variants as Table`.
- Ensure filtered/select outputs import cleanly into the variant browser and preserve provenance.

### Phase 6: Workflow Export Interop

- Export cohort workflows toward nf-core/sarek-compatible sample sheets after the general Workflow Builder/export provenance work is ready.
- Include GATK/reference pack versions and sidecar ancestry in the export.

## Release Criteria

- `gatk-core` and `human-grch38-gatk` install, validate, and report status.
- HaplotypeCaller, joint genotyping, VariantFiltration, SelectVariants, and VariantsToTable work from CLI and intended GUI surfaces.
- Missing prerequisites fail with clear, user-facing errors.
- All GATK outputs write complete final-location provenance.
- Integration tests pass on the approved small human fixture.
- Manual/help IDs describe the implemented behavior and out-of-scope boundaries without changing chapter numbering in this task.
