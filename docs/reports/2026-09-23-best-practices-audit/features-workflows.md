# Feature completeness and dead ends, part B: analysis workflows end to end (WFL)

Audit date: 2026-09-23. Tree: `claude/lge-best-practices-audit-0a1b8f` at HEAD `a1f439076`.

## Scope

For each analysis workflow, this review follows the full chain: wizard or dialog, then pipeline, results bundle, sidebar entry, viewport, exports and CLI equivalent. The workflows covered are:

- FASTQ operations
- read mapping and BAM primer trim
- variant calling
- metagenomics classifiers (Kraken2/Bracken, EsViritu, TaxTriage, NAO-MGS, NVD, CZ ID) and the BLAST drawer
- assembly
- MSA (MAFFT) and phylogenetics (IQ-TREE)
- clustering (Savont, pbAA)
- Viral Recon and generic Nextflow/Snakemake
- MHC genotyping and the haplotype editor, including AI haplotyping
- 12S amplicon matching
- primer design (Primer3, PrimalScheme)
- orient
- recipes (VSP2)
- Freyja
- external workflow registration

Import, viewers and export as standalone features belong to the sibling report. Deep scientific validity belongs to the scientific-correctness report. Where a workflow defect is also a scientific one (WFL-01, WFL-08), it is recorded here because it happens inside the workflow plumbing.

## Method

- I read the composition roots first:
  - `MainMenu.swift`, `ToolsMenuModel.swift`, `WorkflowLibrary.swift`
  - `AnalysesFolder.swift`, `SidebarProjectScanner.swift`
  - `MainSplitViewController+ContentDisplay/ClassifierDisplay`, `AnalysisResultDisplayRoute.swift`
  - `OperationCenter.swift`, the Operations panel, and the CLI root command tree
- Six read-only tracing passes then covered the workflow families. Each followed call chains from the menu item to the on-disk result and back through the sidebar.
- I re-opened and personally checked every finding at P0/P1, and most P2 findings. Where I did not, the finding says so.
- Nothing was built, run or modified. No `swift build` or `swift test` was run, as the brief requires.

**Confidence labels.**
- **Traced:** the control flow was followed in source, end to end.
- **Suspected:** the code path is clear, but the outcome depends on tool or data behaviour that was not observed.
- Nothing is labelled **Confirmed**, because nothing was executed.

## Limits

- No GUI or CLI run was performed, so no finding is reproduced.
- Line numbers are for HEAD `a1f439076`.
- The report does not re-judge algorithm parameters, for example whether iVar thresholds are right. It only checks whether the values the user sets reach the tool.

## Executive summary

The workflow layer is broad and mostly well wired at its core. Nearly every analysis now goes through `OperationCenter` with progress, logs, failure reports and (usually) cancel. Most tools shell out to `lungfish-cli` rather than reimplementing logic. Results land in typed bundles (`.lungfishgenotype`, `.lungfish12s`, `.lungfishmsa`, `.lungfishtree`, `.lungfishprimeranalysis`) that the sidebar discovers by extension and that reopen after restart. That is a sound spine and should be preserved.

The jaggedness sits at the edges: re-ingestion, routing, preflight and options that fall between layers. The most serious problems:

- **Every FASTQ-operation output is silently rewritten** during re-ingestion (WFL-01). Qualities are quantised to Illumina 4-level bins even for ONT and PacBio data. Above a memory-derived size threshold, the output is also passed through Trim Galore, which adapter-trims, quality-trims and drops short reads that the user never asked to remove.
- **`lungfish tree infer iqtree` can destroy data** (WFL-02). It deletes the whole shared project `.tmp` scratch directory under concurrent jobs. It also deletes an existing output bundle when it refuses to overwrite it, and it can deadlock on IQ-TREE's stdout.
- **Several features are exposed but go nowhere:**
  - the "GATK + WhatsHap Phased" caller always ends in a "Not Ready" alert
  - pbAA results are written into a folder the sidebar hides by design
  - Savont batch samples open as "Unsupported analysis"
  - a renamed Kraken2/EsViritu/TaxTriage batch can no longer be opened
  - the human-read removal database picker discards the file the user chose
- **Options are ignored downstream in at least a dozen places.** EsViritu minimum read length, TaxTriage classifiers, Viral Recon caller overrides, demultiplex settings and the IQ-TREE "random" seed are examples. The ignored values are sometimes recorded in the inspector as if they had been applied.
- **Dependency handling is uneven.** Kraken2 and EsViritu offer a Download button. Primer design silently installs a pack. Mapping, MAFFT, IQ-TREE (hard-coded "available"), pbAA, Viral Recon (Docker), TaxTriage and variant callers discover a missing tool only as a failed run.
- **CLI parity has regressed in a subtle way.** The "CLI command" shown in the Operations panel and failure reports is not runnable for Kraken2, TaxTriage and EsViritu batches. Several provenance records store the GUI binary path as argv.
- **Dead code is widespread.** There are at least eight dead dialogs and launch paths, and a 730-line batch recipe engine, kept alive only by tests.

For lab scientists, the right move is fewer, finished surfaces:

- one execution path per operation
- a shared dependency preflight with an install button
- a single result-routing table keyed on `analysis-metadata.json`
- no silent data rewriting

## Workflow matrix

Key:
- **OC** = OperationCenter. P = progress, L = log, C = cancel wired.
- **Restart** = result reopens after app restart.
- **Prov** = provenance written for the result the user opens.

