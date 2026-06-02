# Ground-Truth Reality Map: 06-human-germline-variants (Preview)

Generated 2026-06-02. Arbiter-of-truth comparison of chapter CLAIMS against
actual Swift source and CLI help. No build performed. CLI help captured from
`.build/debug/lungfish-cli` (built Jun 2 06:39).

**Headline finding:** The four chapters frame the entire GATK feature set as
"dry-run / command-construction only" and repeatedly assert "does not run
GATK." This is now FALSE. Every `lungfish gatk` subcommand has a real
`--execute` flag that runs GATK through the managed `gatk-core` conda
environment via `GATKPipelineExecutor` and writes provenance
(`Sources/LungfishCLI/Commands/GATKCommand.swift:37-52`,
`Sources/LungfishWorkflow/Variants/GATKPipelineExecutor.swift:691-727`).
Additionally, GATK HaplotypeCaller executes from the GUI (BAM variant-calling
dialog / Inspector variant workflow), which the chapters never mention.

---

## 01-haplotype-caller.md

### 1. CLAIMS THAT DO NOT MATCH CODE

- **Doc title + claim: "HaplotypeCaller Dry Runs" / "it does not run GATK and
  does not create a VCF" (line 1, lines 27-28).** The CLI subcommand has both
  `--execute` and `--dry-run` flags. With `--execute` (and without
  `--dry-run`) GATK actually runs.
  Cite: `GATKCommand.swift:95-99` (HaplotypeCallerSubcommand `execute` /
  `dryRun` flags), `GATKCommand.swift:43-52` (`runOrPreview`: `guard execute
  else { emit preview }` then `GATKPipelineExecutor(runner:).run(request)`),
  `GATKCommand.swift:155` (`ManagedGATKCommandRunner()`). CLI help confirms:
  `--execute  Run GATK and write final-location provenance.`

- **Doc claim: "Because no scientific output is written, there is no output
  bundle provenance to record yet" (lines 53-54).** When `--execute` runs,
  provenance IS written. `GATKPipelineExecutor.run` calls `writeProvenance(...)`
  and returns `result.provenanceURL`; the CLI prints `Provenance: <path>`.
  Cite: `GATKPipelineExecutor.swift:714-726`, `GATKCommand.swift:50-51`.

- **Frontmatter: `entry_points: ["CLI: lungfish gatk haplotype-caller"]`
  (line 11).** The CLI entry point is correct, but the chapter omits the GUI
  entry point that also runs HaplotypeCaller. See "App features missing" below.

### 2. APP FEATURES MISSING FROM THE DOCS

- **`--execute` flag and managed execution.** Entire execution path
  undocumented (treated as nonexistent). `GATKCommand.swift:95-96, 174`.

- **GUI HaplotypeCaller execution.** A GUI BAM variant-calling tool
  `gatk-haplotype-caller` ("GATK HaplotypeCaller", "Germline SNP and indel
  calling with standard VCF genotypes") runs HaplotypeCaller on a bundle BAM,
  emits `emitReferenceConfidence: .none`, writes `variants/gatk/<id>.vcf.gz`,
  and attaches it as a variant track.
  Cite: `Sources/LungfishApp/Views/BAM/BAMVariantCallingCatalog.swift:15,30-31,167-168`,
  `Sources/LungfishApp/Views/BAM/BAMVariantCallingDialogState.swift:380-396`,
  `Sources/LungfishApp/Views/Inspector/InspectorViewController+VariantWorkflow.swift:224-248`.

- **Promoted tuning flags not listed in chapter prose.** `--pcr-indel-model`
  (default CONSERVATIVE), `--stand-call-conf` (default 30.0),
  `--max-alternate-alleles` (default 6), `--pair-hmm-threads` (default 4),
  `--ploidy` (default 2), `--emit-ref-confidence` (default GVCF). The chapter
  says "explicit defaults for the main tuning flags" but names none.
  Cite: `GATKCommand.swift:110-129`.

### 3. UNCERTAIN / NEEDS-HUMAN-CHECK

- The chapter's "Coming soon" admonition ("Full execution workflows ... are on
  the way") may be a deliberate editorial choice to under-promise a
  preview/experimental feature: the `gatk-core` pack is flagged
  `isExperimental: true` (`Sources/LungfishWorkflow/Conda/PluginPack.swift:455`).
  Human should decide whether to document `--execute` as a real-but-experimental
  capability or keep the dry-run framing. Either way the flat "does not run
  GATK" statements are factually wrong as written.

- Whether `--execute` GATK runs are intended to be user-facing in this manual
  slice, or internal/testing-only, is a product decision (`executeForTesting`
  naming at `GATKCommand.swift:152` suggests test-first design, but `run()` at
  line 148 wires the real path for end users).

---

## 02-joint-genotyping.md

### 1. CLAIMS THAT DO NOT MATCH CODE

- **Doc title + claim: "Joint Genotyping Dry Runs" / "Lungfish can construct
  the command sequence without running it" / "These dry runs do not import
  GenomicsDB workspaces, write VCFs, or attach variant tracks" (line 1, lines
  26-27, lines 58-59).** The `joint-genotype` subcommand has `--execute` and
  runs `CombineGVCFs`/`GenomicsDBImport` + `GenotypeGVCFs` through the managed
  environment when executed.
  Cite: `GATKCommand.swift:214-217` (execute/dryRun flags),
  `GATKCommand.swift:265-274` (`runOrPreview ... execute: execute && !dryRun`),
  `Sources/LungfishWorkflow/Variants/GATKCommandBuilder.swift:416-423`
  (`jointGenotypingCommands` switch).

