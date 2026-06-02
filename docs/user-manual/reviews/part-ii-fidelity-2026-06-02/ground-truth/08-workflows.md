# Ground-truth reality map: 08-workflows

Scope: verified the two Workflows chapters against the real Swift source and the
built CLI binary at `.build/debug/lungfish-cli`. CLI help was read live (the
binary exists and runs). No build was performed. Symbols, flags, file names,
and emitted-file contents below are cited from source or CLI `--help`.

Authoritative sources read:
- `Sources/LungfishWorkflow/Builder/WorkflowNode.swift` (node types, categories, ports, params)
- `Sources/LungfishApp/Views/WorkflowBuilder/WorkflowNodePalette.swift` (palette grouping)
- `Sources/LungfishWorkflow/Builder/WorkflowBuilderPlanCompiler.swift` (native plan)
- `Sources/LungfishWorkflow/Builder/WorkflowBuilderNativeRunner.swift` (native FASTQ runner)
- `Sources/LungfishApp/Services/WorkflowBuilderRunService.swift` (run dispatch + binding sheet path)
- `Sources/LungfishApp/Views/WorkflowBuilder/WorkflowCanvasView.swift` (connect/reject behavior)
- `Sources/LungfishWorkflow/Builder/WorkflowGraph.swift` / `WorkflowConnection.swift` (typed-port + cycle validation)
- `Sources/LungfishWorkflow/Builder/WorkflowGraphDiff.swift`, `WorkflowVersion.swift`, `WorkflowLibraryStore.swift`, `WorkflowBuilderRunRecord.swift`
- `Sources/LungfishWorkflow/Builder/VSP2WorkflowTemplate.swift`, `NextflowExporter.swift`
- `Sources/LungfishWorkflow/Provenance/ProvenanceExporter.swift` (the menu-wired exporter)
- `Sources/LungfishCLI/Commands/WorkflowCommand.swift`, `BundleCommand.swift`
- `Sources/LungfishApp/App/MainMenu.swift`, `AppDelegate+ImportExport.swift`

---

## Chapter 01: The Workflow Builder

### 1. CLAIMS THAT DO NOT MATCH CODE

**The palette category names are invented.** The chapter (lines 86-88) says
"Categories follow the same structure as the Tools menu: Acquire, Align and map,
Trim, Call, Profile, Assemble, Tree." The real categories are the cases of
`NodeCategory` in `WorkflowNode.swift` (lines 410-417), and the palette is built
directly from `NodeCategory.allCases` in `WorkflowNodePalette.buildDataModel()`
(lines 75-90). The seven REAL categories are:
`Input`, `Preprocessing`, `Trimming & Filtering`, `Decontamination`,
`Read Processing`, `Analysis`, `Output`. None of "Acquire / Align and map / Trim
/ Call / Profile / Assemble / Tree" exists.

**The "Common node types" table invents node types that have no enum case.**
The only node types that exist are the cases of `WorkflowNodeType`
(`WorkflowNode.swift` lines 13-53). Mapping the chapter table (lines 158-175)
against the enum:

- Real (enum case exists): FASTQ Bundle Input (`fastqBundleInput`), FASTP
  deduplicate (`fastpDedup`), FASTP/Adapter trim (`fastpTrim`), Deacon human
  scrub (`deaconHumanScrub`), FASTP merge (`fastpMerge`), SeqKit length filter
  (`seqkitLengthFilter`), Import/FASTQ Input (`fastqInput`), generic Quality
  Control (`qualityControl`), generic Trimming (`trimming`), generic Alignment
  (`alignment`), generic Variant Calling (`variantCalling`), Quantification
  (`quantification`), Assembly (`assembly`), Report (`report`), plus inputs
  `fastaInput`, `bamInput`, `sampleSheet`, and the export/anchor nodes.
- INVENTED (no enum case, not in palette): "Download reference" (Acquire),
  "Map reads (minimap2)", "Trim primers" (BAM + primer scheme), "Annotate
  variants" (VCF + GFF), "Profile taxa (Kraken2)", "Build tree (IQ-TREE)". The
  table's "Plugin" column (minimap2 / iVar / Kraken2 / SPAdes / IQ-TREE) is also
  not modeled; nodes carry only a `category`, not a plugin. There is no
  accession/download node type, no annotation node type, no primer-trim node
  type, and no tree node type anywhere in `WorkflowNodeType`
  (grep confirmed: only `primerSchemeBundle` exists as a PORT data type, never as
  a node).

