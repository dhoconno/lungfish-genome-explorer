# Ground-truth reality map: 06-classification

Arbiter-of-truth comparison of the eight Classification chapters against the
actual Swift source and the shipped CLI binary (`.build/debug/lungfish-cli`,
version `0.5.0-alpha11`). Every claim below is grounded in a cited symbol,
flag, file, or live `--help` output. "Does not match code" means the doc states
something the code does not do; it is not a style note.

Primary sources read:
- CLI: `LungfishCLI.swift` (root subcommand registry), `ClassifyCommand.swift`, `EsVirituCommand.swift`, `TaxTriageCommand.swift`, `NaoMgsCommand.swift`, `BlastCommand.swift`, `FreyjaCommand.swift`, `CzIdCommand.swift`, `ImportCzIdSubcommand.swift`, `NvdCommand.swift`, `BuildDbCommand.swift`, `CompositionCommand.swift`
- GUI wizards: `UnifiedMetagenomicsWizard.swift`, `ClassificationWizardSheet.swift`, `EsVirituWizardSheet.swift`, `TaxTriageWizardSheet.swift`, `NaoMgsImportSheet.swift`, `NvdImportSheet.swift`, `CzIdImportSheet.swift`
- Menus: `Sources/LungfishApp/App/MainMenu.swift`, `AppDelegate+ToolsMenu.swift`
- Viewports: `LungfishApp/Views/Metagenomics/TaxonomyViewController.swift` + `TaxonomySunburstView.swift`, `LungfishEsVirituUI/`, `LungfishTaxTriageUI/`, `LungfishNaoMgsUI/`, `LungfishNvdUI/`
- BLAST cluster: `LungfishKit/ClassifierActionBar.swift`, `BlastConfigPopoverView.swift`, `BlastResultsDrawerTab.swift`; `LungfishCore/Services/Blast/BlastVerificationRequest.swift`, `BlastService.swift`
- Import Center: `LungfishApp/Views/ImportCenter/ImportCenterViewModel.swift`

Four facts dominate the whole section and recur per chapter:

1. **There is NO top-level `lungfish classify` command; the real Kraken2 runner
   is `lungfish conda classify`.** `ClassifyCommand` (`commandName: "classify"`,
   `ClassifyCommand.swift:31`) is **not** in the root `subcommands:` list
   (`LungfishCLI.swift:32-76`), so `./lungfish-cli classify` returns
   `Error: Unexpected argument 'classify'`. It is registered as a **subcommand of
   `conda`**: `lungfish conda classify <fastq> --db <db>` ("Run Kraken2
   taxonomic classification on FASTQ or FASTA inputs", with `--preset`,
   `--profile`/Bracken, `--confidence`, `--min-hit-groups`, `--memory-mapping`,
   `--quick`). Chapters that write `CLI: lungfish classify` have the wrong path;
   the correct invocation is `lungfish conda classify`. (`CompositionCommand` /
   `composition` is genuinely not registered anywhere and is not runnable.)
2. **The GUI wizard ships THREE runnable classifiers, not four.** The unified
   wizard (`UnifiedMetagenomicsWizard.AnalysisType`, lines 102-145) has exactly
   `classification` (Kraken2), `viralDetection` (EsViritu), `clinicalTriage`
   (TaxTriage). **NAO-MGS is import-only**; it is not a tool in the wizard.
3. **There is ONE menu item, not a per-tool submenu.** The real path is
   `Tools > FASTQ/FASTA Operations > Classification…`, a single item wired to
   `showFASTQClassificationOperations` (`MainMenu.swift:690-694`). Paths like
   `... > Classification > Kraken2` / `> EsViritu` / `> TaxTriage` / `> NAO-MGS`
   do not exist as menu paths.
4. **NVD (Novel Virus Diagnostics) is a whole tool/viewport with zero chapter
   coverage.** It has a CLI (`nvd import`, `nvd summary`), an Import Center card,
   an import sheet, and a dedicated viewport (`NvdResultViewController`). See
   Section-wide.

---

## Chapter 01: What Is Read Classification

### 1. CLAIMS THAT DO NOT MATCH CODE

- **"the four classifiers Lungfish ships" / "four runnable classifiers"** (lines
  38, 42, 44, 46, and the 5-row table at 54-60). Only three are runnable in the
  app: Kraken2, EsViritu, TaxTriage (`UnifiedMetagenomicsWizard.swift:102-145`).
  NAO-MGS is import-only (`NaoMgsCommand` has only `import`/`summary`
  subcommands, `NaoMgsCommand.swift:43`; the GUI surface is `launchNaoMgsImport`
  / `NaoMgsImportSheet`, not the wizard).
