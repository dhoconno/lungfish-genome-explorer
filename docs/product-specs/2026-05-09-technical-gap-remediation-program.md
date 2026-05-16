# 2026-05-09 Technical Gap Remediation Program

**Status:** Product spec
**Source requirements:** `docs/issues/2026-05-09-technical-gaps-from-documentation.md`, plus `docs/issues/2026-05-09-docs-039-gatk-first-class-integration.md` for the GATK epic.
**Scope:** Program-level remediation plan for documentation-backed technical gaps. This spec groups the issue list into buildable epics, orders dependencies, and separates immediate implementation from follow-on work.

## Goals

Close the highest-impact gaps between the user manual and implemented product behavior while strengthening Lungfish's scientific reproducibility contract. Every epic that creates, imports, transforms, exports, or wraps scientific data must satisfy the Lungfish provenance requirements: final bundles/directories carry reproducible provenance with tool/workflow version, exact argv or command, resolved options, runtime identity, input/output paths, checksums, sizes, exit status, wall time, and useful stderr.

The program should produce shippable increments. A milestone is not complete when code exists; it is complete when CLI, GUI, provenance, tests, help IDs, and manual changes agree.

## Assumptions

- The issue documents are the source of truth for scope; unsupported claims are not added here.
- Manual chapter renumbering is explicitly out of scope for this Worker A task. Some implementation epics may later require documentation navigation changes, but this spec does not perform or prescribe a manual renumber in this branch.
- File ownership areas listed below are inferred from current repository structure and named files in the issue documents. Implementation workers should confirm exact call sites before editing.
- `docs-015` is closed and `docs-009` is lifted to `docs-039`; both remain traceability records, not implementation work.

## Program Epics

### Epic A: Provenance, Audit, and Reproducibility Foundation

**Issues:** `docs-027`, `docs-029`, `docs-030`, `docs-021`, `docs-018`, `docs-019`, `docs-026`, `docs-028`, `docs-033`, plus provenance parts of every data-producing issue.

**Why this epic comes first:** Nearly every feature depends on trustworthy sidecars and stable tool/runtime identity. Missing provenance is a blocking defect for new scientific workflows.

**Ownership areas:**

- `Sources/LungfishWorkflow/Provenance/`
- `Sources/LungfishCLI/Support/CLIProvenanceSupport.swift`
- `Sources/LungfishWorkflow/Native/ToolVersionsManifest.swift`
- `Sources/LungfishWorkflow/Resources/Tools/tool-versions.json`
- `Sources/LungfishWorkflow/Builder/NextflowExporter.swift`
- `Sources/LungfishWorkflow/Builder/SnakemakeExporter.swift`
- `Sources/LungfishApp/Views/Operations/OperationsPanelController.swift`
- Provenance-disclosure views under `Sources/LungfishApp/Views/**`
- Tests in `Tests/LungfishWorkflowTests/`, `Tests/LungfishCLITests/`, and targeted app tests.

**Immediate implementation:**

- Add `runtime.user` to every provenance writer and display path (`docs-027`).
- Add `lungfish version --tools` and a release-maintained tool-version table (`docs-029`).
- Audit and normalize `--extra-args` across wrapped tools, recording a top-level `extra_args` field and conflict detection (`docs-021`).
- Add the Methods Section draft warning banner (`docs-028`).

**Follow-on:**

- Signed provenance sidecars with sigstore / in-toto (`docs-026`).
- Tool-paper bibliography and `lungfish provenance bibliography <bundle>` (`docs-030`).
- OCI container image export (`docs-018`) after lockfile support is available.
- Per-operation peak RAM collection and `lungfish ops stats` (`docs-033`).

**Acceptance criteria by epic:**