| Workflow | GUI entry | CLI equivalent (GUI uses it?) | OC P/L/C | Result bundle / location | Sidebar | Viewport | Restart | Exports | Prov | Failure path |
|---|---|---|---|---|---|---|---|---|---|---|
| FASTQ ops (trim, filter, dedup, subsample, demux, QC, etc.) | Tools > category > op (FASTQ Operations dialog) | `fastq <sub>` (yes, subprocess) | Y/Y/Y | new `.lungfishfastq`, re-ingested (WFL-01) | yes | FASTQ dataset viewer | yes | sibling scope | yes (CLI sidecar, misses re-ingest step) | OC row + failure report |
| Read mapping (minimap2, BWA-MEM2, Bowtie2, BBMap) | Tools > Mapping | `map` (no, same pipeline in-process) | Y/Y/Y | `Analyses/<tool>-<ts>/` + `mapping-result.json` + viewer `.lungfishref` | yes (knownTools) | Mapping viewport | yes | table CSV/TSV, consensus | yes | OC row only, raw enum text (WFL-19) |
| BAM primer trim | Inspector "Primer-trim BAM..." only | `bam primer-trim` (yes) | Y/Y/Y | new track in bundle + sidecar | via bundle | reference viewer | yes | n/a | yes | OC + alert |
| Variant calling (LoFreq, iVar, bcftools, Medaka, Clair3, GATK) | Tools > Call Variants..., Inspector | `variants call` (yes; GATK in-process) | Y/Y/Y | `variants/<id>.vcf.gz` in bundle | via bundle | variant track | yes | sibling scope | yes | OC + alert. Phased = dead end (WFL-03) |
| Kraken2 + Bracken | Tools > Classification | `conda classify` (no, in-process) | Y/Y/Y | `Analyses/kraken2-<ts>` or `-batch-` | yes | Taxonomy viewer | yes, but single runs change view mode | CSV/TSV/PNG/extract | yes | OC + alert |
| EsViritu | Tools > Classification | `esviritu detect` (no) | Y/Y/Y | always `esviritu-batch-*` | yes | EsViritu viewer | yes | CSV/TSV | yes, but replay argv wrong (WFL-11) | OC |
| TaxTriage | Tools > Classification | `taxtriage run` (no) | Y/Y/Y | `taxtriage-batch-*` | yes | TaxTriage viewer | yes | CSV/TSV/matrix/report | yes | OC. No DB install path |
| NAO-MGS / NVD import | File > Import Center | `nao-mgs` / `nvd` (helper relaunch of app) | Y/Y/Y | NAO-MGS `Analyses/`, NVD `Imports/` | yes | own viewers | yes | summary/contigs/extract | yes | OC |
| CZ ID import | Import Center | `import cz-id` (no) | Y/Y/**N** | `Classifications/*.lungfishtax` | only after manual refresh | Taxonomy wrapper | yes | taxonomy exports | yes | OC |
| BLAST drawer | classifier/assembly/12S context menus | `blast verify` (no) | Y/Y/Y (OC), drawer Cancel inert | none (not persisted) | n/a | drawer tab | **no** | CSV/TSV | **no** | OC + drawer message |
| Assembly (SPAdes, MEGAHIT, SKESA, Flye, Hifiasm) | Tools > Assembly; sidebar "Reassemble..." | `assemble` (Tools: yes; Reassemble: in-process) | Y/Y/Y | `Analyses/<tool>-<ts>` (Reassemble: next to source bundle) | yes | Assembly viewer | yes | contig tables/FASTA | yes | OC |
| MSA (MAFFT) | Tools > Multiple Sequence Alignment; MSA viewer | `align mafft` (yes) | Y/Y/Y | `Analyses/Multiple Sequence Alignments/*.lungfishmsa` | yes (extension) | MSA viewer | yes | alignment/residues/extract | yes | OC. Silent no-op without project |
| Phylogenetics (IQ-TREE) | MSA viewer context menu only | `tree infer iqtree` (yes) | Y/Y/Y | `Phylogenetic Trees/*.lungfishtree` | yes (extension) | tree viewer | yes | subtree only | yes (subtree argv fake) | OC. Hang risk (WFL-02) |
| Savont clustering | Tools > Clustering | `fastq savont-cluster` (yes) | Y/Y/Y | single: loose FASTA in `Analyses/`; batch: `savont-batch-*` | batch children route to "Unsupported" | FASTA viewer (single only) | single yes, batch no | n/a | yes | OC |
| pbAA clustering | Tools > Clustering | `fastq pbaa-cluster` (yes) | Y/Y/Y | `Analyses/cli-output-pbaa-<uuid>/*.lungfishref` | **hidden** | n/a | **no** | n/a | yes | OC. No Nextflow/Docker preflight |
| Viral Recon | Tools > Mapping > Viral Recon | `workflow run nf-core/viralrecon` (yes) | Y/Y/C (hard kill, no grace) | `Analyses/viralrecon-<ts>` + hidden `.lungfishrun` | yes | reference viewer | yes | report links only | **not in the opened folder** | OC stderr tail |
| User Nextflow/Snakemake packages | Workflow Library, then Workflow Operations window (reached indirectly) | `workflow run <path>` (yes) | Y/Y/**N on first run** | loose in `Analyses/` + hidden run bundle | no analysis node | none | n/a | none | run bundle only | OC exit 127 on missing engine |
| MHC genotyping ("miSeq amplicon") | Tools > Genotyping (enabled by default) | `fastq genotype` (yes) | Y/Y/Y | `Analyses/Amplicon genotyping results/*.lungfishgenotype` | yes | Genotype viewport | yes | CSV/TSV, Excel (LabKey and pivot are CLI only) | yes (Excel argv fake) | OC |
| Full-length ONT MHC | Tools > Genotyping (off by default) | `fastq full-length-ont-mhc-genotype` (yes) | Y/Y/**N** | `.lungfishgenotype` | yes | Genotype viewport | yes | as above | yes | OC |
| AI haplotyping | Genotype viewport buttons | `genotype ai-haplotyping` (no, in-process) | Y/Y/**N** | bundle sidecar | via bundle | viewport | yes | n/a | synthetic argv | status text + OC |
| 12S amplicon matching | Tools > Genotyping (off by default) | `fastq 12s-match` (yes) | Y/Y/**N** | `Analyses/12S amplicon results/*.lungfish12s` | yes | 12S viewport | yes | `12s-export` (no OC feedback) | yes | OC |
| Primer design (Primer3, PrimalScheme) | Tools > PCR primer design | `primers design` (no, in-process) | Y/Y/Y | `Analyses/*.lungfishprimeranalysis` | yes | primer viewer | yes | primer-order (no CLI) | yes, but argv = GUI binary | OC. Silent pack auto-install |
| Orient | Tools > Read Processing; FASTQ viewer bar (two paths) | `fastq orient` **and** `orient` (dialog: yes; viewer: in-process) | Y/Y/Y | `.lungfishfastq` | yes | FASTQ viewer | yes | n/a | yes | malformed extra args = silent no-op |
| Recipes (VSP2 etc.) | FASTQ import sheet only | `import fastq --recipe` (yes) | via import | import bundle | yes | FASTQ viewer | yes | n/a | yes | import failure |
| Freyja | none (handler exists, no menu item) | `freyja demix` (plan unless `--execute`) | n/a | n/a | n/a | n/a | n/a | n/a | plan-mode provenance lists outputs that were never written | n/a |

## Preserve (do not "fix" these away)

1. **CLI subprocess execution for most tools.** FASTQ ops, assembly (Tools path), MAFFT, IQ-TREE, primer trim, variant calling, Viral Recon, genotyping and 12S all run `lungfish-cli` as a child process with JSON progress events and process-tree termination on cancel (`FASTQOperationExecutionService.swift:718-831`). This gives real CLI parity and crash isolation. Extend it, don't replace it.
2. **`OperationCenter` bundle locking and the cancel/fail race resolution** (`LungfishKit/OperationCenter.swift:381-455, 654-704`). A "busy bundle" is reported as a failed row instead of corrupting data. `finishWorker` lets `.cancelling` win over a late `fail`.
3. **Typed bundle extensions discovered by the sidebar independently of `knownTools`** (`SidebarProjectScanner.swift:304-340`). This is why genotype, 12S, MSA, tree and primer results survive renames and restarts. New workflows should emit a typed bundle.
4. **The `analysis-metadata.json` sidecar as the authoritative tool identity** (`AnalysesFolder.swift:444-452`). The design is right. WFL-06 is about the display layer not honouring it.
5. **Failure reports that include the CLI command and log** (`OperationFailureReportStore.swift:165-180`). This is valuable for support once WFL-11 makes the command accurate.
6. **Staged output then atomic publish in the FASTQ output importer** (`FASTQOperationOutputImporter.swift:88-176`), and run-scoped failure cleanup that only removes directories created by the run (`FASTQOperationStagingCleanup.swift:17-30`).
7. **Experimental Workflow Builder gated behind Settings** (`MainMenu.swift:741`), and specialised workflows gated behind the Workflow Library with a clear "(not enabled)" menu affordance (`MainMenu.swift:834-857`). This is a good pattern for keeping niche features out of the main path.
8. **Kraken2 and EsViritu wizards' "Download Database..." button** (`ClassificationWizardSheet.swift:448-450`, `EsVirituWizardSheet.swift:404-405`). This is the model the other workflows should copy (WFL-09).
9. **The Viral Recon "trimmed BAM beside iVar calls" logic** (`ViralReconResultInventory.swift:40-47`) and the refusal of wizard-owned advanced keys. Only the unowned keys are the problem (WFL-04).

## Findings

| ID | Priority | Title | Confidence | Effort |
|---|---|---|---|---|
| WFL-01 | P0 | FASTQ-operation outputs are silently quality-binned and, when large, Trim Galore-trimmed during re-ingestion | Traced | M |
| WFL-02 | P0 | `tree infer iqtree` deletes the shared project `.tmp`, deletes pre-existing output on refusal, and can deadlock | Traced | S |
| WFL-03 | P1 | "GATK + WhatsHap Phased" is selectable and runnable-looking but always dead-ends | Traced | S (hide) / M (implement) |
| WFL-04 | P1 | Viral Recon loses outputs on caller overrides and (likely) Nanopore; analysis folder has no provenance; cancel hard-kills | Traced (overrides), Suspected (Nanopore) | M |
| WFL-05 | P1 | pbAA results are written into a sidebar-hidden folder; Savont batch samples route to "Unsupported analysis" | Traced | S |
| WFL-06 | P1 | Renamed classifier batch folders cannot be reopened (routing uses name prefix, not metadata) | Traced | S |
| WFL-07 | P1 | "Remove Human Reads" database chooser discards the chosen file and rejects the real index | Traced | S |
| WFL-08 | P1 | BAM primer trim never matches the scheme's contig to the BAM's `@SQ` name | Traced (code), Suspected (outcome) | S |
| WFL-09 | P1 | No shared dependency preflight: most workflows find a missing tool only by failing | Traced | M |
| WFL-10 | P1 | Wizard options silently ignored downstream (EsViritu min length, TaxTriage classifiers, demux, seeds, etc.) | Traced | M |
| WFL-11 | P2 | Operations-panel CLI commands and several provenance argv records are not runnable | Traced | M |
| WFL-12 | P2 | Cancel missing or inert on several long-running paths | Traced | S |
| WFL-13 | P2 | MHC genotyping naming: "miSeq amplicon" workflow runs ONT data and tags it as MiSeq | Traced | S |
| WFL-14 | P2 | AI haplotyping exposed in the main viewport with no key check, no consent, macaque defaults | Traced | S |
| WFL-15 | P2 | BLAST drawer inconsistencies: CZ ID no-op, `nt` vs `core_nt`, NAO-MGS taxon restriction, no persistence | Traced | M |
| WFL-16 | P2 | User-registered workflows are a half-surface: no menu, loose outputs, no sidebar result, "Beta1" copy | Traced | M |
| WFL-17 | P2 | Surface asymmetry: capabilities only on one surface (CLI-only exports, context-menu-only tree, import-only recipes, orphan Freyja) | Traced | M |
| WFL-18 | P2 | Two execution paths for the same operation with different defaults (orient, assembly Reassemble, genotyping) | Traced | M |
| WFL-19 | P2 | Failure-path quality: raw enum text, silent no-ops, cleanup errors failing successful runs | Traced | S |
| WFL-20 | P2 | Inconsistent result layouts across sibling tools (single vs batch, import destinations, warning states) | Traced | M |
| WFL-21 | P3 | Dead dialogs, launchers and engines kept alive only by tests | Traced | S |

---

### WFL-01 (P0): FASTQ-operation outputs are silently rewritten during re-ingestion

**Evidence (Traced, re-verified).**
- Every derivative produced from the FASTQ Operations dialog is imported through `FASTQOperationOutputImporter`, which calls the ingestion pipeline with `qualityBinning: .illumina4` and `skipClumpify: false` ([FASTQOperationOutputImporter.swift:101-111](Sources/LungfishApp/Services/FASTQOperationOutputImporter.swift:101)). No `clumpingTool` is passed, so it defaults to `.auto` ([FASTQIngestionPipeline.swift:67-76](Sources/LungfishWorkflow/Ingestion/FASTQIngestionPipeline.swift:67)).
- With `.bbtools`, `quantize=0,8,13,22,27,32,37` is appended unconditionally, regardless of platform ([FASTQIngestionPipeline.swift:433-435](Sources/LungfishWorkflow/Ingestion/FASTQIngestionPipeline.swift:433)). Nothing in this path checks whether the reads are ONT or PacBio.
- `.auto` resolves to `.trimGalore` when the estimated uncompressed input exceeds half the managed Java heap ([ClumpingTool.swift:55-66](Sources/LungfishWorkflow/Ingestion/ClumpingTool.swift:55)). The Trim Galore arguments are `--clumpify` plus defaults ([FASTQIngestionPipeline.swift:758-778](Sources/LungfishWorkflow/Ingestion/FASTQIngestionPipeline.swift:758)), which means adapter auto-detection, Q20 trimming and a 20 bp length filter.
- The type itself documents this side effect in `operationNotice` ([ClumpingTool.swift:37-41](Sources/LungfishWorkflow/Ingestion/ClumpingTool.swift:37)). That notice is shown only by the batch importer (`FASTQBatchImporter.swift:690`) and never on the operation path.

**Impact.**
- A user who runs "Subsample by Count" or "Remove Human Reads" on an ONT run gets back reads whose qualities have been collapsed to Illumina bins. For ONT and PacBio, those bins are scientifically inappropriate.
- If the output is large, the result is also silently adapter- and quality-trimmed, and short reads are dropped. Read counts no longer equal what the operation reports.
- Downstream tools that use qualities (Medaka, Clair3, variant callers, dedup) see altered input.
- Provenance copies the CLI sidecar, but no re-ingestion step or checksum refresh is recorded. The recorded output descriptor is therefore not the file on disk (see the importer's rehydration, [FASTQOperationOutputImporter.swift:300-317](Sources/LungfishApp/Services/FASTQOperationOutputImporter.swift:300)).

**Recommendation.**
- In `FASTQOperationOutputImporter`, re-ingest with `qualityBinning: .none` and an explicit `clumpingTool` that never resolves to `.trimGalore`. Use `.bbtools` without quantize, or `.none` if clumping is not needed for a derivative.
- If binning is desired for storage, make it an explicit, platform-aware user choice at import time only (sibling scope), and record it as a provenance step.
- Add a guard in `FASTQIngestionPipeline` that refuses `illumina4` for reads detected as ONT or PacBio.

**Acceptance test.**
- Run each dialog operation on a small ONT fixture with varied qualities. Output qualities must be byte-identical to the CLI tool's output.
- Force `.auto` resolution above the threshold (inject `physicalMemoryBytes`) and assert that no Trim Galore invocation occurs on the operation path.
- The provenance output checksum must equal the bundle payload checksum.

**Effort:** M.

### WFL-02 (P0): `tree infer iqtree` destroys shared scratch and existing output, and can hang

**Evidence (Traced, re-verified).**
- **Shared scratch deletion.** `tempRoot = projectURL/.tmp` ([TreeCommand.swift:445](Sources/LungfishCLI/Commands/TreeCommand.swift:445)). Both the `defer` and the `catch` remove `tempRoot` recursively ([TreeCommand.swift:459-462](Sources/LungfishCLI/Commands/TreeCommand.swift:459), [:596-600](Sources/LungfishCLI/Commands/TreeCommand.swift:596)). `.tmp` is the project-wide scratch root used by `ProjectTempDirectory` ([ProjectTempDirectory.swift:132](Sources/LungfishIO/Bundles/ProjectTempDirectory.swift:132)) and SRA downloads ([SRAService.swift:664](Sources/LungfishCore/Services/NCBI/SRAService.swift:664)), including classification and MAFFT materialisation. A tree run that finishes while a Kraken2 or MAFFT job is materialising inputs deletes that job's working files.
- **Deletes the output it refused to overwrite.** If the output exists and `--force` is false, a `ValidationError` is thrown ([TreeCommand.swift:451-452](Sources/LungfishCLI/Commands/TreeCommand.swift:451)). The `catch` then runs `try? FileManager.default.removeItem(at: outputURL)` ([TreeCommand.swift:598](Sources/LungfishCLI/Commands/TreeCommand.swift:598)), deleting the user's existing `.lungfishtree`.
- **Deadlock.** `runProcess` calls `process.waitUntilExit()` before draining either pipe ([TreeCommand.swift:966-969](Sources/LungfishCLI/Commands/TreeCommand.swift:966)). IQ-TREE with `-m MFP` easily writes more than the pipe buffer, which blocks the child forever.

**Impact.** Data loss in unrelated concurrent operations, loss of a finished tree on a simple re-run, and a hung operation with no progress (there are no events between 0.34 and 0.72).

**Recommendation.**
- Remove only `stagingURL`. Never remove `tempRoot`.
- Move the "exists and not force" check before the `do` block, or track whether this invocation created `outputURL` and delete only then.
- Replace `runProcess` with the streaming runner already used elsewhere (`NativeToolRunner`, or drain pipes via `readabilityHandler`), and emit progress from IQ-TREE's log.
- Audit `MSACommand.swift:2562` for the same `.tmp` sibling pattern. It does not delete the root, but it creates `.tmp` next to arbitrary output paths.

**Acceptance test.**
- A test creates `projectURL/.tmp/sentinel`, runs `tree infer` to success and to failure, and asserts the sentinel survives.
- A test runs with an existing output and no `--force`, and asserts the output is unchanged and the exit is non-zero.
- A test runs a stub `iqtree` that writes 1 MB to stdout, and asserts completion.

**Effort:** S.

### WFL-03 (P1): "GATK + WhatsHap Phased" always dead-ends

**Evidence (Traced, re-verified).**
- The caller is listed in the catalog ([BAMVariantCallingCatalog.swift:16, 32-33](Sources/LungfishApp/Views/BAM/BAMVariantCallingCatalog.swift:16)).
- Readiness returns `true` ([BAMVariantCallingDialogState.swift:214-216](Sources/LungfishApp/Views/BAM/BAMVariantCallingDialogState.swift:214)), and the readiness text says "Ready to build a GATK plus WhatsHap phased command plan" ([:172-173](Sources/LungfishApp/Views/BAM/BAMVariantCallingDialogState.swift:172)).
- `prepareForRun` sets only `pendingPhasedVariantPlan` ([:261-264](Sources/LungfishApp/Views/BAM/BAMVariantCallingDialogState.swift:261)).
- The launcher checks `pendingGATKRequest`, then `pendingRequest`, and otherwise shows the alert "Variant Calling Not Ready" with that same "Ready..." text ([InspectorViewController+VariantWorkflow.swift:81-99](Sources/LungfishApp/Views/Inspector/InspectorViewController+VariantWorkflow.swift:81)).
- `pendingPhasedVariantPlan` is read nowhere else in `Sources/`.
- Separately, minimum AF and depth fields are shown for GATK but never read by `makeGATKRequest` or `makePhasedVariantPlan` (`BAMVariantCallingDialogState.swift:393-460`, per trace).

**Impact.** A main-menu feature that contradicts itself: the dialog reports "Ready", then an alert reports "Not Ready". Users cannot tell whether their data or the app is at fault.

**Recommendation.** Remove `gatkWhatsHapPhased` from `BAMVariantCallingToolID.allCases` until it is implemented, or gate it behind `experimentalFeaturesEnabled`. When it is implemented, route `pendingPhasedVariantPlan` to the CLI's `variants phase`. Hide the AF and depth fields for GATK tools.

**Acceptance test.**
- A UI state test asserts that the phased tool is absent from the list while unimplemented.
- Alternatively, a launch test asserts that selecting it spawns `variants phase` with an OperationCenter row.

**Effort:** S to hide, M to implement.

### WFL-04 (P1): Viral Recon silently loses results on supported overrides; analysis folder lacks provenance

**Evidence.**
- **Caller overrides (Traced, re-verified).** `variant_caller` and `consensus_caller` are advertised as overridable ([ViralReconRunRequest.swift:248-252](Sources/LungfishWorkflow/ViralRecon/ViralReconRunRequest.swift:248)). The inventory only looks in `variants/ivar/...` and `variants/ivar/consensus/bcftools` ([ViralReconResultInventory.swift:51-53](Sources/LungfishWorkflow/ViralRecon/ViralReconResultInventory.swift:51)). With `variant_caller=bcftools` the run succeeds, but no VCF or consensus is ingested. The track label is hard-coded "iVar variants from Viral Recon" (`ViralReconViewerPublication.swift:100`).
- **Nanopore (Suspected).** The Nanopore platform is selectable, but BAM lookup is fixed to `variants/bowtie2/` ([ViralReconResultInventory.swift:46-47](Sources/LungfishWorkflow/ViralRecon/ViralReconResultInventory.swift:46)). viralrecon's Nanopore branch writes elsewhere.
- **Hard-coded values (Traced, by design).** Reference MN908947.3 (`ViralReconReferenceCatalog.swift:10`, wizard `ViralReconWizardSheet.swift:462`), Docker executor, pipeline 3.0.0, and caller defaults (`ViralReconWizardSheet.swift:614-617`). These are acceptable for a SARS-CoV-2 tool, but the UI should say so.
- **No provenance in the opened folder (Traced).** `ViralReconResultIngest` and `ViralReconViewerPublication` write no provenance. The Operations row's output points to the hidden `.lungfishrun`, which the sidebar deliberately hides (`SidebarProjectScanner.swift:397-403`).
- **Cancel (Traced).** `requestProcessTreeTermination(gracePeriod: 0)` (`ViralReconWorkflowExecutionService.swift:806`), followed by SIGKILL after 50 ms (`ProcessTreeTerminator.swift:179-189`). Nextflow cannot clean up. Docker containers belong to the daemon, not the process tree, so they likely keep running (Suspected). The run manifest stays `.running`.
- **Other (Traced).**
  - Staging folders `.viralrecon-inputs-*` are never removed.
  - Nanopore reads are copied twice.
  - Nextflow logs are overwritten by the CLI's own log (`ViralReconWorkflowExecutionService.swift:99`).

**Impact.** A "successful" run that shows an empty viewer. This is exactly the failure a lab user cannot diagnose.

**Recommendation.**
- Drive `ViralReconResultInventory` from the effective `variant_caller`, `consensus_caller` and platform recorded in the run request, or refuse unsupported overrides in the wizard.
- Fail the ingest (with `completeWithWarning` at minimum) when zero VCFs or consensus sequences were found for a sample.
- Write a provenance sidecar into `Analyses/viralrecon-<ts>/` that links to the run bundle.
- Give Nextflow a 10-30 s SIGTERM grace, and run `docker ps --filter label=nextflow...` cleanup on cancel.
- Delete the staging folders after ingest.

**Acceptance test.**
- An ingest unit test against canned viralrecon output trees for `bcftools` and Nanopore layouts asserts a non-empty inventory.
- A test asserts that an empty inventory produces a warning completion.
- A test asserts that `analysis-metadata.json` and a provenance file both exist in the ingested folder.

**Effort:** M.

### WFL-05 (P1): Clustering results that never reach a viewport

**Evidence (Traced, re-verified).**
- **pbAA.** The planner places output in `Analyses/cli-output-pbaa-<uuid>/` ([FASTQOperationPlanner.swift:36-40](Sources/LungfishApp/Services/FASTQOperationPlanner.swift:36)). The importer returns the URLs as-is ([FASTQOperationOutputImporter.swift:438-439](Sources/LungfishApp/Services/FASTQOperationOutputImporter.swift:438)), and cleanup preserves the folder because the outputs live inside it. But the sidebar hides every `cli-output-*` directory ([SidebarProjectScanner.swift:374-375](Sources/LungfishApp/Views/Sidebar/SidebarProjectScanner.swift:374), [:529-533](Sources/LungfishApp/Views/Sidebar/SidebarProjectScanner.swift:529)). The `.lungfishref` results are invisible, now and after restart.
- **Savont batch.** The batch folder is created with tool `savont` ([MainSplitViewController.swift:73-76](Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift:73)). The sidebar builds a generic batch whose children are `.analysisResult` with `analysisTool=savont` ([SidebarProjectScanner.swift:700-725](Sources/LungfishApp/Views/Sidebar/SidebarProjectScanner.swift:700)). `AnalysisResultDisplayRoute` has no savont case ([AnalysisResultDisplayRoute.swift:14-38](Sources/LungfishApp/Views/MainWindow/AnalysisResultDisplayRoute.swift:14)).
  - Clicking a child shows "Unsupported analysis: savont." ([MainSplitViewController+ContentDisplay.swift:180-184](Sources/LungfishApp/Views/MainWindow/MainSplitViewController+ContentDisplay.swift:180)).
  - Clicking the group falls through to "Unrecognized batch prefix" and changes nothing ([MainSplitViewController+ClassifierDisplay.swift:534](Sources/LungfishApp/Views/MainWindow/MainSplitViewController+ClassifierDisplay.swift:534)).
- **Mapping batch root (Suspected).** `displayBatchGroup` routes a mapping batch root to `displayMappingAnalysisFromSidebar(at: batchURL)` ([MainSplitViewController+ClassifierDisplay.swift:323-324](Sources/LungfishApp/Views/MainWindow/MainSplitViewController+ClassifierDisplay.swift:323)), but `mapping-result.json` only exists per sample.

**Impact.** The workflow reports success while the user cannot find or open the result. These are the textbook dead ends this audit targets.

**Recommendation.**
- Give pbAA a real output folder: `Analyses/pbaa-<ts>/`, or `pbaa-batch-*`, with `analysis-metadata.json`, and add it to `knownTools`.
- For Savont, either publish per-sample FASTA as `.lungfishref` bundles (which open through the typed-bundle path), or add `.fastaFile` routing for `.analysisResult` children whose URL is a sequence file.
- For batch groups of generic tools, open the first child or show a batch summary rather than doing nothing.

**Acceptance test.**
- A sidebar-scanner test on a fixture project containing a pbAA output and a Savont batch asserts that each result node's display route is not `.unknown`.
- A `displayBatchGroup` test asserts that a generic batch URL produces a viewport change.

**Effort:** S.

### WFL-06 (P1): Renamed classifier batch folders cannot be reopened

**Evidence (Traced, re-verified).**
- Sidebar "Rename..." is allowed on `.batchGroup` items ([SidebarViewController+MenuDelegate.swift:71, 333-337](Sources/LungfishApp/Views/Sidebar/SidebarViewController+MenuDelegate.swift:71)).
- After a rename, `AnalysesFolder` still identifies the folder from `analysis-metadata.json`, so the sidebar keeps the K2/ES/TT badge.
- `displayBatchGroup` computes `toolId` from the metadata ([MainSplitViewController+ClassifierDisplay.swift:312](Sources/LungfishApp/Views/MainWindow/MainSplitViewController+ClassifierDisplay.swift:312)) but branches on `dirName.hasPrefix("kraken2")`, `"esviritu"` and `"taxtriage"` ([:336](Sources/LungfishApp/Views/MainWindow/MainSplitViewController+ClassifierDisplay.swift:336), [:393](Sources/LungfishApp/Views/MainWindow/MainSplitViewController+ClassifierDisplay.swift:393), [:445](Sources/LungfishApp/Views/MainWindow/MainSplitViewController+ClassifierDisplay.swift:445)), then logs "Unrecognized batch prefix" ([:534](Sources/LungfishApp/Views/MainWindow/MainSplitViewController+ClassifierDisplay.swift:534)).
- NAO-MGS and NVD alone fall back to metadata. `ClassifierDatabaseRouter` is also prefix-only (`ClassifierDatabaseRouter.swift:24-29, 60-72`, per trace).

**Impact.** Renaming a run to something meaningful, which lab users routinely do, makes it unopenable. The contract promised in `AnalysesFolder.swift:440` ("survives renames") is broken.

**Recommendation.** Replace the prefix chain with a switch on the resolved tool id (metadata first, prefix second). Make `AnalysisResultDisplayRoute` the single routing table for both single and batch results, and extend it with `.kraken2`, `.esviritu`, `.taxtriage`, `.savont` and `.pbaa`.

**Acceptance test.** A table test for each classifier: create a batch, rename it to `My run`, call `displayBatchGroup`, and assert that the corresponding viewer is installed.

**Effort:** S.

### WFL-07 (P1): "Remove Human Reads" database chooser discards the chosen database

**Evidence (Traced, re-verified).**
- The request uses `auxiliaryInputURL(for: .database)?.deletingPathExtension().lastPathComponent` as a registry id ([FASTQOperationDialogState.swift:594-599](Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift:594)). The CLI resolves that id only through `DatabaseRegistry.shared.requiredDatabasePath` ([FastqScrubHumanSubcommand.swift:55-56](Sources/LungfishCLI/Commands/FastqScrubHumanSubcommand.swift:55)).
- The `.database` input accepts only directories, extensionless files and `db/k2d/sqlite/json` ([FASTQOperationDialogState.swift:2266-2267](Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift:2266)). The managed Deacon index is an `.idx` file, so the user cannot even select it.
- The input is required, so the `?? DeaconPanhumanDatabaseInstaller.databaseID` fallback is unreachable.
- When the database is missing, the error text says human-read scrubbing even for the rRNA database (`DatabaseRegistry.swift:69`, per trace).

**Impact.** The user must pick some file that is then ignored. Picking the obvious file (the index) is impossible. The operation works only by coincidence of file stem.

**Recommendation.** Replace the file chooser with a popup of managed databases from `DatabaseRegistry` (installed and installable, with an Install button), as the Kraken2 wizard does. Drop `.database` from `requiredInputKinds` for `removeHumanReads`.

**Acceptance test.** A dialog-state test shows that with no selection the request carries `deacon-panhuman`. A test with the registry reporting "not installed" shows an Install action and Run disabled.

**Effort:** S.

### WFL-08 (P1): BAM primer trim never reconciles the scheme contig with the BAM header

**Evidence (Traced in code; outcome Suspected).**
- The CLI defaults `targetReference` to `scheme.manifest.canonicalAccession` when no override is given ([BAMPrimerTrimSubcommand.swift:208-210](Sources/LungfishCLI/Commands/BAMPrimerTrimSubcommand.swift:208)).
- The GUI never passes an override ([InspectorViewController+TrimDuplicateWorkflows.swift:114-123](Sources/LungfishApp/Views/Inspector/InspectorViewController+TrimDuplicateWorkflows.swift:114)), and nothing reads `@SQ SN` from the BAM.
- The equivalent-accession BED rewrite ([PrimerSchemeResolver.swift:87-99](Sources/LungfishWorkflow/Primers/PrimerSchemeResolver.swift:87)) is therefore never exercised from the GUI.

**Impact.** A BAM aligned to `NC_045512.2` with an ARTIC scheme keyed on `MN908947.3` gets a BED whose chromosome names match nothing. iVar then likely trims zero primers, and the downstream iVar variant call inherits primer-derived artefacts. The Inspector shows a "primer-trimmed" track either way.

**Recommendation.**
- In the CLI, when `--target-reference` is absent, read the source BAM header (`samtools view -H`). Pick the `@SQ` name matching the canonical accession or one of its equivalents. Error if none matches.
- Surface the chosen contig in the dialog.
- Record trimmed-read counts from `ivar trim` stderr and warn when 0% of reads were primer-trimmed.

**Acceptance test.** A fixture BAM with `@SQ SN:NC_045512.2` plus a scheme with canonical `MN908947.3`. Assert that the rewritten BED is used and that the trim statistics are non-zero.

**Effort:** S.

### WFL-09 (P1): No shared dependency preflight or install path

**Evidence (Traced).**

| Workflow | Missing-dependency behaviour |
|---|---|
| Kraken2, EsViritu | "Download Database..." button (good) |
| TaxTriage | text only, "No Kraken2 databases installed" (`TaxTriageWizardSheet.swift:434-438`). Also lists databases that are downloaded but not ready (`:593`) |
| Mapping | runtime failure "... is not installed. Install the read-mapping plugin pack first." (`ManagedMappingPipeline.swift:56`). No button |
| MAFFT | no check. The dialog preflights only Savont (`FASTQOperationDialogState.swift:1050, 1116`) |
| IQ-TREE | row hard-coded `availability: .available` (`IQTreeInferenceDialog.swift:74`) despite a phylogenetics pack |
| pbAA | needs Nextflow + Docker (`PBAANextflowWorkflowWriter.swift:159`). No preflight |
| Viral Recon | "Requires Docker Desktop." text only. Readiness has no Docker, Nextflow or Java check (`ViralReconWizardSheet.swift:185, 835-863`) |
| Variant callers, primer trim | disabled rows with "Requires ... Pack" text, no install action (`BAMVariantCallingCatalog.swift:119-146`, `BAMPrimerTrimCatalog.swift:18-29`) |
| FASTQ databases (panhuman, ribokmers) | runtime `installRequired`. The only install-and-retry prompt is on a dead in-process path (`FASTQDatasetViewController.swift:1985-2060`) |
| Genotyping | pack check only when enabling in Workflow Library (`WorkflowLibrary.swift:442-452`). The default-enabled workflow never passes that check |
| Primer design | silently installs `pcr-primer-design` at run time without confirmation (`PrimerDesignManagedRuntime.swift:26-45`) |
| User workflows | `/usr/bin/env nextflow` fallback, exit 127 (`WorkflowEngineLaunch.swift:106-117`) |

**Impact.** For a bench scientist, "the run failed with exit 127" is a dead end. The inconsistency also makes the product feel unfinished. One tool offers a button, the next fails, a third installs gigabytes silently.

**Recommendation.**
- Introduce one `WorkflowDependencyPreflight` in `LungfishKit`. It takes pack ids, database ids and external engines (Docker, Nextflow) and returns `ready`, `installable(action)` or `unsupported(reason)`.
- Every dialog renders it with the same banner and an "Install..." button that opens Plugin Manager at the right pack, with a return path.
- Remove silent auto-install from primer design, or at least confirm the download size first.
- Map each `FASTQOperationToolID`, `BAMVariantCallingToolID` and workflow item to its requirements in one table.

**Acceptance test.** A parameterised test over all tool ids: with an empty pack status, `canRun == false` and the preflight exposes an install action whose pack id matches the tool's `requiredPluginPackIDs`.

**Effort:** M.

### WFL-10 (P1): Options collected in wizards but ignored downstream

**Evidence (Traced; items marked * re-verified by me).**
- **EsViritu minimum read length*.** It lives in the config and wizard (`EsVirituConfig.swift:85,116`; stepper `EsVirituWizardSheet.swift:469`), but `esVirituArguments()` never emits it ([EsVirituConfig.swift:189-221](Sources/LungfishWorkflow/Metagenomics/EsVirituConfig.swift:189)). It is still displayed in the summary and inspector.
- **TaxTriage `classifiers`.** Recorded in provenance and inspector (`TaxTriageSerialBatchRunner.swift:202`, `ClassifierDisplay.swift:477`), never added to the Nextflow arguments (`TaxTriageConfig.swift:284-323`).
- **Viral Recon `variant_caller` and `consensus_caller`*.** Accepted but outputs are not ingested (WFL-04).
- **Demultiplex.** `symmetryMode`, `sampleAssignments` and `kitOverride` are hard-coded nil (`FASTQOperationDialogState.swift:463-470`). The location, distance and error-rate fields are dropped for the `exactBareBarcode` engine (`FASTQOperationCLIInvocationBuilder.swift:475-481`).
- **Subsample.** No seed in the dialog, the request or the CLI (`FastqCommand.swift:302-318`), so the result is not reproducible from provenance.
- **IQ-TREE seed.** The dialog says to leave it blank for random, but blank maps to the CLI default `seed = 1` (`TreeCommand.swift:395`). Bootstrap counts are only checked for being positive, below IQ-TREE's UFBoot minimum of 1000 (`IQTreeInferenceDialog.swift:146`). The tree can be started with 2 rows selected (`MultipleSequenceAlignmentViewController.swift:1759`).
- **Full-length ONT.** Dropout fractions and overrides are hard-coded nil or empty (`WorkflowOperationDialogState.swift:1247-1251`). Savont QV and cluster size have no fields.
- **Genotyping FASTQ-dialog path.** Dead state for dropout percents (`FASTQOperationDialogState.swift:171-173, 814-816`).
- **Translate.** Frame is always 0 and the table is not exposed (`FASTQOperationDialogState.swift:674`).
- **12S.** A thread value of 1 is dropped (`WorkflowOperationExecutionService.swift:680`).
- **Kraken2 Bracken.** Read length 150 and threshold 10 are hard-coded with no UI (`BrackenProfileModels.swift:44-48`). That is acceptable if documented, but the CLI exposes both.

**Impact.** The user believes a parameter was applied. The worst cases are where the ignored value is echoed back in the inspector or provenance (EsViritu, TaxTriage), because the audit trail then contradicts the computation.

**Recommendation.**
- For each item, either wire the value through or delete the control. Never echo an unapplied value in the inspector or provenance.
- Add a subsample `--seed` (default random, recorded) to CLI and dialog.
- Map a blank IQ-TREE seed to a generated random seed that is recorded.
- Add a "config round-trip" test pattern: build config, produce argv, assert that each user-facing field appears.

**Acceptance test.** For EsViritu: `esVirituArguments()` contains the min-length flag (or the field is removed from wizard and summary). For TaxTriage: the Nextflow args contain `--classifiers`. One such assertion per bullet above.

**Effort:** M.

### WFL-11 (P2): Displayed CLI commands and provenance argv are not runnable

**Evidence (Traced, re-verified).**
- **Kraken2.** The Operations-panel command is `conda classify --db <absolute path> <inputs>` ([AppDelegate+Classification.swift:861-865](Sources/LungfishApp/App/AppDelegate+Classification.swift:861)). The CLI `--db` is a registry name resolved with `registry.database(named:)` ([ClassifyCommand.swift:79-80](Sources/LungfishCLI/Commands/ClassifyCommand.swift:79), [:207](Sources/LungfishCLI/Commands/ClassifyCommand.swift:207); `MetagenomicsDatabaseRegistry.swift:507-510`). The command also omits `--profile`, confidence and min-hit-groups. The batch form repeats the pattern (`AppDelegate+Classification.swift:1370-1381`).
- **TaxTriage.** `taxtriage --input f1 f2 f3 ...` (`AppDelegate+Classification.swift:2186-2191`), but `--input` is a single `String?` ([TaxTriageCommand.swift:66-70](Sources/LungfishCLI/Commands/TaxTriageCommand.swift:66)) and the required output is missing.
- **EsViritu.** Single-run provenance argv is only `--input ... --sample` ([AppDelegate+Classification.swift:1071-1077](Sources/LungfishApp/App/AppDelegate+Classification.swift:1071)), with no `--db` or output. The batch command puts all samples' inputs under one `--sample` (`:1840-1848`), so replaying it would merge the samples.
- **Kraken2 BLAST.** The command passes `--kreport` with the per-read `.kraken` output (`ViewerViewController+Taxonomy.swift:167-169`).
- **Fake argv.**
  - Primer design and primer-order record `argv: CommandLine.arguments`, which is the GUI binary (`PrimerDesignDialogPresenter.swift:89`, `MainSplitViewController+PrimerAnalysis.swift:76`).
  - Genotype Excel export records `["Lungfish", "genotype.export.excel", ...]` (`GenotypeViewportExportService.swift:119`).
  - Tree subtree export records `["Lungfish Genome Explorer", "export-tree-subtree"]` (`PhylogeneticTreeViewController.swift:976`).
- The memory note for this project tells developers to debug from the failure report's command. For these tools, that command is wrong.

**Recommendation.**
- Build the displayed command from the same argv the provenance writer uses, as `CLIPrimerTrimRunner` and `CLIMSAAlignmentRunner` already do.
- For in-process tools, add `CLIReplayCommandBuilder` implementations with a unit test that parses the string through the ArgumentParser command type (`ClassifyCommand.parse(...)`) and checks that it succeeds.
- Replace `CommandLine.arguments` with the real `lungfish primers design ...` or `lungfish genotype export-xlsx ...` equivalents.

**Acceptance test.** For each tool that sets `cliCommand`, a test parses the tokenised command with the root `LungfishCLI.parseAsRoot` and asserts that no error occurs and that the key options round-trip.

**Effort:** M.

### WFL-12 (P2): Cancel missing or inert on long-running paths

**Evidence (Traced).**
- Full-length ONT genotyping, 12S matching and 12S reference build start OperationCenter rows without `setCancelCallback` (`WorkflowOperationExecutionService.swift:200, 485` and siblings). The file's own comment notes that this is what enables the Cancel button (`:373-375`).
- User workflows get no cancel on their first run, only on replays (`LocalWorkflowExecutionService.swift:104-121`). Workflow Builder rows are started without `onCancel` (`WorkflowBuilderRunService.swift:137-145, 325-332`).
- CZ ID import: the `Task.detached` is not stored (`AppDelegate+ToolsMenu.swift:853-882`).
- AI haplotyping: no cancel (`GenotypeAIHaplotypingExecutionService.swift:72-79`).
- The BLAST drawer's own Cancel button only logs (`TaxonomyViewController+Blast.swift:133-137`). EsViritu, TaxTriage, NAO-MGS and NVD never set `onCancelBlast`.
- The classifier "build database on open" placeholder runs `build-db` outside OperationCenter (`MainSplitViewController+ClassifierDisplay.swift:576-713`).
- Viral Recon cancels with zero grace (WFL-04).

**Recommendation.** Make `OperationCenter.start` require an `onCancel` or an explicit `.notCancellable(reason)` argument, so this cannot regress silently. Wire the drawer's Cancel button to `OperationCenter.shared.cancel(id:)` for the current BLAST operation.

**Acceptance test.** A test enumerates each `start(` call site through a registry, or a lint in `scripts/`, and fails when neither a cancel callback nor an explicit non-cancellable marker is present.

**Effort:** S.

### WFL-13 (P2): MHC genotyping naming and workflow-kind mislabel

**Evidence (Traced).**
- The enum case is `ontGenotyping`, and its title is "miSeq amplicon MHC genotyping" ([FASTQOperationDialogState.swift:1982](Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift:1982)). The subtitle says the workflow runs "ONT barcode-demux or prepared Illumina" data.
- The Workflow Operations dialog defaults non-Illumina input to ONT mode (`WorkflowOperationDialogState.swift:367-378`), yet hard-codes `resultWorkflowKind: .miSeqAmpliconMHCGenotype` (`:1203, 1219`). That kind feeds the viewport presentation policy (`appliesToHaplotypedMiSeq`).
- The display name for the analyses folder is "ONT Genotyping" (`AnalysesFolder.swift:97`).
- The FASTQ-dialog genotyping path uses the deprecated `.ontBarcodeDemux` mode and applies default haplotypes silently (`FASTQOperationCLIInvocationBuilder.swift:165-205`, `FASTQOperationDialogState.swift:818`). Its opener has no menu wiring (`AppDelegate+ToolsMenu.swift:129`).

**Impact.** An ONT run is labelled MiSeq, and the viewport may apply MiSeq-specific presentation rules to ONT data. The three names confuse users.

**Recommendation.** Rename to a platform-neutral "Amplicon MHC genotyping (MiSeq or ONT)", or split it into two items. Derive `resultWorkflowKind` from the resolved input mode. Delete the FASTQ-dialog genotyping path (see WFL-18).

**Acceptance test.** A dialog-state test with ONT sample bundles asserts that the ONT-appropriate `resultWorkflowKind` is used, and that the menu title matches the catalog title.

**Effort:** S.

### WFL-14 (P2): AI haplotyping in the main viewport without key check, consent or species-aware defaults

**Evidence (Traced).**
- The "AI Discovery" button is enabled whenever the bundle is writable ([GenotypeResultViewController.swift:5586-5590](Sources/LungfishGenotypeUI/GenotypeResultViewController.swift:5586)). `requestAIHaplotyping` goes straight to the Operations panel with no confirmation ([:5612-5633](Sources/LungfishGenotypeUI/GenotypeResultViewController.swift:5612)).
- The key-check helper `hasConfiguredProvider` is dead (`GenotypeAIHaplotypingExecutionService.swift:23-50`). Without a key, users see "AI haplotyping failed, see Operations Panel."
- The model and reasoning effort come from the macaque preset `mcmMHCmiseq` for every bundle (`:404-405`).
- There is no experimental gate, and no notice that genotype data leaves the machine.

**Recommendation.** Gate the section behind a configured provider (show "Configure AI provider in Settings..." otherwise). Add a one-time consent sheet naming the provider and the data sent. Take defaults from the bundle's species or preset, not a global constant. Consider moving the whole feature behind `experimentalFeaturesEnabled` until it is validated.

**Acceptance test.** With no key configured, the buttons are replaced by a Settings link. With a key, the first run shows consent, and the choice persists.

**Effort:** S.

### WFL-15 (P2): BLAST drawer is inconsistent across classifiers

**Evidence (Traced; CZ ID re-verified).**
- **CZ ID.** `TaxonomyViewController` always adds "BLAST Matching Reads..." ([TaxonomyViewController.swift:1406-1414](Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift:1406)). Run calls `self.onBlastVerification?(...)` ([:1478](Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift:1478)). `CzIdResultViewController` embeds the taxonomy view but no code sets `onBlastVerification` for it (only the seven setters in `ViewerViewController+*.swift`). The user clicks Run and nothing happens.
- **Database.** Kraken2 and the CLI use `nt` (`BlastService.swift:368-373`, `BlastCommand.swift:239-245`). EsViritu, TaxTriage, NVD, NAO-MGS, Assembly and 12S use `core_nt`. The popover says "BLASTN nt" (`BlastConfigPopoverView.swift:90`).
- **NAO-MGS.** Restricts the search to the claimed taxon with `entrezQuery: txid...[Organism:exp]` (`ViewerViewController+NaoMgs.swift:95`). The verification can therefore only confirm the classification, never contradict it. This is a scientific concern the sibling report should weigh.
- **Persistence.** Results are not persisted and no provenance is written (`BlastService.swift`, `BlastCommand.swift`).

**Recommendation.**
- Hide the BLAST menu item when `onBlastVerification == nil`.
- Centralise the database choice in `BlastVerificationRequest`, show the real database in the popover, and default to `core_nt` everywhere.
- Drop the Entrez restriction, or make it an explicit toggle labelled "within claimed taxon only".
- Persist the last BLAST result as a sidecar next to the analysis, with provenance.

**Acceptance test.** A test that CZ ID's context menu has no BLAST item. A test that every `BlastVerificationRequest` construction uses the shared default database.

**Effort:** M.

### WFL-16 (P2): User-registered workflows are a half-built surface

**Evidence (Traced).**
- **No menu entry.** User packages never appear in the Tools menu, which is built only from `WorkflowLibraryCatalog.builtIn` (`ToolsMenuModel.swift:26-30`). `showWorkflowOperations(_:)` is declared (`MainMenu.swift:1194`) but no menu item uses it. `WorkflowFeatureAvailability.hasWorkflowOperations` is computed but never read. Users reach the runner only through a built-in specialised item or "Run Again".
- **Release-phase copy in the UI.** The packages show as "Catalog Only" with the tooltips "beta builds do not execute them" and "Beta1 Workflow Operations require a required .lungfishref input, a required .lungfishfastq input..." ([WorkflowLibrary.swift:308, 329](Sources/LungfishApp/Services/WorkflowLibrary.swift:308); [WorkflowLibraryPanelView.swift:450-454](Sources/LungfishApp/Views/WorkflowLibrary/WorkflowLibraryPanelView.swift:450)).
- **Outputs.** The default output folder is `Analyses/` itself, used both as `outdir` and as the Nextflow working directory (`WorkflowOperationDialogState.swift:1493-1494`, `LocalWorkflowRunBundle.swift:214`), so `work/` and `.nextflow*` likely land loose there (Suspected). No `analysis-metadata.json` is written, and the sidebar is not refreshed after the run (`WorkflowOperationsWindowController.swift:230-246`).
- **Inputs.** Only the first selected reads bundle is mapped to a parameter (`WorkflowOperationDialogState.swift:1313, 1328-1334`).
- **CLI.** `workflow run` rejects any nf-core pipeline other than viralrecon (`WorkflowCommand.swift:772-786`), and its help text still describes Apple Containerization.
- **Two notification names for one event.** `workflowLibraryEnablementChanged` and `workflowLibraryEnablementDidChange` are posted in different places ([WorkflowLibrary.swift:406, 532](Sources/LungfishApp/Services/WorkflowLibrary.swift:406)) and observed by different listeners (`AppDelegate.swift:1208`, `WorkflowOperationDialogState.swift:237`).

**Judgement.** This is overbuilt for what it delivers: registration, validation, enablement, catalog UI and replay exist, but a registered workflow has no discoverable launch point and no result surface. For lab scientists, either finish it (menu entry, own output folder with metadata, sidebar result node) or hide the "User Workflows" section behind the experimental flag.

**Recommendation.** Short term: gate user-package UI behind `experimentalFeaturesEnabled` and remove "beta" wording. Longer term:
- add a Tools > Workflows submenu listing enabled packages
- write outputs to `Analyses/<package-id>-<ts>/` with `analysis-metadata.json`
- give Nextflow a separate `-work-dir` under the run bundle
- refresh the sidebar on completion
- unify the two notification names

**Acceptance test.** Enabling a validated package adds a Tools menu item. A completed run produces one sidebar node under Analyses, and no `work/` directory appears in `Analyses/`.

**Effort:** M.

### WFL-17 (P2): Capabilities available on only one surface

**Evidence (Traced).**
- **CLI only:**
  - genotype `export-labkey` and `export-pivot-xlsx` (no GUI surface in LungfishApp or LungfishGenotypeUI)
  - `fastq interleave` and `deinterleave`
  - 12S `--ambiguity-resolution`
  - Freyja `demix`
- **Orphan GUI handler for Freyja.** `showFreyjaDemix` only opens the Plugin Manager and is not attached to any menu item ([AppDelegate+ToolsMenu.swift:146-148](Sources/LungfishApp/App/AppDelegate+ToolsMenu.swift:146)). The Viral Recon comment claims "Lungfish runs Freyja natively" (`ViralReconRunRequest.swift:44`). In plan-only mode, Freyja provenance lists outputs that were never produced (`FreyjaCommand.swift:87`).
- **GUI only:** primer-order export (no CLI). The BLAST drawer is persisted nowhere.
- **Single entry point only:**
  - IQ-TREE only from the MSA viewer context menu, with at least 2 rows selected (`MultipleSequenceAlignmentViewController.swift:1754-1760`). There is no Tools menu item in the "Multiple Sequence Alignment" category.
  - BAM primer trim only from an Inspector button.
  - Recipes only in the FASTQ import sheet, not on existing bundles (`FASTQImportConfigSheet.swift:127-160`).
- **Stale recipe help.** The recipe help text lists "vsp2, wgs, hifi" while the shipped recipes include `wastewater-metagenomics` and `illumina-amplicon-merge` (`ImportFastqCommand.swift:83`, `FASTQBatchImporter.swift:85`).

**Recommendation.**
- Add GUI export entries for LabKey and pivot xlsx in the genotype viewport's export menu (through the CLI runner).
- Add "Build Tree..." and "Primer-trim BAM..." to the Tools menu.
- Allow "Apply Recipe..." on an existing FASTQ bundle.
- Either expose Freyja properly (after Viral Recon, with a dialog) or remove `showFreyjaDemix` and the misleading comment. Make plan-only provenance list only the plan file.
- Regenerate the CLI help lists from `RecipeRegistryV2`.

**Acceptance test.** A parity table test enumerates CLI subcommands tagged `userFacing` and asserts that each maps to a GUI action id, or is explicitly listed as CLI-only in one allow-list.

**Effort:** M.

### WFL-18 (P2): Two execution paths for the same operation

**Evidence (Traced).**
- **Orient** has two paths:
  - Tools menu dialog → `fastq orient` with `saveUnoriented: false` hard-coded; the builder throws if it is true.
  - FASTQ viewer bar → in-process `OrientPipeline` with "Save unoriented reads" defaulted on (`FASTQDatasetViewController.swift:320, 1119, 2497-2505`).

  There are also two CLI commands, `orient` and `fastq orient`, with different flag names. The latter hard-codes `--threads 0` and a 1800 s timeout (`FastqOrientSubcommand.swift:55-61`).
- **Assembly.** The Tools path runs through the CLI and writes to `Analyses/`. Sidebar "Reassemble..." runs in-process, ignores the run mode and writes next to the source bundle (`AssemblyConfigurationViewController.swift:69-94`, `SidebarViewController+MenuDelegate.swift:919`).
- **Genotyping.** Workflow Operations window vs FASTQ-dialog path (WFL-13).
- **FASTQ dataset viewer.** Its in-process derivative path is effectively dead in production: only `.qualityReport` is ever selected (`FASTQDatasetViewController.swift:1616`). It is still maintained and still the home of the only install-and-retry prompt.

**Impact.** The same operation behaves differently depending on where it was launched, which erodes trust and doubles maintenance.

**Recommendation.** Make the CLI-backed dialog path canonical. Route the viewer bar and Reassemble through `runFASTQOperationLaunchRequest`. Delete the in-process derivative path once the quality report is moved. Collapse `orient` into `fastq orient` (keep an alias), with the save-unoriented option supported.

**Acceptance test.** One test per operation asserts that the viewer-initiated and menu-initiated launches produce identical `FASTQOperationLaunchRequest` values for identical inputs.

**Effort:** M.

### WFL-19 (P2): Failure-path quality

**Evidence (Traced).**
- **Raw enum text.** Mapping fails with `"\(error)"` ([AppDelegate+ToolsMenu.swift:1412](Sources/LungfishApp/App/AppDelegate+ToolsMenu.swift:1412)). `ManagedMappingPipelineError` is `LocalizedError` (`ManagedMappingPipeline.swift:34-43`), but interpolation prints the case name, not `errorDescription`.
- **Silent no-ops.**
  - Orient with malformed extra arguments: `try?` makes the request nil, but Run stays enabled and nothing happens (`FASTQOperationDialogState.swift:681`, readiness `:1386-1389`).
  - MAFFT without a project: `makeMSAAlignmentRequest` returns nil and falls through silently (`FASTQOperationDialogState.swift:843`; Suspected).
- **Cleanup errors fail successful runs.** Classifier runs call `try FileManager.default.removeItem(at: materializeTempDir)` inside the success `do` block after results are written ([AppDelegate+Classification.swift:936](Sources/LungfishApp/App/AppDelegate+Classification.swift:936); also `:1249`, `:2270`). A cleanup error turns a finished run into a failure, and a `defer` already covers cleanup.
- **Duplicate CLI builder fallback.** `FASTQOperationCLIInvocationBuilder` turns a derivative with zero inputs into a `qc-summary` invocation (`:237-239`). This is latent.
- **Viral Recon without a project.** It fails only after creating an orphan `.lungfishrun` (`ViralReconWizardSheet.swift:64-69, 382-391`).

**Recommendation.**
- Use `error.localizedDescription` and set `errorMessage`.
- Make readiness include every nil-producing validation, so Run is disabled with a reason.
- Change the temp cleanup to `try?`, or remove it.
- Validate the project precondition in the wizard's readiness.

**Acceptance test.** Unit tests for each: the mapping fail detail equals `errorDescription`. Orient with `--bad"quote` makes `canRun` false with a message. A classification run whose temp dir is already gone completes successfully.

**Effort:** S.

### WFL-20 (P2): Inconsistent result layouts among sibling tools

**Evidence (Traced).**
- **Kraken2 single run.** Uses a non-batch folder, displays the in-memory tree immediately and builds no `kraken2.sqlite` (`AppDelegate+Classification.swift:843, 975`). After a restart it goes through the database-build placeholder and a different "flat aggregated table" view (Suspected, `ViewerViewController+Taxonomy.swift:311`).
- **EsViritu single run.** Forced into `esviritu-batch-*` (`AppDelegate+Classification.swift:1061-1068`) and not auto-opened. The sidebar then says "1 samples".
- **Warning states.** Kraken2 uses `completeWithWarning` for degraded results. EsViritu partial failures and TaxTriage sample failures report plain `complete` (`:2134`, `:2330`).
- **Import destinations.** NAO-MGS goes to `Analyses/`, NVD to `Imports/`, CZ ID to `Classifications/*.lungfishtax`, and CZ ID does not refresh the sidebar (`AppDelegate+ImportCenter.swift:709-711`, `AppDelegate+ToolsMenu.swift:636, 861-866, 908-920`).
- **Reassemble output.** Goes next to the source bundle rather than `Analyses/` (WFL-18).

**Recommendation.** Define one layout contract, "every analysis, single or batch, is `Analyses/<tool>[-batch]-<ts>/` with metadata, a manifest and a SQLite index when the viewer needs one", and enforce it in `AnalysesFolder`. Send all three metagenomics imports to `Analyses/`. Use `completeWithWarning` whenever any sample failed.

**Acceptance test.** A test runs a single and a two-sample batch for each classifier (stubbed pipelines) and asserts the same directory shape, sidecars and completion-state semantics.

**Effort:** M.

### WFL-21 (P3): Dead dialogs, launchers and engines

**Evidence (Traced; each has no production caller).**

| Code | Kept alive by |
|---|---|
| [OrientWizardSheet.swift](Sources/LungfishApp/Views/Metagenomics/OrientWizardSheet.swift:49) (256 lines) | no references outside its own file |
| [UnifiedMetagenomicsWizard.swift](Sources/LungfishApp/Views/Metagenomics/UnifiedMetagenomicsWizard.swift:24) (330 lines) | `GUIRegressionTests`, `WindowAppearanceTests`, `UnifiedClassifierRunnerTests` |
| [BatchProcessingEngine.swift](Sources/LungfishApp/Services/BatchProcessingEngine.swift:101) (730 lines) | `BatchProcessingEngineTests` only. It also throws for `orient` steps (`:701-703`) |
| `FASTQDerivativeService+RecipePipeline.swift` / `runVSP2RecipeWithDelayedInterleave` | nothing. It would also record skipped steps as executed (`RecipePipeline.swift:234-248`) |
| `launchKraken2Classification`, `launchEsVirituDetection`, `launchTaxTriage` | nothing (`AppDelegate+Classification.swift:188-200`) |
| `captureMinimap2Config`, `runMinimap2Mapping`, `launchMinimap2Mapping`, `showFASTQMappingOperations`, `showFASTQGenotypingOperations` | nothing |
| `runOrientReads` | a source-text test |
| `FastqRiboDetectorSubcommand` | nothing. It is not registered in `FastqCommand` |
| `showFreyjaDemix` | protocol declaration only |
| `hasConfiguredProvider` | nothing |
| `ontGenotypingSubcommand(for:)` | nothing. It also diverges from the live copy |
| `AssemblyRunner.run(config:)`, `spadesConfig(from:)`, `captureAssemblyWizardConfig` | nothing |

The project's own memory still names `OrientWizardSheet` as a dialog template, which will mislead future agents.

**Recommendation.** Delete these in one reviewed package, together with the tests that only pin them. Update the dialog-template note to point at the FASTQ Operations dialog panes.

**Acceptance test.** `grep` shows no remaining symbol references, and the unit tier stays green.

**Effort:** S.

## Judgement: fit for lab scientists

- **Appropriately built.** The FASTQ Operations dialog and its categories, the classifier viewers with extract and export, the genotype viewport's three lenses, and typed result bundles. These match how bench users think ("I have reads, I want X").
- **Overbuilt.**
  - The Workflow Library and user-package machinery relative to its reachable value (WFL-16).
  - The unused batch recipe engine (WFL-21).
  - AI haplotyping in the primary viewport before key, consent and species handling exist (WFL-14).
  - The variant caller list includes a phased option that does not run (WFL-03).
- **Underbuilt.**
  - dependency preflight (WFL-09)
  - result routing robustness (WFL-05, WFL-06)
  - parity between shown and applied options (WFL-10)
  - discoverability of tree building and primer trim (WFL-17)
- **Hard-coding.** Hard-coding Viral Recon to MN908947.3 with Docker is acceptable for a SARS-CoV-2-specific tool, but the wizard should say "SARS-CoV-2 (MN908947.3) only" plainly, and overrides that break ingestion should be refused.

## Proposed work packages

Packages are ordered by risk reduction. Each is independently reviewable.

**WP1: Stop silent data modification (WFL-01, WFL-02).** P0.
- **Files:**
  - `Sources/LungfishApp/Services/FASTQOperationOutputImporter.swift`
  - `Sources/LungfishWorkflow/Ingestion/FASTQIngestionPipeline.swift`
  - `Sources/LungfishWorkflow/Ingestion/ClumpingTool.swift`
  - `Sources/LungfishCLI/Commands/TreeCommand.swift`
- **Risk:** low code risk. Behaviour change is intentional (larger derivative files). Coordinate with the scientific-correctness and import reviewers, since import-time binning is their call.
- **Dependencies:** none.

**WP2: Result routing single source of truth (WFL-05, WFL-06, part of WFL-20).**
- **Files:**
  - `AnalysisResultDisplayRoute.swift`
  - `MainSplitViewController+ClassifierDisplay.swift`
  - `MainSplitViewController+ContentDisplay.swift`
  - `ClassifierDatabaseRouter.swift`
  - `AnalysesFolder.swift`
  - `FASTQOperationPlanner.swift` (pbAA folder)
  - `SidebarProjectScanner.swift`
- **Risk:** medium, because it touches the display path for every analysis. Mitigate with a table-driven routing test over fixture projects.
- **Dependencies:** none.

**WP3: Remove or finish dead-end features (WFL-03, WFL-07, WFL-14, WFL-15 CZ ID part, WFL-16 gating).**
- **Files:**
  - `BAMVariantCallingCatalog.swift` and `BAMVariantCallingDialogState.swift`
  - `FASTQOperationDialogState.swift` and the removeHumanReads pane
  - `GenotypeResultViewController.swift`
  - `GenotypeAIHaplotypingExecutionService.swift`
  - `TaxonomyViewController.swift`
  - `WorkflowLibrary.swift` and `WorkflowLibraryPanelView.swift`
- **Risk:** low.
- **Dependencies:** none.

**WP4: Wizard-to-tool option fidelity (WFL-10, WFL-08, WFL-04 ingestion part, WFL-13).**
- **Files:**
  - `EsVirituConfig.swift`, `TaxTriageConfig.swift`/`TaxTriagePipeline.swift`
  - `ViralReconResultInventory.swift`, `ViralReconResultIngest.swift`
  - `BAMPrimerTrimSubcommand.swift`
  - `FastqCommand.swift` (subsample seed), `TreeCommand.swift` (seed)
  - `WorkflowOperationDialogState.swift`
- **Risk:** medium, because it changes the tools' actual inputs. Every change needs a fixture regression per the project's `FunctionalFixtureTests` convention.
- **Dependencies:** WP1 for `TreeCommand.swift` edits (same file, sequence them).

**WP5: Dependency preflight and install path (WFL-09).**
- **Files:**
  - new `LungfishKit/WorkflowDependencyPreflight.swift`
  - each wizard or dialog readiness function
  - `PrimerDesignManagedRuntime.swift`
  - `IQTreeInferenceDialog.swift`
  - `ViralReconWizardSheet.swift`
- **Risk:** medium (UI across many dialogs). Do it after WP3 so dead options are not wired.
- **Dependencies:** WP3.

**WP6: CLI parity and cancel hygiene (WFL-11, WFL-12, WFL-19).**
- **Files:**
  - `AppDelegate+Classification.swift`
  - `ViewerViewController+Taxonomy.swift`
  - `PrimerDesignDialogPresenter.swift`
  - `MainSplitViewController+PrimerAnalysis.swift`
  - `GenotypeViewportExportService.swift`
  - `PhylogeneticTreeViewController.swift`
  - `WorkflowOperationExecutionService.swift`
  - `LocalWorkflowExecutionService.swift`
  - `OperationCenter.swift` (require explicit cancel semantics)
  - BLAST drawer controllers
  - `AppDelegate+ToolsMenu.swift`
- **Risk:** low to medium. The `OperationCenter.start` signature change touches about 80 call sites. Do it mechanically, with the compiler as the check.
- **Dependencies:** none, but land after WP2 to avoid conflicts in `AppDelegate+Classification.swift`.

**WP7: Consolidate execution paths and surfaces (WFL-17, WFL-18, WFL-20 remainder, WFL-16 finish).**
- **Files:**
  - `FASTQDatasetViewController.swift`
  - `AssemblyConfigurationViewController.swift` and `SidebarViewController+MenuDelegate.swift` (Reassemble)
  - `OrientCommand.swift` and `FastqOrientSubcommand.swift`
  - `MainMenu.swift` (Build Tree, Primer-trim, Workflows submenu)
  - genotype export menu
  - `ImportFastqCommand.swift` help
- **Risk:** medium to high. This is the largest behavioural change. Stage it per operation.
- **Dependencies:** WP5 (preflight available for new menu entries).

**WP8: Delete dead code (WFL-21).**
- **Files:** listed in WFL-21, plus the tests that pin them.
- **Risk:** low.
- **Dependencies:** land after WP7, because some dead paths (the FASTQ viewer in-process path, Reassemble) are consolidated there first.

### Accept (do not fix now)

- **Viral Recon hard-coded to MN908947.3, Docker, pipeline 3.0.0.** This is a deliberate product scope for a SARS-CoV-2 workflow. Fix only the labelling and the override-ingestion mismatch (WFL-04).
- **Bracken read length 150 and threshold 10 without UI.** These are reasonable defaults for the target users. Document them in the Inspector's parameters list rather than adding controls.
- **GATK HaplotypeCaller running in-process rather than through the CLI.** It is wired to OperationCenter with process-tree cancel. Migrating it to `variants call` is nice-to-have parity, not a user-visible defect.
- **Primer-order export lacking a CLI.** It is a formatting step over an existing analysis bundle. Low value for scripting, so accept, but fix its provenance argv (WFL-11).
