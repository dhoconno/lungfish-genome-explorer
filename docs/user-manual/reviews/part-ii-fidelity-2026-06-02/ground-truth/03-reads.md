# Ground-truth reality map: 03-reads

Arbiter-of-truth map comparing the seven `03-reads` chapters against the
actual Swift source and the `lungfish-cli` binary at
`.build/debug/lungfish-cli` (built 2026-06-01). Every claim below cites a
CLI flag observed from `--help` output or a Swift `file:line` symbol.

Conventions used here:
- "GUI op" = a `FASTQOperationToolID` case in
  `Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift`.
- "CLI" = a `fastq` subcommand registered in
  `Sources/LungfishCLI/Commands/FastqCommand.swift` and its
  `Fastq*Subcommand.swift` siblings.
- The GUI Tools menu only ever opens a category dialog (e.g.
  `Trimming & Filtering…`); the individual operation is then picked from a
  list inside that dialog. The menu does NOT have one item per operation.

---

## Chapter 01: Importing FASTQ (`01-importing-fastq.md`)

### CLAIMS THAT DO NOT MATCH CODE

1. Front-matter entry point `"File > Import Center (Cmd-Shift-I) > FASTQ"`.
   The menu item is titled `Import Center…` (`MainMenu.swift:201`,
   `keyEquivalent: "i"` + `[.command, .shift]` at `MainMenu.swift:203-208`),
   so the shortcut is right, but the FASTQ destination is a tile titled
   `FASTQ Files`, not `FASTQ` (`ImportCenterViewModel.swift:231`). Minor
   label drift.

2. "choose **Sequencing Reads > FASTQ Sample Sheet**" (line 110). The
   category is `Sequencing Reads` (`ImportCenterViewModel.swift:156`) and the
   tile is `FASTQ Sample Sheet` (`ImportCenterViewModel.swift:253`), so this
   is correct. No defect; recorded to confirm.

3. The repeated drag-drop claim "The Import Center opens with the two files
   listed and a green 'Paired' badge" (lines 70, 83, 95). The badge text and
   color are not verifiable from the model layer read here; the import flow
   model is in `ImportCenterViewModel.swift` and `FASTQImportConfigSheet.swift`
   but the literal string "Paired" / badge color was not located. Flagged
   under needs-human-check rather than asserted wrong.

4. "From the CLI, pass the sheet directly: `lungfish import fastq
   --samplesheet samples.csv ... --platform illumina`" (lines 112-117). Both
   `lungfish import fastq` (subcommand) and `lungfish import-fastq`
   (top-level alias) exist and accept `--samplesheet`, `--project`/`-p`, and
   `--platform` (`import fastq --help`). Correct. Note the doc's positional
   form `lungfish import fastq SRR..._1.fastq.gz SRR..._2.fastq.gz` (lines
   128-132) is also valid: input is a variadic `[<input>]` positional.

5. "`File > Import > Project Sample Metadata`" (line 166). No such menu path
   exists. The File menu has no `Import` submenu containing a
   `Project Sample Metadata` item; the only related item is the EXPORT
   action `exportProjectSampleMetadata(_:)` (`MainMenu.swift:232`). Sample
   metadata import is not exposed at this menu path. Needs-human-check on the
   true import path (the CLI has `lungfish metadata` for FASTQ sample
   metadata, top-level `metadata` subcommand).

### APP FEATURES MISSING FROM THE DOCS

1. `lungfish import-fastq` exposes rich options the chapter never mentions:
   `--recipe` (vsp2, wgs, amplicon, hifi, none), `--quality-binning`
   (illumina4 default, eightLevel, none), `--compression` (fast, balanced,
   maximum), `--no-optimize-storage`, `--recursive`, `--dry-run`, `--force`,
   `--log-dir` (all from `import-fastq --help`). The chapter presents import
   as a plain copy + checksum; the CLI defaults to `--quality-binning
   illumina4` and storage-optimized reordering, which silently transform the
   stored reads.

2. The Import Center `Sequencing Reads` category also offers an
   `ONT Run Folder` tile (`ImportCenterViewModel.swift:270`). This chapter
   only cross-references it via chapter 07; worth noting it lives in the same
   dialog.

### UNCERTAIN / NEEDS-HUMAN-CHECK

1. "computes a SHA-256 checksum of the source file before any copying, and a
   second checksum of the file as it lands ... The two must match" (line
   140). Checksum algorithm and the dual-checksum verification behavior were
   not confirmed in the read source; verify against the import service.

2. Whether per-file QC sparklines are "computed from a sample of reads at the
   time of import" (line 152). The viewport sparkline source was not located;
   verify against `FASTQDatasetViewController.swift`.

---

## Chapter 02: Downloading from SRA (`02-downloading-from-sra.md`)

### CLAIMS THAT DO NOT MATCH CODE

1. Front-matter/entry points cite `Tools > Search Online Databases >
   Search SRA`. The actual menu item is `Search SRA...`
   (`MainMenu.swift:759`, action `searchSRA(_:)`) under a submenu titled
   `Search Online Databases` (`MainMenu.swift:749`). The ellipsis spelling is
   `...` (three dots), not the unicode ellipsis. Essentially correct.

2. "A free-text query ... returns up to the first 200 matching runs" (line
   76). The CLI `fetch sra search` default `--limit` is `20`, not 200
   (`fetch sra search --help`). The GUI search limit was not located, so the
   200 figure is unverified and contradicts the CLI default.

3. CLI example `lungfish fetch sra download SRR36291587 --output-dir
   Downloads` (line 129). Correct: `fetch sra download <accession>
   [--output-dir <dir>]` exists, `--output-dir` defaults to `.`
   (`fetch sra download --help`).

4. Provenance field claims `source: ena` and `source: sra-toolkit`, and host
   strings `https://ftp.sra.ebi.ac.uk/` vs
   `https://sra-download.ncbi.nlm.nih.gov/` (lines 142-146, 162). These exact
   provenance key/value strings were not confirmed in `FetchCommand.swift`
   (the SRA download path delegates to `SRASubcommand`/`ENASubcommand`, see
   `FetchCommand.swift:20`). The user-facing toggle in the CLI is
   `--use-toolkit` ("Use SRA Toolkit instead of ENA (requires
   prefetch/fasterq-dump)"), confirming ENA-preferred with a Toolkit
   fallback, but the literal provenance schema fields are unverified.

