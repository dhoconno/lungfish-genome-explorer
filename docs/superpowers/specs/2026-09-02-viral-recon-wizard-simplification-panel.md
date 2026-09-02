# Viral Recon Wizard Simplification: Design Review Panel

Date: 2026-09-02
Status: Recommendation. No code changed by this document.
Subject: `Sources/LungfishApp/Views/Mapping/ViralReconWizardSheet.swift` (1132 lines)
Request model: `Sources/LungfishWorkflow/ViralRecon/ViralReconRunRequest.swift`

## 1. Method

### Panel

- **E1, viral genomics (wet-lab adjacent).** Runs ARTIC and Midnight amplicon panels on clinical SARS-CoV-2 isolates. Reads consensus FASTA and iVar variant tables; does not write Nextflow config.
- **E2, pipeline and Nextflow specialist.** Maintains nf-core deployments. Reads `nextflow.config` profiles, container pins, and `-profile` semantics.
- **S1-S4, four first-year graduate students.** No prior Lungfish exposure. Shallow bioinformatics: S1 and S2 have run a Galaxy workflow once; S3 has used `bwa` from a lab protocol; S4 has never run an aligner. None has used Nextflow or Docker.

### Session structure

The wizard was walked top to bottom, section by section, in its embedded form inside the FASTQ Operations dialog (`FASTQOperationToolPanes.swift:24`), which owns the Run button. Per control, each student was asked two questions before any explanation: **what does this do**, and **what changes in your result if you move it**. Answers were scored as *correct*, *partial* (right domain, wrong consequence), or *wrong*. Experts then ruled on scientific consequence, and disagreements were recorded rather than smoothed over.

One rule was imposed on the experts: a control may only be defended as "keep visible" if a wrong setting produces a **scientifically wrong result that the user would not notice**. Controls whose wrong setting produces a loud failure were treated as candidates for defaulting.

### Code grounding

Claims about behavior were checked against source, not against the manual. Where the manual and the code disagree, the code is treated as authoritative and the disagreement is recorded.

## 2. Per-control findings, current wizard

Comprehension is scored across S1-S4. "0/4" means no student could state what the control does.