- **"pick the matching tool from the Unified Metagenomics Wizard at
  `Tools > FASTQ/FASTA Operations > Classification`"** (line 38), repeated as the
  `entry_points` front-matter (line 11). The menu item is literally
  `Classification…` and opens the wizard, but the wizard never offers NAO-MGS,
  so "pick NAO-MGS from this wizard" (implied by the four-tool framing) is
  impossible.
- **"Every classifier produces output that opens in the same taxonomy viewport"
  / "Lungfish renders that distribution three ways inside the same taxonomy
  viewport: a sunburst ... a sortable per-taxon table ... and a breadcrumb bar"**
  (lines 34, 84). Only **Kraken2 and imported CZ-ID** open the sunburst
  `TaxonomyViewController` (`ViewerViewController+Taxonomy.swift:60`,
  `ViewerViewController+CzId.swift`). EsViritu, TaxTriage, NAO-MGS, and NVD each
  have a **distinct, table-based** viewport (`EsVirituResultViewController`,
  `TaxTriageResultViewController`, `NaoMgsResultViewController`,
  `NvdResultViewController`) with no sunburst. The "same viewport for all" claim
  is false.
- **Kraken2 row: "Viral fits in 16 GB"** (table, line 56). The Viral DB is
  ~0.5 GB and chapter 02's own table says "1 GB" minimum RAM. "16 GB" here is an
  internal contradiction (chapter 05's comparison table repeats the 16 GB
  figure). NEEDS-HUMAN-CHECK on the canonical RAM number, but both cannot be
  right.
- **"the Plugin Manager. ... runs `micromamba` against the bioconda channel ...
  and downloads the matched database from the official source"** (line 100). The
  micromamba/bioconda mechanism is real (`CondaCommand`, MEMORY conda-plugin
  notes). However TaxTriage additionally requires **Nextflow + a container
  runtime (Docker or Apple Containerization)**, not just a conda database
  (`TaxTriageCommand.swift:13-14, 37-39`). The "install a database and the
  wizard runs the tool directly" story (line 101) omits this for TaxTriage.

### 2. APP FEATURES MISSING FROM THE DOCS

- **NVD** is entirely absent from the chapter's tool roster (it belongs in the
  "imported results" set alongside CZ-ID). See Section-wide.
- **Kraken2 runs Bracken.** The wizard tool is labelled "Classify & Profile
  (Kraken2)" and its description says it "estimates community abundance using
  Kraken2 and Bracken" (`UnifiedMetagenomicsWizard.swift:129, 138`). The chapter
  never mentions abundance profiling.
- **Import of native-tool results.** Kraken2, EsViritu, and TaxTriage results
  produced outside Lungfish can be imported via the Import Center
  (`ImportCenterViewModel.swift:401-464`); the chapter frames only CZ-ID as
  importable.

### 3. UNCERTAIN / NEEDS-HUMAN-CHECK

- The narrative "100 to 200 GB of disk for all four classifiers" (line 104)
  cannot be verified from source; disk figures live in plugin-pack manifests not
  read here.
- The per-database RAM figures in the table (Standard/PlusPF "67/72 GB") are
  plausible but unverified against the actual pack manifests.

---

## Chapter 02: Running Kraken2

### 1. CLAIMS THAT DO NOT MATCH CODE

- **`CLI: lungfish classify`** (front-matter line 12). Wrong path. The runnable
  Kraken2 CLI is **`lungfish conda classify <fastq> --db <db>`** (see fact 1;
  confirmed via `conda classify --help`). Adjacent surfaces:
  `lungfish import kraken2 <kreport-file>` (import existing results) and
  `lungfish build-db kraken2 <result-dir>` (`BuildDbCommand`). A headless run
  exists; it just lives under `conda`, not as a top-level `classify`.
- **"a Confidence threshold slider (default 0.0, which keeps every hit)"**
  (line 133). The actual default is **0.2** (`ClassificationWizardSheet.swift:77`
  `@State private var confidence: Double = 0.2`; the header ASCII art shows
  `0.20` at line 48). The "0.0 keeps every hit" rationale is fabricated.
- **The wizard's options are described as only "Database / Confidence / Minimum
  hit groups"** (lines 130-133). The wizard also has a **Sensitivity preset**
  picker (Sensitive / Balanced / Precise, default `.balanced`,
  `ClassificationWizardSheet.swift:73, 460-467`) shown prominently above
  Advanced. The chapter omits it entirely. (Min hit groups default 2 is correct:
  `minimumHitGroups: Int = 2`, line 78.)
