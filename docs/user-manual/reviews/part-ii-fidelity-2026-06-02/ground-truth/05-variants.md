# Ground-truth reality map: 05-variants

Arbiter-of-truth comparison of the six Variants chapters against the actual
Swift source and CLI. Every claim below is grounded in a cited symbol, flag, or
file. "Does not match code" means the doc states something the code does not do;
it is not a style note.

Primary sources read:
- `Sources/LungfishCLI/Commands/VariantsCommand.swift` (subcommands `call`, `phase`, `extract-sample`, `query`)
- `Sources/LungfishCLI/Commands/FreyjaCommand.swift`, `ImportCommand.swift` (`VCFSubcommand`), `ConvertCommand.swift`, `AnalyzeCommand.swift`
- `Sources/LungfishApp/Views/BAM/BAMVariantCallingCatalog.swift`, `BAMVariantCallingToolPanes.swift`, `BAMVariantCallingDialogState.swift`
- `Sources/LungfishWorkflow/Variants/` (`ViralVariantCallingPipeline.swift`, `BundleVariantCallingModels.swift`, `IVarCodonMerger.swift`, `IVarTSVToVCFConverter.swift`)
- `Sources/LungfishApp/Views/Viewer/AnnotationTableDrawerView+Columns.swift`, `+Filtering.swift`, `+TableView.swift`, `SmartFilterTokens.swift`, `VCFDatasetViewController.swift`
- `Sources/LungfishIO/Bundles/VariantSmartFilter.swift`, `VariantDatabase+Query.swift`
- `Sources/LungfishWorkflow/Conda/PluginPack.swift`

Two facts dominate the whole section and recur per chapter:

1. **There are five viral callers, not three.** `ViralVariantCaller`
   (`BundleVariantCallingModels.swift:5`) is `lofreq, ivar, medaka, bcftools,
   clair3`. The GUI sidebar (`BAMVariantCallingToolID`,
   `BAMVariantCallingCatalog.swift:9`) lists those five plus
   `gatk-haplotype-caller` and `gatk-whatshap-phased`. The CLI `--caller` help
   string reads `lofreq, ivar, medaka, bcftools, clair3` (`VariantsCommand.swift:570`).
2. **The iVar variant pipeline never writes a consensus FASTA, and no
   cross-caller comparison view exists.** `ivarConsensusAF` is a codon-merge
   AF rule, not a consensus-FASTA threshold. There is no `ivar consensus`,
   `samtools consensus`, `isec`, or intersection/union export in the variant
   pipeline.

---

## Chapter 01: Calling Variants from Amplicons

### 1. CLAIMS THAT DO NOT MATCH CODE