| Section | Control | What it actually does | Student comprehension | Expert verdict |
|---|---|---|---|---|
| Inputs | Input summary text | Read-only count or path of selected FASTQ bundles | 4/4 correct | Keep |
| Inputs | Platform (Auto / Illumina / Nanopore) | Overrides platform detection; `ViralReconWizardInputPolicy.resolveInputs` only consults the override when auto-detection throws `.unsupportedPlatform` (line 707) | 3/4 partial. All four read it as "tell it what machine I used" and expected it to be authoritative. None guessed it is a fallback that is ignored when detection succeeds | Keep, but relabel and demote to a fallback that appears only on detection failure |
| Reference | Reference mode (SARS-CoV-2 Genome / Local FASTA) | Chooses `.genome(accession)` versus `.local(fastaURL:gffURL:)` in `buildReference()` (line 514) | 1/4 partial, 3/4 wrong. S2: "Local FASTA means my sequencing files are local." S4 picked Local FASTA because "local sounds faster" | Remove. See finding F1 below |
| Reference | Genome accession text field (`MN908947.3`) | Passed as viralrecon `--genome`; validated against the primer manifest by `validateGenomeAccession` (line 771) | 0/4. All four said they would not touch it. S3: "I assume that is the COVID one" | Default and hide |
| Reference | Local FASTA picker (project references) | Menu over `ReferenceSequenceScanner.scanAll(in:)` results | 2/4 partial. Confusion was about **why it appears** alongside the accession field, not what a FASTA is | Keep, promoted to the single reference control |
| Reference | Choose FASTA... button | `NSOpenPanel` free-form file browse; result gets pseudo-id `__browsed__` (line 668) | 3/4 correct on mechanism, 0/4 on why it is needed given the picker above it | Remove |
| Reference | Choose GFF... button | Optional annotation, only in Local FASTA mode | 0/4. S1: "Is GFF a file format or a setting?" | Move to advanced |
| Primer Scheme | Scheme picker plus detail line | Built-in and project `.lungfishprimers` bundles; detail shows accession, primer count, amplicon count | 4/4 correct. Every student connected it to the wet-lab kit they would have used | **Keep unchanged.** Unanimous |
| Execution | Executor (Docker / Conda / Local) | Becomes `-profile <raw>` verbatim (`NFCoreRunRequest.swift:65`) | 0/4. S1 guessed Local means "run on my laptop rather than a server", which is a reasonable reading and wrong | Remove. See finding F3 |
| Execution | Version text field (`3.0.0`) | Becomes `nextflow run -r 3.0.0` | 0/4. S4: "Is this the version of my data?" | Default and hide |
| Execution | Minimum mapped reads stepper (1000) | viralrecon `--min_mapped_reads`; samples below threshold are dropped from consensus | 1/4 partial. S3 correctly guessed "a quality cutoff" but expected it to filter reads, not whole samples | Keep. See objection O1 |
| Execution | CPUs stepper | Written into `advancedParams["max_cpus"]` (line 572) | 4/4 correct that it means speed. 0/4 aware it can cause a hard failure if set above what the container gets | Default and hide |
| Execution | Memory text field (`8.GB`) | `advancedParams["max_memory"]`; free text with Nextflow unit syntax | 2/4 partial. S2 typed `8GB` when asked to change it, which is not the same string | Default and hide |
| Callers | Variant caller (iVar / BCFtools) | viralrecon `--variant_caller` | 0/4. S1: "Which one is better?" is the only response any student produced | Default and hide. See objection O2 |
| Callers | Consensus caller (iVar / BCFtools) | viralrecon `--consensus_caller` | 0/4 | Default and hide |
| Skip Options | Nine checkboxes | Each sets `skip_<x>=true` | 0/4 on consequence. S2 read the grid as a checklist of steps to **run**, i.e. exactly inverted. S4 assumed unchecked meant skipped | Remove from simple UI. See finding F6 |
| Readiness | Readiness label | `ViralReconWizardReadiness.evaluate` message | 4/4 correct and all four called it the most useful thing on screen | Keep, promote |

### Student debrief, verbatim intent

- **S2** described the screen as "a settings page, not a task", and said the presence of nine checkboxes implied all nine were decisions expected of them.
- **S4** stopped at the Reference section and said "I do not know if I am supposed to already have a file."
- **S1** and **S3** both completed a run only after being told which executor to pick. Neither could have chosen unaided.
- All four independently identified the primer scheme picker as the one control they felt qualified to set.

## 3. Answers to the seven complaints

### F1. Two places to specify a local FASTA

**Confirmed, and worse than reported.** The reference section renders `localReferencePicker` in *both* branches of the mode switch (lines 217 and 219), so the picker plus its "Choose FASTA..." button are always on screen. In SARS-CoV-2 Genome mode it appears underneath the accession field with no explanatory label; in Local FASTA mode it appears as the primary control. Same view, two meanings.

The root cause is `primerRequiresLocalReference` (line 70): in genome mode, if the selected primer scheme carries no bundled `primers.fasta`, the wizard needs a real FASTA to derive primer sequences.

**Every built-in scheme hits this path.** All eight bundles under `Sources/LungfishApp/Resources/PrimerSchemes/` contain exactly `PROVENANCE.md`, `manifest.json`, `primers.bed` and no `primers.fasta`. So `option.bundle.fastaURL` is nil for every built-in scheme, `primerRequiresLocalReference` is true by default, and the wizard's default configuration is **blocked** on a control the user has no reason to expect. This is not an edge case; it is the first-run experience.