- **Entry path "open `Tools > FASTQ/FASTA Operations > Classification`. ... In
  the Classifier picker, choose Kraken2"** (lines 128-130). The menu item and
  picker are real, but the chapter's repeated `... > Classification > Kraken2`
  menu path (front-matter line 11) is not a menu path.
- **"Open `Lungfish > Settings > Plugin Manager`"** (line 108) and **"Open
  `Lungfish > Settings > Plugin Manager`, find the Kraken2 row"** (procedure).
  The Plugin Manager is at **`Tools > Plugin Manager…`** (Cmd-Shift-B),
  `MainMenu.swift:783-789`. It is not under `Lungfish > Settings`.
- **"From the CLI, use `lungfish conda db info Viral`"** (line 119) and
  **`lungfish conda db info "..."` / `lungfish conda db list`** (echoed in chs
  03-05). **These are real and correct**: `lungfish conda db` has `list`, `info`
  ("Show installed database version and update status"), `download`, `remove`,
  and `recommend` (confirmed via `conda db --help`). No change needed.
- **"the database under `~/.lungfish/conda/databases/kraken2/<scope>/`"**
  (line 116). NEEDS-HUMAN-CHECK on the exact subpath; MEMORY documents the conda
  root as `~/.lungfish/conda` but the `databases/kraken2/<scope>` layout was not
  verified in source.

### 2. APP FEATURES MISSING FROM THE DOCS

- **Sensitivity preset** (above) and **Bracken abundance profiling** (the tool
  is "Classify & Profile"). The CLI-only `ClassifyCommand` (even if unregistered)
  documents the surface: `--preset sensitive|balanced|precise`, `--profile`
  (Bracken), `--bracken-read-length/-level/-threshold`, `--memory-mapping`,
  `--quick` (`ClassifyCommand.swift:49-79`).
- **`lungfish build-db kraken2`** builds a SQLite database from a Kraken2 result
  directory (`--force`, `--no-cleanup`); not mentioned.

### 3. UNCERTAIN / NEEDS-HUMAN-CHECK

- The worked-example bundle name `SRR36291587.kraken2.viral.lungfishtax`
  (line 170) and the right-click action **"Extract Reads as FASTQ Bundle"**
  (line 196) are plausible (the taxonomy table has Extract Reads), but the exact
  result-bundle filename pattern and menu wording were not confirmed.
- Sunburst layout: the chapter says sunburst "at the top, table below"
  (lines 39-40). The real `TaxonomyViewController` is a **side-by-side split**
  ("Sunburst Chart | Taxonomy Table", `TaxonomyViewController.swift:58`). The
  sunburst, table, and breadcrumb all exist; the vertical-vs-horizontal layout
  is the only discrepancy.

---

## Chapter 03: Running EsViritu

### 1. CLAIMS THAT DO NOT MATCH CODE

- **`CLI: lungfish esviritu run`** (front-matter line 12). The real subcommand
  is **`lungfish esviritu detect`** (`EsVirituCommand` -> `detect`, confirmed by
  `esviritu --help`: `USAGE: lungfish esviritu detect ... --sample <sample>`).
  There is no `esviritu run`.
- **"Power users ... can install with `lungfish esviritu db install`"** (line
  125). No such subcommand: `esviritu` has only `detect`. Database install is
  via the Plugin Manager / conda, not an `esviritu db` group.
- **The "Options" defaults: "minimum read length 100 nt, minimum breadth 10%,
  minimum read count 50"** (line 148), and **"defaults: 50 reads and 10% breadth
  at 1x, configurable in the wizard"** (line 93). The EsViritu wizard exposes
  **only Min Read Length (default 100) and a quality-filter toggle**
  (`EsVirituWizardSheet.swift:88, 92`). There is no minimum-breadth or
  minimum-read-count field in the wizard. The CLI `detect` likewise exposes
  `--min-read-length` (default 100) and `--no-qc`, not breadth/read-count
  thresholds. The "50 reads / 10% breadth" thresholds are fabricated as wizard
  options.
- **The "strain comparison view": "Select two rows ... click Compare ... stacks
  the two coverage tracks ... a small bar chart breaks down ... unique ... split
  ... tie-breaker"** (entire section, lines 192-214, plus front-matter shot
  `esviritu-strain-comparison`). **No such feature exists in EsViritu.** There is
  no `Compare` control, no two-track stack, no unique-read bar chart in
  `LungfishEsVirituUI/`. (A `StrainComparisonView` exists, but in
  **`LungfishTaxTriageUI/`**, and it is a per-position SNP matrix table, not a
  coverage-track comparison.)