- Every touched CLI/app scientific operation writes provenance into the final output location, not a temporary staging directory.
- Sidecars include user, host, runtime/conda/container identity, resolved defaults, inputs/outputs with checksums and file sizes, exit status, wall time, and useful stderr.
- `--extra-args` behavior is uniform across wrapped tools and rejected when it conflicts with first-class flags.
- Tool versions are discoverable from CLI and docs without embedding stale per-chapter copies.
- Exported reproducibility artifacts include provenance sidecars verbatim and are covered by tests.

### Epic B: Bundle and Reference Integrity

**Issues:** `docs-001`, `docs-003`, `docs-035`, `docs-036`.

**Why this epic matters:** The manual's core promise is that Lungfish bundles are portable, inspectable scientific artifacts. Import, migration, primer schemes, and annotation handling must be correct before higher-level workflows can rely on bundles.

**Ownership areas:**

- `Sources/LungfishCore/Bundles/ReferenceBundleBuilder.swift`
- `Sources/LungfishIO/Bundles/ReferenceBundle.swift`
- `Sources/LungfishIO/Bundles/AnnotationDatabase.swift`
- `Sources/LungfishWorkflow/Annotation/AnnotationDatabaseGFFExporter.swift`
- `Sources/LungfishWorkflow/Native/NativeBundleBuilder.swift`
- `Sources/LungfishApp/Services/ReferenceBundleImportService.swift`
- `Sources/LungfishApp/Services/ReferenceBundleAnnotationImportService.swift`
- `Sources/LungfishApp/Views/ImportCenter/PrimerSchemeImportView.swift`
- `Sources/LungfishCLI/Commands/ImportCommand.swift`
- `Sources/LungfishCLI/Commands/FetchCommand.swift`
- Tests in `Tests/LungfishIOTests/`, `Tests/LungfishWorkflowTests/`, `Tests/LungfishCLITests/`, `Tests/LungfishAppTests/PrimerTrim/`.

**Immediate implementation:**

- GenBank import extracts CDS, gene, and mat_peptide features into bundle annotation tracks (`docs-001`, P0).
- Empty GFF3 fetch/import writes a valid manifest entry with a "no annotations" note (`docs-035`).
- Custom primer scheme import from BED + FASTA works and is documented (`docs-036`).
- Update adapter-removal vs primer-trim guidance so FASTQ-level fastp combined adapter+quality behavior matches the dialog default (`docs-037`).

**Follow-on:**

- Non-destructive project/bundle migration tool and menu item (`docs-003`).

**Acceptance criteria by epic:**

- Single-file GenBank import can create a `.lungfishref` with usable GFF3-equivalent annotations and downstream iVar codon merge behavior.
- Annotation-free upstream responses do not masquerade as corrupt input.
- Primer scheme bundles can be built from user BEDs, added to `Primer Schemes/`, and used by CLI and GUI primer trimming with provenance.
- Migration preserves prior bundles and provenance rather than rewriting history.

### Epic C: Network, Pack, and Offline Operations

**Issues:** `docs-004`, `docs-005`, `docs-006`, `docs-031`, `docs-032`, `docs-012`, `docs-034`.

**Why this epic matters:** Many documented workflows start with external data or managed environments. Labs with rate limits, firewalls, shared workstations, or memory-limited Macs need first-class behavior.

**Ownership areas:**

- `Sources/LungfishCLI/Commands/FetchCommand.swift`
- `Sources/LungfishApp/Views/DatabaseBrowser/`
- `Sources/LungfishApp/Views/Settings/GeneralSettingsTab.swift`
- `Sources/LungfishCore/Storage/KeychainSecretStorage.swift`
- `Sources/LungfishWorkflow/Conda/`
- `Sources/LungfishWorkflow/Metagenomics/MetagenomicsDatabaseRegistry.swift`
- `Sources/LungfishApp/Views/PluginManager/`
- `Sources/LungfishCore/Storage/ManagedStorageConfigStore.swift`
- `Sources/LungfishCore/Models/AppSettings.swift`

**Immediate implementation:**