5. "Lungfish resumes from the last byte received when the server supports
   range requests" and partial files under `Downloads/.partial/` (lines
   194, 200). Resume/`.partial` behavior was not located in source; flag as
   unverified.

### APP FEATURES MISSING FROM THE DOCS

1. The CLI `fetch sra download` `--use-toolkit` flag lets a user force the
   SRA Toolkit path directly. The chapter describes the fallback as automatic
   only and never mentions the explicit override flag.

2. `fetch sra search --limit <n>` (default 20) and `--api-key` (NCBI API key
   for higher rate limits) are unmentioned. The chapter's rate-limit
   troubleshooting (lines 191-195) never points at `--api-key`, which is the
   actual mitigation the CLI offers.

3. The broader `fetch` command also has `fetch ncbi` (GenBank/RefSeq by
   accession) and a `fetch pathoplexus`-style path (`Search Pathoplexus`
   menu item at `MainMenu.swift:766`). Out of scope for SRA but adjacent.

### UNCERTAIN / NEEDS-HUMAN-CHECK

1. Whether the GUI download writes a sidecar named
   `<accession>.provenance.json` (line 179) vs the CLI convention
   `<output>.lungfish-provenance.json` (`FetchCommand.swift:172-173`). The
   two names differ; confirm which the SRA download path actually writes.

2. The search results columns (study, sample, layout, strategy, platform,
   bases) at lines 77-80 were not verified against the search dialog model.

---

## Chapter 03: Quality Control (`03-quality-control.md`)

### CLAIMS THAT DO NOT MATCH CODE

1. Entry point `Tools > FASTQ/FASTA Operations > QC & Reporting > Refresh QC
   Summary` (front-matter and lines 37-38, 63-64). The real menu path stops
   at `Tools > FASTQ/FASTA Operations > QC & Reporting…`
   (`MainMenu.swift:646`, action `showFASTQQCReportingOperations(_:)`); that
   opens the operations dialog with the `QC & REPORTING` category
   (`FASTQOperationsCatalog.swift:19`). `Refresh QC Summary` is the single
   operation listed inside that dialog
   (`FASTQOperationDialogState.swift:1056, 1651`), not a fourth menu level.

2. "Lungfish runs `fastp` to compute a per-bundle QC summary" (line 35) and
   "a new `fastp` row" (line 64). The CLI op is `fastq qc-summary` whose
   abstract is "Compute a JSON QC summary for FASTQ input files"
   (`FastqQCSummarySubcommand.swift`, `qc-summary --help`). Whether the QC
   summary engine is actually fastp or a native Swift summarizer was not
   confirmed; the subcommand name and "JSON QC summary" phrasing suggest it
   may not shell out to fastp at all. The `tools: [fastp]` front-matter and
   the "fastp row" claim are unverified and possibly wrong.