- **Mini-BAM trigger: "click any strain row and then click Show reads in the
  inspector"** (line 219). There is no "Show reads" button. The mini-BAM appears
  **automatically in the detail pane** when a virus row with BAM data is
  selected (`EsVirituDetailPane.swift:25-27`; `EsVirituResultViewController.swift:101`).
- **"the EsViritu viewport's left pane is a sortable strain table ... columns
  for accession, organism, lineage label ..., read count, mean depth, and
  percent breadth at 1x"** (line 164). The real single-sample table is
  `ViralDetectionTableView` and the batch table (`BatchEsVirituTableView`) has
  columns including reads, uniqueReads, rpkmf, **coverage (breadth %)**. NEEDS
  reconciliation: "mean depth" / "lineage label" columns were not confirmed;
  "coverage" is breadth, and RPKMF is a real column the chapter omits.

### 2. APP FEATURES MISSING FROM THE DOCS

- **Segment completeness grid** for segmented viruses (`SegmentCompletenessView`,
  "Segment Coverage (N of M segments detected)", green/yellow by depth). Not
  mentioned.
- **Row context menu**: "Extract Reads…", **"BLAST Verify…"**, and a "Look Up on
  NCBI" submenu (GenBank Accession / Assembly Record / PubMed Literature /
  Taxonomy Browser) (`ViralDetectionTableView.swift:718-748`).
- **`--paired`, `--no-qc`, `--db`, `--extra-args`** on `esviritu detect`.

### 3. UNCERTAIN / NEEDS-HUMAN-CHECK

- DB size claims "roughly 400 MB compressed, ~5 GB uncompressed, 19,925 curated
  viral assemblies across 63 families" (line 99) and ">=8 GB RAM" are specific
  and unverified against the pack manifest. The wizard doc string says "~5 GB
  extracted" (`EsVirituWizardSheet.swift:44`), which is consistent for the
  uncompressed figure only.

---

## Chapter 04: Running TaxTriage

### 1. CLAIMS THAT DO NOT MATCH CODE

- **The "Profile step": "choose Clinical surveillance (default) ... research and
  wastewater profiles change the score weighting"** (lines 145-149, 218, and
  shots referencing a profile picker). **No profile picker exists.** The
  `TaxTriageWizardSheet` fields are: Kraken2 Database picker, Sequencing Platform
  (Illumina / Oxford Nanopore / PacBio), Skip-assembly toggle (default true),
  Skip-Krona toggle, and Advanced (k2Confidence 0.2, topHits 10, maxMemory 16 GB,
  maxCPUs) (`TaxTriageWizardSheet.swift:90-104, 404-451`). "Clinical /
  research / wastewater profiles" are fabricated.
- **RESOLVED 2026-07-05: The confidence score is now named as TASS in the active
  chapter.** The old standalone `TaxTriageConfidenceView` chart was removed
  because the result viewport uses a TASS-ranked organism table with a compact
  confidence bar cell. The documented high/medium/low tiers now match the UI's
  >=0.8 / 0.4-0.8 / <0.4 thresholds.
- **Manual-review flag names `LOW_BREADTH`, `CLASSIFIER_DISAGREE`,
  `BLANK_MATCH`, `LOW_QUALITY_SUPPORT`** (table, lines 203-208). **None of these
  identifiers exist** in `LungfishTaxTriageUI/` or the TaxTriage workflow/IO. The
  entire flag taxonomy is fabricated.
- **Export path: "File > Export > TaxTriage Batch Report" with "Clinical
  reporting / research summary / surveillance feed" templates producing "a PDF
  summary, a per-sample CSV ..., and a provenance sidecar"** (lines 219-230).
  The real exporter is `TaxTriageBatchExporter`, which generates a **cross-sample
  organism matrix CSV** (columns: Organism, Mean TASS, Samples Detected,
  Contamination Risk, then per-sample TASS) and a text summary report
  (`TaxTriageBatchExporter.swift:14-65`). There are **no templates**, **no PDF**,
  and the "File > Export > TaxTriage Batch Report" menu path was not found (the
  export is reached from the viewport action bar, not a File-menu item).
- **"Open the Plugin Manager from the Tools menu, find the TaxTriage entry ...
  click Install. The Plugin Manager downloads the database ... and the wizard
  then picks up"** (lines 105-109). Installing a database is necessary but **not
  sufficient**: TaxTriage runs the `jhuapl-bio/taxtriage` Nextflow DSL2 pipeline
  and requires **Nextflow + Docker (or Apple Containerization)**
  (`TaxTriageCommand.swift:13-14`; the wizard literally checks
  `nextflowAvailable` / `containerAvailable`, `TaxTriageWizardSheet.swift:107-109`,
  and its description reads "Requires Nextflow and Docker"). The chapter never
  mentions this hard dependency.