**The "red flash" on a type mismatch is invented.** Chapter lines 102-106 say
"The builder draws a thin red flash across an attempted edge if the types do not
match, then drops the connection." The real rejection in
`WorkflowCanvasView.createConnection(...)` (lines 1013-1038) calls
`graph.addConnection(...)`; on the thrown error it emits **`NSSound.beep()`**
(line 1036) and logs. There is no red flash, no transient red edge. (Typed-port
validation itself IS real: `WorkflowConnection.swift` line 107 checks
`sourcePort.dataType.isCompatible(with:)` and returns `.incompatibleTypes`.)

**The "More inputs" drawer / secondary inputs are invented.** Chapter lines
115-119 describe optional secondary inputs (BED, GFF, sample-sheet CSV) that
"collapse into a single More inputs drawer on the node header; click the drawer
chevron to reveal them." Grep for `More inputs`, `moreInputs`, `drawer`,
`chevron`, `secondary` across the WorkflowBuilder views returns nothing. Ports
are fixed per node type (`WorkflowNodeType.inputPorts`, lines 141-185); there is
no drawer and no collapsing. Node types that take a second input (`alignment`
takes reads+reference; `variantCalling` takes alignments+reference;
`quantification` takes alignments+annotation) expose both ports directly, always
visible.

**The reads-to-variants worked example is NOT buildable today (the central
over-claim).** Chapter lines 284-322 walk the user through dragging "Download
reference (MN908947.3)", "Map reads (minimap2)", "Trim primers (ARTIC v3)",
"Call variants (iVar, MAF 0.5)", "Annotate variants (NCBI GFF)" and fanning a
reference output to multiple inputs. None of these five node types exists (see
above), so this graph cannot be assembled from the palette. Even setting that
aside, the native runner cannot execute alignment/variant nodes:
`WorkflowBuilderPlanCompiler.recipeOperation(for:)` (lines 373-388) returns
`nil` for every node type except the five FASTQ ops, and
`validateSupportedNodes` (lines 271-277) throws `unsupportedNode` for anything
else. The fan-out described ("one output port can fan out to many input ports")
is also rejected by the native compiler, which requires `outgoing.count == 1`
per node (lines 92-97, `nonLinearGraph`). The only described worked example that
is real is the VSP2 FASTQ chain (see below).

**Minor: the menu title omits "(Experimental)".** Chapter lines 11, 76, 256,
291 use "Tools > Workflow Builder". The actual menu item is
"Workflow Builder (Experimental)…" (`MainMenu.swift` line 739). The window title
is "Workflow Builder" (`WorkflowBuilderViewController.swift` line 97), so the
window matches but the menu path does not.

**Minor: the iVar/minimap2/SPAdes parameter examples are not the real node
params.** Chapter lines 130-133 promise iVar "Minimum allele frequency",
minimap2 preset, SPAdes `--meta`. The real `alignment`, `variantCalling`, and
`assembly` node types expose only the two hidden metadata params
(`workflow_builder_tool_id`, `workflow_builder_operation_summary`) in
`parameterDefinitions` (lines 380-404); they have no MAF/preset/`--meta` fields.
The nodes with real typed parameters are the FASTQ ops and the generic
`trimming`/`qualityControl` nodes.

### 2. APP FEATURES MISSING FROM THE DOCS

**The native runner fuses adjacent fastp steps.** `WorkflowBuilderNativeRunner`
collapses consecutive `fastpDedup`/`fastpTrim` builder steps into a single fastp
invocation for provenance accounting (`isFusibleFastpBuilderStep`,
`executionRecordsByBuilderStep`, lines 402-438). The chapter presents each step
as an independent operation; the fusion behavior (and its effect on
`stepResults`) is undocumented.

**A built-in VSP2 template graph generator exists.** `VSP2WorkflowTemplate`
(`makeGraph(...)`) programmatically builds the full FASTQ chain
(input -> dedup -> trim -> scrub -> merge -> length-filter -> Project output)
from the `vsp2-target-enrichment` built-in recipe, with stable node UUIDs. The
chapter tells the reader to drag the five nodes by hand and never mentions a
template path.