- **"Three variant callers ship with Lungfish."** (line 69, and the 3-row
  table at lines 71-76). Code ships five viral callers plus two GATK options.
  iVar / LoFreq / Medaka are three of them, but the count and the framing are
  wrong. The dialog's left sidebar lists `LoFreq, iVar, Medaka, bcftools,
  Clair3, GATK HaplotypeCaller, GATK + WhatsHap Phased`
  (`BAMVariantCallingCatalog.swift:155-172`).

- **"The left tool sidebar has `iVar`, `LoFreq`, and `Medaka` entries; choose
  `iVar`."** (line 163). The real sidebar has seven entries (above). Default
  selection is LoFreq, not iVar (`BAMVariantCallingDialogState.swift:72-73`,
  `selectedToolID = .lofreq`).

- **Entry point: "In the Inspector's `Analysis` section, select `Variant
  Calling` and click `Call Variants…`."** (line 163). NEEDS-HUMAN-CHECK on the
  exact menu/Inspector wording (see Section-wide), but the dialog itself is
  `BAMVariantCallingDialog` driven by `BAMVariantCallingDialogState`. The
  three-column layout (tool sidebar / inputs / output) is real.

- **iVar Options defaults: "minimum allele frequency `0.05`, consensus allele
  frequency `0.75`, merge AF distance `0.25`, minimum ALT quality `20`, ignore
  strand bias on."** (line 165). The values match
  (`BAMVariantCallingDialogState.swift:74,82-85`:
  `minimumAlleleFrequencyText="0.05"`, `ivarConsensusAF=0.75`,
  `ivarMergeAFThreshold=0.25`, `ivarBadQualityThreshold=20`,
  `ivarIgnoreStrandBias=true`). BUT the doc labels min-AF as inside "iVar
  Options"; in code "Minimum Allele Frequency" and "Minimum Depth" live in a
  shared **Thresholds** section that applies to every caller
  (`BAMVariantCallingToolPanes.swift:43-66`), and the iVar-only box
  (`ivarOptionsSection`, lines 140-171) holds consensus AF, merge AF distance,
  minimum ALT quality, and the strand-bias toggle. Minor structural mismatch.

- **The strand-bias toggle label.** Doc says "ignore strand bias on." The real
  control reads **"Ignore strand bias (recommended for amplicons)"**
  (`BAMVariantCallingToolPanes.swift:166`). Default on. Accurate in substance.

- **"iVar reports the within-codon pair at 28881-28882 as a single row with
  `REF GG`, `ALT AA`, and the protein consequence in the `INFO` field."**
  (line 185). The `REF GG / ALT AA` single-row merge is real
  (`IVarCodonMerger`, `IVarTSVToVCFConverter.encodeAlleles` lines 149-158). The
  **protein consequence is NOT written to INFO**. The converter writes only
  `INFO=TYPE=SNP` (`IVarTSVToVCFConverter.swift:120,144`). There is no
  `GFF_FEATURE`, `AA_REF`, or `AA_ALT` in the emitted VCF. The merged AF/DP go
  into `FORMAT` as `MERGED_AF`/`MERGED_DP` (lines 136-137, 197-198). Any amino-
  acid label the user sees comes from the Inspector re-deriving it against the
  bundle GFF, not from the VCF row.

- **CLI: "`lungfish variants call ... --caller ivar --ivar-primer-trimmed
  --min-af 0.05 --name "iVar variants"`."** (line 171, and the shell script
  lines 264-270). Flags are correct and exist (`VariantsCommand.swift:564-606`).
  Accurate.

- **"Lungfish exports the bundle's GFF3 ... as `ivar-annotations.gff3`, then
  runs `samtools mpileup` piped into `ivar variants` with that GFF3 as the
  `-g` argument."** (line 169). Correct. `exportBundleGFFIfAvailable` writes
  `ivar-annotations.gff3` (`ViralVariantCallingPipeline.swift:1108`); the
  pileup is `samtools mpileup -aa -A -d 600000 -B -Q 20 -q 0 -f <ref> <bam>`
  (lines 1041-1053) piped to `ivar variants ... -g <gff>` (lines 1055-1069).

- **"The pipeline finishes with `bcftools sort`, `bgzip`, and `tabix`."**
  (line 169). Broadly correct; the staged VCF.GZ + tabix index are produced and
  attached (`BundleVariantTrackAttachmentService`). NEEDS-HUMAN-CHECK on the
  exact `bcftools sort` step name, but sort+bgzip+tabix is the real shape.

- **`ft` glossed as "(failed threshold)".** (lines 179, 197, and ch.02
  line 134). The VCF header defines `ft` as **"Fisher's exact test of variant
  frequency compared to mean error rate, p-value > 0.05"**
  (`IVarTSVToVCFConverter.swift:122`). The plain-English gloss "failed
  threshold" is loose but defensible; the literal header text differs. Also,
  iVar can emit `bq` (bad quality, ALT_QUAL < 20) and `sb` (strand bias, only
  when strand-bias filter is on) filters, not only `ft` (lines 123-125,
  205-228).

### 2. APP FEATURES MISSING FROM THE DOCS

- The shared **Minimum Depth** threshold (default `10`) applies to iVar via
  `ivar variants -m` (`ViralVariantCallingPipeline.swift:1063`); the chapter
  never mentions it.
- The all-haplotypes VCF: the converter can write a second
  `allHaplotypesVCFURL` enumerating every non-all-REF subset of a codon group
  (`IVarTSVToVCFConverter.swift:91-96`, `IVarCodonMerger.swift:58-68`). Not
  documented.
- `--ivar-consensus-af`, `--ivar-merge-af-threshold`,
  `--ivar-bad-quality-threshold`, `--ivar-no-ignore-strand-bias` CLI flags
  exist (`VariantsCommand.swift:588-598`) and are not shown in the chapter's
  CLI script.

### 3. UNCERTAIN / NEEDS-HUMAN-CHECK

- Whether the dialog is reached via "Inspector > Analysis > Variant Calling >
  Call Variants" vs. a Tools menu path. Code defines the dialog and state but
  the menu-wiring glue lives in `ViewerViewController+*` / inspector action
  handlers not fully traced here.
- Expected PASS-row counts (~80-90) and specific positions (21618 T19I, etc.)
  are biological expectations, not code-checkable.

---

## Chapter 02: Reading the Variant Browser

### 1. CLAIMS THAT DO NOT MATCH CODE

- **Column names `Chrom`, `Pos`, `Ref`, `Alt`, `Qual`, `Filter`, `Source`**
  (table lines 48-61). The bundle variant browser is the
  `AnnotationTableDrawerView`. Its real column titles
  (`AnnotationTableDrawerView+Columns.swift:313-332`) are: `ID` (`variant_id`),
  `Chrom` (`chromosome`), **`Position`** (`position`), `Ref`, `Alt`,
  **`Quality`** (`quality`), `Filter`, `Source` (`source`). So `Pos` is
  actually **`Position`** and `Qual` is actually **`Quality`**. There is also an
  `ID` column the chapter omits. (The separate standalone
  `VCFDatasetViewController` table uses `# Chrom Position Ref Alt Type Quality
  Filter AF DP` and has **no Source column** -- that view is for loose VCF
  files, not bundle tracks.)

- **`Source` = "Which variant track the row came from"** (line 56). In code the
  `source` column sorts on `sourceFile`
  (`AnnotationTableDrawerView+TableView.swift:367-368`), which is the
  **per-variant source-file** dimension (the staged VCF filename / multi-sample
  source), populated from the VCF import, not a human "track name." For a
  Lungfish-called track this is the staged VCF basename, not "iVar variants."
  The "distinguish iVar rows from LoFreq rows" use case is plausible only
  because each track has a distinct source file; verify the displayed value.

- **`INFO.AF`, `INFO.DP`, `INFO.SB`, `FORMAT.GT`, `FORMAT.AD` as table
  columns** (lines 57-61). These are not fixed table columns. The table
  promotes INFO keys dynamically; `promotedInfoKeyPatterns`
  (`AnnotationTableDrawerView+Columns.swift:526-527`) maps the title `AF` to
  keys `["AF","af","gnomAD_AF","ExAC_AF","1000G_AF"]`. There is no built-in
  `INFO.SB` or `FORMAT.AD` column; genotype data is shown via a `GT` sub-tab
  (`variantSubtabControl.setLabel("GT", ...)`, lines 51-62), not an `AD`
  column. The dotted names `INFO.AF`/`FORMAT.GT` are doc inventions.

- **"iVar emits `AF`, `DP`, `REF_DP`, `ALT_DP`, `ALT_QUAL`, and a
  `GFF_FEATURE`/`AA_REF`/`AA_ALT` triple when annotations are attached. LoFreq
  emits `AF`, `DP`, `SB`, and `DP4`."** (line 63). The iVar VCF fields are
  **FORMAT** fields `GT:DP:REF_DP:REF_RV:REF_QUAL:ALT_DP:ALT_RV:ALT_QUAL:
  ALT_FREQ[:MERGED_AF:MERGED_DP]` (`IVarTSVToVCFConverter.swift:189,197`) and
  the only INFO field is `TYPE`. There is **no `AF` INFO key** (it is
  `ALT_FREQ` in FORMAT) and **no `GFF_FEATURE`/`AA_REF`/`AA_ALT`** anywhere in
  the emitted iVar VCF. LoFreq's fields are whatever `lofreq call-parallel`
  writes (the pipeline does not post-process them); the doc's specific
  `AF/DP/SB/DP4` list is not produced or validated by Lungfish.

- **Preset chips: "`PASS only`, `AF >= 0.5`, `DP >= 50`, `Coding`, `High
  confidence`."** (line 93). The curated smart tokens
  (`SmartFilterTokens.swift:15-66`) are: `PASS`, `SNV`, `Indel`, `High Impact`,
  `Moderate+`, `Rare (<1%)`, `Qual >= 30`, `DP >= 10`, `ClinVar Path.`, `Het
  Only`, `Bookmarked`, `Minor (<=20%)`, `Mixed (20-80%)`, `Dominant (>=80%)`.
  Additionally, the "Presets" toggle reveals **value chips generated from the
  VCF's actual INFO key values** (`variantInfoPresetValues`,
  `AnnotationTableDrawerView+Columns.swift:980-1015`), i.e. `key=value` chips,
  not a fixed list. None of `AF >= 0.5`, `DP >= 50`, `Coding`, or `High
  confidence` exist as named chips.

- **Smart-filter examples using `Source=iVar` and `Pos>=21000 Pos<=25500`**
  (lines 105-106) and **"Combine clauses with spaces (AND) or with the literal
  token `OR`."** (line 116). The variant free-text filter parses clauses as
  `key OP value` with ops `>= <= != > < = ~` (`VariantDatabase+Query.swift:
  159-177`) joined by **AND only**. There is **no `OR` token** between clauses
  (the only `OR` in the engine is inside the hardcoded PASS preset SQL,
  `VariantDatabase+Query.swift:64`). `Source=` is not a recognized variant-
  table filter key (a `source:` clause exists only in the separate Samples-view
  parser, `+Filtering.swift:1564`). So `Source=iVar` and `OR` are not
  supported as documented.

- **Per-sample syntax `Sample[NA12878].GT=1/1`, `.AF>=0.5`, `.DP>=30`,
  `count(Sample[*].GT=1/1) >= 5`, `Sample[X].GT != Sample[Y].GT`** (lines
  100-114). These ARE supported. `VariantSmartFilter` recognizes sample fields
  `GT`, `AF`, `DP` (`VariantSmartFilter.swift:43-54`), `count(...)` predicates,
  and field-vs-field comparisons (`VariantSmartPredicate`, lines 72-86).
  Operators `>= <= != > < =` match (lines 30-41). Accurate.

- **"use `File > Export Filtered VCF` once the filter is in place."** (line
  38). No such menu command found. The only filtered-VCF export is the **CLI**
  `lungfish variants query ... --filter ... --output`
  (`VariantsCommand.swift:472-556`). The GUI `File` menu exposes a generic
  `exportFASTA` (`MainMenu.swift:216`), not "Export Filtered VCF."
  NEEDS-HUMAN-CHECK whether a filtered-VCF export exists under another menu.

- **"Cmd-click a second variant track ... The browser keeps the first track
  loaded and merges the second track's rows into the same table."** (Step 5,
  lines 122-128). The search index already holds **all** of a bundle's variant
  databases simultaneously (`AnnotationSearchIndex.variantDatabaseHandles`, an
  array keyed by `trackId`; bundle display iterates every variant track,
  `ViewerViewController+BundleDisplay.swift:354-375`). This suggests the browser
  aggregates all variant tracks of a bundle automatically rather than via
  incremental Cmd-click. The "Cmd-click to add a second track" interaction is
  unverified and likely not the actual mechanism. NEEDS-HUMAN-CHECK.

### 2. APP FEATURES MISSING FROM THE DOCS

- A `GT` genotype sub-tab toggles the variant table between variant rows and
  per-sample genotype rows (`AnnotationTableDrawerView+Columns.swift:51-62`).
  The chapter treats genotype as columns, not a sub-tab.
- Bookmarking variants (`SmartToken.bookmarked`,
  `AnnotationTableDrawerView+Bookmarks.swift`) is a real browser feature not
  mentioned.
- Within-sample frequency presets (`Minor <=20%`, `Mixed 20-80%`, `Dominant
  >=80%`) are purpose-built for viral minority-variant reading and go
  undocumented.

### 3. UNCERTAIN / NEEDS-HUMAN-CHECK

- Exact displayed value of the `Source` column for a Lungfish-called track
  (staged VCF basename vs. track display name).
- Whether the genome-track "row of ticks" and reference panel behave exactly as
  described on row selection (centering is plausible but not traced).

---

## Chapter 03: Cross-Caller Comparison

### 1. CLAIMS THAT DO NOT MATCH CODE

- **The entire premise of a guided cross-caller comparison surface.** There is
  **no cross-caller comparison view, no intersection/union export, and no
  codon-aware decomposition feature** in the codebase. Grep for
  `cross.caller|CrossCaller|isec|intersection` across `Sources/` returns only
  unrelated set-operations (annotation type filters, URL sets, genomic-region
  overlap). Specifically false:
  - **"Lungfish's intersection export does the decomposition automatically;
    manual `bcftools isec` does not"** (line 141). No intersection export
    exists. There is no atomize/decompose step on variant tracks.
  - The chapter's whole "intersection vs. union" tooling framing is
    aspirational. Comparison is only possible by eye in the shared variant
    table (all tracks aggregated), not via a feature.

- **bcftools as a first-class documented caller with `--extra-args "--ploidy
  1"`** (lines 46-55, 83). bcftools IS a real caller
  (`ViralVariantCaller.bcftools`) and runs `bcftools mpileup -Ou -f <ref> <bam>
  | bcftools call -mv -Ov -o <out>` (`ViralVariantCallingPipeline.swift:
  1143-1160`). The CLI `--caller bcftools --extra-args "--ploidy 1"` is valid
  (`--extra-args`/`--advanced-options`, `VariantsCommand.swift:600-605`; extra
  args are inserted into the `bcftools call` argument list, line 1154). So this
  part is accurate. NOTE: in the GUI, **bcftools is gated by the
  `lungfish-tools` pack, not `variant-calling`** (`BAMVariantCallingCatalog.swift:
  44-46`), unlike iVar/LoFreq/Medaka/Clair3 which are in `variant-calling`
  (`PluginPack.swift:383-428`). The chapter's "install variant-calling pack"
  setup does not cover bcftools availability.

