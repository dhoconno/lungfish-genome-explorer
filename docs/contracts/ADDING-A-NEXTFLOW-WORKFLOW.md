# Adding a Nextflow workflow

This contract says how Lungfish Genome Explorer (LGE) describes, launches and records a Nextflow workflow, and what a new workflow adds. Phase 2.9 built it from TaxTriage's launch code so that every Nextflow workflow shares one shape. It has eight parts, one per section below. A workflow is data in one descriptor, and its repository and commit come only from the managed tool lock. One builder writes its samplesheet, one engine process runs it, one record shape describes the run, one registry row names it, one stand-in replays it in tests, and one executor tool runs it from the command line. nf-core/viralrecon still launches through its own request, and a fit test shows that it fits the same descriptor.

Each section names the Phase 2.9 lane that owns it, and a lane edits only its own section. The owners of sections 3 to 8 write them as their lanes land.

## 1. The descriptor and the lock (A16)

A workflow is one `NextflowWorkflowDescriptor` value. The type is declared in `Sources/LungfishWorkflow/Nextflow/NextflowWorkflowDescriptor.swift`, and each workflow's value sits in a file of its own. TaxTriage's is `NextflowWorkflowDescriptor.taxTriage` in `Sources/LungfishWorkflow/Nextflow/NextflowWorkflowDescriptor+TaxTriage.swift`, and Viral Recon's is `NextflowWorkflowDescriptor.viralRecon` in `Sources/LungfishWorkflow/Nextflow/NextflowWorkflowDescriptor+ViralRecon.swift`. The types take `package` access, so the CLI and the test support can use them and the module map gains no public type. The initializer has no defaults, so a new workflow states every field.

| Field | What it holds | TaxTriage | Viral Recon |
|---|---|---|---|
| `toolID` | The analysis kind, which names the result folder and keys the registry row | `taxtriage` | `viralrecon` |
| `lockPipelineID` | The id of the workflow's entry in the lock's `pipelines` | `taxtriage` | `nf-core-viralrecon` |
| `profile` | The `-profile` of a launch whose caller names none | `docker` | `docker` |
| `containerRuntime` | Whether the tasks need the Docker daemon, `docker` or `hostOnly` | `docker` | `docker` |
| `releaseEnvironment` | Environment settings keyed by the release tag the lock pins | none | `NXF_SYNTAX_PARSER=v1` for `3.0.0` |
| `parameterSchemaPath` | The parameter schema inside the pipeline checkout, or nil | nil | `nextflow_schema.json` |
| `workDirectoryOption` | The option that names the work folder | `-w` | `-work-dir` |
| `traceFileName` | The trace file a run writes into its output folder, or nil | `trace.txt` | nil |
| `argumentLayout` | How a launch orders its options after the target | `inputFirst` | `sortedParameters` |
| `scratchPrefix` | The name prefix of a run's scratch folder | `taxtriage-run-` | `nfcore-run-` |
| `keepWorkEnvironmentKey` | The variable that keeps the scratch after a run when it is `1`, or nil | `LUNGFISH_TAXTRIAGE_KEEP_WORK` | nil |
| `expectedTaskCountPerSample` | The tasks one sample runs, which the progress bar counts against, or nil for the engine's own estimate | nil | nil |
| `finalizeProgressShare` | The share at the end of the progress bar that the finalize phase takes, at least 0 and less than 1 | 0.1 | 0 |

### The pin comes only from the lock

The repository, the commit and the release tag of a run come from the workflow's entry in the managed tool lock, `Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json`. An entry is a `PipelineSpec` (`Sources/LungfishWorkflow/Dependencies/DependencyManifestSections.swift`) with `id`, `repository`, `revision` and `releaseVersion`, and the descriptor holds none of these. `resolvePin(in:)` returns them unchanged as a `NextflowPipelinePin`, and `resolveBundledPin()` reads the lock bundled with LGE. A caller resolves the pin at plan, before it creates any folder.

A lock with no entry for the workflow, or an entry with a blank repository or revision, holds no pin. `resolvePin(in:)` then throws a `NextflowDescriptorRefusal` with the message `LGE's tool lock has no pinned version of <W>, so LGE will not run it.`, where `<W>` is the registry's display name, and exit code 126. That is `CLIExitCode.dependency`, the code a missing Kraken2 database exits with. No fallback branch or tag takes the pin's place (panel decision N4). A revision the user picks, such as TaxTriage's `--revision`, replaces the pin's revision, and the repository always comes from the lock. The release tag is the lock's only when the picked revision is the pin's revision or its tag, as `TaxTriageConfig.githubReleaseVersion(for:)` decides today, so neither a record nor the release environment names the lock's tag for other code.