- **`CLI: lungfish taxtriage run`** (front-matter line 12) IS correct
  (`taxtriage --help` -> `USAGE: lungfish taxtriage run`). Good.

### 2. APP FEATURES MISSING FROM THE DOCS

- **`lungfish taxtriage check-prerequisites`** subcommand (verifies Nextflow /
  container runtime) (`TaxTriageCommand.swift:30, 47`). Critical given the
  undocumented dependency.
- **CLI run knobs**: `--platform`, `--samplesheet`, `--confidence` (0.2),
  `--top-hits` (10), `--rank` (S), `--skip-assembly` (default true),
  `--skip-krona`, `--max-memory` (16.GB), `--nf-profile` (docker), `--revision`
  (pinned `c808b451...`).
- **`StrainComparisonView`** (per-position cross-sample SNP table) and
  **`TaxTriageBatchOverviewView`** exist as real viewport tabs; only the latter
  ("batch overview") is described.
- **Row menu "Verify with BLAST…"** on the batch table
  (`BatchTaxTriageTableView.swift:64`).

### 3. UNCERTAIN / NEEDS-HUMAN-CHECK

- The mini-BAM "at the bottom of the viewport" (line 190) is plausible (a
  classifier mini-BAM pattern exists) but the exact TaxTriage docking was not
  confirmed.
- Database size "tens of gigabytes, 16 to 32 GB RAM" and the "Use external
  location" Plugin Manager option (lines 111-117) are unverified.

---

## Chapter 05: Running NAO-MGS

### 1. CLAIMS THAT DO NOT MATCH CODE

- **The entire "Procedure: running NAO-MGS on a fresh sample" via the
  Classification wizard** (lines 56-70, and front-matter
  `Tools > FASTQ/FASTA Operations > Classification > NAO-MGS`). **NAO-MGS cannot
  be run from the wizard.** It is import-only: the wizard has no NAO-MGS option
  (fact 2), and `NaoMgsCommand` exposes only `import` and `summary`
  (`NaoMgsCommand.swift:43`). There is no "run NAO-MGS" surface anywhere.
- **The "Sample date", "Series", "New series", site/matrix model**, and **time-
  series storage "`Imports/NAO-MGS/<series-name>/<sample-date>.parquet`",
  "series.json"** (lines 64-70, 88-94). None of this exists. The
  `NaoMgsImportSheet` has a **single field: a results location** that must
  contain `virus_hits_final.tsv.gz` (`NaoMgsImportSheet.swift:129-153`). There is
  no series, no sample-date, no site, no matrix, no Parquet, no `series.json`.
- **The "longitudinal surveillance viewport ... stacked-line chart, one line per
  pathogen ... weeks along the horizontal axis ... relative abundance on the
  vertical"** (lines 96-106, the "twelve weeks of MMSD influent" worked example
  at 114-118, and shot `nao-mgs-result-viewport`). **There is no time-series
  chart.** `NaoMgsResultViewController` is a **single-import split view: detail
  pane | taxonomy table** with columns **Sample, Taxon, Hits, Unique Reads, Refs**
  (`NaoMgsResultViewController.swift:1360-1425`) plus per-sample metadata
  columns. The only chart is a **per-accession coverage depth sparkline**
  (`NaoMgsChartViews.swift` `CoveragePlotView`), like EsViritu, not a multi-week
  abundance line.
- **Upstream attribution to "the Nucleic Acid Observatory ... `naobservatory.org`
  ... `github.com/naobservatory`"** (lines 31, 108-112). The code attributes
  NAO-MGS to **SecureBio**: "the SecureBio NAO-MGS metagenomic surveillance
  pipeline ... `github.com/securebio/nao-mgs-workflow`"
  (`NaoMgsImportSheet.swift:11`, `NaoMgsResultParser.swift:319`,
  `NaoMgsCommand.swift:11-12, 39`). The `nao-mgs --help` discussion says
  "SecureBio NAO-MGS". NEEDS-HUMAN-CHECK on which org to credit, but the in-code
  source is SecureBio, not naobservatory.org.
- **CLI import form `lungfish nao-mgs import --run-dir <path> --project <path>`**
  (line 86). The real signature takes a **positional `<input-path>`** and has
  **no `--run-dir` and no `--project`** flag; it converts alignments to SAM
  (`nao-mgs import --help`: `USAGE: lungfish nao-mgs import [<options>]
  <input-path>`; abstract "Import NAO-MGS results and convert to SAM").