- **Doc claim: "CombineGVCFs for cohorts up to 50 samples and GenomicsDBImport
  above that threshold" (lines 38-39).** ACCURATE. Threshold constant is 50 and
  resolution is `sampleCount <= 50 ? .combineGVCFs : .genomicsDB`.
  Cite: `GATKCommandBuilder.swift:380` (`jointGenotypingCombineGVCFsThreshold =
  50`), `GATKCommandBuilder.swift:408-413`. No discrepancy; recorded as a
  verified-correct claim.

### 2. APP FEATURES MISSING FROM THE DOCS

- **`--execute` execution of the full combine + genotype sequence.** When run,
  `GATKPipelineExecutor` executes each command in `request.commands` in order
  and writes provenance for the multi-step run.
  Cite: `GATKPipelineExecutor.swift:695-712`, `GATKCommandBuilder.swift:582-615`.

- **`--combine-strategy` accepts `auto`, `combine-gvcfs`, `genomicsdb`** and
  defaults to `auto`. The chapter mentions `auto` and `genomicsdb` but never
  lists the literal `combine-gvcfs` value as a forceable option.
  Cite: `GATKCommand.swift:232-233`, CLI help line `auto, combine-gvcfs, or
  genomicsdb (default: auto)`.

### 3. UNCERTAIN / NEEDS-HUMAN-CHECK

- Same experimental-vs-shipping framing question as chapter 01: human should
  confirm whether to document execution. The "Any future execution workflow
  must preserve provenance" sentence (lines 60-61) is satisfied today by
  `GATKPipelineExecutor.writeProvenance` (`GATKPipelineExecutor.swift:729-766`),
  so the "future" framing is stale.

---

## 03-filtering-selecting-and-metrics.md

### 1. CLAIMS THAT DO NOT MATCH CODE

- **Doc title + claim: "Filtering, Selecting, and Metrics Dry Runs" / "The
  printed command is meant for review, logging, and workflow integration tests
  before real execution support is added" / "These commands do not write
  normalized VCFs, filtered VCFs, tables, or metrics files" (line 1, lines
  65-67, lines 70-72).** `filter`, `select`, `leftalign`, and `collect-metrics`
  each have `--execute` and run the corresponding GATK/Picard tool when
  executed. Execution support already exists.
  Cite: `GATKCommand.swift:307-310` (filter), `GATKCommand.swift:388-391`
  (select), `GATKCommand.swift:878-881` (leftalign), `GATKCommand.swift:984-987`
  (collect-metrics); all route through `runOrPreview` with `execute: execute &&
  !dryRun`.

- **Doc shows `gatk select ... --type SNP` (line 40).** ACCURATE. `--type`
  accepts `SNP`, `INDEL`, `MIXED` (uppercased and mapped to
  `GATKSelectedVariantType`). No discrepancy.
  Cite: `GATKCommand.swift:400-401, 453`.

- **Doc `filter --preset best-practices-both` (line 34).** ACCURATE. Presets
  are `best-practices-snp`, `best-practices-indel`, `best-practices-both`
  (default both).
  Cite: `GATKCommand.swift:316-317`, CLI help confirms.

### 2. APP FEATURES MISSING FROM THE DOCS

- **`variants-to-table` subcommand is entirely undocumented in this chapter.**
  It builds a Picard/GATK `VariantsToTable` command (default fields
  `CHROM,POS,REF,ALT,QUAL,AF,DP`) and the entry-points frontmatter omits it.
  Cite: `GATKCommand.swift:471-487`, top-level `gatk --help` lists
  `variants-to-table`.

- **`leftalign` tuning flags not described:** `--split-multi-allelics`,
  `--max-indel-length` (default 200), `--max-leading-bases` (default 1000). The
  chapter shows `--split-multi-allelics` in an example but does not document the
  numeric defaults.
  Cite: `GATKCommand.swift:896-903`.

- **`collect-metrics --gvcf-input` flag** (treat input as GVCF) is undocumented.
  Cite: `GATKCommand.swift:1002-1003`.

- **`--execute` execution for all four (plus variants-to-table).** Undocumented.

### 3. UNCERTAIN / NEEDS-HUMAN-CHECK