- NCBI 429 retry with exponential backoff, `--no-retry`, Operations Panel status, and retry provenance (`docs-004`).
- NCBI API key in Settings and `NCBI_API_KEY` fallback, with provenance recording only `apiKeyProvided` (`docs-005`).
- Offline conda pack export/install and HTTPS proxy support (`docs-031`).

**Follow-on:**

- Shared `LUNGFISH_CONDA_ROOT` with read-only shared installs and install locking (`docs-032`).
- Database update tracking and surveillance viewport change markers (`docs-012`).
- Pathoplexus documentation/completion if the dialog has implementation gaps (`docs-006`).
- Hardware floor declaration and preflight memory warnings (`docs-034`).

**Acceptance criteria by epic:**

- Rate-limited fetches recover automatically without hiding retry timing from provenance.
- Secrets are stored securely and never written into sidecars or logs.
- Plugin pack installation can be reproduced on disconnected systems.
- Shared pack/database installs prevent concurrent mutation and avoid per-user duplication where supported.
- Plugin Manager reports install/update state clearly enough for audit-sensitive users.

### Epic D: Mapping and Read Metadata Readiness

**Issues:** `docs-014`, `docs-016`, mapping dependencies from `docs-039`.

**Why this epic matters:** Human germline and cohort workflows require complete read groups. Viralrecon is already exposed enough that missing documentation and provenance clarity hurt users.

**Ownership areas:**

- `Sources/LungfishWorkflow/Mapping/`
- `Sources/LungfishApp/Views/Mapping/MappingWizardSheet.swift`
- `Sources/LungfishApp/Views/Mapping/ViralReconWizardSheet.swift`
- `Sources/LungfishWorkflow/ViralRecon/`
- `Sources/LungfishApp/Services/ViralReconWorkflowExecutionService.swift`
- `Sources/LungfishCLI/Commands/MapCommand.swift`
- `Tests/LungfishAppTests/MappingWizardSheetTests.swift`
- `Tests/LungfishCLITests/AlignCommandTests.swift`

**Immediate implementation:**

- Add full `@RG` fields to mapping CLI/dialog and record derived defaults in provenance (`docs-014`).
- Document and test the viralrecon wizard workflow (`docs-016`).

**Follow-on:**

- Additional read metadata validation required by GATK cohort assembly.

**Acceptance criteria by epic:**

- Mapping produces BAMs with complete `ID`, `SM`, `LB`, `PL`, and `PU` read-group fields by default or explicit option.
- The GUI and CLI share the same request model and provenance fields.
- GATK HaplotypeCaller preflight can reject missing or inconsistent read groups before invoking GATK.

### Epic E: Variant Calling and Variant Browser Expansion

**Issues:** `docs-007`, `docs-008`, `docs-010`, `docs-024`, `docs-025`, `docs-039`.

**Why this epic matters:** Lungfish's existing viral callers remain valid, but the documented audience now includes human germline, orthogonal cross-validation, phased/haplotype work, ONT alternatives, and large multi-sample VCFs.

**Ownership areas:**

- `Sources/LungfishWorkflow/Variants/`
- `Sources/LungfishApp/Views/BAM/BAMVariantCallingDialog.swift`
- `Sources/LungfishApp/Services/CLIVariantCallingRunner.swift`
- `Sources/LungfishCLI/Commands/VariantsCommand.swift`
- `Sources/LungfishIO/Bundles/VariantDatabase.swift`
- `Sources/LungfishApp/Views/Viewer/VCFDatasetViewController.swift`
- `Sources/LungfishApp/Views/Viewer/VariantQueryBuilderSheet.swift`
- `Sources/LungfishApp/Views/Viewer/SmartFilterTokens.swift`

**Immediate implementation:**

- Reject VCFv3 with an explicit converter pointer (`docs-025`).
- Add read-group readiness first (`docs-014`) before GATK.
- Implement GATK first-class integration as its own phased program (`docs-039`), described in `2026-05-09-gatk-first-class-integration.md`.