- **Menu path "File > Import > NAO-MGS Results"** (line 76). The real path is
  **`File > Import Center… > Classification Results > NAO-MGS Results`** (Import
  Center card `id: "nao-mgs"`, `tab: .classificationResults`,
  `ImportCenterViewModel.swift:391-400`), or the standalone
  `launchNaoMgsImport`. There is no `File > Import > NAO-MGS Results` submenu.
- **Import expects "`samples/` subfolder ... `metadata.tsv` ... `manifest.json`
  ... Series mapping ... Reference in place"** (lines 80-84). The importer
  validates only for `virus_hits_final.tsv(.gz)` / `_virus_hits.tsv.gz`
  (`ImportCenterViewModel.swift:393-397`, `NaoMgsImportSheet.swift:153`); none of
  the `samples/`/`metadata.tsv`/`manifest.json`/series-mapping machinery exists.

### 2. APP FEATURES MISSING FROM THE DOCS

- **`lungfish nao-mgs summary <input-path> [--top N]`** (top-taxa summary,
  default 20).
- **`lungfish import nao-mgs`** (the Import-command-family form, distinct from
  `nao-mgs import`).
- **BLAST verification from the NAO-MGS viewport**: coverage-stratified read
  selection (`NaoMgsDataConverter.selectBlastReads`, lines 242-262) feeds the
  shared BLAST Verify flow.

### 3. UNCERTAIN / NEEDS-HUMAN-CHECK

- RAM "16 to 32 GB for default wastewater runs" (table line 52 and prose) is
  unverifiable and moot since NAO-MGS is never run inside Lungfish (import only).

---

## Chapter 06: BLAST Verification

### 1. CLAIMS THAT DO NOT MATCH CODE

- **Entry point "BLAST tab in the taxonomy viewport" / "Click the BLAST tab in
  the viewport's top toolbar"** (front-matter line 11; lines 41, 89). There is
  **no BLAST tab**. Verification is launched from a **"BLAST Verify" button** in
  the `ClassifierActionBar` (`ClassifierActionBar.swift:22-24`, title
  "BLAST Verify") and from a **taxon's row context menu** ("BLAST Matching
  Reads…" / "BLAST Verify…"). Results appear in a **bottom drawer**
  (`BlastResultsDrawerTab`), not a tab's lower pane.
- **The single-representative-read workflow: "pick a hit ... choose a
  representative read ... Select the longest read in the list. The sequence
  preview shows the read in IBM Plex Mono ... Click Send to BLAST"** (lines
  44-103). The real flow submits a **subsample of N reads from the taxon's clade
  (default 20, slider 1-50)** via `BlastConfigPopoverView` (titled `Verify
  "<taxon>" via NCBI BLAST`, one "Reads to submit" slider, "Run BLAST" button;
  `BlastConfigPopoverView.swift:28-108`). There is no "representative read list",
  no "select the longest read", no "Send to BLAST" button, and no per-read
  sequence preview before submission. Read selection is **coverage-stratified
  and automatic**, not user-picked.
- **"The submission dialog confirms the database (NCBI `nt` by default) and the
  program (`blastn` ...). ... switch the BLAST tab's database selector to the
  local path ... install a local BLAST database via the appropriate plugin
  pack"** (lines 102, 171-175). **There is no database selector and no local-
  BLAST option in the UI.** The popover has only the read-count slider. The
  database (`nt`) and program (`blastn` with `MEGABLAST=on`) are **hard-coded**
  in `BlastVerificationRequest` (defaults `program: "blastn"`, `database: "nt"`,
  `BlastVerificationRequest.swift:85-86`) and `BlastService` (endpoint
  `https://blast.ncbi.nlm.nih.gov/blast/Blast.cgi`, `BlastService.swift:51, 545`).
  The CLI `blast verify` exposes no `--database`/`--program` flag (only
  `--extra-args KEY=VALUE` and `--reads`/`--max-concurrent`/`--include-children`).
  Local BLAST is not implemented.
- **"The result table lists up to 50 NCBI hits in descending order of bit
  score"** (line 116). Default `maxTargetSeqs` / `HITLIST_SIZE` is **5**, not 50
  (`BlastVerificationRequest.swift:88`, `BlastService.swift:537`). The drawer
  shows results **per submitted read** (parent rows), each with up to ~5 child
  hits (`BlastResultsDrawerTab.swift:167, 175`), not a flat 50-hit list.