**The output bundle is published via atomic staging.** The runner writes to a
hidden `.staging-<uuid>` bundle, writes provenance there, then `moveItem`s into
place, deleting both staging and target on any error
(`WorkflowBuilderNativeRunner` lines 97-135, 210-214). The chapter says only
"the output bundle is only published after provenance has been written"; the
staging/atomic-rename mechanism and the cleanup-on-failure are undocumented.

### 3. UNCERTAIN / NEEDS-HUMAN-CHECK

**`builder-run` flag set vs. the chapter's example.** Chapter lines 239-244 show
`lungfish-cli workflow builder-run --workflow ... --project ... --run-directory
...`. CLI help confirms `--workflow`, `--project`, `--run-directory`,
`--threads`, `--dry-run` all exist (`WorkflowBuilderRunSubcommand`,
`WorkflowCommand.swift` lines 34-94). The example is accurate. Note, however,
that the plan compiler emits an internal `workflow builder-run --graph-id ...
--input-bundle ...` argv (lines 178-190) and a phantom `workflow builder-step
run` argv (lines 291-315) that are NOT registered subcommands; those argv are
provenance strings only, not runnable. Worth a human note that these argv are
not user-invocable.

**Run record file names match, but verify the prose pairing.** Chapter lines
229-235 and 337-340 reference `runs/<run-id>/run.json` and
`runs/<run-id>/provenance.json`. `WorkflowBuilderRunStore` (lines 150-172) writes
exactly `run.json` + `provenance.json` under `runs/<runID>/`. Real. The record
carries `graphChecksumSHA256`, per-node `WorkflowBuilderNodeRunStatus` (including
`.skipped`), `errorMessage`, and `runtimeIdentity` (`WorkflowBuilderRunRecord`),
matching the chapter's "graph checksum, sample/project bindings, per-node status,
error state". Confirmed real.

**Version subtitle.** Chapter lines 198-200 say the semver version is "visible in
the Workflow Builder window subtitle". `viewWillAppear` sets the subtitle to
`graph.name` (line 98), but a later reload sets it to
`"\(graph.name) \(workflowVersionDisplayText)"` (line 959, where
`workflowVersionDisplayText` = `"v\(graph.version)"`). So the version shows in
the subtitle after a graph load/version change, not necessarily on first appear.
Human should confirm the exact UI moment. The `versions/history.json` append
(`WorkflowLibraryStore.appendWorkflowVersionHistory`, lines 222-235, entry =
version + savedAt + workflowName) and semver normalization (`WorkflowVersion`)
are real and match lines 201-204.

---

## Chapter 02: Exporting as Nextflow or Snakemake

Important framing note: the **File > Export > Provenance** menu items are wired
to `AppDelegate.exportProvenanceNextflow` etc.
(`AppDelegate+ImportExport.swift` lines 25-34), which call
`exportProvenance(format:)` and ultimately `ProvenanceExporter.exportBundle`.
That exporter renders from a `WorkflowRun` provenance record, NOT from a saved
`.lungfishflow` Builder graph. There is a separate `Builder/NextflowExporter`,
but it is only used by the in-app run pipeline
(`WorkflowBuilderRunService` line 285), never by the export menu. So this chapter
documents the provenance exporter, while pretending its input is "the
reads-to-variants workflow from The Workflow Builder" (lines 65-71) - a graph
that cannot be built or run (see chapter 01).

### 1. CLAIMS THAT DO NOT MATCH CODE

**"Four targets are available" is wrong; there are six.** Chapter lines 32-46
list exactly four (Nextflow, Snakemake, Shell, Methods Section). The real
`ProvenanceExportFormat` enum (`ProvenanceExporter.swift` lines 11-17) has SIX
cases, and the menu builds all six (`ProvenanceExportMenuModel.items`,
`MainMenu.swift` lines 1027-1064): Shell Script, **Python Script**, Nextflow
Pipeline, Snakemake Workflow, Methods Section, **Full Provenance (JSON)**. The
chapter omits Python Script and Full Provenance (JSON). (The submenu visually
splits the first four from the last two with a separator, `MainMenu.swift` lines
256-262, which may be the source of the "four" error, but six items render.)