Read a pin only through the descriptor. The older readers in `TaxTriageConfig` and `NFCoreSupportedWorkflowCatalog` fall back to a literal when the lock lacks the entry, and each fallback goes when its workflow's launch moves onto the descriptor.

### The release environment

`releaseEnvironment` holds the settings a release needs, keyed by the pin's `releaseVersion` and not by the revision that `-r` passes, so a commit of a tagged release gets the tag's settings. `launchEnvironment(for:)` returns them, and nothing for a release with no entry. Viral Recon 3.0.0 needs `NXF_SYNTAX_PARSER=v1`, because its `nextflow.config` includes a file the tag does not ship and Nextflow 25 and later parse every include before the run starts (`NFCoreSupportedWorkflow.launchEnvironment(forVersion:)` in `Sources/LungfishWorkflow/nf-core/NFCoreSupportedWorkflowCatalog.swift`). A pin bump in the lock is the cue to check whether an entry is still needed.

### The registry row

Every analysis kind that `AnalysisToolRegistry` (`Sources/LungfishIO/Analysis/AnalysisToolRegistry.swift`) provisions as `.lockedPipeline` is a Nextflow workflow. Its row runs `nextflow`, and exactly one descriptor names its kind and its lock pipeline. `Tests/LungfishWorkflowTests/NextflowWorkflowsRegistryAgreementTests.swift` fails when such a row has no descriptor or does not run `nextflow`, when a descriptor names a pipeline that its row or the lock lacks, and when two descriptors share a kind or a pipeline. A lock pipeline that is not a Nextflow workflow cannot be provisioned as `.lockedPipeline` until this rule and that suite change together. Section 5 covers the row's other fields.

### The launch's arguments

`nextflowArguments(for:)` builds the arguments of `nextflow` from a `NextflowLaunchRequest`, which holds the run-time parts of one launch. The descriptor puts them in the order the workflow's launch writes today, so moving a launch onto it changes no recorded command.

| Request field | Written as |
|---|---|
| `configFiles` | `-c <file>` for each file, before `run` |
| `target` | `run <repository> -r <revision>` for `.pinned(pin)`, or `run <folder>` for `.snapshot(folder)`, LGE's copy of the pinned code |
| `resume` | `-resume` after the target, when it is true |
| `profile` | `-profile <profile>`, the profile as the caller normalized it, or the descriptor's when it is nil |
| `samplesheet` | `--input <path>` |
| `outputDirectory` | `--outdir <path>`, and `-with-trace <path>` for the trace file inside it when `traceFileName` is set |
| `workDirectory` | the descriptor's `workDirectoryOption` and the path, when it is set |
| `pipelineArguments` | the workflow's own options |

`argumentLayout` orders what follows the target and `-resume`.

| Layout | Order | Workflow |
|---|---|---|
| `inputFirst` | `-profile`, `--input`, `--outdir`, the trace, the work folder, then the workflow's options as given | TaxTriage, as `TaxTriagePipeline.buildNextflowLaunchArguments` writes them |
| `sortedParameters` | the work folder, `-profile`, the trace, then every parameter as a `--name value` pair sorted by name, `--input` and `--outdir` among them | Viral Recon, as `NFCoreRunRequest.nextflowArguments` writes them |

Under `sortedParameters` the workflow's options must be `--name value` pairs, without `--input` or `--outdir` and without an empty value, which the request leaves out. Viral Recon's options come from `NFCoreRunRequest.effectiveParams` and not from `params`, so the forced `skip_freyja` and `skip_freyja_boot` stay in every launch, as `Tests/LungfishWorkflowTests/NextflowViralReconFitTests.swift` builds them. TaxTriage's options come from `TaxTriageConfig.nextflowPipelineArguments()`, from the Kraken2 database to the extra arguments.

The Docker wait follows the launch's effective profile. `waitsForDocker(profile:)` is true only when `containerRuntime` is `docker` and the profile is exactly the descriptor's, so a conda run or a stand-in run with `local` never waits.

### What holds this section