Recommendation: adopt the product owner's position. One reference control, a menu over project reference bundles only, no `NSOpenPanel`. Delete `browseForReference()`, `browsedReferenceURL`, the `__browsed__` pseudo-id, and the mode picker. Reference becomes `.local(fastaURL:gffURL:)` always. Note the consequence in section 5, Q1: dropping `.genome` mode means the app no longer asks viralrecon to fetch a reference by accession, so the project must contain a SARS-CoV-2 reference bundle before a run is possible.

### F2. Primer scheme selection

**Keep exactly as built.** Unanimous across experts and students; the only control with 4/4 comprehension. Preserve the picker, the source suffix ("Built-in" / "Project"), and the detail line showing accession, primer count, and amplicon count. E1 noted the detail line is what let students connect the software choice to the bench kit, and asked that it not be shortened.

### F3. Are all three executors supported

**No. Docker is the only executor supported end to end.** Stated definitively, grounded in the code read:

- **`.local` is not merely unsupported, it is broken.** `NFCoreRunRequest.nextflowArguments` appends `["-profile", executor.rawValue]` (`NFCoreRunRequest.swift:65`), and `NFCoreRunBundleManifest.swift:182` does the same for the preview. There is no `switch` on the executor anywhere in `Sources/` except the UI `displayName` extension (`ViralReconWizardSheet.swift:1070`). The pinned release is viralrecon 3.0.0 (`third-party-tools-lock.json`, consumed at `NFCoreSupportedWorkflowCatalog.swift:148`), whose `profiles {}` block declares `debug, conda, mamba, docker, singularity, podman, shifter, charliecloud, apptainer, wave, gpu, arm64, emulate_amd64` and the test profiles. There is no `local` profile. Nextflow's `local` is an *executor* name (`process.executor`), a different namespace from `-profile`. The only config Lungfish writes is `NFCoreResourceLimits.swift:57-72`, a bare `process { }` block with no `profiles {}`. So `-profile local` names a profile the pipeline does not define, and Nextflow aborts before doing any work.
- **`.conda` reaches a real profile but the prerequisite is never provisioned.** Nextflow's conda backend shells out to a `conda` or `mamba` executable on PATH. The PATH built at `WorkflowEngineLaunch.swift:48-63` prepends the managed nextflow env bin, `~/.lungfish/conda/bin`, and `/usr/local/bin`. The managed conda root ships **micromamba only**; there is no `conda` or `mamba` binary under those names. `NXF_CONDA_ENABLED` appears nowhere in the codebase, and no cache dir is set. A conda run can only succeed by accident, on a machine where the user independently installed conda somewhere on the inherited PATH.
- **`.docker` is the real target.** It is the default in both GUI (line 27) and CLI (`WorkflowCommand.swift:264`). `/usr/local/bin` is on PATH specifically because, per the source comment, "Docker Desktop symlinks its CLI here". Every mitigation on this branch is container-shaped and applied unconditionally: the Freyja amd64 skips (`ViralReconRunRequest.swift:47`) and the Rosetta startup retry (`NFCoreResourceLimits.swift:88-99`) are meaningless under conda or local, yet they always run.

Test coverage confirms nothing to the contrary: no test in the repo executes Nextflow. Conda appears in two tests, both asserting only that the string reaches the argv. Local appears incidentally in failure-path tests that pass because the stub runner never inspects the profile.

The manual currently states the opposite (`docs/user-manual/chapters/04-alignments/05-viral-recon-wizard.md:93`): "Local is for machines where the required tools are already installed and managed outside Lungfish." That sentence describes a capability that does not exist. It must be corrected as part of this work.

**Recommendation: remove the executor picker entirely and hard-code Docker.** Add a container-runtime preflight so absence of Docker produces a readiness message rather than a raw Nextflow stderr tail. E2 objected briefly that removing conda forecloses a legitimate deployment; see objection O3.

### F4. Version field