**Follow-on:**

- `--phase-aware` iVar warning and later WhatsHap phase command (`docs-007`).
- Clair3 caller pack and UX (`docs-008`).
- bcftools caller for cross-validation (`docs-010`).
- >100-sample VCF rendering, per-sample filters, and VCF query/extract CLI (`docs-024`). GATK's first milestone supports up to 50 samples; this issue owns broader scaling.

**Acceptance criteria by epic:**

- Variant workflows refuse unsupported formats with actionable errors.
- New callers match existing CLI/dialog patterns, tool pack management, Operations Panel updates, and provenance requirements.
- Multi-sample VCF work extends the SQLite-backed variant store and smart-filter grammar rather than re-parsing large VCFs in memory.
- GATK integration remains additive; existing viral workflows do not regress.

### Epic F: Classification, Metagenomics, and Read Extraction

**Issues:** `docs-011`, `docs-038`, `docs-013`, classification parts of `docs-012`.

**Why this epic matters:** Focus groups identified Freyja and CZ-ID as adoption blockers for surveillance and industry users. CZ-ID is an import workflow; Freyja is a runnable lineage-demixing workflow.

**Ownership areas:**

- `Sources/LungfishWorkflow/Metagenomics/`
- `Sources/LungfishApp/Views/Metagenomics/`
- `Sources/LungfishApp/Services/MetagenomicsImportHelperClient.swift`
- `Sources/LungfishApp/App/MetagenomicsImportHelper.swift`
- `Sources/LungfishCLI/Commands/ClassifyCommand.swift`
- `Sources/LungfishCLI/Commands/NaoMgsCommand.swift`
- `Sources/LungfishCLI/Commands/NvdCommand.swift`
- `Sources/LungfishCLI/Commands/BlastCommand.swift`
- `Sources/LungfishWorkflow/Extraction/`

**Immediate implementation:**

- CZ-ID import to NVD parity with converter, result viewer, provenance view, CLI import, help IDs, and read extraction when source FASTQ is present (`docs-038`).
- BLAST rate-limiting/queueing for existing `lungfish blast` workflows (`docs-013`).

**Follow-on:**

- Freyja plugin pack and lineage-demixing UI/CLI (`docs-011`).
- Classifier database update tracking from Epic C (`docs-012`).

**Acceptance criteria by epic:**

- Imported hosted-platform results preserve upstream pipeline/database metadata and source archive checksums.
- Import-only tools are not exposed as fresh-run Workflow Builder nodes.
- Read extraction from imported taxonomy results follows the existing Kraken2 pattern and degrades clearly when source FASTQ is absent.
- BLAST workflows respect upstream etiquette by default and expose request IDs during queueing.

### Epic G: Workflow Builder, Export, and Batch Processing

**Issues:** `docs-040`, `docs-022`, `docs-023`, `docs-020`, plus dependencies on `docs-018`, `docs-019`, `docs-021`, `docs-028`.

**Why this epic matters:** The Workflow Builder chapter depends on feature-complete typed nodes, parameters, runner behavior, and exporter validity. Batch/sample-sheet support is a cross-cutting prerequisite for multi-sample workflows and GATK cohorts.

**Ownership areas:**

- `Sources/LungfishWorkflow/Builder/`
- `Sources/LungfishWorkflow/WorkflowRunner.swift`
- `Sources/LungfishWorkflow/WorkflowDefinition.swift`
- `Sources/LungfishApp/Views/WorkflowBuilder/`
- `Sources/LungfishApp/Services/WorkflowBuilderRunService.swift`
- `Sources/LungfishCLI/Commands/WorkflowCommand.swift`
- `Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift`
- `Sources/LungfishApp/Views/ImportCenter/`

**Immediate implementation:**

- Define and enforce Workflow Builder port type contracts (`docs-040.C`).
- Bind palette nodes to concrete tools and mirror dialog parameters (`docs-040.A`, `040.B`, `040.D`).
- Add sample-sheet-driven Illumina batch import (`docs-023`) after the type contract supports sample-sheet ports.