| Suite | What it pins |
|---|---|
| `Tests/LungfishWorkflowTests/NextflowWorkflowDescriptorTests.swift` | Each pin as the lock spells it, the refusal with its words and 126, the release environment, the Docker wait, and each instance fact against the code that launches the workflow today |
| `Tests/LungfishWorkflowTests/NextflowWorkflowsRegistryAgreementTests.swift` | The registry rule above, with negative controls on damaged copies |
| `Tests/LungfishWorkflowTests/NextflowLaunchArgumentsTests.swift` | TaxTriage's arguments byte for byte against `TaxTriagePipeline.buildNextflowLaunchArguments`, for both targets and a user's revision, with and without a work folder, under the profiles nil, `conda` and `local` |
| `Tests/LungfishWorkflowTests/NextflowViralReconFitTests.swift` | Viral Recon's arguments and environment against `NFCoreRunRequest` for the pinned release, with and without `-resume` and a work folder, for each executor and for a release the user picks |

The Viral Recon fit leaves three differences to the commit that moves its launch. The request writes no `--input` when it has no input and joins several inputs with commas, while `lungfish-cli workflow run` always passes one samplesheet. The command adds its resource-limit config with `-c` after the parameters (`Sources/LungfishCLI/Commands/NFCoreResourceLimits.swift`), where the descriptor writes every `-c` file before `run`. Its catalog still falls back to `3.0.0` when the lock lacks its pin.

## 2. The samplesheet (A16)

A workflow reads its samples from one CSV file that it takes as `--input`, the launch request's `samplesheet`. A builder that conforms to `NextflowSamplesheetBuilding` (`Sources/LungfishWorkflow/Nextflow/NextflowSamplesheetBuilding.swift`) turns the samples LGE resolved into that file.

| Requirement | Rule |
|---|---|
| `Sample` | The workflow's sample type, such as `TaxTriageSample` |
| `rows(for:)` | One row per sample below the header, in the order of the samples. The first field is the sample's name, the key the workflow names that sample's outputs by, so two samples with one name are refused |
| `write(_:to:)` | Writes the header and then the rows of `rows(for:)`, and creates the folder that holds the file. A refusal comes before any file or folder is written |

The rows a test reads and the bytes a run reads come from one builder, so a test can pin either.

TaxTriage's builder is `TaxTriageSamplesheetBuilder`. Its sheet has the columns `sample,fastq_1,fastq_2,platform`. `fastq_2` is empty for a sample with one file, and the platform is `ILLUMINA`, `OXFORD` or `PACBIO`. The file goes through `TaxTriageSamplesheet.write(samples:to:)` in `Sources/LungfishIO/Formats/TaxTriage/TaxTriageSamplesheet.swift`, which quotes a field that holds a comma, a quote or a line break and ends every line with a line feed. Its bytes equal the bytes `TaxTriagePipeline` writes today. It refuses a shared name with the error `TaxTriageConfig.validate()` throws for the same samples, such as `Duplicate sample IDs: S1, S2`. TaxTriage writes the sheet as `samplesheet.csv` in the output folder (`TaxTriageConfig.samplesheetURL`).

A builder writes the paths it is given. The caller hands it files that exist, with virtual FASTQ materialized and mates resolved as `docs/contracts/READ-PAIRING.md` says, and stages a path that holds whitespace first, because Nextflow and its Docker bind mounts break on such paths. TaxTriage's pipeline splits a strictly interleaved file into mate files and redirects paths with spaces through a folder without spaces before it writes the sheet. For Viral Recon, `Sources/LungfishCLI/Commands/NFCoreLaunchStaging.swift` copies such inputs.

Viral Recon's sheet is written today by `ViralReconSamplesheetBuilder` in `Sources/LungfishWorkflow/ViralRecon/ViralReconSamplesheetBuilder.swift`, which conforms to the protocol when Viral Recon's launch moves onto the descriptor.

A new workflow adds its builder in `Sources/LungfishWorkflow/Nextflow/` and a test that pins the builder's bytes, against the code that writes the sheet today when there is one, as `Tests/LungfishWorkflowTests/NextflowSamplesheetBuilderTests.swift` does for TaxTriage.

## 3. The engine process (S9)

## 4. The record (B11)

## 5. The registry row and the words (U9)

## 6. The stand-in for tests (Q9)

## 7. The executor tool (A2)

## 8. Adding a workflow, step by step (A2)