**Remove and pin.** The field is free text validated only for non-emptiness (`ViralReconWizardReadiness.evaluate`, line 929). Typing a version that does not exist as a git ref produces a Nextflow failure minutes into the run. Worse, version and behavior are coupled elsewhere: `NFCoreSupportedWorkflowCatalog.swift:127-136` applies `NXF_SYNTAX_PARSER=v1` for 3.0.0 specifically, and `NFCoreResourceLimits` only writes a resource-limits config for major version 3 or higher. A user who types `2.6.0` silently loses the resource config. The pinned version already lives in `third-party-tools-lock.json`; the wizard should read it and display it as static provenance text, not as an editable field.

### F5. Variant and consensus callers

**Default and hide.** Recommended defaults, matching current state: **variant caller iVar, consensus caller BCFtools.** E1 argued these are the right defaults for amplicon SARS-CoV-2 and that a novice choosing BCFtools for variant calling on primer-trimmed amplicon data would get subtly worse allele fractions without any error. Both must remain reachable from advanced. See objection O2.

### F6. Nine skip checkboxes

**Remove from the simple UI; do not replace with an advanced checkbox grid.** Students inverted the polarity: S2 and S4 both read unchecked as "skipped". A grid of nine negations is the worst available presentation of this idea.

Note also that the defaults are already opinionated and correct: `ViralReconSkipOption.defaultSelection` skips assembly and Kraken2, and `alwaysSkipped` forces Freyja off regardless of the UI. The forced pair is already invisible (`selectable` filters them out, line 59). Extending that philosophy, the remaining nine are exactly the kind of thing the advanced text field should carry.

The house pattern for this already exists and is used by at least six wizards: a free-text field parsed by `AdvancedCommandLineOptions.parse` (`Sources/LungfishWorkflow/Native/ShellUtilities.swift`), with the parse error surfaced in the readiness or footer line. See `ClassificationWizardSheet.swift:607`, `MappingWizardSheet.swift:765`, `AssemblyWizardSheet.swift:610`. Viral Recon is the outlier that never adopted it. Its `advancedParams()` (line 571) is a hard-coded two-key dictionary with no user path into it at all.

### F7. Overall simplicity

The current sheet renders eight sections and roughly nineteen interactive controls in a single scroll. The comparators render three to five sections with the tail collapsed behind `DisclosureGroup("Advanced Settings")`. Viral Recon is the most complex pipeline in the app and has the least progressive disclosure, which is backwards. The design in section 4 brings it to five visible controls.

## 4. Recommended simplified wizard

### Visible controls, in order

1. **Inputs** (read-only). Existing `inputSummary` text. Below it, the detected platform as static text: "Detected platform: Illumina". If detection throws `.unsupportedPlatform`, and only then, show the segmented Platform control relabeled **"Platform could not be detected. Choose one:"** with Illumina and Nanopore only. Drop the Auto segment; auto is the absence of the control.
2. **Reference**: menu, label **"Reference"**. Options are project reference bundles from `ReferenceSequenceScanner.scanAll(in:)`. Default: the first candidate whose FASTA header or bundle name matches the selected scheme's canonical accession, otherwise the first candidate. When the project has none, show "No reference sequences in this project. Import a SARS-CoV-2 reference first." and block. No browse button, no mode picker, no accession field.
3. **Primer Scheme**: menu, label **"Primer Scheme"**, unchanged from today including the detail line. Default: first entry sorted as today.
4. **Minimum mapped reads**: stepper, label **"Minimum mapped reads"**, default **1000**. Retained visible on E1's objection (O1). Add caption: "Samples with fewer mapped reads are dropped from the consensus."
5. **Readiness**: existing readiness or build-error text, promoted directly above the dialog's Run button. Also carries the advanced-options parse error, matching `MappingWizardSheet.footerSection`.

That is four inputs plus one status line. Everything else is defaulted.

### Fixed, not shown