- **LoFreq Options dialog: "minimum coverage 10, minimum base quality 6,
  significance threshold 0.01, multiple-testing correction Benjamini-Hochberg,
  strand-bias filter on."** (line 77). **These controls do not exist.** The
  dialog's LoFreq pane is a single sentence: "LoFreq is ready to run directly on
  the selected bundle alignment track."
  (`BAMVariantCallingToolPanes.swift:82-84`). The only LoFreq-affecting inputs
  are the shared Minimum Allele Frequency / Minimum Depth thresholds and the
  free-text Extra-arguments box. The actual command is `lofreq call-parallel
  --pp-threads N -f <ref> -o <out> <bam>`
  (`ViralVariantCallingPipeline.swift:1030-1039`) plus any `--extra-args`;
  Lungfish supplies no `--min-cov`, `--min-bq`, `--sig`, or `-B` flags itself.

- **"LoFreq emits a VCF directly; the pipeline finishes with `bcftools sort`,
  `bgzip`, and `tabix`."** (line 81). LoFreq emitting a VCF is correct; the
  sort/bgzip/tabix tail is the general staging shape. Accurate enough; verify
  the literal `bcftools sort` step.

- **Position-specific claims (1193, 1989, 27889, 28881) with exact AF, depth,
  and filter values, and `Pos:1193` filter syntax.** (Step 4, lines 91-141).
  The colon syntax `Pos:1193` is **not a valid filter operator** (ops are `>=
  <= != > < = ~`, `VariantDatabase+Query.swift:164`). The biological numbers are
  not code-checkable and read as illustrative. The codon-merge mechanics (iVar
  one `GG->AA` row + one `G->C` row; LoFreq three single-base rows) are
  consistent with `IVarCodonMerger` behavior, but again the "INFO carrying the
  protein consequence `R203K`" claim (lines 133-135) is wrong: iVar's VCF has
  no INFO AA field (see ch.01).