3. "the four panels ... per-base quality, length distribution, GC content,
   adapter contamination" with per-panel Warning/Fail flags (lines 68-73).
   The panel set and the Warning/Fail flagging are viewport claims not
   verified in source; the `qc-summary` output schema was not read. Flag as
   unverified.

### APP FEATURES MISSING FROM THE DOCS

1. `fastq qc-summary` accepts multiple inputs (`<inputs> ...` variadic) and
   writes to an explicit `-o/--output` JSON path with `--force`/`--compress`
   (`qc-summary --help`). The chapter presents QC only as an in-app viewport
   action and never mentions the standalone CLI that emits a JSON report.

### UNCERTAIN / NEEDS-HUMAN-CHECK

1. The entire numeric "worked example" for SRR36291587 (Q30 through base 140,
   GC 38.1 percent, adapter 0.4 percent, lines 147-156) is illustrative and
   cannot be validated against code. Human/fixture check required.

2. Whether QC is invoked as `Refresh QC Summary` automatically or only on
   demand, and whether it really shells out to `fastp` for the charts.

---

## Chapter 04: Trimming and Filtering (`04-trimming-and-filtering.md`)

### CLAIMS THAT DO NOT MATCH CODE

1. Five entry points of the form `Tools > FASTQ/FASTA Operations > Trimming &
   Filtering > <Operation>` (front-matter lines 11-15). The menu path ends at
   `Trimming & Filtering…` (`MainMenu.swift:656`); the five operations
   (`fastp Adapter + Quality Trim`, `Quality Trim`, `Adapter Removal`,
   `Primer Trimming`, `Trim Fixed Bases`, `Filter by Read Length`) are picked
   inside the dialog (`FASTQOperationDialogState.swift:1060`,
   titles at `:1653-1658`). The menu does not branch per operation.

2. The category contains SIX operations, not the five the chapter implies.
   The chapter omits `Trim Fixed Bases` (`trimFixedBases`, CLI `fastq
   fixed-trim` with `--front`/`--tail`, both default 0). The `Trimming &
   Filtering` list is `[.fastpTrim, .qualityTrim, .adapterRemoval,
   .primerTrimming, .trimFixedBases, .filterByReadLength]`
   (`FASTQOperationDialogState.swift:1060`).

3. Tool table row "Primer Trimming (FASTQ-level) ... Tool: fastp" (line 40).
   WRONG. FASTQ-level primer trimming is built as `fastq primer-remove`
   (`FASTQDerivativeServiceModels.swift:500`,
   `FASTQOperationCLIInvocationBuilder.swift:312, 337`) whose default engine
   is `bbduk`, with `cutadapt-linked` as the only alternative (`primer-remove
   --help`: `--engine bbduk` default, `--kmer 23`, `--mink 11`, `--hdist 1`).
   fastp is never used for primer trimming.