| Parameter | Value | Where it comes from |
|---|---|---|
| Executor | `.docker` | Hard-coded; picker deleted |
| Version | `3.0.0` | Read from `third-party-tools-lock.json`, shown as static provenance text |
| `variant_caller` | `ivar` | Default retained |
| `consensus_caller` | `bcftools` | Default retained |
| `skip_assembly`, `skip_kraken2` | true | `ViralReconSkipOption.defaultSelection`, unchanged |
| `skip_freyja`, `skip_freyja_boot` | true, forced | `alwaysSkipped`, unchanged |
| `max_cpus` | `min(coreCount, 8)` | Current default expression, line 30 |
| `max_memory` | `8.GB` | Current default |
| `protocol` | `amplicon` | Already the only case |

### Advanced escape hatch

A collapsed `DisclosureGroup("Advanced Settings")`, matching `ClassificationWizardSheet.advancedSettings` in structure and default-collapsed state. Contents, in order:

- **Annotation (GFF)**: the existing `Choose GFF...` button plus the staged-path caption. Optional, rarely set, and genuinely a file choice, so it stays a picker rather than a text argument.
- **Extra parameters**: single-line monospace `TextField`, label **"Extra parameters"**, placeholder `--skip_fastqc --variant_caller bcftools --max_memory 16.GB`, caption "Additional nf-core/viralrecon parameters, passed through to Nextflow." Parsed with `AdvancedCommandLineOptions.parse`; parse failure blocks Run and reports through the readiness line.

**Parameters the advanced field must be able to reach.** Every one of these is currently either a visible control or unreachable, and all must survive the simplification:

- All nine selectable skips: `skip_assembly`, `skip_variants`, `skip_consensus`, `skip_fastqc`, `skip_kraken2`, `skip_fastp`, `skip_cutadapt`, `skip_ivar_trim`, `skip_multiqc`.
- `variant_caller`, `consensus_caller`, `min_mapped_reads`.
- `max_cpus`, `max_memory`, and any other resource or tuning parameter viralrecon accepts.
- Arbitrary viralrecon parameters the app has never modeled, which is the point of the escape hatch.

**Required change to the request model.** `ViralReconRunRequest.validateAdvancedParams` (`ViralReconRunRequest.swift:225`) currently *throws* `conflictingAdvancedParam` for any key in a generated set that includes every `skip_*` case, `variant_caller`, `consensus_caller`, and `min_mapped_reads`. Under the recommended design those are precisely the keys advanced users need. The rule must change from "reject" to "override, last writer wins" for the tuning keys, while continuing to reject the structural keys the wizard owns: `input`, `outdir`, `platform`, `protocol`, `genome`, `fasta`, `gff`, `fastq_dir`, `sequencing_summary`, and the four `primer_*` keys. Attempting to override a structural key should produce a readable readiness message naming the key, not a raw error. `skip_freyja` and `skip_freyja_boot` must stay in the reject set: they are forced for a platform reason (`ViralReconRunRequest.swift:35-50`) and a user override cannot make an amd64-only container work here.

The `--param key=value` CLI path (`cliArguments`, line 279) already carries whatever `effectiveParams` contains, so CLI parity follows automatically once the merge rule changes.

### Removed symbols

`selectedReferenceMode`, `ReferenceMode`, `genomeAccession`, `browsedReferenceURL`, `Self.browsedReferenceID`, `browseForReference()`, `executor` state and `Self.executors`, `version` state, `variantCaller` and `consensusCaller` state, `skipOptions` state, `skipSection`, `callersSection`, and the `NFCoreExecutor.displayName` extension. `ViralReconWizardPrimerCompatibility.validateGenomeAccession` loses its wizard caller but should be retained and re-pointed at the selected reference bundle's accession, so the scheme-versus-reference mismatch check survives; see Q1.

Accessibility identifiers `viral-recon-reference-mode-picker`, `viral-recon-genome-field`, and `viral-recon-executor-picker` become dead and should be deleted from `XCUIAccessibilityIdentifiers.swift:249`. `viral-recon-version-field` becomes a static label. `Tests/LungfishXCUITests/ViralReconXCUITests.swift` references only `viral-recon-input-summary` and is unaffected.

## Recorded expert objections