- The chapter scopes itself to `filter`, `select`, `leftalign`,
  `collect-metrics` (frontmatter line 10-14) but the `gatk` command also exposes
  `bqsr`, `markdup`, `validate-sam`, and `variants-to-table`. Human should
  decide whether those belong in this chapter or chapter 04 (bqsr is shown in
  chapter 04). `bqsr` and `markdup`/`validate-sam` currently have no chapter
  home for their full flag set.
  Cite: `GATKCommand.swift:561-665` (bqsr), `:667-767` (markdup), `:769-870`
  (validate-sam).

---

## 04-reference-packs.md

### 1. CLAIMS THAT DO NOT MATCH CODE

- **Doc claim: "Lungfish does not ship a human reference pack in this dry-run
  slice" (lines 37-38).** ACCURATE as stated: there is no `ReferencePack` /
  `refpack` / "reference pack" symbol anywhere in `Sources/`. Grep for
  `reference pack|ReferencePack|refpack|reference-pack|referencePack` returns
  zero hits. The "reference pack" concept is purely a documentation construct
  (a recommended on-disk file layout), not a code feature. Recorded as
  verified-correct, but note the term has no code backing, so do not expect any
  CLI/GUI affordance named "reference pack."

- **Doc claim: "The pack pins `bioconda::gatk4=4.6.2.0` and verifies it with
  `gatk --version`" (lines 60-61).** ACCURATE. `gatk-core` pack installs
  `bioconda::gatk4=4.6.2.0`, version `4.6.2.0`, smoke test runs `gatk
  --version` expecting output substring "The Genome Analysis Toolkit".
  Cite: `Sources/LungfishWorkflow/Conda/PluginPack.swift:447-474`.

- **Doc claim: "Installing the pack is not the same as executing a workflow.
  The current CLI only prints commands" (lines 62-63).** FALSE as to "only
  prints commands." See execute findings in chapters 01-03. The first sentence
  (install != execute) is true; the second is stale.

- **Doc `lungfish conda install --pack gatk-core` (line 57).** ACCURATE.
  `--pack` is a flag and `gatk-core` is a positional package/pack name.
  Cite: `conda install --help` (`--pack  Install a plugin pack instead of
  individual packages`); pack ID `gatk-core` at `PluginPack.swift:448`.

- **Doc `lungfish gatk bqsr ... --known-sites ... --recal-table ... --output`
  (lines 42-49).** ACCURATE against the `bqsr` subcommand: `--reference`,
  `--bam`, `--known-sites` (repeatable), `--recal-table`, `--output`.
  Cite: `GATKCommand.swift:573-586`. No discrepancy.

### 2. APP FEATURES MISSING FROM THE DOCS

- **`bqsr --intervals` and `--create-output-bam-index` (default true)** are not
  shown in the reference-pack example.
  Cite: `GATKCommand.swift:588-592`.

- **The `gatk-core` pack carries `isExperimental: true` and
  `estimatedSizeMB: 600`,** which the chapter does not surface. Useful for the
  "before using these commands" install guidance.
  Cite: `PluginPack.swift:455, 474`.

### 3. UNCERTAIN / NEEDS-HUMAN-CHECK

- The reference-pack file table (lines 28-35: `GRCh38.fa`, `.fai`, `.dict`,
  `dbsnp.vcf.gz`, `known_indels.vcf.gz`, interval list) is a recommended
  external layout, not validated or constructed by any code. Nothing in
  `Sources/` enforces, downloads, or checks these files. Human should confirm
  this is intentionally advisory.

---

## Section-wide

- **Execution reality (the central correction):** The chapters' uniform "dry-run
  only / does not run GATK / future execution" framing contradicts the code.
  Every `gatk` subcommand has `--execute` wired to a real
  `GATKPipelineExecutor` + `ManagedGATKCommandRunner` that runs GATK4 in the
  `gatk-core` conda env and writes provenance
  (`GATKCommand.swift:37-52, 95-99`; `GATKPipelineExecutor.swift:691-766`).
  Default behavior with no flags is preview (so "construct without running" is
  true by default), but the absolute claims that execution does not exist are
  false. Recommend rewording from "does not run / coming soon" to "previews by
  default; `--execute` runs (experimental)."

- **Undocumented GUI germline path:** GATK HaplotypeCaller (and a GATK+WhatsHap
  phased plan) run from the GUI BAM variant-calling dialog and Inspector variant
  workflow, executing real tools and attaching VCF tracks to a bundle
  (`BAMVariantCallingCatalog.swift:15-33`;
  `InspectorViewController+VariantWorkflow.swift:200-248`). Chapter 01's
  "GUI integration ... on the way" is inaccurate for single-sample HaplotypeCaller.

- **Verified-correct claims worth preserving:** the 50-sample joint-genotyping
  threshold (`GATKCommandBuilder.swift:380, 408-413`), the `gatk4=4.6.2.0` pin
  (`PluginPack.swift:461, 469`), `conda install --pack gatk-core` syntax, and
  the absence of any shipped human reference pack (no `ReferencePack` symbol in
  `Sources/`). The "reference pack" is a docs-only concept with zero code
  backing, which is itself a fact reviewers should know.