**The Nextflow `nextflow.config` profiles are invented.** Chapter lines 88-92
claim "`nextflow.config` declares a `standard` profile that runs locally and a
`slurm` profile that submits each process as a SLURM job." The real
`exportNextflowConfig` (`ProvenanceExporter.swift` lines 793-803) emits only:
```
process {
    errorStrategy = 'terminate'
}
docker.enabled = true
```
There is no `profiles { ... }` block, no `standard` profile, and no `slurm`
profile. The chapter's "switch the Nextflow profile to use it" (line 176) and
"-profile standard" run command (lines 80-82) reference profiles that the export
does not generate.

**The Nextflow parameter block is invented.** Chapter lines 184-200 show
`params.reads_r1`, `params.reads_r2`, `params.reference`, `params.primer_bed`,
`params.outdir`, overridable via `--reads_r1` etc. The real `exportNextflow`
(lines 1012-1019) emits one `params.<sanitized-filename>` per input file (e.g.
`params.srrxxxxxxx_1_fastq_gz`) derived from the provenance input filenames, plus
`params.outdir = './results'`. There are no semantic `reads_r1`/`reference`/
`primer_bed` parameters. The Builder `NextflowExporter` (the unused one) emits a
`params { ... }` config block instead, also without those semantic names
(lines 160-197). Either way the chapter's groovy is not what is produced.

**The Snakemake "modern workflow/ layout" is invented.** Chapter lines 219-224
claim the export "uses the modern `workflow/` directory convention", writes a
`config/config.yaml`, and writes "Per-rule conda environments into
`workflow/envs/`." The real `exportBundle` for `.snakemake`
(`ProvenanceExporter.swift` lines 158-167) writes a flat `Snakefile` plus a flat
`config.yaml` in the export root. There is no `workflow/` directory, no
`config/config.yaml`, and no `workflow/envs/`. Per-rule isolation uses
`singularity:` directives (`"docker://<image>"`, `exportSnakemake` lines
1148-1152), NOT conda environment files.

**The emitted-files table is partly wrong for Nextflow.** Chapter line 43 lists
Nextflow as `main.nf`, `nextflow.config`, `provenance/`. The real Nextflow export
also creates `containers/manifest.json` (a JSON list of tool/version/image/digest
entries, `exportBundle` lines 149-157, `exportContainerManifest` lines 805-826).
The table omits it.

**"Exact tool versions and command lines that ran, not a reconstruction"
overstates the synthesized steps.** Chapter lines 34-35. The exporter expands the
provenance chain and can SYNTHESIZE provenance for reference downloads that were
never recorded as steps (`synthesizedReferenceProvenanceEnvelope`, lines
440-508), stamping `toolVersion: "unknown"`. So for some steps the export is a
reconstruction with an unknown version, contradicting the absolute claim.

### 2. APP FEATURES MISSING FROM THE DOCS

**Two undocumented export targets.** Python Script (`reproduce.py`, a subprocess
driver, `exportPython` lines 918-993) and Full Provenance (JSON)
(`provenance.json`, the raw envelope, lines 171-174) are both shipped menu items
the chapter never mentions.

**Every export is cryptographically signed when a signer is configured.**
`signReportArtifacts` (lines 253-268) signs each generated artifact and writes
`.signature.json` + `.pub` files next to it, and self-verifies for the local
provider. The `provenance/` folder also gets its own export-sidecar with argv and
options (`writeExportProvenanceSidecar`, lines 528-581). The chapter mentions
provenance copying but not signing.

**The export bundles the upstream provenance chain, not just the final step.**
`expandProvenanceChain` (lines 280-345) walks input dependencies (including
enclosing `.lungfishref` bundles and their manifests) and merges them, copying
each discovered sidecar into `provenance/source/...`. The chapter's "copied
verbatim from the project" (line 49) understates this transitive collection.

### 3. UNCERTAIN / NEEDS-HUMAN-CHECK