**Follow-on:**

- Exporter completeness for Nextflow/Snakemake/shell/methods (`docs-040.F`) after provenance/export foundations land.
- Runner failure/cancel/resume robustness (`docs-040.G`).
- Workflow versioning/diff (`docs-020`).
- Headless GUI/CI mode (`docs-022`) once CLI parity gaps are audited.

**Acceptance criteria by epic:**

- Workflow graph types are stable identifiers in source, and mismatched edges are rejected with visible feedback.
- Every tool-bound node round-trips the same parameters and defaults as the dialog.
- Saved workflows avoid absolute external paths and rebind path inputs at run time.
- Generated Nextflow and Snakemake exports run against fixtures without manual edits and carry provenance.

### Epic H: Tree and Sequence Result Tools

**Issues:** `docs-017`, sequence/export portions of `docs-040.B`.

**Why this epic matters:** Tree viewport tools are result operations, not workflow palette nodes. Keeping that boundary clear prevents the Workflow Builder from absorbing interactive result grooming.

**Ownership areas:**

- `Sources/LungfishApp/Views/Viewer/PhylogeneticTreeViewController.swift`
- `Sources/LungfishIO/Bundles/PhylogeneticTreeBundle.swift`
- `Sources/LungfishCLI/Commands/TreeCommand.swift`
- `Sources/LungfishWorkflow/MSA/`
- `Sources/LungfishWorkflow/Annotation/`

**Immediate implementation:**

- Tree viewport re-root, tip relabeling, clade collapse, subtree extraction, selection/highlighting, and CLI parity (`docs-017`) after provenance foundation is in place.

**Follow-on:**

- Additional workflow palette sequence nodes from `docs-040.B` after Workflow Builder type contracts land.

**Acceptance criteria by epic:**

- Interactive tree operations preserve originals and write derived bundles/layers with provenance.
- CLI operations produce equivalent outputs with the same provenance.
- Metadata-driven tip relabeling uses the same metadata schema as MSA bundles.

### Epic I: Multi-User Project Safety

**Issues:** `docs-002`, plus `docs-027` as a prerequisite.

**Why this epic matters:** Shared project access without attribution or locking risks data loss and audit ambiguity.

**Ownership areas:**

- `Sources/LungfishCore/Storage/ProjectStore.swift`
- `Sources/LungfishCore/Storage/ProjectFile.swift`
- `Sources/LungfishApp/App/DocumentManager.swift`
- `Sources/LungfishApp/App/DocumentLoader.swift`
- `Sources/LungfishCLI/Commands/` for `project lock` and `project unlock`
- Provenance runtime fields in `Sources/LungfishWorkflow/Provenance/`

**Immediate implementation:**

- Ship `runtime.user` first via Epic A (`docs-027`).

**Follow-on:**

- Project open lock warnings, read-only mode, explicit `lungfish project lock/unlock`, and shared-project documentation (`docs-002`).

**Acceptance criteria by epic:**

- A second process opening a locked project receives a clear warning and can choose read-only.
- CLI lock/unlock commands are explicit, auditable, and safe for advanced shared-filesystem workflows.
- Provenance can answer who performed each operation.

## Milestone Sequencing

### Milestone 0: Spec and Issue Slicing

Split this program into implementation tickets that preserve the epic boundaries above. Mark `docs-001`, `docs-027`, `docs-029`, `docs-014`, `docs-021`, `docs-031`, `docs-004`, and `docs-038` as immediate implementation candidates. Keep `docs-039` as a separate program because it introduces human germline, reference packs, cohorts, and a new `lungfish gatk` surface.

### Milestone 1: Reproducibility Baseline

Deliver `runtime.user`, tool-version table/CLI, Methods draft banner, VCFv3 explicit rejection, and provenance test helpers. This milestone should update tests before broad feature work begins.

