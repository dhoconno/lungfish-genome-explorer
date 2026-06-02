# Round 3 adversarial fidelity audit (most-rewritten chapters)

Method: every concrete claim (feature, menu path, CLI command/flag, dialog
control, output file, default value) in the seven priority chapters was
re-verified from scratch against the live binary `.build/debug/lungfish-cli`
(v0.5.0-alpha11) and against Swift source. No build was run; the binary already
existed. Ground-truth maps under `ground-truth/{05-variants,06-classification,
08-workflows}.md` were used only as a starting checklist, not as authority; each
claim was independently re-checked. The headline result: the rewrites are
effectively fabrication-free. Every fabricated feature the ground-truth maps
flagged in the OLD chapters (cross-caller intersection/union tooling, iVar
consensus-FASTA side output, the "run NAO-MGS" wizard surface + time-series
viewport, the BLAST "tab" / single-representative-read / local-DB selector, the
invented Workflow Builder categories and node types and the un-buildable
reads-to-variants graph, the four-target export with invented Nextflow profiles
and `workflow/` Snakemake layout) is GONE and has been replaced with claims that
match the binary and source. Two minor residual issues remain (one mislabeled UI
control, one slightly-imprecise command-position phrasing); neither is a
fabricated feature.

---

## Surviving or new fabrications (MUST FIX)

None. No surviving fabricated feature, menu path, CLI command, flag, output
file, or default value was found in any of the seven priority chapters, and no
new fabrication was introduced by the rewrites. The two items below are
accuracy/wording defects, not fabrications, and are placed in the next section.

---

## Misleading-but-technically-real items (should fix)

1. **Mislabeled MSA consensus control name -- `05-variants/05-consensus-and-lineage.md`, line 100.**
   The doc says, in backticks as if quoting a UI control: "The same consensus
   action is available in the app from the multiple-sequence-alignment viewport
   as `Create consensus FASTA`."
   Evidence: the only MSA consensus action descriptor in source is titled
   **"Create Consensus Sequence"** (`Sources/LungfishIO/Bundles/MultipleSequenceAlignmentActionRegistry.swift:475`,
   id `msa.transform.consensus`, surfaced in `.contextMenu`/`.commandLine`/
   `.operationCenter`/`.inspector`). Its own description text is "Create a
   consensus FASTA from selected rows ..." but that is prose, not the control
   label. No UI string `Create consensus FASTA` exists; the in-viewport header
   is just "Consensus" (`MultipleSequenceAlignmentViewController.swift:777`).
   Correct form: quote the action as **"Create Consensus Sequence"** (or drop
   the backticks and say "a Create Consensus action"). The feature itself is
   real and does produce a consensus FASTA, so this is a label-fidelity nit, not
   a fabrication. NOTE: the underlying CLI it points to, `lungfish msa
   consensus`, is fully correct (see verified section).

2. **Slightly imprecise extra-args position -- `05-variants/03-cross-caller-comparison.md`, line 88.**
   The doc says LoFreq runs `lofreq call-parallel --pp-threads N -f <reference>
   -o <out> <bam>`, "appending anything from `Extra arguments`."
   Evidence: `lofreqArguments` (`Sources/LungfishWorkflow/Variants/ViralVariantCallingPipeline.swift:1030-1039`)
   returns `["call-parallel"] + request.advancedArguments + ["--pp-threads", N,
   "-f", ref, "-o", out, bam]`. The extra args are inserted **immediately after
   `call-parallel`** (i.e. before the `--pp-threads`/`-f`/`-o` flags and the
   positional BAM), not "appended" at the end. The substantive claim (Extra
   arguments reach LoFreq) is correct; only the word "appending" misstates the
   position. (Compare line 90's bcftools claim, which is precise: the
   `--ploidy 1` extra arg is "inserted into the `bcftools call` stage" -- and
   indeed `bcftoolsCallArguments` puts `request.advancedArguments` right after
   `call`, lines 1151-1159. So the chapter is internally inconsistent in
   precision: bcftools right, LoFreq loose.) Low severity.

