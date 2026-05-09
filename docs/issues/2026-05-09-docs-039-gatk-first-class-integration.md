# #docs-039: GATK as a first-class set of tools (research-tier human germline)

**Severity:** P1
**Filed:** 2026-05-09
**Replaces:** docs-009 (P3 placeholder), which is retired in favor of this rigorous specification.
**Domain:** Variant calling (scope expansion).

## Audience scope

This issue scopes a research-tier integration of the GATK4 toolkit aimed at single-sample human germline variant calling and joint genotyping across small to medium cohorts. It is the first non-viral variant-calling capability in Lungfish and the first that targets human genomes at any scope.

**Explicitly out of scope** for this round:

- Clinical / IVD use (CLIA / CAP validation, IVD audit trail beyond what the existing provenance sidecar already captures, regulator-facing report templates). Likely follow-on tickets, but they ride on top of the research-tier work below and do not change its shape.
- Somatic calling (Mutect2, paired tumor / normal, panel of normals).
- Copy-number variation (the GATK CNV pipeline, CollectReadCounts, DenoiseReadCounts).
- Structural variants (GATK-SV, Manta, Delly).
- Liftover and cross-build coordinate translation.
- Pedigree-aware joint calling (PED files, de novo discovery, transmission filtering). The clinical-research persona on the panel wants this; the population-genomics persona agreed it ships next.

## Panel members

Five experts scoped this initiative. Their bios appear below; section voices are attributed where relevant.

1. **Dr. Asha Vaidya** — Senior GATK developer, eight years on the GATK4 codebase at the Broad Institute. Owns several core walkers, including parts of HaplotypeCaller's active-region handling. Voice for the tool-surface decisions and edge cases.
2. **Dr. Marcus Holloway** — Clinical-research bioinformatician, ten years running production germline pipelines for a research hospital's molecular diagnostics R&D group. Voice for what a pipeline needs to be useful for return-of-results research, short of clinical validation.
3. **Dr. Yuki Nakamura** — Population-genomics researcher, fifteen years joint-genotyping cohorts of two hundred to ten thousand samples for case-control and cohort studies. Voice for the joint-genotyping workflow and reference-pack decisions.
4. **Pat Olusegun** — Pipeline engineer, six years on nf-core/sarek, dna-seq-gatk-variant-calling, and similar Nextflow GATK pipelines. Voice for pipeline interoperability and integration testing.
5. **Sasha Reynolds** — Computational biologist, one year of GATK experience, came to germline work from RNA-seq. The audience for the new manual chapter and the load-bearing voice for the dialog UX defaults.

## Background

GATK is the reference implementation of human germline variant calling for short-read data. The community standard pipeline (GATK Best Practices) is the path of least resistance for any researcher producing single-sample VCFs or joint-genotyped cohort VCFs from Illumina whole-genome or exome data. The toolkit is published, peer-reviewed, and validated against publicly available truth sets (Genome in a Bottle). For the audience the focus groups identified (Year 3 genetics PhD Rachel Sturm, clinical-research consultant Sara Linhardt, anyone touching human DNA), GATK's absence from Lungfish is disqualifying. The viral callers Lungfish already ships (iVar, LoFreq, Medaka) target a different regime and are not interchangeable with HaplotypeCaller for a human germline workload.

The viral toolchain remains. GATK is additive. A user analyzing SARS-CoV-2 amplicon data continues to use iVar as the chapter teaches today; that workflow does not change. What changes is that a user analyzing human exome data now has a first-class path through Lungfish that ends in a joint-genotyped, hard-filtered, annotation-ready VCF, with the same provenance sidecars, the same reproducibility story, and the same Inspector affordances as the viral pipeline.

## C. Tool surface decision

The panel walked the GATK4 tool list (over fifty walkers) and bucketed each tool into one of three tiers. The first tier ships as a Lungfish-native dialog and CLI; the second tier ships as a CLI wrapper without a dedicated dialog; the third tier is reachable only by activating the conda environment by hand or via `--extra-args` passthrough.

### First-class GUI dialog tier

Each of these gets a dedicated dialog that mirrors the existing Variant Calling dialog pattern (`OrientWizardSheet.swift` shape, 480-520 px wide, "Run" button, advanced-options disclosure):

- **HaplotypeCaller** (single-sample germline). The flagship caller. Runs in `-ERC GVCF` mode by default (see Defaults). Produces a per-sample `.g.vcf.gz` plus index. Optionally produces a hard-called single-sample VCF when the user does not intend to joint-genotype.
- **Joint genotyping pipeline.** A composite operation that runs `CombineGVCFs` (small cohorts) or `GenomicsDBImport` (cohorts above the threshold; see Defaults) followed by `GenotypeGVCFs`. The dialog presents this as one user-visible action ("Joint Genotype Cohort") even though it is two GATK invocations under the hood.
- **VariantFiltration.** Hard-filter pass with the GATK Best Practices defaults baked in for SNPs and indels separately. Operates on a single-sample or joint-called VCF.
- **SelectVariants.** Select-by-type, select-by-sample, select-by-interval. Useful enough as a building block to deserve a dialog. Doubles as the per-sample VCF extractor referenced in docs-024.

The panel debated adding **VariantsToTable** as a fifth dialog. Vaidya argued it is a natural export action and belongs in the dialog tier. Reynolds (the audience) said exporting to TSV is rarely a discoverable user need and clutters the dialog list. The panel split the difference: VariantsToTable ships as a CLI subcommand and a "Tools > Export Variants as Table" menu entry, but does not get its own sidebar tile.

Five dialogs total. Six menu / sidebar entries (the joint-genotype dialog gets two paths: as a tile in the sidebar and as a "Cohort" entry in the project menu).

### Wrapped CLI tier

These ship as `lungfish gatk <tool>` subcommands but no dialog. They are required for some pipelines and useful for power users, but they do not need a discoverable dialog because they are upstream-of-calling steps that Lungfish already handles cleanly through its existing operations or that a typical user invokes only once per project setup:

- **MarkDuplicates** (the GATK / Picard one). Lungfish currently uses `samtools markdup` in the read-mapping pack; the GATK port produces equivalent output but with the slight metric-reporting differences that some pipelines depend on. Wrap it for parity, default to samtools.
- **BaseRecalibrator** + **ApplyBQSR** (BQSR). Required by GATK Best Practices for whole-genome data; optional for exome. Wrapped behind one `lungfish gatk bqsr` composite subcommand because users always run them together.
- **ValidateSamFile.** Diagnostic. Runs on demand from the CLI when a user reports an alignment problem.
- **LeftAlignAndTrimVariants.** Sometimes useful as a normalization step alongside `bcftools norm` (Lungfish already runs `bcftools norm` in the existing variant pipeline). Wrapped for completeness.
- **CollectVariantCallingMetrics.** QC metrics on a finished VCF. Wrapped because Holloway's audience wants the per-sample TiTv ratio and dbSNP concordance numbers in the provenance sidecar.

### Not wrapped this round

Everything else. The user can activate the GATK conda environment by hand (`micromamba activate ~/.lungfish/conda/gatk-core`) or pass arbitrary flags via `--extra-args` on any wrapped command. The panel deliberately resisted wrapping every walker for the sake of completeness.

### Disagreement captured

Vaidya (GATK developer) and Nakamura (population genomics) disagreed on `GenomicsDBImport` versus `CombineGVCFs`. Vaidya argued GenomicsDBImport should always be the path because the CombineGVCFs intermediate file is unbounded in size. Nakamura argued CombineGVCFs is fine for cohorts under fifty samples and avoids a DB store on disk that confuses users new to GATK. The panel resolved this by hiding the choice from the dialog (the user picks "Joint Genotype Cohort" and Lungfish routes by sample count; see Defaults) but exposing it in the CLI for power users.

## D. Plugin pack decision

Three options were tabled.

1. **New `germline-variant-calling` pack** containing GATK4, bcftools, tabix, bgzip. Pro: clean separation; viral users do not download GATK they will never use. Con: bcftools / tabix / bgzip are duplicated with the existing `variant-calling` pack, and the duplication wastes disk and confuses users who see two installs of the same tool.
2. **Extend the existing `variant-calling` pack to include GATK.** Pro: one pack to install. Con: GATK4 is roughly 600 MB, dwarfing the rest of the pack (the current `variant-calling` pack is about 280 MB). Every viral user pays for GATK on first install whether or not they ever call human variants.
3. **Two packs: a thin `gatk-core` pack containing only GATK4 + dependencies, and the existing `variant-calling` pack continues to ship bcftools, tabix, bgzip.** Pro: GATK is opt-in, no duplication, the existing pack remains lean. Con: the user has to install two packs to call human variants. The chapter says so.

The panel recommends option 3 unanimously. The chapter teaches:

```bash
lungfish conda install --pack variant-calling gatk-core
```

as the GATK starting point. Olusegun noted that nf-core/sarek splits its container the same way (a slim base image plus a separate GATK image) for the same reason: GATK's size makes it a poor co-passenger.

The `gatk-core` pack pins to the latest 4.x release on bioconda and updates on a schedule independent of `variant-calling`. The `01-foundations/07-plugin-packs.md` table grows by one row.

## E. Defaults

The audience persona for this section is Reynolds (one year of GATK experience). Every default below has a rationale, and the dialog exposes the rationale on hover so a user can ask why the default is what it is without leaving the dialog.

### HaplotypeCaller dialog

| Field | Default | Rationale |
|---|---|---|
| Emit reference confidence (`-ERC`) | `GVCF` | Joint genotyping is the load-bearing capability. GVCF mode is the only mode that lets a per-sample call participate in a later joint call. The user who only wants a single-sample VCF can flip the dropdown to `NONE`. |
| Sample ploidy | `2` (diploid) | Human germline is diploid. The dropdown offers 1, 2, 4 for users analyzing other organisms or pooled samples. The dialog warns clearly when the dropdown leaves 2. |
| `--standard-min-confidence-threshold-for-calling` (`stand-call-conf`) | `30.0` in non-GVCF mode; not exposed in GVCF mode (HC always emits at conf 0 in GVCF mode and the threshold is applied later by GenotypeGVCFs) | The GATK4 default. |
| `--max-alternate-alleles` | `6` | GATK default. |
| Intervals | None (whole genome) by default; the user supplies a BED, an interval list, or a contig name | An exome user always supplies a BED. A WGS user usually does not. The "Intervals" picker (see Reference handling) accepts any of the three. |
| `--pcr-indel-model` | `CONSERVATIVE` for exome; `NONE` for WGS | Default differs because PCR-amplified exome libraries have a different indel-error profile than PCR-free WGS. The dialog asks the user "PCR-amplified library?" with a yes/no and toggles internally. |
| Threads (`--native-pair-hmm-threads`) | 4 | Reasonable default on Apple Silicon. The CPU picker exposes more. |
| Memory | Autoscaled to 80% of physical RAM, capped at 16 GB | HaplotypeCaller's memory ceiling matters; the auto-cap prevents the swap death some users hit. |

### Joint-genotyping dialog

| Field | Default | Rationale |
|---|---|---|
| Cohort definition | The user picks a Cohort folder (see Joint-genotyping workflow). The dialog displays the count of GVCF samples it found. | A cohort is a sidebar entity in this initiative. |
| Combine strategy | Auto (route to `CombineGVCFs` for ≤ 50 samples, `GenomicsDBImport` for > 50) | Threshold of 50 follows nf-core/sarek's published guidance and the GATK Forum's joint-genotyping cookbook. The user can override in Advanced. |
| `--standard-min-confidence-threshold-for-calling` on GenotypeGVCFs | `30.0` | GATK4 default. |
| Intervals | Inherited from the cohort if every per-sample call used the same intervals; required if any sample disagrees | The dialog warns when sample intervals are heterogeneous. |
| Allele-specific annotations | On | Required by VQSR if the user later opts in (out of scope this round, but the data should not be discarded). |