- **`sb_fdr` filter value** (line 119) for LoFreq. Lungfish does not generate or
  rename LoFreq filter strings; whatever `lofreq` writes is passed through. The
  iVar strand-bias filter code is `sb` (`IVarTSVToVCFConverter.swift:125`), not
  `sb_fdr`. The `sb_fdr` token, if real, comes from upstream LoFreq, not
  Lungfish; unverifiable here.

### 2. APP FEATURES MISSING FROM THE DOCS

- That all variant tracks of a bundle are shown together automatically (the
  real comparison substrate) is the feature that should anchor this chapter; it
  is described only as a Cmd-click add (see ch.02).
- The `--extra-args` / `--advanced-options` passthrough (the only way to reach
  LoFreq/bcftools internal knobs) is under-explained relative to its
  importance here.

### 3. UNCERTAIN / NEEDS-HUMAN-CHECK

- Whether LoFreq actually runs on an un-trimmed track by design or whether that
  is purely an operator convention (code accepts any eligible BAM; no caller-
  specific trim coupling for LoFreq, unlike iVar's primer-trim attestation).
- The exact LoFreq/bcftools filter strings shown in any real run.

---

## Chapter 04: Nanopore Variant Calling

### 1. CLAIMS THAT DO NOT MATCH CODE

- **Medaka command: "`medaka_haploid_variant` or the equivalent Medaka
  inference pipeline."** (line 115). Code runs **`medaka variant`**, not
  `medaka_haploid_variant`: `medakaArguments` returns `["variant", ...,
  "-i", <fastq>, "-r", <ref>, "-o", <out>, "-m", <model>, "-t", <threads>]`
  (`ViralVariantCallingPipeline.swift:1120-1130`). Also notable: Medaka takes a
  **reconstructed FASTQ** input (`-i`), not the BAM; the pipeline rebuilds a
  FASTQ from the alignment before calling (lines 183-184, 240-286). The chapter
  says "runs the selected caller against the primer-trimmed BAM," which is true
  for Clair3 but not Medaka.

- **Clair3 command and tool name.** Doc: "`run_clair3.sh` with `--bam_fn`,
  `--ref_fn`, `--model_path`, `--platform=ont`, and `--threads`." (line 115).
  Code uses tool `.clair3` with args `--bam_fn=<bam> --ref_fn=<ref>
  --threads=N --platform=ont --model_path=<model> --output=<dir>`
  (`clair3Arguments`, `ViralVariantCallingPipeline.swift:1132-1141`), and reads
  back `merge_output.vcf.gz` (line 775). Substantively correct (the `=`-joined
  long options and the `--output` dir are extra detail the doc omits, but the
  flags listed are real).

- **Medaka model picker: "Open the `Basecaller model` dropdown. The picker
  lists the models bundled with the current Medaka build, grouped by pore
  chemistry, with the most recent R10.4.1 super-accuracy model selected by
  default."** (lines 109-112). **There is no dropdown/picker.** The Medaka and
  Clair3 model controls are **free-text fields** with the placeholder
  `r1041_e82_400bps_sup_v5.0.0` (`BAMVariantCallingToolPanes.swift:107-123`),
  bound to `state.medakaModel`, which **initializes empty** (`""`,
  `BAMVariantCallingDialogState.swift:86`). Nothing is "selected by default";
  the run button is disabled until the user types a model
  (`isRunEnabled` requires non-empty model, lines 221-224). The "grouped by pore
  chemistry" list does not exist.

- **Medaka options: "`Minimum mapping quality 20`, `Minimum depth 20`, `Region`
  blank."** (line 113). These controls do not exist in the Medaka pane. The only
  Medaka-specific control is the model text field. The shared Minimum Depth
  default is `10`, not `20` (`BAMVariantCallingDialogState.swift:74`); there is
  no "minimum mapping quality" or "region" field anywhere in the dialog.

- **Both Medaka and Clair3 use a single shared model field.** The doc implies a
  Medaka-specific picker and a separate Clair3 model path. In code BOTH callers
  write to the same `state.medakaModel` field
  (`BAMVariantCallingToolPanes.swift:112,121`), and the CLI flag for both is
  `--medaka-model` (`VariantsCommand.swift:585`, help: "Required ONT/basecaller
  model identifier or Clair3 model path"). The Clair3 CLI example correctly uses
  `--medaka-model /models/clair3/...` (doc line 135), which is the real flag.

- **CLI entry points** (front-matter lines 13-14: `--caller medaka`,
  `--caller clair3`). Valid; both are accepted callers
  (`VariantsCommand.swift:570`).

### 2. APP FEATURES MISSING FROM THE DOCS

- Medaka requires model metadata or the pipeline throws
  `medakaRequiresModelMetadata` (`ViralVariantCallingPipeline.swift:86,215-217`).
  Worth surfacing as the failure mode.
- Medaka's FASTQ-reconstruction-from-BAM step (and its temp `medaka_*.fastq`
  sidecars) is an implementation reality not mentioned.

### 3. UNCERTAIN / NEEDS-HUMAN-CHECK

- Whether any Medaka model list is surfaced elsewhere (e.g. autocomplete). Only
  a placeholder string was found in the pane.
- The chapter is explicitly marked aspirational ("partially aspirational",
  "hypothetical run `ONT-SAMPLE-01`"); expected row counts are not checkable.

---

## Chapter 05: Consensus and Lineage

### 1. CLAIMS THAT DO NOT MATCH CODE

- **CORE CLAIM IS FALSE: "Lungfish writes a consensus FASTA as a side output of
  the iVar Variant Calling step ... whenever the consensus allele-frequency
  threshold is set in the dialog."** (line 34, and the whole procedure lines
  41-68). The iVar variant pipeline writes **only VCF + tabix + SQLite**; it
  never produces a `.consensus.fa`. Grep of `ViralVariantCallingPipeline.swift`
  and `BundleVariantTrackAttachmentService.swift` for any consensus FASTA output
  returns nothing. The `ivarConsensusAF` field (default 0.75) is consumed by
  **`IVarCodonMerger.mergeRuleCheck`** (`IVarCodonMerger.swift:50,105-115`) to
  decide whether adjacent within-codon SNPs collapse into one "consensus
  haplotype" VCF row versus splitting into per-base rows. It is a codon-merge AF
  rule, NOT a "call this base vs. mask as N" consensus threshold.
  `IVarTSVToVCFConverter` uses it the same way (lines 79-83). There is no `ivar
  consensus`, `samtools consensus`, or `bcftools consensus` call in the variant
  pipeline.