**`bundle export --format container` and `conda lock --pack` are real.** CLI help
confirms `lungfish bundle export <bundle> --format container --output <tar>
[--plugin-pack ...]` (`BundleCommand.swift`, `BundleExportFormat.container` line
82-83) and `lungfish conda lock --pack <pack> --output <file>`. The chapter's
commands at lines 130-135 and 148-151 match the real flags. The OCI-layout
deterministic-tarball description (lines 137-144) should be spot-checked against
the bundle export implementation, but the command surface is correct.

**Methods export file name.** Chapter line 46 / 169 implies `methods.md`. The
menu path writes `methods.md` (`exportBundle` line 169), though
`ProvenanceExportFormat.methods.defaultFilename` returns `methods.txt` (line 38).
The active menu export produces `.md`; the `.txt` default is dead for this path.
Human may want to flag the internal inconsistency, but the chapter's `methods.md`
is correct for the menu.

**Shell/Methods/Snakemake parameterization prose.** Chapter lines 202-207 claim
the Snakemake export overrides via `--config` against `config.yaml`, the shell
export uses "positional environment variables documented at the top of
`run.sh`", and methods "does not parameterise anything." The real shell export
writes `INPUT_n` and `OUTDIR` variables with no header docs block
(`exportShell` lines 841-899), and the primary shell artifact is named `run.sh`
in the bundle path (line 133) though `defaultFilename` says `reproduce.sh`. These
are roughly directionally true but the specifics (documented positional env vars)
are not in the code; human should confirm acceptable.

---

## Section-wide

**What is real.** The Workflow Builder is a genuine NSSplitViewController
node-graph editor (palette + canvas + inspector,
`WorkflowBuilderViewController`). Typed-port compatibility checking
(`PortDataType.isCompatible`), cycle prevention (`wouldCreateCycle`), graph
validation (`WorkflowGraph.validate`), pinned Sample input / Project output
anchors, the run-binding sheet for legacy graphs (`showRunBindingSheet`),
project-scoped FASTQ-bundle input with the `@/...lungfishfastq` pattern and
project-containment enforcement, semver versioning + `versions/history.json`,
`run.json`/`provenance.json` run records with per-node status and graph checksum,
Operation Center parent+child rows, and the `lungfish workflow diff
[--format json]` CLI (`WorkflowDiffSubcommand`, verified via `--help`) all exist
as described. The VSP2 FASTQ worked example (dedup -> trim -> scrub -> merge ->
length-filter, with the stated default parameters) is genuinely buildable and is
the one graph the native runner (`WorkflowBuilderNativeRunner`) executes.

**Which node CATEGORIES are real.** REAL (the only ones): `Input`,
`Preprocessing`, `Trimming & Filtering`, `Decontamination`, `Read Processing`,
`Analysis`, `Output`. INVENTED by chapter 01: `Acquire`, `Align and map`, `Trim`,
`Call`, `Profile`, `Assemble`, `Tree`.

**Which node TYPES are real.** REAL: `fastqBundleInput`, `fastqInput`,
`fastaInput`, `bamInput`, `sampleSheet`, `qualityControl`, `trimming`,
`fastpDedup`, `fastpTrim`, `deaconHumanScrub`, `fastpMerge`, `seqkitLengthFilter`,
`alignment` (generic, bwa-backed in export), `variantCalling` (generic,
bcftools-backed in export), `quantification`, `assembly` (SPAdes), `report`,
`export`, plus the pinned `sampleInput`/`projectOutput`. INVENTED: "Download
reference", "Map reads (minimap2)", "Trim primers", "Annotate variants",
"Profile taxa (Kraken2)", "Build tree (IQ-TREE)". Only the five FASTQ ops are
executable by the native runner; the generic analysis nodes are export-only
(Nextflow text) and run only if a separate `nextflow` binary is present and the
graph uses no `fastqBundleInput`.

**Bottom line on the reads-to-variants worked example.** NOT buildable today.
Three independent blockers: (1) the five node types it requires do not exist in
`WorkflowNodeType`; (2) the native FASTQ runner supports only the five fastp/
deacon/seqkit ops and rejects everything else (`recipeOperation` returns nil,
`validateSupportedNodes` throws); (3) the reference fan-out it depends on is
rejected by the linear-chain constraint. The only end-to-end runnable Builder
graph is the VSP2 FASTQ chain.