### VariantFiltration dialog

The canonical GATK Best Practices hard-filter expressions ship as preset radio buttons. The dialog separates SNPs from indels because the thresholds differ.

**SNP preset (default):**

- `QD < 2.0` flagged as `QD2`
- `FS > 60.0` flagged as `FS60`
- `MQ < 40.0` flagged as `MQ40`
- `MQRankSum < -12.5` flagged as `MQRankSum-12.5`
- `ReadPosRankSum < -8.0` flagged as `ReadPosRankSum-8`
- `SOR > 3.0` flagged as `SOR3`

**Indel preset (default):**

- `QD < 2.0` flagged as `QD2`
- `FS > 200.0` flagged as `FS200`
- `ReadPosRankSum < -20.0` flagged as `ReadPosRankSum-20`
- `SOR > 10.0` flagged as `SOR10`

The dialog has a "Custom" option that opens a free-form expression editor with autocomplete on the standard INFO field names. Reynolds asked specifically for the preset radios; the verbal expression syntax is opaque to her.

VQSR (Variant Quality Score Recalibration) is a follow-on. Hard filters are the GATK Best Practices fallback for cohorts too small for VQSR, which is the regime most Lungfish users are in.

## F. CLI surface

`lungfish gatk` is a new top-level subcommand. Its subcommand list mirrors the dialog tier first, then the wrapped tier:

```
lungfish gatk haplotype-caller \
    --bundle <reference-bundle> \
    --alignment-track <track-id> \
    --emit-ref-confidence GVCF \
    --ploidy 2 \
    --intervals <bed-or-list> \
    --pcr-indel-model NONE \
    --output-name <name> \
    --extra-args "<verbatim-passthrough>"

lungfish gatk joint-genotype \
    --bundle <reference-bundle> \
    --cohort <cohort-folder> \
    --intervals <bed-or-list> \
    --combine-strategy auto|combine-gvcfs|genomicsdb \
    --output-name <name> \
    --extra-args "<verbatim-passthrough>"

lungfish gatk filter \
    --vcf <input-vcf> \
    --preset best-practices-snp|best-practices-indel|best-practices-both|custom \
    --custom-snp-expression "..." \
    --custom-indel-expression "..." \
    --output-name <name>

lungfish gatk select \
    --vcf <input-vcf> \
    --sample <sample-id> \
    --type SNP|INDEL|MIXED \
    --intervals <bed-or-list> \
    --output-name <name>

lungfish gatk variants-to-table \
    --vcf <input-vcf> \
    --fields CHROM,POS,REF,ALT,QUAL,AF,DP \
    --output <tsv>

lungfish gatk bqsr \
    --bundle <reference-bundle> \
    --alignment-track <track-id> \
    --known-sites <vcf-or-list> \
    --intervals <bed-or-list> \
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
    --intervals <bed-or-list>
```

Flag conventions match `lungfish variants call`: `--bundle`, `--alignment-track`, `--output-name` (rather than the older `--name`), `--extra-args` for verbatim passthrough on every wrapped command (per docs-021), `--pack gatk-core` is implicit and the CLI errors with a clear message if the pack is missing.

## G. Dialog UX

The audience for these sketches is Reynolds. Each dialog opens from the tool sidebar's new "GATK" group, which appears below "Variants" once the `gatk-core` pack is installed.

### HaplotypeCaller dialog

A user picks **Tools > Variant Calling > GATK HaplotypeCaller** or drags an alignment track onto the GATK tile. Required inputs: reference bundle, alignment track. Required-but-defaulted: ploidy (2), ERC mode (GVCF), interval source (none = whole reference). Advanced disclosure: `stand-call-conf`, `max-alternate-alleles`, `pcr-indel-model`, threads, memory cap, `--extra-args`. The "Run" button is enabled when the bundle and the alignment track are valid; it is disabled with a red pill explaining why otherwise.

The Inspector's Analysis section grows a "GATK HaplotypeCaller" subsection (analogous to iVar's Variant Calling subsection today) that surfaces ERC mode, ploidy, intervals used, dbSNP version (when known-sites provided), and the resolved GATK version with command line.

### Joint-genotyping dialog

The user picks a Cohort folder from the project sidebar (see Joint-genotyping workflow). The dialog scans the folder, shows the count of `.g.vcf.gz` files it found, and the count of distinct interval sets across them. If the intervals are heterogeneous it warns. Required-but-defaulted: combine strategy (auto), confidence threshold (30). Advanced: explicit GenomicsDBImport workspace path, allele-specific annotations toggle.

A progress strip above the Run button reads "Sample N/M" during the per-sample import phase and "Genotyping" during the GenotypeGVCFs phase. OperationCenter logs both phases as separate steps in the cohort sidecar.

### VariantFiltration dialog

The user picks a VCF (single-sample or joint-called). The dialog presents three radio rows: SNP preset, indel preset, joint preset. Each radio expands to show the active hard-filter expressions when selected; the user can edit any expression in place. The Run button writes a new VCF with `FILTER` populated; the input VCF is left untouched.

### SelectVariants dialog

A simple form. Input VCF, optional sample-name dropdown (populated from the VCF header), optional type radio (SNP / INDEL / MIXED), optional intervals picker. One Run button. This is the dialog Reynolds asked for to extract her own sample out of a 50-sample joint call without having to remember the bcftools incantation.

## H. Reference handling

Human germline calling needs a FASTA, an index, a sequence dictionary, dbSNP, the Mills-and-1000G gold-standard indels, and (for exome users) an exome interval list. None of this is currently bundled with Lungfish.

### Bundled reference packs (panel recommendation: ship)

Lungfish ships an optional **reference pack** the user can download from the Plugin Manager, the same way classifier databases work today. The pack ID is `human-grch38-gatk` and it contains:

- `Homo_sapiens_assembly38.fasta` plus `.fai` and `.dict`
- `Homo_sapiens_assembly38.dbsnp138.vcf.gz` plus `.tbi`
- `Mills_and_1000G_gold_standard.indels.hg38.vcf.gz` plus `.tbi`
- `wgs_calling_regions.hg38.interval_list`
- A canonical exome BED (the panel recommends shipping the Twist Comprehensive Exome v2 BED with attribution; vendor-specific exome BEDs stay as user-supplied files)

Total pack size is on the order of 4 GB. The pack is hosted on the same artifact server as the classifier databases; the manifest records the upstream hash (Broad's resource bundle is the source of truth) so a user can verify what they downloaded against the Broad's published hash.

A second pack `human-grch37-gatk` exists for users who must stay on b37 (some legacy clinical-research datasets). It is a separate download and not the default.

The panel debated whether to ship reference packs at all. Holloway argued strongly for shipping them: "If a user has to assemble the Best Practices resource bundle by hand from the Broad's FTP server, two-thirds of them will give up before they finish, and the ones who succeed will get a half-right pack that breaks BQSR in subtle ways." Olusegun seconded this, citing nf-core/sarek's `igenomes` system as evidence the community wants curated reference bundles. Nakamura noted the disk cost (4 GB) is acceptable because users only download it once.

### How known-sites VCFs reach the dialog

Three paths, in order of expected use:

1. **The bundled reference pack carries them.** When the user picks the human GRCh38 reference bundle in a dialog, dbSNP and Mills are auto-attached to BQSR and to CollectVariantCallingMetrics. The user does not have to do anything.
2. **File picker.** A user with their own known-sites VCF (lab-specific, organism-specific) picks it from the dialog's "Known sites" field. Multiple VCFs are accepted; they are passed as multiple `--known-sites` flags.
3. **Drag and drop onto the dialog.** Treats the dropped file as the same input the picker would have accepted.

NCBI fetch was considered and rejected: dbSNP from NCBI directly is not the same shape as the Broad's curated dbSNP138 used by GATK Best Practices, and the panel does not want to teach a path that drifts from the canon.

### Interval lists

A BED interval list is a file like a primer scheme. The panel chose to handle them similarly: a project's `Intervals/` folder is the canonical location, and a `.bed` or `.interval_list` file dropped there appears as an option in any dialog that takes intervals. The exome BED that ships in the bundled reference pack is symlinked into the project's `Intervals/` folder when the user opens a project against the human reference bundle.

This adds one new project folder. The convention list grows: `Imports/`, `Downloads/`, `Reference Sequences/`, `Assemblies/`, `Primer Schemes/`, **`Intervals/`**, `Cohorts/`.

## I. Joint-genotyping workflow

This is the load-bearing capability that distinguishes GATK from the existing single-sample callers. Lungfish has not had a multi-sample concept until now.

### Cohorts as a project sidebar entity

A new top-level sidebar group, `Cohorts/`, sits below `Variants/`. A cohort is a folder. The folder contains:

- `manifest.json` listing the GVCF samples and pointing at each per-sample sidecar
- A `samples/` subdirectory with one entry per per-sample GVCF (each entry is a small bundle: the `.g.vcf.gz`, its `.tbi`, and its provenance sidecar). The actual GVCFs may live in their original projects (sample-as-project pattern) or be copied in (cohort-as-project pattern); the manifest records which.
- `joint-call.vcf.gz` and `.tbi` once the joint call has been run
- `joint-call.sidecar.json` referencing every per-sample sidecar by checksum

A user creates a Cohort by right-clicking the sidebar and picking "New Cohort," then dragging GVCF results from other projects (or the same project) onto it. The cohort lives at the project level. Cross-project cohorts are supported through symlinks to per-sample bundles, with the manifest recording the source project path.

### The four steps

1. **Per-sample GVCF generation.** Run HaplotypeCaller in `-ERC GVCF` mode on each sample's BAM. Each run is a normal Lungfish operation, producing a per-sample GVCF result and sidecar in the sample's project. The user drops these results onto the Cohort.
2. **Combine.** When the user clicks Run on the joint-genotyping dialog, Lungfish picks `CombineGVCFs` (≤ 50 samples) or `GenomicsDBImport` (> 50). For `GenomicsDBImport` the workspace is created under the cohort folder.
3. **GenotypeGVCFs.** Runs against the combined intermediate. Produces the joint VCF.
4. **Hard-filter.** Optional but offered by the dialog: pipe directly into VariantFiltration with the joint Best Practices preset.

### How cohorts appear in provenance

The cohort's sidecar references every per-sample sidecar by its `sha256` (the existing sidecar schema already does this for input checksums; the new use is downstream-cross-reference). The export-as-Nextflow operation walks the cohort's per-sample sidecar pointers and emits a sarek-compatible workflow that re-runs every step from FASTQ to joint VCF. For 50 samples, this is 50 input rows and one cohort row in the exported sample sheet.

### Disagreement captured

Vaidya argued for storing GVCFs as a new bundle type (`.lungfishgvcf`) parallel to the existing `.lungfishref` and `.lungfishprimers`. Reynolds and Olusegun both argued against introducing a new bundle type for what is essentially a versioned VCF. The panel resolved this in favor of Reynolds: a per-sample GVCF is just a result file (with sidecar) in the sample's project, the same shape an iVar VCF result has today. The Cohort folder is the new abstraction; the GVCF file format is not.

## J. Provenance considerations

The existing provenance sidecar schema handles single-step operations cleanly and multi-process pipes (`samtools mpileup | ivar variants`) via the `steps[]` array. Joint genotyping is a many-sample, many-step DAG. Three additions to the schema:

1. **Per-sample HaplotypeCaller writes its own sidecar.** No change from current behavior; this works today. The sidecar's `tools[]` lists the GATK version, command line, and ERC mode. The sidecar's `inputs[]` lists the BAM and reference bundle by sha256.
2. **The joint call's sidecar references all the per-sample sidecars by checksum.** New field: `cohort.gvcfs[]` is a list of objects, each with `sample`, `gvcfPath`, `gvcfSha256`, and `sidecarSha256`. The verifier walks this list and reconstructs the full ancestry. Sha256 is the existing checksum field; the schema does not need a new hash.
3. **A new `cohort.combineStrategy` field** records `combine-gvcfs` or `genomicsdb`, the threshold used to choose, and the GenomicsDB workspace path when applicable.

### Export as Nextflow

A 50-sample cohort exports to a runnable Nextflow workflow. The panel recommends targeting nf-core/sarek's input format directly: a CSV sample sheet with `patient`, `sample`, `lane`, `fastq_1`, `fastq_2`, `bam`, `bai`. Lungfish's exporter walks the cohort's per-sample sidecars, derives the sarek sample sheet, and writes a `main.nf` that pins the GATK version (`gatk-core` pack version) and the reference pack version. The resulting workflow is a drop-in `nextflow run nf-core/sarek -profile docker --input samplesheet.csv` invocation.

Olusegun argued strongly for sarek interoperability rather than Lungfish-native Nextflow. Vaidya pushed back: "Lungfish should compete with sarek, not interoperate." The panel sided with Olusegun. The reasoning: a research lab that already runs sarek for production cohort calling will use Lungfish for exploration and hand off to sarek for the production run. Lungfish's Nextflow export is for that handoff, not for replacing sarek.

## K. Acceptance criteria

Long, rigorous, grouped by area. Every checkbox is a discrete unit of work.

### Plugin pack and tool installation

- [ ] A new `gatk-core` plugin pack is defined in the conda plugin registry, pinned to a specific GATK4 release (4.x.y) on bioconda
- [ ] `lungfish conda install --pack gatk-core` installs into `~/.lungfish/conda/gatk-core` and registers the env
- [ ] The `01-foundations/07-plugin-packs.md` table grows by one row for `gatk-core` with size estimate (~600 MB)
- [ ] First-launch validation runs `gatk --version` and records the version string in the pack's manifest
- [ ] `lungfish conda info gatk-core` reports installation date, version, install size, and known-issues link
- [ ] The Plugin Manager UI lists `gatk-core` with a clear "for human germline variant calling" subtitle
- [ ] Re-running install on a current pack is idempotent (matches existing pack behavior)
- [ ] A `human-grch38-gatk` reference pack is hosted on the artifact server with the contents listed in section H, and Lungfish's Plugin Manager can install it

### HaplotypeCaller dialog and CLI

- [ ] `Sources/LungfishApp/Views/Variants/Gatk/HaplotypeCallerDialog.swift` provides the dialog described in section G
- [ ] `lungfish gatk haplotype-caller` provides the CLI described in section F with full flag parity
- [ ] GVCF mode is the default; running without `--emit-ref-confidence` produces a GVCF
- [ ] The output is a result bundle attached to the project with the per-sample GVCF, its index, and a provenance sidecar
- [ ] The Inspector's Analysis section exposes a "GATK HaplotypeCaller" subsection mirroring the iVar pattern
- [ ] Operation rows pipe through `OperationCenter.shared.update()` AND `OperationCenter.shared.log()` (per project memory)
- [ ] HaplotypeCaller runs do not block the main thread; cancel works mid-operation
- [ ] The dialog refuses to run when the alignment track is missing read groups (cross-link to docs-014)
- [ ] The dialog refuses to run when the reference bundle is not human or has no associated dictionary, with a clear error

### Joint-genotyping dialog and CLI

- [ ] `Sources/LungfishApp/Views/Variants/Gatk/JointGenotypeDialog.swift` provides the dialog described in section G
- [ ] `lungfish gatk joint-genotype` provides the CLI described in section F
- [ ] The auto strategy routes ≤ 50 samples to CombineGVCFs and > 50 to GenomicsDBImport
- [ ] The dialog scans the cohort folder and lists per-sample GVCFs with their interval sets
- [ ] Heterogeneous-interval cohorts produce a clear warning before run
- [ ] Per-step progress (CombineGVCFs / GenomicsDBImport, then GenotypeGVCFs) is surfaced in the Operations Panel
- [ ] The output is a `joint-call.vcf.gz` plus index plus sidecar in the cohort folder
- [ ] The cohort sidecar references every per-sample sidecar by sha256
- [ ] Cancel mid-cohort cleans up the GenomicsDBImport workspace and partially-written outputs

### VariantFiltration dialog and CLI

- [ ] `Sources/LungfishApp/Views/Variants/Gatk/VariantFiltrationDialog.swift` ships the SNP / indel / joint Best Practices presets exactly as listed in section E
- [ ] `lungfish gatk filter` provides the CLI; presets are named identifiers
- [ ] Custom expression mode shows autocomplete on standard INFO fields
- [ ] The output is a new VCF with `FILTER` populated; the input is unmodified
- [ ] Filter expressions are recorded verbatim in the sidecar

### SelectVariants and VariantsToTable

- [ ] `Sources/LungfishApp/Views/Variants/Gatk/SelectVariantsDialog.swift` ships the form
- [ ] `lungfish gatk select` and `lungfish gatk variants-to-table` provide CLIs
- [ ] `Tools > Export Variants as Table` menu item is wired to the variants-to-table CLI

### Wrapped CLI tier

- [ ] `lungfish gatk bqsr` runs BaseRecalibrator + ApplyBQSR as a composite step
- [ ] `lungfish gatk markdup` runs Picard MarkDuplicates with parameters matching samtools markdup
- [ ] `lungfish gatk validate-sam` runs ValidateSamFile and prints a structured report
- [ ] `lungfish gatk leftalign` runs LeftAlignAndTrimVariants
- [ ] `lungfish gatk collect-metrics` runs CollectVariantCallingMetrics and writes the metrics into the VCF's sidecar

### Reference and known-sites handling

- [ ] The `human-grch38-gatk` reference pack downloads, verifies, and installs
- [ ] A user opening a project against the human reference bundle sees dbSNP, Mills, and the WGS interval list pre-attached in any dialog that accepts them
- [ ] The "Intervals" picker accepts BED, interval_list, and contig name
- [ ] A new project-folder convention `Intervals/` is created and recognized
- [ ] Custom known-sites VCFs can be supplied via dialog file picker, drag-drop, or CLI flag
- [ ] The `human-grch37-gatk` legacy pack is available but not default

### Variant browser / viewport changes

- [ ] The variant browser handles multi-sample joint VCFs without UI degradation up to 50 samples (cross-link docs-024 for the > 50 sample work)
- [ ] Per-sample GT / AF / DP fields are accessible from the row inspector
- [ ] The browser distinguishes hard-call VCFs from filtered VCFs in its header strip
- [ ] Cohort VCFs render with a sample selector at the top of the browser

### Documentation chapter requirements

- [ ] A new manual part `06-human-germline-variants/` is added (decision in section N below)
- [ ] Chapter `06-human-germline-variants/01-single-sample-haplotypecaller.md` covers the HC dialog and CLI end-to-end against a small fixture
- [ ] Chapter `06-human-germline-variants/02-joint-genotyping.md` covers cohort creation, joint calling, and the cohort sidebar
- [ ] Chapter `06-human-germline-variants/03-filtering-and-selecting.md` covers VariantFiltration and SelectVariants
- [ ] Chapter `06-human-germline-variants/04-reference-packs.md` documents the bundled `human-grch38-gatk` pack
- [ ] The existing `05-variants/01-calling-variants-from-amplicons.md` adds a one-paragraph scope note pointing readers to part 06 if they want human germline
- [ ] The "what Lungfish does not target" note in `01-foundations/01-what-is-a-genome.md` is updated to remove human germline from the not-yet list and add the still-out items (somatic, CNV, SV)

### Test fixture requirements

- [ ] A small public human fixture is committed under `Tests/Fixtures/human-na12878-chr22-subset/`: the GIAB NA12878 high-confidence chr22 subset, downsampled to a few hundred MB
- [ ] A `Tests/LungfishIntegrationTests/GatkHaplotypeCallerFixtureTests.swift` runs HC against the fixture and asserts the resulting VCF matches a committed truth set
- [ ] A `Tests/LungfishIntegrationTests/GatkJointGenotypingFixtureTests.swift` runs a 3-sample joint call against three downsampled fixtures
- [ ] A `Tests/LungfishCLITests/GatkCLITests.swift` covers all CLI subcommands with smoke tests

### Provenance schema additions

- [ ] Sidecars for HC GVCF runs include `tools[].toolName == "gatk-haplotype-caller"`, the GATK version, the ERC mode, the ploidy, the intervals checksum
- [ ] Cohort sidecars include `cohort.gvcfs[]` with per-sample sha256 references
- [ ] Cohort sidecars include `cohort.combineStrategy` with the chosen strategy and the threshold logic
- [ ] BQSR sidecars include the known-sites VCF checksums
- [ ] The provenance JSON schema in `docs/spec/provenance-schema.md` is updated

### help-ids.yaml additions

- [ ] `dialog.GatkHaplotypeCaller` mapped to chapter 06/01
- [ ] `dialog.GatkJointGenotype` mapped to chapter 06/02
- [ ] `dialog.GatkVariantFiltration` mapped to chapter 06/03
- [ ] `dialog.GatkSelectVariants` mapped to chapter 06/03
- [ ] `viewport.CohortBrowser` mapped to chapter 06/02
- [ ] `pack.gatk-core` mapped to chapter 06 introduction
- [ ] `pack.human-grch38-gatk` mapped to chapter 06/04

## L. Edge cases to handle

The senior GATK developer's voice. These are the cases that bite implementations.

1. **Mixed reference dictionaries.** A user runs HC on samples aligned to GRCh38 + decoy and joint-calls against samples aligned to bare GRCh38. Their dictionaries differ. GATK fails mid-run with a confusing error. Lungfish should detect dictionary mismatch at cohort assembly time and refuse with a clear message.
2. **Partial GenomicsDBImport workspaces.** A cohort run cancelled or crashed leaves a half-written GenomicsDB workspace. Restarting must not reuse it silently. The dialog detects an existing workspace and prompts: "Resume, restart, or rename."
3. **Sample IDs with whitespace, slashes, or apostrophes.** GATK escapes some of these inconsistently between walkers. Lungfish normalizes per-sample IDs to a `[A-Za-z0-9_.-]+` charset before any GATK invocation, records the original-to-normalized map in the sidecar, and warns the user when normalization changes the displayed name.
4. **Read-group SM (sample) field disagreement with the cohort sample name.** A common mistake. Lungfish refuses to add a GVCF to a cohort when the GVCF's SM tag does not match the user-provided sample name; the error names both values.
5. **dbSNP version drift in BQSR.** A user runs BQSR with one dbSNP version, then later replaces the reference pack with a newer dbSNP. Subsequent runs use the newer one but pre-existing recal tables are stale. Lungfish records the dbSNP sha256 in the BQSR sidecar; the joint-genotyping operation refuses to proceed when per-sample BQSR sidecars reference different dbSNP shas without a `--allow-mixed-known-sites` flag.
6. **Whole-genome HC on a bundle that is actually exome-mapped.** The user did not supply intervals; HC runs over the whole reference and is wasteful but produces a correct GVCF. Lungfish detects this from the alignment's coverage histogram and warns ("This BAM has 0% coverage on 96% of the reference; did you mean to supply an exome BED?").
7. **NaN, infinity, and missing annotations in custom filter expressions.** GATK's expression engine returns true for a missing-value comparison in some cases, false in others. The custom-expression editor's autocomplete includes a "missing-value" caveat in the tooltip for each annotation.
8. **A cohort with one sample.** Joint genotyping a single GVCF is legal and useful (it forces re-genotyping with updated thresholds). The dialog accepts it without warning; the implementation does not optimize away the combine step in this case.
9. **Cohorts that exceed the file-descriptor limit.** GenomicsDBImport opens many files simultaneously. macOS's default limit is 256 (RLIMIT_NOFILE). Lungfish raises the limit at process start to 8192 and records the prior value in case raising fails.
10. **GVCFs from a different GATK major version than the joint caller.** Cross-version joint calling sometimes works, sometimes silently miscalls. Lungfish records the per-sample GATK version in each GVCF's sidecar, the cohort manifest aggregates these, and the joint-genotype dialog warns when the cohort spans more than one major.minor pair.

## M. Tests to add

The pipeline engineer's voice. Integration tests are the load-bearing safety net for a project that wraps a tool of GATK's complexity.

### Unit tests

- `Tests/LungfishWorkflowTests/GatkHaplotypeCallerCommandLineTests.swift` — covers command-line construction for every flag combination the dialog can produce
- `Tests/LungfishWorkflowTests/GatkJointGenotypeRoutingTests.swift` — covers the auto-routing logic between CombineGVCFs and GenomicsDBImport at threshold boundaries (49, 50, 51 samples)
- `Tests/LungfishWorkflowTests/GatkVariantFiltrationPresetTests.swift` — verifies the SNP and indel Best Practices presets produce exactly the canonical expressions
- `Tests/LungfishCoreTests/CohortManifestTests.swift` — round-trips cohort manifests with diverse sample counts, normalizes whitespace in sample IDs

### Integration tests

- `Tests/LungfishIntegrationTests/GatkHaplotypeCallerFixtureTests.swift` — runs HC against the GIAB chr22 fixture and asserts the produced GVCF's record count, header dictionary, and a sample of variant positions match a committed expected output
- `Tests/LungfishIntegrationTests/GatkJointGenotypingFixtureTests.swift` — runs a 3-sample joint call and asserts the joint VCF passes hap.py concordance against the GIAB truth set above 99% recall and 99% precision in confidence regions
- `Tests/LungfishIntegrationTests/GatkBqsrFixtureTests.swift` — runs BQSR against the chr22 fixture with the bundled dbSNP and asserts the recal table is non-empty and the post-BQSR alignment passes ValidateSamFile

### Regression tests

- A `Tests/LungfishIntegrationTests/GatkFunctionalFixtureTests.swift` mirrors the existing `FunctionalFixtureTests.swift` pattern: every wrapped GATK tool runs against the human chr22 fixture and a committed expected output is compared bit-for-bit (or schema-aware where bit-for-bit is brittle, e.g. timestamps in VCF headers)

### Fixture decision

The panel debated three options:

1. Synthetic data (small, fast, but does not catch issues that emerge only on real data)
2. The full GIAB NA12878 high-confidence subset (large, comprehensive, but the chr20 / chr21 / chr22 subsets are still in the GB range)
3. A downsampled GIAB chr22 subset (panel recommendation)

Recommendation: ship a downsampled GIAB NA12878 chr22 fixture under `Tests/Fixtures/human-na12878-chr22-subset/`. The chr22 region is small enough to fit in a few hundred MB at 30x coverage; GIAB's truth VCF for the same region is small (a few MB); the high-confidence BED defines the comparison region. This is the standard fixture used in the wider community (nf-core/sarek's CI, GATK's own integration tests) so any deviation is detectable.

A larger chr20+21+22 fixture lives outside the repo, hosted on the artifact server, and is downloaded on demand by a separate `--integration-tier human-large` test target.

## N. Documentation impact

The panel split on whether GATK fits inside `05-variants/` or deserves its own part. Reynolds argued for a separate part: "When I open a manual and there are five chapters under 'Variants' that all say SARS-CoV-2 and one that says human germline, I am going to assume the human one is an afterthought." Holloway agreed. The panel recommends a new top-level part:

- `06-human-germline-variants/01-single-sample-haplotypecaller.md`
- `06-human-germline-variants/02-joint-genotyping.md`
- `06-human-germline-variants/03-filtering-and-selecting.md`
- `06-human-germline-variants/04-reference-packs.md`

The existing viral-variants chapters renumber down nothing (they keep `05-variants/`), and the new part takes `06-`. The old `06-classification/` becomes `07-classification/`, and so on. The renumber is mechanical but touches every cross-reference; an automated step in the chapter renumber tool already exists for similar shifts.

The existing `05-variants/01-calling-variants-from-amplicons.md` adds a scope-clarification paragraph near the top: "This chapter covers viral amplicon variant calling. For human germline variant calling and joint genotyping, see Part 6." Similar one-liners go into the LoFreq and Medaka chapters.

The "what Lungfish does not target" passage in `01-foundations/01-what-is-a-genome.md` is updated to remove human germline and add: "somatic variant calling, copy-number variation, and structural variants are not yet supported."

A worked end-to-end example chapter (`06-human-germline-variants/05-end-to-end-na12878.md`) covers the GIAB NA12878 chr22 fixture from FASTQ to filtered joint VCF. The panel deferred the decision on whether to write this fifth chapter or fold the worked example into chapter 02 to whoever picks up the implementation.

## O. Out of scope for this round

Explicit list. Each is tagged as obvious-follow-on or speculative.

- **Clinical / IVD validation** (CLIA-grade audit trail, signed report templates, validation against reference samples for clinical sign-off). Obvious follow-on.
- **Mutect2 / somatic.** Obvious follow-on; reuses much of the GATK plumbing this issue establishes.
- **GATK CNV pipeline** (CollectReadCounts, DenoiseReadCounts, ModelSegments). Speculative.
- **Structural variants** (Manta, Delly, GATK-SV). Speculative; would more likely come through a separate caller initiative.
- **Liftover** between assembly versions. Speculative; users today run `picard LiftoverVcf` by hand.
- **Pedigree-aware joint calling** (PED files, de novo discovery, transmission filtering). Obvious follow-on; Holloway flagged this as the next ticket he wants.
- **VQSR.** Obvious follow-on. Lungfish ships hard-filter Best Practices presets in this round; VQSR for cohorts large enough to benefit is the next logical capability.
- **Funcotator, VEP, snpEff annotation.** Obvious follow-on. Annotation is a known gap and deserves its own scoping pass.
- **GATK CNN scoring** (CNNScoreVariants). Speculative.
- **GATK on RNA-seq variant calling.** Speculative; the tool exists but the audience is small.

## P. Risks and unknowns

Things the panel cannot decide without prototyping.

1. **Variant browser scaling above 50 samples.** Cross-link docs-024. The panel cannot commit to a 1000-sample cohort rendering well in the current variant browser; that is its own scoping pass. Joint calling produces the VCF; whether Lungfish's UI handles the resulting wide table is an orthogonal question.
2. **GenomicsDBImport workspace portability.** A cohort moved between machines may or may not pick up cleanly because GenomicsDB encodes some absolute paths. Test on copy.
3. **Apple Silicon native GATK performance.** GATK4 ships a JNI native pair-HMM that is x86_64-tuned. The arm64 build paths through Java's pair-HMM, which is slower. A 30-sample exome joint call may take longer than the panel expects; benchmark before committing on user-facing runtime estimates.
4. **Reference pack hosting bandwidth.** A 4 GB pack served to a global user base costs something. Confirm CDN availability before announcing a download.
5. **Conda package availability for the latest GATK.** Bioconda's GATK lag varies. Pin to a version known to work, accept the lag, document it.
6. **GVCF block-gzip compatibility across versions.** Some bgzip versions write subtly different blocks; Lungfish's existing bgzip / tabix reader paths assume modern blocks. Check on a GVCF from an older GATK release.

## Q. Panel discussion summary

The panel's most productive disagreements were over scope, not over technical correctness. Vaidya (the senior GATK developer) wanted the full GATK4 surface available because, in her experience, every six months a researcher comes to her asking for the one walker she did not expose. Reynolds (the new-to-GATK biologist) wanted ten dialogs, not fifty, because she could not reason about the choices in a long list. The panel landed on five GUI dialogs plus a wrapped CLI tier; Vaidya conceded that every walker not in the dialog tier remains reachable by activating the conda env, which preserves her power-user path without inflicting it on Reynolds.

Holloway (clinical-research) and Nakamura (population genomics) converged quickly on shipping a curated reference pack rather than asking users to assemble the Best Practices resource bundle by hand. They diverged on pedigree (PED) handling: Holloway wanted it in this round because his return-of-results research workflow uses trios, Nakamura agreed it would be useful but argued (and won) that joint genotyping for unrelated cohorts is the fundamental capability and pedigree is layered on top. Pedigree handling becomes the obvious follow-on ticket.

Olusegun (pipeline engineer) and Vaidya disagreed about the role of nf-core/sarek. Olusegun saw Lungfish as the exploratory environment that hands off to sarek for production. Vaidya wanted Lungfish to be the production environment, with sarek as a competitor rather than a collaborator. The panel sided with Olusegun: the export-as-Nextflow pathway specifically targets sarek's input format because that is what users will actually do. Lungfish's job is to make the exploration phase pleasant; sarek's job is to scale the production phase.

Reynolds asked the question that quietly shaped most of the defaults: "Why is `-ERC GVCF` the default? I do not know what a GVCF is." The panel debated whether to make `-ERC NONE` the default for users who only want a single-sample VCF and never plan to joint-genotype, but landed on GVCF-by-default because the cost of a wasteful GVCF for a user who never joint-genotypes is small (a slightly larger output file) and the cost of a NONE default for a user who later wants to joint-genotype is high (re-running HC on every sample). The dialog explains the choice on hover.

The five experts converged on a smaller, sharper initial scope than any of them would have produced individually. The result is closer to Reynolds's "ship five things well" than to Vaidya's "ship the full toolkit." Vaidya signed off because the wrapped CLI tier preserves her path. The shape of the final spec is a compromise; the panel agreed it is the right one for a first round.

## R. References

- GATK Best Practices: https://gatk.broadinstitute.org/hc/en-us/sections/360007226651-Best-Practices-Workflows
- GATK joint-genotyping cookbook: https://gatk.broadinstitute.org/hc/en-us/articles/360035890411-Calling-variants-on-cohorts-of-samples-using-the-HaplotypeCaller-in-GVCF-mode
- GATK hard-filtering Germline Short Variants: https://gatk.broadinstitute.org/hc/en-us/articles/360035531112-Hard-filtering-germline-short-variants
- nf-core/sarek: https://nf-co.re/sarek
- nf-core/dna-seq-gatk-variant-calling: https://github.com/snakemake-workflows/dna-seq-gatk-variant-calling
- Genome in a Bottle (NA12878 truth set): https://www.nist.gov/programs-projects/genome-bottle
- GIAB NA12878 high-confidence calls: https://ftp-trace.ncbi.nlm.nih.gov/giab/ftp/release/NA12878_HG001/
- dbSNP: https://www.ncbi.nlm.nih.gov/snp/
- Mills and 1000G gold-standard indels: https://console.cloud.google.com/storage/browser/genomics-public-data/resources/broad/hg38/v0
- Broad's GRCh38 reference resource bundle: https://console.cloud.google.com/storage/browser/genomics-public-data/references/Homo_sapiens_assembly38
- hap.py (concordance benchmarking): https://github.com/Illumina/hap.py
- GenomicsDBImport docs: https://gatk.broadinstitute.org/hc/en-us/articles/360057439331-GenomicsDBImport
- Twist Comprehensive Exome v2 BED (vendor docs): https://www.twistbioscience.com/

Cross-references inside Lungfish:

- docs-014 (read-group configuration in mapping dialog) — required prerequisite for HC since GATK refuses to run without a complete @RG line
- docs-024 (multi-sample VCF rendering at scale) — orthogonal scaling concern surfaced by joint genotyping
- docs-021 (pass-through arguments) — the `--extra-args` pattern this issue depends on
- docs-019 (conda lockfile generation) — required to make `gatk-core` reproducible across machines
- docs-018 (OCI container export) — feeds the Nextflow / sarek interoperability story
- docs-029 (tool-version reference table) — must grow to include the GATK version per release