- **"The consensus output is iVar-specific in Lungfish; LoFreq and Medaka write
  a VCF only."** (line 46). Misleading: **iVar also writes a VCF only** in this
  pipeline. No caller produces a consensus FASTA via Call Variants.

- **Consensus AF threshold table (`0.5` / `0.75` / `0.9` -> base vs N)** (lines
  54-58). The threshold does not control N-masking anywhere. The N-mask
  semantics described do not exist in this code path.

- **"`Consensuses` subfolder of the reference bundle ... one FASTA per call"**
  and **"a `.consensus.fa`" second output in the Operations Panel** (lines
  66-68). No `Consensuses` folder and no `.consensus.fa` are created by the
  variant pipeline. The attachment service writes the VCF.GZ, tabix, and SQLite
  into the bundle's variants area (`BundleVariantTrackAttachmentService`),
  nothing consensus-related.

- **"File > Export > Consensus FASTA" and "Right-click ... Save As FASTA" on a
  consensus track** (lines 76-77, 87). No "Export > Consensus FASTA" menu and no
  consensus track exist. The `File` menu has a generic `exportFASTA`
  (`MainMenu.swift:216,999`), not a consensus-track exporter.

- **WHERE CONSENSUS ACTUALLY LIVES (so the chapter can be re-pointed):**
  - **`lungfish msa consensus`** (`MSACommand.swift:678`) and the MSA
    "Create consensus FASTA" action (`MultipleSequenceAlignmentActionRegistry.swift:
    478-485`) build a consensus from aligned rows with explicit thresholds and
    gap policy. This is MSA-scoped, not VCF-scoped.
  - **`samtools consensus`** for a region is used by `AlignmentDataProvider`
    (`AlignmentDataProvider.swift:273,305`) to preview a consensus over an
    alignment region (Inspector consensus mode controls live in
    `InspectorView.swift:741-814`: consensus mode, IUPAC ambiguity, gap masking,
    min depth, min mapQ, min baseQ). This is alignment-scoped.
  - **nf-core/viralrecon** (`ViralReconWizardSheet.swift`) runs an end-to-end
    pipeline whose Consensus picker (`ViralReconConsensusCaller`, lines 295-312)
    does produce a consensus FASTA. This is the only "variant-call -> consensus
    FASTA" path, and it is a separate wizard, not the Call Variants dialog.