**O1. Minimum mapped reads must stay visible.** E1 objected to hiding it. His argument: it is the one threshold that silently changes which samples appear in the output, and a bench scientist running low-titre wastewater or late-Ct clinical samples will legitimately want it lower. Hiding it means a sample vanishes from the consensus with no visible cause. E2 countered that 1000 is a sane default and the control adds a fifth line. **Resolution: E1 prevailed, it stays visible, with the caption above.** The panel accepted that a silent sample-dropping threshold is exactly the category the "keep visible" rule protects.

**O2. Variant caller has real scientific consequence.** E1 objected to hiding the caller pickers on the grounds that iVar versus BCFtools materially changes minor-allele calls on amplicon data, and that a lab standardizing on BCFtools would need it. He did not dispute that novices cannot choose. **Resolution: hidden from the simple UI, reachable via `--variant_caller bcftools` in Extra parameters, which is why that key must move from the reject set to the override set.** E1 accepted this on the condition that the advanced placeholder text names `--variant_caller` explicitly, so the capability is discoverable. It does.

**O3. Removing conda forecloses a real deployment.** E2 objected that conda is a legitimate nf-core execution mode and that some sites forbid Docker. **Resolution: objection noted, removal upheld, because the code does not currently support conda.** The panel's position is that shipping a picker for an unprovisioned backend is worse than shipping no picker. If conda support is wanted it is a separate piece of work: provision a `conda` or `mamba` executable on the subprocess PATH, set the cache dir, and test an actual run. Until then the picker misrepresents the product. E2 asked that this be logged as a follow-up rather than closed; see Q3.

**O4. Dropping genome-accession mode is a real capability loss.** E2 noted that `.genome("MN908947.3")` lets viralrecon fetch and index the reference itself via its iGenomes-style path, and that requiring a project reference bundle adds a setup step. E1 countered that in practice the genome path is unusable today anyway, since all eight built-in schemes lack `primers.fasta` and therefore force a local FASTA regardless of mode. **Resolution: removal upheld on E1's evidence.** The mode is nominally available and practically never usable. See Q1 for the migration consequence.

## 5. Open questions for the product owner

**Q1. Must the project contain a SARS-CoV-2 reference before Viral Recon can run?**
Dropping genome-accession mode means yes. *Recommendation: accept it, and pair it with a one-click remedy.* When the reference picker is empty, the empty-state message should carry a button that imports the canonical `MN908947.3` reference into `Reference Sequences/`. Also re-point `validateGenomeAccession` at the chosen reference bundle so a Midnight-scheme-versus-wrong-reference mismatch is still caught before the run starts.

**Q2. Should `max_cpus` and `max_memory` remain wizard-controlled at all?**
They are currently the only things `advancedParams()` populates, and for viralrecon 3.x `NFCoreResourceLimits` writes `process.resourceLimits` from a `-c` config instead, so the two `--max_*` params may be redundant on the pinned version. *Recommendation: keep emitting them for compatibility, default them as listed, and let Extra parameters override. Confirm against a real 3.0.0 run before deleting.*

**Q3. Is conda support a committed roadmap item or a dropped capability?**
The manual currently promises it. *Recommendation: drop it for now and correct the manual in the same change. If it is wanted, file it as scoped work covering PATH provisioning, cache dir, and a real end-to-end run, and do not restore the picker until that lands.* Leaving the picker in place while the backend is unprovisioned is the status quo the panel is recommending against.

**Q4. Should the advanced field validate parameter names against viralrecon's schema?**
A typo like `--skip_fastq` fails minutes into the run. viralrecon ships `nextflow_schema.json`, so names are checkable up front. *Recommendation: not in this change. Ship the pass-through first, and treat schema validation as a follow-up that would also improve the Workflow Builder.*

**Q5. Where does the pinned version get displayed?**
*Recommendation: a static provenance line in Advanced Settings reading "nf-core/viralrecon 3.0.0", sourced from the tool lock. It belongs in the run's provenance record regardless, and showing it in the collapsed section costs nothing.*