4. Tool table row "Filter by Read Length ... Default parameters: Minimum 30
   bp, drop pair if either fails" (line 41), repeated at lines 67, 94. WRONG
   on both counts. The GUI defaults `filterByReadLengthMin = nil` and
   `filterByReadLengthMax = nil` (`FASTQOperationDialogState.swift:199`); the
   length filter pane shows only `Min Length` and `Max Length` fields
   (`FASTQOperationToolPanes.swift:333-336`). There is no "drop pair if either
   mate fails" checkbox in the pane, and no 30 bp default. The CLI `fastq
   length-filter` likewise has `--min`/`--max` with no default and no
   drop-pair flag (`length-filter --help`).

5. "The operation provenance records the `lungfish fastq trim` command" (line
   61) for the combined fastp pass. Correct command name: the combined op is
   `fastq trim` ("Trim adapters and low-quality bases in one fastp pass",
   `trim --help`). Defaults match the doc: `--threshold 20`, `--window 4`,
   `--mode cut-right`, `--adapter-trimming` enabled. GUI defaults agree
   (`qualityTrimThreshold = 20`, `qualityTrimWindowSize = 4`,
   `qualityTrimMode = .cutRight`, `FASTQOperationDialogState.swift:185-187`).

6. "reduce the window from 4 bp to 1 bp to trim base by base" (line 96). The
   `--window` option accepts an int with no stated lower bound; plausibly
   valid but the 1 bp behavior is unverified. Low risk.

### APP FEATURES MISSING FROM THE DOCS

1. `Trim Fixed Bases` / `fastq fixed-trim` (`--front`, `--tail`) lets a user
   hard-trim N bases off each end, independent of quality. Never mentioned.

2. The combined `fastq trim` accepts `--adapter <seq>` (manual adapter
   override), `--no-adapter-trimming` (quality only), and `--extra-args`
   passed verbatim to fastp (`trim --help`). The chapter only describes
   auto-detect adapters.

3. `fastq primer-remove` `cutadapt-linked` engine with `--minimum-overlap`
   (default 12) and `--error-rate` (default 0.12) is a real second primer
   engine (`primer-remove --help`); the chapter implies a single fastp-based
   primer trim.

4. `Adapter Removal` as its own op maps to `fastq adapter-trim` (fastp,
   `--adapter` optional auto-detect, `adapter-trim --help`); `Quality Trim`
   maps to `fastq quality-trim` (fastp, threshold 20 / window 4 / cut-right).
   The chapter lists these but does not give their standalone CLI names.

### UNCERTAIN / NEEDS-HUMAN-CHECK

1. Output bundle suffixes `(fastp-trim)`, `(fastp-trim, len30)`, `(primtrim)`
   (lines 61, 70, 76). Suffix-naming was not confirmed against
   `FASTQOperationPlanner.swift` / `FASTQOperationOutputImporter.swift`;
   given the 30 bp default is wrong, `len30` is likely fictional too.

2. The Primer Trimming pane's actual fields (literal vs reference source,
   k-mer settings) were seen at `FASTQOperationToolPanes.swift:308` and
   `FASTQOperationDialogState.swift:410-432` but the chapter gives no field
   detail to compare.

---

## Chapter 05: Decontamination (`05-decontamination.md`)

### CLAIMS THAT DO NOT MATCH CODE

1. Entry points `Tools > FASTQ/FASTA Operations > Decontamination > Remove
   Human Reads | Remove Ribosomal RNA | Remove Contaminants` (front-matter
   lines 11-13). The menu path ends at `Decontamination…`
   (`MainMenu.swift:661`); the operations are picked in-dialog. The
   `Decontamination` category list is `[.removeHumanReads,
   .removeRibosomalRNA, .removeContaminants, .removeDuplicates]`
   (`FASTQOperationDialogState.swift:1062`) — note it also includes `Remove
   Duplicates`, which this chapter never mentions (it surfaces in chapter 6's
   territory instead, but lives under Decontamination in the UI).

2. "Remove Ribosomal RNA runs either Deacon against an rRNA database or
   RiboDetector" and the table row "Tool: Deacon or RiboDetector" plus "a
   tool toggle for RiboDetector" (lines 30, 35, 70). WRONG. The GUI
   `removeRibosomalRNA` op builds ONLY `fastq deacon-ribo`
   (`FASTQDerivativeServiceModels.swift:563-569`,
   `FASTQOperationCLIInvocationBuilder.swift:452`), i.e. Deacon + BBMap
   ribokmers against `deacon-ribokmers`
   (`FastqDeaconRiboSubcommand.swift:23, 33`). The rRNA pane exposes only a
   single `Retain Reads` segmented picker
   (`FASTQOperationToolPanes.swift:355-361`); there is NO tool toggle and no
   path to RiboDetector from this operation. (The misleadingly named state
   property is `riboDetectorRetention`, but it feeds `deacon-ribo`.)

3. "RiboDetector, a deep-learning classifier ... install the **RiboDetector**
   plugin pack instead. It carries the model weights" (lines 30, 60). The
   `ribodetector` plugin (display name `RiboDetector`,
   `PluginPack.swift:671-684`) exists but is a member of the metagenomics
   pack alongside kraken2/bracken/esviritu (`PluginPack.swift:633`), not a
   standalone "RiboDetector plugin pack", and its CLI is `fastq ribodetector`
   (`FastqRiboDetectorSubcommand.swift:15`) — which is NOT reachable from the
   Remove Ribosomal RNA GUI op at all. Installing it does not change the rRNA
   dialog.

4. "**Remove Human Reads** runs Deacon against a prebuilt human-genome
   **k-mer** database" and table "Database: Prebuilt human-genome index,
   installed via Plugin Manager" (lines 30, 34). Partially wrong. The tool is
   Deacon (correct), but the managed database is `deacon-panhuman`
   (`DatabaseRegistry.swift:64`, a "panhuman host-depletion index" using
   Deacon minimizers, `DatabaseRegistry.swift:62`), resolved from the
   user-supplied `--database-id` via
   `FastqScrubHumanSubcommand.canonicalHumanReadRemovalDatabaseID`
   (`FastqScrubHumanSubcommand.swift:265-271`). Deacon is a minimizer-based
   host-depletion tool, not a "k-mer database" in the bbduk sense. Also it is
   a managed DATABASE (`DatabaseRegistry`), not a Plugin Manager "pack".

5. "Open the Plugin Manager ... find the **Decontamination** plugin pack ...
   pulls the Deacon binary plus the human-genome and rRNA k-mer indexes"
   (line 58). No plugin pack named `Decontamination` was found in
   `PluginPack.swift`. The Deacon human and rRNA indexes are managed
   databases (`deacon-panhuman`, `deacon-ribokmers` in `DatabaseRegistry`),
   not a single named pack. Needs-human-check on the real install surface.

6. "Choose `... > Decontamination > Remove Human Reads`" CLI mirror: the
   chapter implies a `Remove Contaminants` Deacon path, but the GUI
   `removeContaminants` op maps to `fastq contaminant-filter` which uses
   **bbduk**, not Deacon (`contaminant-filter --help`: "Remove contaminant
   reads using bbduk", `--mode phix|custom` default phix, `--kmer 31`,
   `--hdist 1`; pane at `FASTQOperationToolPanes.swift:339-353`). The table
   row "Remove Contaminants ... Tool: Deacon" (line 36) and the
   troubleshooting note "Deacon needs enough k-mers" (line 106) are WRONG:
   Remove Contaminants is bbduk, and its custom mode takes a reference FASTA
   via `--ref`, not a Deacon index.

7. "The exact Deacon or RiboDetector command line" in the op log (line 80)
   and "a re-run on the same input with the same database produces a
   checksum-identical output" (line 82). The Remove Human Reads scrub records
   a Deacon `filter` invocation (`FastqScrubHumanSubcommand.swift:368-374`),
   correct for that op, but determinism/checksum-identical output is
   unverified.

8. CLI: the chapter gives no CLI for these ops, but for the record the human
   scrub CLI is `fastq scrub-human <input> -o <out> --database-id <id>`
   (`scrub-human --help`); `--remove-reads` is a deprecated no-op
   (`FastqScrubHumanSubcommand.swift:42-46`). rRNA is `fastq deacon-ribo`
   (default `--retain norrna`). The GUI Tools-menu entry points are all the
   user has; both have CLI equivalents the chapter omits.

### APP FEATURES MISSING FROM THE DOCS

1. `fastq deacon-ribo` exposes `--retain norrna|rrna|both` (default norrna),
   `--absolute-threshold` (default 1) and `--relative-threshold` (default
   0.0) tuning knobs (`deacon-ribo --help`). The GUI surfaces the retain
   choice as `Retain Reads`; the thresholds are CLI-only. None are documented.

2. `fastq ribodetector` is a genuinely separate rRNA tool (RiboDetector CPU
   mode, `--retain`, `--ensure rrna|norrna|both|none`,
   `FastqRiboDetectorSubcommand.swift:13-26`) that the manual conflates with
   the Deacon rRNA op. It is CLI-only and not wired to any Tools-menu op.

3. `Remove Duplicates` (`removeDuplicates` GUI op / `fastq deduplicate`,
   clumpify.sh, `--subs`, `--optical`, `--dupedist 40`) lives in the
   Decontamination category (`FASTQOperationDialogState.swift:1062`) but is
   absent from this chapter and from chapter 6.

4. `fastq scrub-human` auto-detects interleaved input and round-trips through
   reformat.sh deinterleave/interleave around Deacon
   (`FastqScrubHumanSubcommand.swift:104-136`). The chapter does not mention
   interleaved handling.

### UNCERTAIN / NEEDS-HUMAN-CHECK

1. The worked-example removal-rate numbers (25 percent, lines 90-96) and the
   "5 to 30 percent typical" guidance are illustrative; not code-checkable.

2. The exact Plugin Manager / database-install UX for the Deacon indexes
   (pack vs managed database) needs a human to reconcile against the actual
   Plugin Manager screen.

---

## Chapter 06: Subsetting and Extraction (`06-subsetting-and-extraction.md`)

### CLAIMS THAT DO NOT MATCH CODE

1. Entry points `Tools > FASTQ/FASTA Operations > Search & Subsetting > <op>`
   (front-matter lines 11-14). Menu path ends at `Search & Subsetting…`
   (`MainMenu.swift:671`, action `showFASTQSearchSubsettingOperations(_:)`);
   ops are picked in-dialog. The category list is `[.subsampleByProportion,
   .subsampleByCount, .extractReadsByID, .extractReadsByMotif,
   .selectReadsBySequence]` (`FASTQOperationDialogState.swift:1066`) — five
   ops, but the chapter only documents four and omits `Select Reads by
   Sequence`.

2. "The CLI mirror is `lungfish fastq subsample`, `lungfish fastq
   extract-ids`, and `lungfish fastq extract-motif`" (lines 96-97). WRONG.
   No `extract-ids` or `extract-motif` subcommands exist. The actual CLI ops
   are `fastq search-text` (Extract Reads by ID maps here:
   `--query`, `--field id|description`, `--regex`;
   `FASTQDerivativeRequest.provenanceCLIArguments` builds `searchText` at
   `FASTQDerivativeServiceModels.swift:584`) and `fastq search-motif`
   (Extract Reads by Motif: `--pattern`, `--regex`;
   `FASTQDerivativeServiceModels.swift:586`). `fastq subsample` is correct.

3. "Extract Reads by ID ... Input: A text file of read names ... Prepare a
   plain-text file with one read ID per line ... Drop the ID list into the
   file picker" (lines 46, 80-86). WRONG. The Extract Reads by ID pane has a
   single `Query` text field, an `ID`/`Description` field picker, and a `Use
   Regular Expression` toggle (`FASTQOperationToolPanes.swift:439-446`); the
   CLI is `search-text --query <string>` (`search-text --help`). It matches a
   query string against the header field, not a file of IDs. There is no file
   picker and no per-line ID list.

4. "Extract Reads by Motif ... Set the mismatch budget (0 for exact match, 1
   or 2 for a tolerant match) ... Choose whether to search both strands
   (default) or only the forward strand" (lines 47, 92-94, 117-118). WRONG
   for this op. The Extract Reads by Motif pane has only a `Pattern` field and
   a `Use Regular Expression` toggle (`FASTQOperationToolPanes.swift:448-450`);
   CLI `search-motif --pattern <p> [--regex]` (`search-motif --help`). There
   is NO mismatch budget and NO strand option here. Those options DO exist on
   the SEPARATE `Select Reads by Sequence` op (`selectReadsBySequence` →
   `fastq sequence-filter`: `--search-end left|right|both` default both,
   `--error-rate 0.1`, `--min-overlap 8`, `--search-rc`, `--keep-matched`;
   `FASTQOperationToolPanes.swift:452-462`, `sequence-filter --help`). The
   chapter has merged two different operations.

5. "Optionally set a random seed if you need a reproducible draw" (line 69)
   and worked example "Subsample by Count with a target of `100000` and a
   fixed seed (for example, `42`)" + "Subsample-by-count uses reservoir
   sampling, so the result is exactly 100,000 reads" (lines 71, 130-136).
   WRONG. The Subsample panes expose only `Proportion`
   (`FASTQOperationToolPanes.swift:433-434`) and `Count`
   (`:436-437`); there is no seed field. CLI `fastq subsample` has only
   `--proportion` / `--count` (`subsample --help`); `--seed` exists ONLY on
   `pbaa-cluster` (`FASTQOperationCLIInvocationBuilder.swift:100`), not
   subsample. The "reservoir sampling / exactly N" guarantee is unverified
   (subsample likely shells out to seqkit `sample`).

6. Front-matter `tools: [seqkit, fastp]` (line 9). Subsample is seqkit-based
   (plausible), but the search/extract ops are native Swift FASTQ filters
   (`search-text` / `search-motif` / `sequence-filter` subcommands), not
   fastp. fastp is not used by any op in this chapter.

7. Output name "`<parent>-sub10k`" and "`SampleA-sub100k`" (lines 71, 132).
   Suffix naming unverified against `FASTQOperationPlanner.swift`; flag.

### APP FEATURES MISSING FROM THE DOCS

1. `Select Reads by Sequence` / `fastq sequence-filter` is a full
   adapter/barcode-presence filter with `--search-end`, `--min-overlap`,
   `--error-rate`, `--search-rc`, and `--keep-matched`
   (`sequence-filter --help`). It is the op the chapter's "motif with
   mismatch and strand" prose actually describes, but it is never named.

2. `search-text --field description` lets you search the read DESCRIPTION,
   not just the ID (`search-text --help`). The chapter treats Extract Reads
   by ID as ID-only.

3. `fastq materialize` (the explicit materialization CLI:
   `materialize <bundle> -o <out> [--temp-dir]`,
   `FastqMaterializeSubcommand.swift`) backs the virtual-bundle story the
   chapter tells (lines 49-53, 110-113). The chapter correctly says
   materialization is automatic but never mentions the manual CLI escape
   hatch.

### UNCERTAIN / NEEDS-HUMAN-CHECK

1. The "~1000 reads preview.fastq" virtual-bundle figure (lines 49-53, 109)
   matches project memory but was not re-confirmed in this read.

2. Whether subsample-by-count is genuinely reservoir sampling (exact N) or a
   proportional/streaming sampler. Needs source confirmation (subsample
   implementation in `FastqCommand.swift`).

---

## Chapter 07: Oxford Nanopore Runs (`07-ont-runs.md`)

### CLAIMS THAT DO NOT MATCH CODE

1. Entry point `File > Import ONT Run` (front-matter line 11; procedure lines
   35, 144-146). WRONG. There is NO `Import ONT Run` item in the File menu.
   `importONTRun(_:)` is declared as a protocol requirement
   (`MainMenu.swift:1011`) and implemented as an `@objc` action
   (`AppDelegate+ImportExport.swift:259`), but it is not attached to any
   `NSMenuItem`. ONT import is reached through the Import Center
   (`Cmd-Shift-I`) -> `Sequencing Reads` -> `ONT Run Folder` tile
   (`ImportCenterViewModel.swift:270-271`). The chapter's entire "Open the
   Import ONT Run dialog" procedure (the "Choose Run Folder" button, the
   "Attach Sample Sheet" button) describes a dialog that is not surfaced at
   the claimed path.

2. The CLI counterpart is unstated, but for the record ONT import is `fastq
   import-ont <dir> -o <out>` ("Import ONT output directory into per-barcode
   bundles", `import-ont --help`), with `--include-unclassified`,
   `--concurrency 4`, `--storage-mode chunked|flattened`,
   `--optimize-storage`, and `--quality-binning none|illumina4|eightLevel`.
   The chapter never mentions this CLI.

3. "If you point it at a sample sheet (a CSV mapping barcode to sample name
   ...)" attached via an `Attach Sample Sheet` button (lines 37-39, 153). The
   `fastq import-ont` CLI takes NO `--samplesheet` option
   (`import-ont --help`); barcode->sample mapping at ONT-import time is not a
   CLI feature. Whether the Import Center ONT tile offers a sample-sheet
   attach control is unverified; the claimed standalone-dialog control does
   not exist at the claimed menu path.

4. Entry point and procedure `Tools > FASTQ/FASTA Operations > Read
   Processing > Orient Reads` (front-matter line 12; procedure line 176).
   Menu path ends at `Read Processing…` (`MainMenu.swift:666`); `Orient
   Reads` is the in-dialog op (`readProcessing` list at
   `FASTQOperationDialogState.swift:1064`; there is also a direct
   `launchOrientReads(_:)` shortcut that opens the dialog preselected to
   `.orientReads`, `AppDelegate+ToolsMenu.swift:910-911`). The category exists
   but the four-level menu path is wrong.

5. "Reads that did not align to the reference are dropped by default; if you
   need to keep unmapped reads ... the Orient Reads dialog has a 'Keep
   unmapped reads' checkbox" (lines 198-199). WRONG / unsupported. The Orient
   Reads pane exposes `Word Length`, a `Database Mask` segmented picker
   (`dust`/`none`), and an `Extra arguments` field
   (`FASTQOperationToolPanes.swift:397-405`); there is NO "Keep unmapped
   reads" checkbox. The underlying tool is vsearch `--orient`
   (`FASTQDerivativeServiceModels.swift:545-554`; CLI `fastq orient
   --reference <fa> --word-length 12 --db-mask dust`, `orient --help`).
   vsearch `--orient`'s drop/keep behavior for non-orientable reads is a
   vsearch detail, not a Lungfish checkbox.

6. "writes a new bundle with `-oriented` appended to the name" (lines 181,
   195). Suffix unverified against the planner; flag.

7. "Orient Reads ... Pick a reference sequence (the SARS-CoV-2 reference,
   MN908947.3 or equivalent)" (line 178) — the op does require a reference
   FASTA (`--reference`, `orient --help`), so the requirement is right; only
   the menu path and the checkbox are wrong.

### APP FEATURES MISSING FROM THE DOCS

1. `fastq import-ont --storage-mode chunked|flattened` and
   `--optimize-storage` (+ `--quality-binning`) control how per-barcode reads
   are stored and whether clumpify reorders them (`import-ont --help`). The
   chapter says nothing about storage mode or quality binning, both of which
   alter the stored bytes.

2. `fastq import-ont --include-unclassified` is the actual flag behind the
   chapter's "you can deselect `unclassified`" prose (lines 159-162); the
   default is to SKIP unclassified, the opposite of the chapter's "By default
   every detected barcode is selected" framing for the unclassified folder.

3. ONT-specific genotyping ops the chapter never mentions but that are
   adjacent ONT read processing: `fastq ont-genotype`,
   `fastq ont-barcode-genotype`, and the generic `fastq genotype`
   (platform-aware) (`FastqONTGenotypingSubcommand.swift`,
   `FastqONTBarcodeGenotypingSubcommand.swift`,
   `FastqGenotypingSubcommand.swift`). The GUI surfaces `Amplicon Genotyping`
   under the Mapping category (`FASTQOperationDialogState.swift:1070`,
   `ontGenotyping`).

4. `fastq demultiplex` / `fastq scout` carry extensive ONT barcode kit
   support (kits `ont-nbd104`, `ont-nbd114`, `ont-rbk004`, `ont-rbk114-24`,
   `ont-16s114-24`, etc.; `demultiplex --help`). The chapter treats ONT
   barcodes as already-split by MinKNOW and never mentions re-demultiplexing.

### UNCERTAIN / NEEDS-HUMAN-CHECK

1. The Import Center ONT tile's actual controls (sample-sheet attach, per-row
   barcode selection, unclassified toggle) were not read at the view level;
   reconcile the chapter's dialog walkthrough against the Import Center ONT
   import flow.

2. The platform comparison table numbers (throughput, cost, error rates,
   lines 74-80) are illustrative and not code-checkable.

---

## Section-wide: app features absent from the manual

These FASTQ capabilities exist in code (CLI and/or GUI) and plausibly belong
in `03-reads` but appear in none of the seven chapters.

1. Pair utilities as first-class ops: `fastq deinterleave`
   (`--out1`/`--out2`), `fastq interleave` (`--in1`/`--in2`), `fastq repair`
   (repair.sh), and `fastq merge` (bbmerge, `--min-overlap 12`, `--strict`).
   GUI surfaces `Merge Overlapping Pairs` and `Repair Paired-End Files` under
   `Read Processing` (`FASTQOperationDialogState.swift:1064`). Only `repair`
   and `merge` get a passing mention; deinterleave/interleave are undocumented.

2. `Correct Sequencing Errors` / `fastq error-correct` (tadpole, `--kmer 50`
   max 62) under `Read Processing` (`FASTQOperationDialogState.swift:1064`,
   `error-correct --help`). No chapter covers error correction.

3. `Remove Duplicates` / `fastq deduplicate` (clumpify.sh, `--subs`,
   `--optical`, `--dupedist 40`) under `Decontamination`
   (`FASTQOperationDialogState.swift:1062`). Undocumented.

4. `Reverse Complement` / `fastq reverse-complement` (seqkit) and `Translate`
   / `fastq translate` (seqkit, `--frame`, `--table`) under `Read Processing`
   (`FASTQDerivativeServiceModels.swift:528-532`). Undocumented in this part.

5. `Demultiplex Barcodes` / `fastq demultiplex` + `fastq scout` (cutadapt or
   exact-bare engines, ~20 built-in kits including TruSeq, Nextera, IDT,
   Fluidigm, PacBio, and ONT kits; custom CSV/TSV barcode defs;
   `demultiplex --help`, `scout --help`). A whole demultiplexing surface
   (`DEMULTIPLEXING` category, `FASTQOperationsCatalog.swift:20`) with zero
   chapter coverage in 03-reads.

6. `fastq materialize` (manual virtual-bundle realization) and `fastq
   qc-summary` (standalone JSON QC) are CLI escape hatches behind GUI-only
   behaviors the chapters describe; neither CLI is named.

7. `fastq ribodetector` (RiboDetector CPU, separate from the Deacon rRNA op),
   `fastq pbaa-cluster` (PacBio HiFi amplicon clustering), and the 12S
   amplicon family (`fastq 12s-match`, `12s-export`, etc.) are FASTQ-input
   tools not covered here (12S has its own part).

### Cross-cutting fidelity pattern

The dominant systematic error across chapters 03-07 is the menu path: every
chapter writes a four-level path `Tools > FASTQ/FASTA Operations > <Category>
> <Operation>`, but the real menu is three levels ending at the category
(`<Category>…`), after which the operation is chosen from a list inside the
opened dialog (`MainMenu.swift:643-693`,
`FASTQOperationDialogState.toolIDs(for:)` at
`FASTQOperationDialogState.swift:1053-1078`). Every `03-reads` entry-point
string and in-body menu instruction needs this correction.