- **Pangolin / Nextclade boundary** (lines 88-101). Accurate in spirit:
  Lungfish ships Pangolin and Nextclade as conda tools in the
  `sars-cov2-lineage`-style packs (`PluginPack.swift:703,725-731,781-787`) and
  cites them (`ToolBibliographyCatalog.swift:191-212`), but there is no in-app
  consensus-to-lineage automation in the variant browser. Saying "Lungfish stops
  at the consensus FASTA" is wrong only because Lungfish never produces that
  consensus FASTA from the variant step in the first place. The "defer to
  external Pangolin/Nextclade web tools" framing is consistent with the absence
  of any in-app lineage assignment.

### 2. APP FEATURES MISSING FROM THE DOCS

- The real consensus surfaces (MSA consensus, alignment-region `samtools
  consensus`, viralrecon Consensus caller) are entirely absent from this
  chapter, which instead documents a non-existent iVar consensus output.
- `Freyja` wastewater lineage **demixing** (`lungfish freyja demix`,
  `FreyjaCommand.swift`) is the closest thing to in-app lineage work for mixed
  samples and is not mentioned.

### 3. UNCERTAIN / NEEDS-HUMAN-CHECK

- Whether any consensus-from-VCF path is reachable from the GUI at all (only
  viralrecon and MSA/alignment consensus were found). A human should confirm
  this chapter is rebuilt around one of those, not around Call Variants.

---

## Chapter 06: Importing Existing VCFs

### 1. CLAIMS THAT DO NOT MATCH CODE