### Milestone 2: Import and Fetch Reliability

Deliver GenBank annotation extraction, empty GFF3 behavior, NCBI retry/API-key handling, offline pack install/export, and custom primer scheme import. This converts several manual workarounds into recommended paths.

### Milestone 3: Mapping and Batch Readiness

Deliver full read-group support, sample-sheet batch import, and viralrecon chapter/test closure. This is the GATK prerequisite milestone and also improves existing mapping workflows.

### Milestone 4: First-Class Result Expansion

Deliver CZ-ID import, BLAST queueing, tree viewport result tools, and the initial Workflow Builder type/palette/parameter fixes. This milestone should avoid entangling import-only classification results with runnable workflow nodes.

### Milestone 5: Reproducible Workflow Export

Deliver conda lockfiles, exporter validity, provenance directories in exports, runner robustness, and OCI container export. This milestone turns Lungfish workflows into portable assets.

### Milestone 6: Human Germline and Cohorts

Deliver the GATK phases defined in the separate GATK product spec after Milestones 1 and 3 are complete. The first release targets research-tier human germline up to small/medium cohorts, not clinical/IVD, somatic, CNV, SV, pedigree, or VQSR.

### Milestone 7: Follow-On Variant and Operations Depth

Deliver Clair3, bcftools, phased variant warnings/WhatsHap, multi-sample VCF scaling beyond the initial GATK limit, shared conda roots, database update markers, signed provenance, workflow versioning/diff, hardware/runtime stats, and remaining P2/P3 polish.

## Immediate vs Follow-On Summary

**Immediate implementation:** `docs-001`, `docs-004`, `docs-005`, `docs-013`, `docs-014`, `docs-016`, `docs-017`, `docs-021`, `docs-023`, `docs-025`, `docs-027`, `docs-028`, `docs-029`, `docs-031`, `docs-035`, `docs-036`, `docs-037`, `docs-038`, `docs-040.C`, `docs-040.A`, `docs-040.B`, `docs-040.D`, and GATK prerequisite planning from `docs-039`.

**Follow-on:** `docs-002`, `docs-003`, `docs-006`, `docs-007`, `docs-008`, `docs-010`, `docs-011`, `docs-012`, `docs-018`, `docs-019`, `docs-020`, `docs-022`, `docs-024`, `docs-026`, `docs-030`, `docs-032`, `docs-033`, `docs-034`, `docs-040.E`, `docs-040.F`, `docs-040.G`, `docs-040.H`, and post-v1 GATK scope expansions.

The follow-on label does not mean unimportant. It means the issue either depends on foundational work, has broader blast radius, or is less blocking for the current manual coherence pass.

## Cross-Epic Dependencies

- `docs-027` is required before multi-user project support and strengthens every provenance-sensitive issue.
- `docs-014` is required before GATK HaplotypeCaller can be reliable.
- `docs-021` is required before new wrappers such as GATK, Clair3, Freyja, and bcftools should ship.
- `docs-019` should precede OCI export and high-confidence Nextflow/Snakemake export.
- `docs-023` enables Workflow Builder fan-out and GATK cohort ergonomics.
- `docs-040.C` must land before broad Workflow Builder palette and exporter work.
- `docs-024` is not required for the first GATK release if that release caps interactive cohort rendering at 50 samples, but it is required for larger cohorts.

## Program-Level Definition of Done

- Every implemented issue has CLI and GUI parity where the issue requires both.
- Every data-producing path writes final-location provenance that satisfies the Lungfish provenance requirements.
- Every new CLI command has focused CLI tests, and every GUI surface has state/routing tests.
- Documentation and `help-ids.yaml` changes are made after behavior is implemented and verified.
- Existing issue files remain unchanged except for explicit follow-up maintenance outside this Worker A task.
- Manual chapter renumbering, if needed later, is handled by a dedicated documentation task and not mixed into feature implementation.