(No third item rises to "should fix." A handful of true-but-omitted details --
e.g. the MSA viewport also has a "Show consensus track in viewer" toggle the
consensus chapter does not list, and the export chapter's six targets are all
documented though the `defaultFilename` enum carries unused `reproduce.sh`/
`methods.txt` strings -- are acceptable omissions, not inaccuracies.)

---

## Verified-accurate (chapter-by-chapter)

### `05-variants/03-cross-caller-comparison.md` (was fabricated; rewritten) -- CLEAN

The rewrite correctly removed the entire fabricated cross-caller tooling layer
and now opens by stating plainly "Lungfish does not have a dedicated
cross-caller comparison tool. There is no comparison view, no intersection or
union export, and no codon-aware decomposition feature" (line 32). Verified:

- **Aggregated `Source`-column table is the real substrate.** The bundle browser
  column is titled **`Position`** (key `position`,
  `AnnotationTableDrawerView+Columns.swift:316`), confirming the chapter's
  insistence (lines 96, 100) that the column is `Position` not `Pos`. Filter
  operators are `>= <= != > < = ~` with no colon form
  (`VariantDatabase+Query.swift:163-177`), confirming line 100's claim that
  `Pos:1193` is invalid and `Position=1193` is the right syntax.
- **LoFreq command line** (line 88): `lofreq call-parallel ... --pp-threads N -f
  <ref> -o <out> <bam>` matches source exactly (caveat on extra-args position,
  above).
- **CLI equivalents** (lines 90): `lungfish variants call --bundle ...
  --alignment-track ... --caller lofreq --name "..."` -- every flag exists
  (`variants call --help`). The bcftools variant `--caller bcftools --extra-args
  "--ploidy 1"` is valid; `--extra-args`/`--advanced-options` exist and feed the
  `bcftools call` stage.
- **Caller availability** (lines 60-66): the `variant-calling` pack contains
  exactly `["lofreq","ivar","medaka","clair3"]` (`PluginPack.swift:387`);
  bcftools is gated by the separate **`lungfish-tools`** pack
  (`BAMVariantCallingCatalog.swift:45`), which in `third-party-tools-lock.json`
  bundles **nextflow, samtools, bcftools, htslib** -- exactly the four the
  chapter names (line 60). `lungfish conda install --pack lungfish-tools`
  (line 63) uses the real `--pack` flag.
- **Codon-merge mechanics** (lines 126-136): the iVar `REF GG / ALT AA` single
  merged row vs. LoFreq's three single-base rows is consistent with
  `IVarCodonMerger`. Critically, the chapter now states the amino-acid labels
  "come from the Inspector deriving them against the bundle's GFF3; they are not
  stored in the VCF, whose only `INFO` key is `TYPE`" (line 132) -- this exactly
  matches the iVar VCF reality (`IVarTSVToVCFConverter`: INFO = TYPE only). The
  old fabrication of "protein consequence in INFO" is gone.
- **External `bcftools isec`/`norm -a`** (lines 138-150): correctly framed as an
  external step Lungfish does not provide; the dialog/CLI claims around it are
  all about external tools, no in-app intersection feature is claimed.
- LoFreq panel text (line 84) "LoFreq is ready to run directly on the selected
  bundle alignment track" matches `BAMVariantCallingToolPanes.swift`. The old
  fabricated "LoFreq Options dialog (min coverage/base quality/significance/BH)"
  is gone.

### `05-variants/05-consensus-and-lineage.md` (was fabricated; rewritten) -- CLEAN (one label nit)

The rewrite correctly removed the false "iVar Call Variants writes a consensus
FASTA" core claim and now states "It is worth being precise ... it is easy to
assume the variant caller produces it. It does not" (line 39). Verified:

- **Three real consensus surfaces.** (a) `lungfish msa consensus` exists with
  `--threshold` (**default 0.6**, matching line 75's note), `--gap-policy`
  (omit/include), `--output-kind fasta|reference`, `--name`, `--rows`
  (`msa consensus --help`). The worked CLI block (lines 92-98) is valid.
  (b) Inspector consensus mode controls (line 102) are exactly `Consensus Mode`
  (Picker), `Use IUPAC ambiguity codes` (Toggle), `Hide high-gap sites`
  (Toggle), and sliders "Consensus minimum depth", "Consensus minimum MAPQ",
  "Consensus minimum base quality" (`InspectorView.swift:741-812`).
  (c) Viral Recon wizard's Consensus picker (iVar/bcftools) is described as the
  only reads-to-consensus path, consistent with ground truth.
- **Freyja** (lines 104-119): `lungfish freyja demix --variants <t> --depths <t>
  --output-dir <d> --sample <s> --execute` matches `freyja demix --help` exactly,
  including `--dry-run` as the alternative to `--execute` (line 119) and the
  `wastewater-surveillance` pack requirement (the `--execute` help literally
  reads "Run Freyja through the wastewater-surveillance tool pack"; pack id
  confirmed `PluginPack.swift:699`).
- **Pangolin/Nextclade boundary** (lines 127-135): correctly external; no in-app
  lineage assignment is claimed.
- Only defect: the `Create consensus FASTA` label (line 100) should read
  "Create Consensus Sequence" (see should-fix #1).

### `06-classification/05-running-nao-mgs.md` (was fabricated; rewritten to import-only) -- CLEAN

The rewrite correctly converted this to import-only and removed every fabricated
run/series/time-series claim. It now states "This is an import-only tool. There
is no NAO-MGS option in the run wizard and no 'run NAO-MGS' surface anywhere in
the app" (line 37) and "It is not a time series ... there is no multi-week
chart, no series, and no per-week abundance line" (line 119). Verified:

- **Source/attribution** (lines 30, 39, 155-156): SecureBio,
  `github.com/securebio/nao-mgs-workflow` -- matches `NaoMgsResultParser.swift:319`
  and `NaoMgsImportSheet.swift:11`. The old "Nucleic Acid Observatory /
  naobservatory.org" error is fixed.
- **Primary file** `virus_hits_final.tsv.gz` plus per-sample `_virus_hits.tsv.gz`
  (lines 44-47): matches `NaoMgsResultParser.swift:319,697,722-723`.
- **CLI** `lungfish nao-mgs import <input-path>` with `--sample-name`,
  `-o/--output-dir`, `--min-bitscore` (lines 99-107): matches `nao-mgs import
  --help` exactly. "converts the pipeline's alignments to SAM" matches the
  command abstract "Import NAO-MGS results and convert to SAM." `lungfish import
  nao-mgs` (line 107) is a real registered subcommand. `lungfish nao-mgs summary
  <path> --top 20` (line 113) matches `nao-mgs summary --help`.
- **Viewport columns** (line 125): **Sample, Taxon, Hits, Unique Reads, Refs** --
  matches `NaoMgsResultViewController.swift:1360-1399,1425` exactly. Coverage
  **sparkline** (line 134) matches `CoveragePlotView` (`NaoMgsChartViews.swift:13`).
- **BLAST Verify from the viewport** (lines 141-144): real --
  `onBlastVerification` + `actionBar.onBlastVerify` + coverage-stratified read
  selection (`NaoMgsResultViewController.swift:232,1527`). This resolves the
  ground-truth's open question (it had not confirmed NAO-MGS BLAST wiring).

### `06-classification/06-blast-verification.md` (was fabricated; rewritten) -- CLEAN

The rewrite removed the fabricated "BLAST tab," "select the longest
representative read," "Send to BLAST," and "database/program selector + local
BLAST" claims, and now leads with the verdict model. Verified:

- **Launch surface** (lines 97-101): "BLAST Verify" button in the viewport
  action bar + a row context menu ("BLAST Verify…"/"BLAST Matching Reads…"), a
  popover titled `Verify "<taxon>" via NCBI BLAST` -- matches
  `ClassifierActionBar` and `BlastConfigPopoverView.swift:14,65`.
- **Reads-to-submit slider** (line 103): default **20**, range **1..50** clamped
  to available reads -- matches `BlastConfigPopoverView.swift:25,75` ("slider
  range is 1...50, clamped to the number of available clade reads") and the
  `BlastVerificationRequest` default. No DB/program selector exists; database
  `nt` / program `blastn` are fixed (`BlastVerificationRequest.swift:85-86,
  default `maxTargetSeqs: 5`), matching line 108.
- **Verdicts** (lines 42-43): `supported / unsupported / mixed / inconclusive`
  matches `BlastVerdict` enum (`BlastResult.swift:348-354`).
- **Drawer** (lines 130-152): per-submitted-read parent rows with ~5 child hits
  ("up to about five per read, the fixed hit-list size" = `maxTargetSeqs 5`);
  columns Status, Read ID, Organism, Identity, E-value, Bit score, Accession,
  Coverage, Align Length, Tax ID, Verdict; "Open in NCBI BLAST" and "Re-run
  BLAST" buttons -- all match `BlastResultsDrawerTab.swift:243-256,307-310`.
- **CLI** (lines 167-180): `lungfish blast verify --kreport <f> --kraken-output
  <f> --source <f> --taxid <n>` plus `--reads` (default 20), `--include-children`,
  `--max-concurrent` (default 1), `--extra-args KEY=VALUE` -- matches `blast
  verify --help` exactly, including the three required inputs.
- **No local-BLAST escape hatch** (line 197): correct; no `--database`/`--program`
  flag exists.

### `06-classification/08-novel-virus-detection.md` (NEW chapter) -- CLEAN

This new chapter is accurate end to end against `Sources/LungfishNvdUI/` and the
NVD CLI. Verified:

- **Source/input** (lines 39-47): NVD is an external Snakemake pipeline; primary
  file `*_blast_concatenated.csv(.gz)` in the `05_labkey_bundling/` folder --
  matches `NvdCommand.swift:12,53,84`.
- **CLI** (lines 103-116): `lungfish nvd import <dir> --output-dir <d> --name <n>`
  with default bundle name **`nvd-<experiment>`** -- matches `nvd import --help`
  (`--name` help: "default: nvd-{experiment}"). `lungfish import nvd` (line 108)
  is a real subcommand. `lungfish nvd summary <path> --top 20` (line 116) matches
  `nvd summary --help`; the example file `100_blast_concatenated.csv.gz` matches
  the source doc-comment.
- **Viewport summary bar** (line 122): "Experiment | Samples | Contigs" -- matches
  `NvdResultViewController.swift:72` (`Experiment: ... | Samples: ... | Contigs:
  ...`).
- **Table columns** (lines 128-132): Sample, Contig, Length, Classification,
  Rank, Accession, **Identity %**, E-value, Bit Score, Mapped Reads, **RPB**
  (readsPerBillion) -- all present as `NSTableColumn` titles
  (`NvdResultViewController.swift:960-1033`). "RPB (reads per billion)" matches
  the `readsPerBillion` column.
- **By Sample / By Taxon grouping** (line 137): real --
  `NSSegmentedControl(labels: ["By Sample","By Taxon"])`
  (`NvdResultViewController.swift:210`).
- **Mini-BAM in the detail pane** (lines 148-151): real `buildMiniBAMPanel` /
  `MiniBAMViewController` with `subjectNoun = "contig"`
  (`NvdResultViewController.swift:681,717`).
- **BLAST Verify submits the contig sequence** (lines 153-155): real --
  `blastVerifySelectedContig()` calls `onBlastVerification?(hit, sequence)`
  (`NvdResultViewController.swift:186,1452-1467`). The **Export** action-bar
  button (line 157) is real (`onExport`, action-bar diagram `[BLAST Verify]
  [Export]`). This confirms the ground-truth's unverified NVD-BLAST wiring.

### `08-workflows/01-the-workflow-builder.md` (heavily rewritten) -- CLEAN

The rewrite replaced the entire fabricated palette (invented categories Acquire/
Align and map/Trim/Call/Profile/Assemble/Tree; invented node types Download
reference/Map reads/Trim primers/Annotate variants/Profile taxa/Build tree; the
"red flash"; the "More inputs drawer"; the un-buildable reads-to-variants worked
example) with claims that match source exactly. Verified:

- **Seven real categories** (line 95): Input, Preprocessing, Trimming &
  Filtering, Decontamination, Read Processing, Analysis, Output -- matches
  `NodeCategory` enum (`WorkflowNode.swift:410-417`).
- **Node types + categories + runnability** (table lines 187-205): every row
  matches `WorkflowNodeType` enum cases, their `category`, and
  `isBuilderNativeFASTQNode` (`WorkflowNode.swift:13-53,110-138`). The five
  runnable FASTQ display names are exact: "Remove PCR duplicates", "Adapter +
  quality trim", "Remove human reads" (Decontamination), "Merge overlapping
  pairs" (Read Processing), "Remove short reads". Generic Analysis nodes
  (Alignment/Variant Calling/Quantification/Assembly) are correctly export-only.
  "There is no download node, no primer-trim node, no annotation node, and no
  phylogenetics node" (line 207) is correct (no such enum cases).
- **Parameter defaults** (table lines 147-153): Remove PCR duplicates = none
  (`fastpDedup` returns `[]`); Adapter+quality trim = Detect adapters (true),
  Quality threshold (15), Window size (5), Cut mode ("right"); Remove human reads
  = Database (deacon-panhuman); Merge overlapping pairs = Minimum overlap (15);
  Remove short reads = Minimum length (50), Maximum length (unset) -- all match
  `parameterDefinitions` (`WorkflowNode.swift:266-379`). The two hidden metadata
  fields on generic nodes (line 158) match `workflowBuilderOperationMetadataDefinitions`.
- **Port typing + one exception** (lines 111-118): exact-type match, `Any`
  accepts anything, and the single bidirectional `reference <-> assembly`
  exception -- matches `PortDataType.isCompatible` (`WorkflowNode.swift:501-512`).
  "Lungfish plays the system alert sound and the connection is dropped" (line
  118) matches `NSSound.beep()` (the old "red flash" is gone).
- **Linear-chain + cycle constraints** (lines 133-139, 307-308): `guard
  outgoing.count == 1` throwing `nonLinearGraph` ("requires a single linear FASTQ
  chain") matches `WorkflowBuilderPlanCompiler.swift:92-93`.
- **Menu title** "(Experimental)" (lines 11, 50, 81, 291): matches
  `MainMenu.swift:739`.
- **VSP2 template** (lines 313-316): `VSP2WorkflowTemplate.makeGraph` with stable
  UUIDs and recipe `vsp2-target-enrichment` (`VSP2WorkflowTemplate.swift:23-118`).
- **fastp fusion** (lines 326-331): `isFusibleFastpBuilderStep`
  (`WorkflowBuilderNativeRunner.swift:411-431`).
- **Atomic staging** (lines 342-348): `.staging-<uuid>` bundle then `moveItem`,
  cleanup on error (`WorkflowBuilderNativeRunner.swift:98-133,210-213`).
- **Run records** (lines 259-262, 352-354): `run.json` + `provenance.json` under
  `runs/<id>/`, node status `running/succeeded/failed/skipped`, graph checksum --
  matches `WorkflowBuilderRunRecord.swift:5-15,152-153`. `builder-plan.json`
  output (line 284) matches `WorkflowBuilderNativeRunner.swift:79`.
- **CLI** (lines 240-279): `lungfish workflow diff <a> <b> [--format json]` and
  `lungfish workflow builder-run --workflow --project --run-directory --threads
  --dry-run` both match `--help` exactly. The chapter's note (lines 280-282) that
  provenance-recorded argv like `workflow builder-step run` are audit strings,
  not invocable commands, is correct and a good clarification.

### `08-workflows/02-exporting-as-nextflow-or-snakemake.md` (heavily rewritten) -- CLEAN

The rewrite fixed the four-vs-six target count, removed the invented Nextflow
`standard`/`slurm` profiles and `params.reads_r1`/`reference`/`primer_bed`
semantic parameters, and removed the invented Snakemake `workflow/` layout +
per-rule conda envs. Verified:

- **Six export targets** (table lines 42-49): Shell Script (`run.sh`), Python
  Script (`reproduce.py`), Nextflow (`main.nf` + `nextflow.config` +
  `containers/manifest.json`), Snakemake (`Snakefile` + `config.yaml`), Methods
  Section (`methods.md`), Full Provenance (JSON) (`provenance.json`) -- matches
  `ProvenanceExportFormat` six cases (`ProvenanceExporter.swift:11-17`) and the
  actual menu-path filenames written by `exportBundle` (`run.sh` line 133,
  `reproduce.py` 137, `main.nf`/`nextflow.config` 141-143, `Snakefile`/
  `config.yaml` 159-161, `methods.md` 169, `provenance.json` 172). The six menu
  items + the "separator between the first four and the last two" (line 51)
  match `MainMenu.swift:1029-1059` with `prefix(4)`/`dropFirst(4)` (lines
  256-260). NOTE: the enum's unused `defaultFilename` values (`reproduce.sh`,
  `methods.txt`) are NOT what the menu produces; the chapter correctly documents
  the menu output (`run.sh`, `methods.md`).
- **Minimal `nextflow.config`** (lines 92-97): `process { errorStrategy =
  'terminate' }` + `docker.enabled = true`, with no profiles -- matches
  `exportNextflowConfig`. "do not pass `-profile`" (line 99) is correct.
- **Filename-derived Nextflow params** (lines 202-205): `params.<sanitized
  filename> = '<filename>'` + `params.outdir = './results'` with `publishDir
  params.outdir, mode: 'copy'` -- matches `exportNextflow` (`ProvenanceExporter.swift:1016-1037`).
  The override example `--srr12345678_1_fastq_gz ...` (lines 211-213) is the
  correct mangled-name form.
- **Snakemake flat layout** (lines 232-238): single `Snakefile` + flat
  `config.yaml`, `singularity: "docker://<image>"` directives, run command
  `snakemake --cores 8 --use-singularity` -- matches `exportSnakemake`
  (`ProvenanceExporter.swift:1108,1150-1151`).
- **`containers/manifest.json`** (lines 101-103, 120) and the `unknown`-version
  synthesis caveat (lines 125-130) are real (`synthesizedReferenceProvenanceEnvelope`).
- **Signing + transitive provenance chain** (lines 263-274): real
  (`signReportArtifacts`, `expandProvenanceChain` copying into
  `provenance/source/`).
- **Container/lockfile CLIs** (lines 148-168): `lungfish bundle export <bundle>
  --format container --output <tar> --plugin-pack ...` matches `bundle export
  --help` (abstract: "deterministic OCI layout tarball"); `lungfish conda lock
  --pack <pack> --output <file>` and `lungfish conda install --from-lockfile
  <file>` match their `--help`. Shell/Python `INPUT_n` + `OUTDIR` variables
  (line 219, 243) match `exportShell`.

---

## Bottom line

Across all seven most-rewritten chapters, the rewrites are fabrication-free per
the v0.5.0-alpha11 binary and source. Every fabricated feature flagged in the
Round-1/2 ground-truth maps has been removed and replaced with claims that match
`--help` output and Swift symbols, and the rewrites resolved two questions the
ground truth had left open (NAO-MGS and NVD viewport BLAST-Verify wiring -- both
confirmed real). The only residual issues are minor wording/labeling: (1) the
MSA consensus control should be quoted "Create Consensus Sequence" not "Create
consensus FASTA" (05-variants/05, line 100); (2) "appending" misstates where the
LoFreq Extra-arguments tokens are inserted (05-variants/03, line 88). Neither is
a fabricated feature; both are safe to leave or fix in a polish pass.