- **CLI: "`lungfish import vcf <path-to-vcf> --project <path-to-project>` ...
  Pass `--reference <bundle-name>` to skip inference and force a specific
  bundle."** (line 70). The CLI `VCFSubcommand` (`ImportCommand.swift:376-474`)
  has only `inputFile` (positional) and `--output-dir`/`-o`. There is **no
  `--project` and no `--reference` flag.** It does **not** infer a reference,
  does **not** apply the alias map, does **not** attach a bundle variant track,
  and does **not** bgzip/index a plain VCF. It validates the header, prints a
  summary (format, variant count, types, samples, contigs), and **copies** the
  VCF plus any existing `.tbi`/`.csi` into the output dir (lines 423-473). The
  reference-inference / alias-matching / attach behavior the chapter describes
  is **GUI-only** (`VCFAutoIngestor` + `VCFReferenceInference.infer`,
  `VCFAutoIngestor.swift:107-111`), not the CLI command.

- **"After import, the `lungfish variants` CLI can extract or filter the
  bundle-owned variant database"** with `variants extract-sample` and `variants
  query` (lines 72-88). These subcommands exist and the flags are correct
  (`VariantsCommand.swift:388-470` extract-sample: `<bundlePath> --sample
  --output`; `472-556` query: `<bundlePath> --filter --output --limit`). BUT
  they operate on a **bundle that already has a SQLite variant database**
  (`openDefaultVariantDatabase` requires a manifest variant track with
  `databasePath`, lines 122-138). The CLI `import vcf` does NOT create such a
  bundle/database, so the chapter's implied chain (CLI import -> CLI
  extract/query) is broken: you must import via the GUI (or otherwise build the
  bundle DB) before `extract-sample`/`query` work. Accurate that the per-sample
  filter grammar matches the browser (`VariantSmartFilter`, fields `GT/AF/DP`,
  `count(...)`).

- **"Lungfish reads VCF 4.0, 4.1, 4.2, 4.3, and 4.4. Older VCFv3 files are not
  accepted directly."** (line 50, Troubleshooting line 110). The CLI import does
  **not** check the VCF version or reject VCFv3; it accepts any file with
  extension `vcf`/`bcf` (after stripping `.gz`) and runs the reader
  (`ImportCommand.swift:404-411`). There is no VCFv3-rejection code path here.
  Whether the GUI import or `VCFReader` rejects v3 is unverified. Treat the
  "v3 rejected" claim as UNCERTAIN, not confirmed.

- **".bcf is accepted by import** (the CLI guard is `["vcf","bcf"]`,
  `ImportCommand.swift:408`), but the chapter's "Accepted formats" table (lines
  44-48) lists only `.vcf`, `.vcf.gz`, `.vcf.gz`+`.tbi` and omits `.bcf`.
  Conversely the table claims "Lungfish bgzips and indexes it on import" for a
  plain `.vcf` -- the **CLI does not** (it only copies). The bgzip/index-on-
  import behavior is GUI-side; verify.

- **Reference inference + alias map (GUI).** The chapter's GUI Import Center
  flow (Variants tab, "Inferred reference" field, alias matching
  `NC_045512.2` -> `MN908947.3`) is grounded: the Import Center has a
  `.variants` tab (`ImportCenterView.swift:72`) and `VCFReferenceInference`
  with NCBI-accession extraction exists (`VCFAutoIngestor.swift:107-111`). The
  drag-drop path and auto-ingest also exist (`VCFAutoIngestor`). This part is
  accurate; the defect is conflating CLI capabilities with GUI capabilities.

- **`features.yaml` `import.vcf` over-claims for the CLI.** The entry's notes
  (features.yaml lines 30-35) say inference "applies RefSeq, UCSC, and Ensembl
  alias mappings"; that is true of the GUI path but the listed
  `Sources/LungfishCLI/Commands/ImportCommand.swift` source does none of it.
  Flag for the cartographer: the CLI import is a copy+summarize, not an
  inference+attach.

### 2. APP FEATURES MISSING FROM THE DOCS

- `analyze validate <vcf>` (`AnalyzeCommand.swift:222-229,301-303`) validates a
  VCF's format and is a natural companion to import; undocumented here.
- The import summary the CLI prints (variant-type breakdown, sample list,
  contig count) is useful provenance the chapter does not mention.

### 3. UNCERTAIN / NEEDS-HUMAN-CHECK

- Whether the GUI import rejects VCFv3 and rejects a stale `.tbi`
  (Troubleshooting lines 108-110). Neither behavior was found in the CLI path;
  the GUI ingestor was not fully traced.
- Whether `ConvertCommand` can help with VCFv3 (it cannot: `ConvertCommand`
  handles only fasta/genbank/fastq/gff3, no VCF, `ConvertCommand.swift:91-166`).
  The chapter's advice to use external `bcftools convert`/`vcftools` is sound.

---

## Section-wide

### Caller roster (authoritative)

`ViralVariantCaller` = **lofreq, ivar, medaka, bcftools, clair3**
(`BundleVariantCallingModels.swift:5-25`). GUI `BAMVariantCallingToolID` adds
**gatk-haplotype-caller** and **gatk-whatshap-phased**
(`BAMVariantCallingCatalog.swift:9-16`). Default dialog selection is **LoFreq**.
The Part-II viral chapters describe a three-caller world (iVar/LoFreq/Medaka)
plus a documented bcftools and Clair3; the actual world is five viral callers
plus two GATK germline options (the latter cross-referenced to Part 06, which
is correct).

### Real caller command lines (for any prose that quotes them)

- iVar: `samtools mpileup -aa -A -d 600000 -B -Q 20 -q 0 -f <ref> <bam> | ivar
  variants [extra] -p <prefix> -q 20 -t <min-af|0.05> -m <min-depth|10> -r <ref>
  [-g <gff>]` (`ViralVariantCallingPipeline.swift:1041-1069`).
- LoFreq: `lofreq call-parallel [extra] --pp-threads N -f <ref> -o <out> <bam>`
  (lines 1030-1039). No `--call-indels` by default; no min-cov/min-bq/sig flags.
- Medaka: `medaka variant [extra] -i <fastq> -r <ref> -o <out> -m <model> -t N`
  (lines 1120-1130) -- FASTQ input reconstructed from the BAM, NOT
  `medaka_haploid_variant`.
- Clair3: `clair3 --bam_fn=<bam> --ref_fn=<ref> --threads=N --platform=ont
  --model_path=<model> --output=<dir> [extra]`; reads `merge_output.vcf.gz`
  (lines 1132-1141, 773-799).
- bcftools: `bcftools mpileup -Ou -f <ref> <bam> | bcftools call [extra] -mv -Ov
  -o <out>` (lines 1143-1160).

### iVar VCF field reality (recurs in ch.01/02/03)

The Lungfish iVar VCF (`IVarTSVToVCFConverter.swift:112-146`) has INFO =
`TYPE` only; allele depth/frequency are FORMAT fields
`GT:DP:REF_DP:REF_RV:REF_QUAL:ALT_DP:ALT_RV:ALT_QUAL:ALT_FREQ` (+`MERGED_AF`/
`MERGED_DP` on merged rows). Filters: `PASS`, `ft` (Fisher exact vs error rate,
p>0.05), `bq` (ALT_QUAL<20), `sb` (strand bias, only when not ignoring it). No
`AF` INFO key, no `GFF_FEATURE`/`AA_REF`/`AA_ALT`. Any doc sentence putting AF
or amino-acid consequence "in INFO" for an iVar row is wrong.

### Variant browser column reality (recurs in ch.02/03)

Bundle browser = `AnnotationTableDrawerView`; columns `ID, Chrom, Position, Ref,
Alt, Quality, Filter, Source` (+ dynamically promoted INFO/sample columns and a
`GT` genotype sub-tab) (`AnnotationTableDrawerView+Columns.swift:313-332`).
Docs' `Pos`/`Qual` should read `Position`/`Quality`; `INFO.AF`/`FORMAT.GT`-style
column names are invented. Free-text filter ops: `>= <= != > < = ~`, AND-only,
no `OR`, no colon syntax, no `Source=` (`VariantDatabase+Query.swift:159-177`).
Per-sample `Sample[X].GT/AF/DP`, `count(...)`, field-vs-field comparisons ARE
real (`VariantSmartFilter.swift`).

### Does cross-caller comparison work as documented? NO.

There is no cross-caller comparison feature, no intersection/union/atomize
export, and no codon-aware VCF decomposition. The shared variant table does
aggregate all of a bundle's variant tracks (with a `Source` column), so visual
side-by-side reading is possible, but every tooling claim in ch.03 (intersection
export, automatic decomposition, the LoFreq options dialog) is unbacked. The
"Cmd-click a second track to merge" interaction is also unverified and probably
not how aggregation happens.

### Does consensus/lineage work as documented? NO.

The iVar Call Variants step does not write a consensus FASTA;
`ivarConsensusAF` is a codon-merge rule, not an N-mask threshold. No
`Consensuses` folder, no `.consensus.fa`, no `File > Export > Consensus FASTA`.
Real consensus generation lives in MSA (`lungfish msa consensus`), alignment-
region preview (`samtools consensus` via `AlignmentDataProvider`/Inspector), and
the nf-core/viralrecon wizard. Pangolin/Nextclade are shipped as external conda
tools and cited; there is no in-app lineage assignment. Chapter 05 must be
rebuilt around the viralrecon/MSA paths, not around Call Variants.

### features.yaml notes for the cartographer (FYI only; not my edit to make here)

- `import.vcf`: the CLI source listed does copy+summarize only; inference/alias/
  attach is GUI-side (`VCFAutoIngestor`/`VCFReferenceInference`). The notes
  should distinguish CLI vs GUI capability, and `--reference`/`--project` flags
  do not exist on the CLI.
- `viewport.variant-browser`: the listed `VCFDatasetViewController` is the
  standalone-VCF dashboard (no Source column); the bundle browser the chapters
  describe is `AnnotationTableDrawerView` (+`AnnotationSearchIndex`). Columns are
  `ID/Chrom/Position/Ref/Alt/Quality/Filter/Source`, not `CHROM POS ID REF ALT
  QUAL FILTER GT AF`.
- `variants.call`: roster should read five callers (lofreq, ivar, medaka,
  bcftools, clair3) plus the two GATK options, and note Medaka uses `medaka
  variant` on a reconstructed FASTQ.