- **The result is framed purely as a hit table** (lines 114-150). The drawer's
  primary output is a **verdict** (`supported` / `unsupported` / `mixed` /
  `inconclusive`) and a **verification rate** (% of submitted reads independently
  verified) (`BlastResultsDrawerTab.swift:72-94, 110-111`; CLI abstract: "report
  how many are independently verified"). The percent-identity / coverage /
  e-value columns exist per hit, but the headline verification model is missing
  from the chapter.

### 2. APP FEATURES MISSING FROM THE DOCS

- **CLI `lungfish blast verify`** requires THREE inputs the chapter never names:
  `--kreport`, `--kraken-output` (per-read `.kraken`), and `--source` FASTQ, plus
  `--taxid`, `--reads` (20), `--max-concurrent` (1), `--include-children`,
  `--extra-args` (`blast --help`). The chapter's `CLI: lungfish blast`
  front-matter is too vague (the subcommand is `blast verify`).
- **Drawer columns**: Status, Read ID, Organism, Identity, E-value, Bit score,
  Accession, Coverage, Align Length, Tax ID, Verdict
  (`BlastResultsDrawerTab.swift:215-225`); plus **"Open in NCBI BLAST"** and
  **"Re-run BLAST"** buttons (lines 249, 346-347).
- **Rate-limit enforcement** is real (`BlastRateLimitConfiguration.ncbiDefault`,
  `BlastVerificationRequest.swift:289`), so the chapter's etiquette section is
  directionally correct even though the "local BLAST" escape hatch is not.

### 3. UNCERTAIN / NEEDS-HUMAN-CHECK

- Whether BLAST Verify is offered from **all** classifier viewports
  (Kraken2/EsViritu/TaxTriage/NAO-MGS/NVD) uniformly: action-bar + row-menu
  hooks exist in Kraken2, EsViritu, TaxTriage, and NAO-MGS; NVD wiring was not
  confirmed. The chapter says "Kraken2, EsViritu, or TaxTriage" (line 44), which
  under-counts NAO-MGS.

---

## Chapter 07: Running Freyja

### 1. CLAIMS THAT DO NOT MATCH CODE

- **Entry point "`Tools > Plugin Manager > wastewater-surveillance`"**
  (front-matter line 11; line 52). The Plugin Manager (`Tools > Plugin Manager…`)
  is real and is where you install the `wastewater-surveillance` pack, but there
  is **no Freyja menu item** at all: `showFreyjaDemix` is declared in the
  `ToolsMenuActions` protocol (`MainMenu.swift:1111`) but is **never added to any
  menu** (no `addItem` for it). The chapter is honest that Freyja runs from the
  CLI, so this is a minor entry-point overstatement rather than a fabricated
  feature.
- Everything else in this chapter checks out:
  - `lungfish freyja demix` with `--variants`, `--depths`, `--output-dir`,
    `--sample`, `--extra-args`, `--execute`, `--dry-run` matches `freyja demix
    --help` exactly.
  - Default (no flags) writes `freyja-command-plan.json` + provenance and prints
    the shell command; it only runs Freyja when `execute && !dryRun`
    (`FreyjaCommand.swift:59-65, 132-136`). "Default mode is dry-run command
    planning" is accurate.
  - Provenance file `.lungfish-provenance.json` is correct
    (`ProvenanceRecorder.provenanceFilename`, used throughout, e.g.
    `SidebarViewController.swift:1452`).
  - Pack id `wastewater-surveillance` and `PluginPack.builtInPack(id:
    "wastewater-surveillance")` are real (`FreyjaCommand.swift:112`).

### 2. APP FEATURES MISSING FROM THE DOCS

- None material. (The `lungfish conda install --pack wastewater-surveillance`
  install command in the chapter is consistent with `CondaCommand`.)

### 3. UNCERTAIN / NEEDS-HUMAN-CHECK

- The provenance field inventory (line 100-104: "workflow name, Lungfish
  version, exact command line, resolved defaults, pack identity, tool version,
  input/output paths, checksums, exit status, wall time, stderr") is plausible
  given `writeCommandPlanProvenance` but the exact field set was not enumerated.

---

## Chapter 07: Importing CZ-ID Results

### 1. CLAIMS THAT DO NOT MATCH CODE

This chapter is the most accurate in the section. Verified:
- **`lungfish import cz-id <input> --project <p> --sample-name <n>`** with
  optional `--metadata` and `--non-host-fastq` matches `import cz-id --help`
  exactly (`ImportCzIdSubcommand.swift:13-32`).
- **`lungfish cz-id summary <input> [--top N]`** is correct (`cz-id --help`).
- Output bundle **`<project>/Classifications/<sample>.lungfishtax`** is correct
  (`CzIdProjectImportWorkflow.swift:24-33`).
- It writes `.lungfish-provenance.json` and a Kraken-compatible taxonomy report
  for the shared taxonomy viewer (`CzIdProjectImportWorkflow` +
  `CzIdDataConverter`); CZ-ID opens the sunburst `TaxonomyViewController`
  (`ViewerViewController+CzId.swift`).
- Import Center path "Classification Results > CZ-ID Results" matches the card
  (`ImportCenterViewModel.swift:475-484`; accepts TSV / ZIP / extracted folder).

Minor discrepancy:
- Front-matter `tools: [import cz-id]` and `entry_points: "CLI: lungfish import
  cz-id"` are correct, but note a **second, differently-flagged CLI form also
  exists**: `lungfish cz-id import <input> [--output-dir]` (writes to a
  standalone `./cz-id-{sample}` dir, no `--project`). The chapter only documents
  the `import cz-id` (project) form; the `cz-id import` (standalone) form is
  undocumented. Both are real and behave differently.

### 2. APP FEATURES MISSING FROM THE DOCS

- The standalone `lungfish cz-id import --output-dir` form (above).

### 3. UNCERTAIN / NEEDS-HUMAN-CHECK

- The provenance field list (line 27) is detailed and mostly consistent with the
  workflow, but not field-by-field verified.

---

## Section-wide

### Whole missing chapter: NVD (Novel Virus Diagnostics)

NVD is a fully shipped classification-import tool with **zero coverage** in any
of the eight chapters. It is the headline gap of this section.

- **CLI**: `lungfish nvd summary <input> [--top N]` and `lungfish nvd import
  <dir> [--output-dir] [--name]`, registered in `LungfishCLI.swift:67`
  (`NvdCommand`). Also `lungfish import nvd`. Source: the **Novel Virus
  Diagnostics Snakemake pipeline**, parsing `*_blast_concatenated.csv(.gz)` with
  per-contig BLAST hit rankings and mapped-read counts for wastewater viral
  surveillance (`NvdCommand.swift:10-39`).
- **GUI**: Import Center card "NVD Results" (`tab: .classificationResults`,
  `ImportCenterViewModel.swift:465-474`) and standalone `launchNvdImport` /
  `NvdImportSheet` (`AppDelegate+ToolsMenu.swift:366-381`).
- **Viewport**: dedicated `NvdResultViewController` (a contig-keyed taxonomy
  browser: best-hit contig rows expandable to secondary BLAST hits), distinct
  from the sunburst taxonomy viewport (`NvdResultViewController.swift:27-44`).

NVD belongs in chapter 01's roster (alongside CZ-ID as an imported-results tool)
and warrants its own chapter analogous to "Importing CZ-ID Results".

### Whole-section structural corrections

1. **Tool count and menu model.** The recurring "four runnable classifiers" and
   per-tool menu paths are wrong throughout chapters 01-05. Reality: three
   runnable in the wizard (Kraken2 / EsViritu / TaxTriage) under one
   `Classification…` menu item; NAO-MGS, NVD, and CZ-ID are **import-only** (with
   Kraken2 / EsViritu / TaxTriage results also importable). A single accurate
   sentence in 01 plus per-chapter entry-point fixes would resolve most of this.
2. **Top-level `lungfish classify` does not exist; use `lungfish conda
   classify`.** Fix the path in chapters 01 and 02 rather than striking the CLI
   entirely (a headless Kraken2 run is available under `conda`). Adjacent verbs:
   `import kraken2`, `build-db kraken2`. (`CompositionCommand` / `composition`
   is genuinely dead code: defined, not registered, not runnable.)
3. **Plugin Manager location.** Multiple chapters place it under `Lungfish >
   Settings`. It is `Tools > Plugin Manager…` (Cmd-Shift-B), `MainMenu.swift:783`.
4. **TaxTriage runtime dependency.** Nextflow + Docker/Apple Containerization is
   a hard, undocumented requirement (`taxtriage check-prerequisites` exists to
   verify it). This is a setup blocker, not a footnote.
5. **Viewport heterogeneity.** Only Kraken2 + CZ-ID use the sunburst
   `TaxonomyViewController`. EsViritu, TaxTriage, NAO-MGS, and NVD each have a
   distinct, table-based viewport. The "same viewport for every classifier"
   premise (ch 01) is false.

### features.yaml note (not edited here)

`docs/user-manual/features.yaml` currently contains only the schema header and
**no classification feature entries** (no `import.cz-id`,
`viewport.taxonomy-browser`, `classify.kraken2`, `classify.esviritu`,
`classify.taxtriage`, `import.nao-mgs`, `import.nvd`, `blast.verify`,
`freyja.demix`, `build-db.*`, etc.). There is no existing entry to diff against;
the section is simply unpopulated. Flagging for the Cartographer's separate
features.yaml pass.
