# Adding a Nextflow workflow

This contract says how Lungfish Genome Explorer (LGE) describes, launches and records a Nextflow workflow, and what a new workflow adds. Phase 2.9 built it from TaxTriage's launch code so that every Nextflow workflow shares one shape. It has eight parts, one per section below. A workflow is data in one descriptor, and its repository and commit come only from the managed tool lock. One builder writes its samplesheet, one engine process runs it, one record shape describes the run, one registry row names it, one stand-in replays it in tests, and one executor tool runs it from the command line. nf-core/viralrecon launches through the same engine process with its descriptor's argv, and its fit test declares one difference left, the catalog's fallback release (section 1).

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
| `expectedTaskCountPerSample` | The tasks one sample runs, which the row's progress counts against, or nil for the engine's own estimate | nil | nil |
| `finalizeProgressShare` | The share at the end of the row's progress that the finalize phase takes, at least 0 and less than 1 | 0.1 | 0 |

### The pin comes only from the lock

The repository, the commit and the release tag of a run come from the workflow's entry in the managed tool lock, `Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json`. An entry is a `PipelineSpec` (`Sources/LungfishWorkflow/Dependencies/DependencyManifestSections.swift`) with `id`, `repository`, `revision` and `releaseVersion`, and the descriptor holds none of these. `resolvePin(in:)` returns them unchanged as a `NextflowPipelinePin`, and `resolveBundledPin()` reads the lock bundled with LGE. A caller resolves the pin at plan, before it creates any folder.

A lock with no entry for the workflow, or an entry with a blank repository or revision, holds no pin. `resolvePin(in:)` then throws a `NextflowDescriptorRefusal` with the message `LGE's tool lock has no pinned version of <W>, so LGE will not run it.`, where `<W>` is the registry's display name, and exit code 126. That is `CLIExitCode.dependency`, the code a missing Kraken2 database exits with. No fallback branch or tag takes the pin's place (panel decision N4). A revision the user picks, such as TaxTriage's `--revision`, replaces the pin's revision, and the repository always comes from the lock. The release tag is the lock's only when the picked revision is the pin's revision or its tag, as `TaxTriageConfig.githubReleaseVersion(for:)` decides today, so neither a record nor the release environment names the lock's tag for other code.

Read a pin only through the descriptor. The older readers in `TaxTriageConfig` and `NFCoreSupportedWorkflowCatalog` fall back to a literal when the lock lacks the entry, and each fallback goes when its workflow's launch moves onto the descriptor. Viral Recon's launch moved in Phase 2.10 but still takes its revision from the run's request, so its catalog keeps the `3.0.0` fallback until the commit that retires the four homes of that tag (Phase 2.10 decision N2). That is fit difference 3 at the end of this section.

### The release environment

`releaseEnvironment` holds the settings a release needs, keyed by the pin's `releaseVersion` and not by the revision that `-r` passes, so a commit of a tagged release gets the tag's settings. `launchEnvironment(for:)` returns them, and nothing for a release with no entry. Viral Recon 3.0.0 needs `NXF_SYNTAX_PARSER=v1`, because its `nextflow.config` includes a file the tag does not ship and Nextflow 25 and later parse every include before the run starts (`NFCoreSupportedWorkflow.launchEnvironment(forVersion:)` in `Sources/LungfishWorkflow/nf-core/NFCoreSupportedWorkflowCatalog.swift`). A pin bump in the lock is the cue to check whether an entry is still needed. `lungfish-cli workflow run` still sets Viral Recon's launch environment from `NFCoreRunRequest.launchEnvironment`, which `NextflowViralReconFitTests` shows equal to the descriptor's for the pinned release and for a release the user picks.

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
| `sortedParameters` | the work folder, `-profile`, the trace, then every parameter as a `--name value` pair sorted by name, `--input` and `--outdir` among them | Viral Recon, from the launch that `NFCoreRunRequest.viralReconLaunch(samplesheet:configFiles:)` builds for the run's request |

A third layout joins only when a fit test shows that neither layout writes the order of a launch LGE already makes, as the Viral Recon fit showed for `sortedParameters`. A workflow that builds its options from a dictionary sorts them or takes `sortedParameters`, because a Swift dictionary's order changes from one process to the next and the recorded command would change with it.

Under `sortedParameters` the workflow's options must be `--name value` pairs, without `--input` or `--outdir` and without an empty value, which the request leaves out. Viral Recon's options come from `NFCoreRunRequest.effectiveParams` and not from `params`, so the forced `skip_freyja` and `skip_freyja_boot` stay in every launch, as `Tests/LungfishWorkflowTests/NextflowViralReconFitTests.swift` builds them. TaxTriage's options come from `TaxTriageConfig.nextflowPipelineArguments()`, from the Kraken2 database to the extra arguments.

The Docker wait follows the launch's effective profile. `waitsForDocker(profile:)` is true only when `containerRuntime` is `docker` and the profile is exactly the descriptor's, so a conda run or a stand-in run with `local` never waits.

### What holds this section

| Suite | What it pins |
|---|---|
| `Tests/LungfishWorkflowTests/NextflowWorkflowDescriptorTests.swift` | Each pin as the lock spells it, the refusal with its words and 126, the release environment, the Docker wait, and each instance fact against the code that launches the workflow today |
| `Tests/LungfishWorkflowTests/NextflowWorkflowsRegistryAgreementTests.swift` | The registry rule above, with negative controls on damaged copies |
| `Tests/LungfishWorkflowTests/NextflowLaunchArgumentsTests.swift` | TaxTriage's arguments byte for byte against `TaxTriagePipeline.buildNextflowLaunchArguments`, for both targets and a user's revision, with and without a work folder, under the profiles nil, `conda` and `local` |
| `Tests/LungfishWorkflowTests/NextflowViralReconFitTests.swift` | Viral Recon's arguments and environment, from the launch `workflow run` builds, against `NFCoreRunRequest` for the pinned release, with and without `-resume` and a work folder, for each executor and for a release the user picks, and the one samplesheet with its `-c` files before `run` |
| `Tests/LungfishAppTests/NextflowWorkflowContractParityReplayTests.swift` | What `lungfish-cli workflow run nf-core/viralrecon` launches on the stand-in against what the descriptor writes for the same launch, with each difference declared in `NextflowWorkflowContractParityKnownDifferences.swift` |

The Viral Recon fit found four differences between the descriptor and the launch that `lungfish-cli workflow run` made before Phase 2.10. The commits that moved the launch onto the descriptor closed three of them, each with a test that failed before it. The launch passes the one samplesheet the command built as `--input`, where the request wrote no `--input` without input and joined several inputs with commas (fit difference 1). It writes the resource-limit config (`Sources/LungfishWorkflow/nf-core/NFCoreResourceLimits.swift`) with `-c` before `run`, where the command added it after the parameters (fit difference 2). Without `--workdir`, which the app never passes, it writes `-work-dir` with the scratch's work folder before `-profile`, as the descriptor's layout orders it, where the command appended it after that `-c` file (fit difference 4). Fit difference 3 stays open. Viral Recon's catalog falls back to `3.0.0` when the lock lacks its pin, where the descriptor refuses the run, until the commit of decision N2. The parity class declares that one difference with the lane that closes it.

## 2. The samplesheet (A16)

A workflow reads its samples from one CSV file that it takes as `--input`, the launch request's `samplesheet`. A builder that conforms to `NextflowSamplesheetBuilding` (`Sources/LungfishWorkflow/Nextflow/NextflowSamplesheetBuilding.swift`) turns the samples LGE resolved into that file.

| Requirement | Rule |
|---|---|
| `Sample` | The workflow's sample type, such as `TaxTriageSample` |
| `rows(for:)` | One row per sample below the header, in the order of the samples. The first field is the sample's name, the key the workflow names that sample's outputs by, so two samples with one name are refused |
| `write(_:to:)` | Writes the header and then the rows of `rows(for:)`, and creates the folder that holds the file. A refusal comes before any file or folder is written |

The rows a test reads and the bytes a run reads come from one builder, so a test can pin either.

TaxTriage's builder is `TaxTriageSamplesheetBuilder`. Its sheet has the columns `sample,fastq_1,fastq_2,platform`. `fastq_2` is empty for a sample with one file, and the platform is `ILLUMINA`, `OXFORD` or `PACBIO`. The file goes through `TaxTriageSamplesheet.write(samples:to:)` in `Sources/LungfishIO/Formats/TaxTriage/TaxTriageSamplesheet.swift`, which quotes a field that holds a comma, a quote or a line break and ends every line with a line feed. Its bytes equal the bytes `TaxTriagePipeline` writes today. It refuses a shared name with the error `TaxTriageConfig.validate()` throws for the same samples, such as `Duplicate sample IDs: S1, S2`. TaxTriage writes the sheet as `samplesheet.csv` in the output folder (`TaxTriageConfig.samplesheetURL`).

A builder writes the paths it is given. The caller hands it files that exist, with virtual FASTQ materialized and mates resolved as `docs/contracts/READ-PAIRING.md` says, and stages a path that holds whitespace first, because Nextflow and its Docker bind mounts break on such paths. TaxTriage's pipeline splits a strictly interleaved file into mate files and redirects paths with spaces through a folder without spaces before it writes the sheet. For Viral Recon, `NFCoreLaunchStaging.stage` in `Sources/LungfishWorkflow/nf-core/NFCoreLaunchStaging.swift` copies such inputs.

Viral Recon's sheet is written today by `ViralReconSamplesheetBuilder` in `Sources/LungfishWorkflow/ViralRecon/ViralReconSamplesheetBuilder.swift`, which does not conform to the protocol, although Viral Recon's launch takes its descriptor's argv.

A new workflow adds its builder in `Sources/LungfishWorkflow/Nextflow/` and a test that pins the builder's bytes, against the code that writes the sheet today when there is one, as `Tests/LungfishWorkflowTests/NextflowSamplesheetBuilderTests.swift` does for TaxTriage.

## 3. The engine process (S9)

`NextflowEngineProcess` (`Sources/LungfishWorkflow/Nextflow/NextflowEngineProcess.swift`) is the one launch path every Nextflow workflow moves onto. TaxTriage and Viral Recon launch through it, and the last paragraph of this section names the launches that have not moved yet. A workflow gets its engine from its descriptor. `engineConfiguration(profile:)` (`Sources/LungfishWorkflow/Nextflow/NextflowWorkflowDescriptor+Engine.swift`) takes the profile the caller resolved and returns the settings below, and TaxTriage builds its engine with `TaxTriagePipeline.nextflowEngine(processManager:profile:)` in `Sources/LungfishWorkflow/TaxTriage/TaxTriageEngineProcess.swift`. Viral Recon's `lungfish-cli workflow run nf-core/viralrecon` builds its engine with `ProcessNFCoreWorkflowProcessRunner.engine(profile:)` in `Sources/LungfishCLI/Commands/ProcessNFCoreWorkflowProcessRunner.swift`. A workflow on the engine never launches Nextflow on its own.

| Setting | Value | What it does |
|---|---|---|
| `scratchPrefix` | The descriptor's | Names the launch folder that holds `.nextflow/` and the work folder |
| `keepWorkEnvironmentKey` | The descriptor's | Keeps the launch folder after the run when the variable is `1` |
| `waitsForDocker` | True only when `containerRuntime` is `docker` and the profile is the descriptor's | Makes `waitForDocker(probe:progress:)` wait for the daemon, so a conda run or a stand-in run with `local` never waits |
| `terminationGracePeriod` | 4 s | The time between TERM and KILL on a cancel (decision N6) |
| `logTailLineCount` | 200 | The lines of each stream the outcome keeps |
| `tracePollInterval` | 5 s | How often the engine reads the trace file for progress |

### One run, in order

1. `waitForDocker(probe:progress:)` waits for the Docker daemon when the configuration says so. It reports `Docker daemon unavailable. Launching Docker Desktop...` at 0.01, asks macOS to start Docker Desktop with `open -g -a Docker`, polls every 2 s for up to 90 s, then reports `Docker daemon ready` at 0.02 and `Starting the pipeline...` at 0.03. A cancel ends the wait at once with `CancellationError`. An `open` that fails ends it at once, and a daemon that has not answered after 90 s ends it then. Either failure reads `Docker Desktop is not running or daemon is unreachable. Start Docker Desktop and retry.` Viral Recon's `workflow run` prints the wait's three lines on standard output as information lines, or as `progress` events at 0.01, 0.02 and 0.03 under `--format json`, and a wait that fails records the run as failed with exit 65 and launches nothing.
2. `makeScratch(contextURL:)` creates the launch folder and its `work/` folder on the volume of the output folder when that volume can host Nextflow's cache, and in the system temp folder otherwise (`NextflowScratchVolumeProbe`).
3. `run(_:in:hooks:)` checks the task before it does anything, so a cancel that came first launches nothing, writes no log and throws `CancellationError`. It launches the `NextflowEngineLaunch` in the launch folder and returns a `NextflowEngineOutcome` once the engine and every process of its tree have ended.
4. The caller writes its record, `cancelled` with exit 125 when the task was cancelled, and only then calls `finish(_:_:)`. Viral Recon's `workflow run` writes the same record for a cancel that comes before the launch, during the Docker wait or while it splits interleaved reads.

### The log

`run` writes `nextflow.log` at the launch's `logFile` while the engine runs. The log holds the launch's `logPreamble`, then `--- stdout ---` and each stdout line as it arrives, then `--- stderr ---` and the stderr lines, which wait in a sidecar in the launch folder until the engine has ended. A launch that fails leaves the preamble and a `--- launcher error ---` part with the words of `NextflowEngineProcess.launchFailureMessage(for:)`. Whatever sits at the log's path is replaced first, so a link left there is never written through. The log is synchronized before `run` returns, so the bytes a step hashes are on disk. A KILL of the CLI or the app leaves the preamble and the stdout so far, with no stderr part. Viral Recon's `workflow run` writes the log at its run bundle's `logs/nextflow.log`, and the preamble names the command that ran, the launch folder and the work folder (`ProcessNFCoreWorkflowProcessRunner.logPreamble`).

A write, read-back or `fsync` that fails is in the outcome's `logFailure`. The caller fails a run that ended on its own when it is set, names no output in the failed step, and lets a cancel win over it.

### A cancel

A cancel of the calling task sends TERM to the engine's process group and every descendant, the launcher, Nextflow's JVM and each task wrapper, then KILL to what is left after the 4 s grace. `run` returns only once the tree is gone. The order after that is fixed (decision N5).

1. The host tree goes first.
2. The `cleanup` hook of `NextflowEngineHooks`, when the caller passes one, stops the run's task containers, which run in Docker Desktop's VM outside the host tree, by their bind mounts of the run's work folder. `run` waits for it at most 1.5 s (`NextflowEngineProcess.containerCleanupBound`), so the grace and the cleanup end inside the 6 s the app gives a cancelled command. Viral Recon's `workflow run` passes the engine's `containerCleanup(probe:)`, which acts only for the descriptor's docker profile. TaxTriage passes no cleanup yet, so the task containers of its cancelled run keep running in Docker Desktop until they end.
3. The caller writes its `cancelled` record.
4. `finish(_:_:)` removes the launch folder with `.remove`, or leaves it for the abandoned-scratch sweep with `.leaveForSweep`, which decision N7 gives a cancelled executor unit of the CLI. TaxTriage's pipeline passes `.remove`, a cancelled run included. Viral Recon's `workflow run` passes `.leaveForSweep` for a cancelled run and `.remove` for every other (Phase 2.10 decision P3). A work or staging folder it made in the system temp folder, because the scratch path holds a space, goes or stays with the scratch. A folder kept with the keep-work variable is never removed.

The cleanup runs in a new task, which starts uncancelled and keeps the caller's task-local values, such as a test's container probe. It unbinds the provenance observer alone, so no `docker` command becomes a step.

### Progress

`NextflowEngineHooks.progress` receives each stdout line once it is in the log, through `NextflowProgressReporting.engineLine`, and each changed reading of the trace file, through `traceProgress`. A reading counts the COMPLETED and CACHED rows and names the last of them. `NextflowProgressReader` (`Sources/LungfishWorkflow/Nextflow/NextflowProgressReader.swift`) words each task line and moves the bar from 0.10 to 0.90 on the readings, against 15 tasks or the descriptor's `expectedTaskCountPerSample` times the sample count, as section 5 sets out. Viral Recon's `workflow run` passes no progress hook, so its task lines reach only the log. After a run that exits 0 it reads the run's own trace, the newest `pipeline_info/execution_trace*.txt` written since the launch, and its results. `NextflowTraceTask` (`Sources/LungfishWorkflow/Nextflow/NextflowTraceTask.swift`) names the ignored tasks, each a FAILED row with no later COMPLETED or CACHED row of its name, and `ViralReconRunOutcome` (`Sources/LungfishWorkflow/ViralRecon/ViralReconRunOutcome.swift`) names the failed samples, those the run's variant caller never reached. The command prints one warning line for each kind on standard error, or a `log` event at `warning` under `--format json`, in the words of section 5.

### What holds this section

| Suite | What it pins |
|---|---|
| `Tests/LungfishWorkflowTests/Nextflow/NextflowEngineProcessTests.swift` | The log's bytes, the streamed lines, the tail, a replaced link, the cancel with its grace and cleanup, the cleanup's task-local values and the trace readings, on `/bin/sh` scripts |
| `Tests/LungfishWorkflowTests/Nextflow/NextflowEngineLogTests.swift` | A failed write that reaches the caller, and a tail that bounds memory |
| `Tests/LungfishWorkflowTests/Nextflow/NextflowEngineScratchTests.swift` | The volume probe, the keep-work variable and both dispositions |
| `Tests/LungfishWorkflowTests/Nextflow/NextflowEngineDockerWaitTests.swift` | The wait's words, a cancelled wait and a failed `open`, on a stub probe that never starts Docker Desktop |
| `Tests/LungfishWorkflowTests/Nextflow/NextflowWorkflowDescriptorEngineTests.swift` | The settings a descriptor gives a launch, and that only its own Docker profile waits |
| `Tests/LungfishWorkflowTests/Nextflow/NextflowProgressReaderTests.swift` | The progress rule |
| `Tests/LungfishAppTests/TaxTriageEngineProcessReplayTests.swift` | TaxTriage on the engine with the stand-in, the cancel's order, the log's bytes, a cancel in the wait and before the launch, the log a KILL leaves, and that only the docker profile asks the daemon |
| `Tests/LungfishAppTests/NextflowWorkflowContractParityReplayTests+Scratch.swift` and `NextflowWorkflowContractParityReplayTests+DockerWait.swift` | Viral Recon's `workflow run` on the engine with the stand-in, the scratch a completed, a failed and a cancelled run leave, the cancel's container cleanup and record, and a failed Docker wait that launches nothing |
| `Tests/LungfishCLITests/ViralReconCancelledRunRecordTests.swift` | A cancel of `workflow run` during the Docker wait or the read split, recorded as cancelled with 125 and nothing launched |
| `Tests/LungfishWorkflowTests/Nextflow/NextflowIgnoredTaskTests.swift` and `Tests/LungfishWorkflowTests/ViralRecon/ViralReconRunOutcomeTests.swift` | An ignored task against a retry, the newest trace since the launch, the failed samples by each caller's files and trace rows, and the words of both lines |
| `Tests/LungfishCLITests/WorkflowRunOutcomeLinesTests.swift` | Viral Recon's `workflow run` prints both outcome lines after exit 0, even under `--quiet`, and the Docker wait's three lines |
| `Tests/LungfishCLITests/WorkflowRunManagedEngineTests.swift` | `workflow run` launches only the managed Nextflow, fails the run with 126 when it is missing, and a Debug build's Docker stand-in fails closed |

Two launches still run Nextflow on their own, with the engine's 4 s grace. `lungfish-cli workflow run` with a local workflow launches Nextflow or Snakemake through `WorkflowEngineProcess.run`, which `Sources/LungfishCLI/Commands/ProcessLocalWorkflowProcessRunner.swift` calls, and pbAA clustering moves onto the engine in Phase 2.11.

## 4. The record (B11)

A workflow on this contract records each of its Nextflow steps in one shape, `NextflowRecordFacts` in `Sources/LungfishWorkflow/Nextflow/NextflowRecordFacts.swift` (decision R1). In Phase 2.9 only TaxTriage's pipeline writes it. Viral Recon and pbAA keep their own records until they move onto the contract. `Tests/LungfishCLITests/ViralReconRecordShapeGapTests.swift` states Viral Recon's gaps.

| Fact | Where the record holds it | Where the value comes from |
|---|---|---|
| Pipeline | The step's `toolName`, the lock's pipeline id, such as `taxtriage` | The descriptor's `lockPipelineID`, through the pin |
| Revision | The step's `toolVersion`, the revision that ran | The lock's pin through `NextflowRecordFacts(pin:pipelineSource:)`, or the revision the user picked in its place (section 1), which TaxTriage records through `TaxTriageRecordFacts.nextflowFacts(revision:pipelineSource:)` |
| Release tag | The step's `githubReleaseVersion`, left out when no tag names the revision | The pin's `releaseVersion` for the pin's own revision or that tag. TaxTriage also records a revision that is itself a `v` tag as its own tag (`TaxTriageConfig.githubReleaseVersion(for:)`) |
| Launch source | The step's resolved option `pipelineSource`, `remote` or `snapshot` | The launch target, the repository with `-r` or LGE's snapshot folder without it |
| Nextflow version | The step's resolved option `nextflowVersion`, left out when the log names none | The run's own log, read by `NextflowRecordFacts.nextflowVersion(inLog:)` |
| Settings | Explicit options for what the user chose, resolved defaults for a value LGE passed unasked or the pipeline used by default | The request and the descriptor |
| Databases | Resolved defaults, each with a status from `DatabaseIdentityStatus` | The install receipt, or a digest LGE checked |
| Fetched data | A `NextflowDatabaseEntry` of status `liveSnapshot` with the fetch date and the kept files that list what the run fetched | The pipeline's kept outputs, which the executor's root record names (lane B12) |
| Command | On the executor route the run's command is LGE's own command and the step's command is the reproducible argv with `-r`. Until a workflow moves there, its step records the argv that ran | The executor tool (section 7) |

A setting is explicit only when the user chose it. TaxTriage's launch passes no `--classifiers`, so its record keeps `classifiers` among the resolved defaults (decision R5).

A database status is one of three words. A digest LGE checked makes a database `pinned`. A database that no digest pins is `unpinned`, and `DatabaseIdentityStatus.status(ofRecordedWord:)` reads Kraken 2's word for the same fact, `unresolved-bounded-metadata`, as `unpinned`. A database the run fetched from a live source is `liveSnapshot`. Writers keep their words until a Preview ships the tolerant reader (decision R3). TaxTriage fetches its references from NCBI during a run and keeps `combine/<sample>.combined.gcfmap.tsv` for each sample, so the executor's root record names those files and the fetch date in its `liveSnapshot` entry (decision R4, lane B12).

Nextflow 25.04 starts its output with the banner `N E X T F L O W  ~  version 25.04.6`. Nextflow 26.04.6, as LGE launches it, prints the same banner as line 1 of its standard output, so the banner names the version for every workflow. A Nextflow that finds `NXF_AGENT_MODE`, `AGENT` or `CLAUDECODE` at `true` or `1` in its environment (`nextflow.SysEnv.isAgentMode`) prints an agent log with no banner and no `Launching` line instead, and a coding agent's shell sets `CLAUDECODE`. LGE's launch sets all three to `false` (`WorkflowEngineLaunch`), so a run started from an agent's shell prints what a run from the app prints. TaxTriage's workflow also prints the line `Nextflow version: 26.04.6` from `workflow.nextflow.version`, so a TaxTriage record names the engine that ran. The parser counts either line only at the start of a line, so a path or an argument in the preamble LGE writes above the engine's output never stands in. A new workflow needs no line of its own, because the banner names the Nextflow version its record keeps.

### Rules for a new workflow's record

| Rule | What it means |
|---|---|
| Lock pin | A run takes its repository from the lock, and its revision from the lock unless the user picks another (section 1). A lock with no pin refuses the run (decision N4). The record names the revision that ran, and the lock's tag only for the pin's own revision or that tag. No test asserts the lock's Nextflow version from a stand-in run, whose banner is the stand-in's own |
| No patch | LGE never edits a pipeline's code. Both launch sources run the code of the recorded revision, so `pipelineSource` says where the code came from and nothing more. The snapshot is a `git archive` of the revision, so a pin bump checks that the revision's `.gitattributes` holds no `export-ignore` or `export-subst` line, which would make the snapshot differ from the commit. A workflow that ever needs a patch records each patched file's SHA-256 before and after it |
| Pooled run | On the executor route (section 7) a plain `--output` runs every sample in one Nextflow run, and `--project` or `--batch` runs one per sample (Phase 2.9 decision T5). The two give the same reports today because no sample is a control. LGE writes no control column and passes neither `--negative` nor `--positive`, the options that name a control at TaxTriage's pinned commit. A run whose extra arguments name a control, and any workflow that scores samples against controls, needs a pooled run that holds those controls, and its record names every sample of the run |

## 5. The registry row and the words (U9)

A Nextflow workflow shows itself to a user in two places. The registry row names it once, and the Operations row is what the user watches while it runs. Every string of the Operations row spells the workflow's name as the registry row does, so a new workflow takes its words from one field. This section states the registry row's other fields, the words of the Operations row from its first detail to the closing line of the command, the rules those words follow, and what each of the four rows a user can start shows today. It rests on panel decisions N13, W1, W2 and W3 of the Phase 2.9 plan (`docs/plans/2026-10-12-phase-2-9.md`).

### The registry row's other fields

`AnalysisToolRegistry` holds one `AnalysisToolDescriptor` per analysis kind (`Sources/LungfishIO/Analysis/AnalysisToolRegistry.swift` and `AnalysisToolDescriptor.swift` beside it). Section 1 covers `runsTools` and `provisioning`, which the agreement test reads. The table lists them again so that one row shows a whole entry.

| Field | What it holds | TaxTriage | Viral Recon |
|---|---|---|---|
| `id` | The analysis kind, which the descriptor's `toolID` repeats | `.taxtriage` | `.viralrecon` |
| `displayName` | The workflow's name in every string a person reads, written `<W>` below | `TaxTriage` | `Viral Recon` |
| `sidebarSymbolName` | The sidebar symbol, or nil for the generic circle | `t.circle` | `v.circle` |
| `runsTools` | The managed tools the workflow launches, by lock id | `nextflow` | `nextflow` |
| `provisioning` | `.lockedPipeline` with the descriptor's `lockPipelineID` | `taxtriage` | `nf-core-viralrecon` |
| `classifierBatchBadge`, `buildDatabaseToken`, `outputStem` | The badge of a classifier batch, the word `lungfish-cli build-db` takes and the stem of an output name, each nil when the kind has none | `TT`, `taxtriage`, `taxtriage` | nil |

The display name is the only place that spells a workflow's name for a person. `NextflowWorkflowDescriptor.workflowName` reads it from this row, the refusal of section 1 puts it in its sentence, and the Operations row takes it as `<W>`. A string that spells the name itself drifts from the registry the first time the name changes, so no row string does.

### The Operations row and its words

The Operations row is the entry of `OperationCenter` that a launch begins and ends. The table sets a new workflow's words beside TaxTriage's. `<W>` is the display name above, `N` is a count, `<t>` is a runtime in seconds with one decimal, and `[s]` is the plural ending.

| Moment | TaxTriage today | A new workflow |
|---|---|---|
| Row title and first detail | `TaxTriage (N sample[s])`, `Starting TaxTriage pipeline…` | `<W> (N sample[s])`, `Starting <W>…` |
| Docker wait | `Docker daemon unavailable. Launching Docker Desktop...`, `Docker daemon ready`, `Starting the pipeline...`, and on a failure `Docker Desktop is not running or daemon is unreachable. Start Docker Desktop and retry.` | The same words, because the engine's one wait reports them for every workflow (section 3). A lane that rewords them does so for every workflow and both surfaces in one commit (decision E15 of Phase 2.7) |
| Before the engine | `Checking prerequisites...`, `Generating samplesheet...` | `Checking Nextflow and Docker…`, `Writing the samplesheet…` |
| A task | `Running <process> (<tag>)`, or `Running <process>` for a task with no tag, such as `Running KRAKEN2_KRAKEN2 (SRR12486989)` and `Running DOWNLOAD_TAXDUMP` | `Running <process> (<tag>)`, or `Running <process>` for a task with no tag, where `<process>` is the last part of the process name, such as `Running KRAKEN2_KRAKEN2 (SRR12486989)` and `Running DOWNLOAD_TAXDUMP` |
| After the engine | `Collecting output files...`, `TaxTriage pipeline complete` | `Collecting output files…`, `<W> complete` |
| Database | `Building TaxTriage database…` | `Building <W> database…`, on the last share of the bar |
| Ignored tasks | One warning line for all ignored tasks, `Some TaxTriage tasks failed` and one clause per failed process, then what is missing and what to change | One warning line for all ignored tasks, `Some <W> tasks failed` and one clause per failed process, and the row reads Completed with Warnings |
| Failure | The sheet `TaxTriage Failed` with the error as its text and no detail | The sheet `<W> Failed` with the error as its text and the log tail as its detail |
| Cancel | `Cancelling...`, then Cancelled with `Cancelled by user`, no sheet, and the overlay shows the row's own `Cancelling...` and takes no later engine line | The same, from `OperationCenter`, and the overlay shows the row's own `Cancelling...` and takes no later engine line |
| CLI closing line | `TaxTriage completed in <t>s` or `TaxTriage completed with warnings in <t>s` | `<W> completed in <t>s` or `<W> completed with warnings in <t>s` |
| Copy CLI Command | `--output` names the app's own folder, so a replay writes into it | The argv the row ran, with `--project`, so a replay makes a new folder |

The TaxTriage column is today's text. TaxTriage's strings stay as they are until a lane changes them on both routes (decision E15 of Phase 2.7), and that lane changes this table in the same commit. U10 changed the task line and the bar for both routes in its first milestone, through the engine's reader, which the app and `lungfish-cli taxtriage run` share. Its second milestone changed the app's overlay, which the command does not have, and its third changes the database's share of the bar.

A task line follows W1. The detail, the log and the overlay show `Running <process> (<tag>)`, or `Running <process>` for a task with no tag, and `nextflow.log` keeps the raw line byte for byte (decision N8). A real Nextflow 26.04 with `NXF_ANSI_LOG=false` prints one `[PROCESS <hash>] <process path>` line per task at submission, ending in ` (<tag>)` when the task has a tag, and no `process >` line and no `[100%]` line. Nextflow 25.04 printed `[<hash>] Submitted process > <process path>` in its place. `NextflowProgressReader` reads both forms and no other line, and `Tests/Fixtures/taxtriage-realrun-26.04.6` holds the lines and trace files of lane Q15's real runs that its tests read.

The bar follows W2 and W3. The engine takes `[0, 1 - s]` of the bar and the finalize phase, which builds the database, takes `[1 - s, 1]`, where `s` is the descriptor's `finalizeProgressShare`, 0.1 for TaxTriage. U10 applies the share to the app's route and A2 to the command's, and until they land the app holds the bar at 100 percent while the database builds. Inside its share the engine's bar counts the completed rows of `trace.txt` against `expectedTaskCountPerSample` times the samples, and a workflow whose descriptor holds no count keeps the engine's estimate of 15 tasks for the whole run. TaxTriage's count is 29, the tasks of a one-sample run in Q15's real runs, 17 of the sample's own and 12 for the whole run. The app launches one sample at a time, so its bar counts against the tasks each launch runs, and a pooled run of several samples on the command line counts against more tasks than it runs and ends its engine stage lower. The engine reads `trace.txt` every 5 s and once more when the engine has ended, and a reading that moves the bar shows the last task line again with it, which the app's log keeps once. A reading moves nothing until the engine has started a task, so a trace file an earlier run left in the folder never moves the bar. The bar never moves back (decision T9 of Phase 2.8), and it stays below `1 - s` until the engine exits, however many rows `trace.txt` holds, because the completed rows fill at most 0.95 of the engine's share. The decision assumed that Nextflow adds rows to `trace.txt` while a run is live, which lane Q15's runs could not show, since they read the file only after the engine ended. `TaxTriageProgressLiveConformanceTests` shows it on a real run of SRR12486989, where the bar left 0.10 about 7 s after the first task line and 114 s before the finish began, rose in steps of the 5 s readings between task lines, and reached 0.86 by the engine's end.

One Docker wait in the engine process serves every workflow that runs on Docker. A cancel ends it, and a failed attempt to open Docker Desktop fails the run at once (decision N9).

### Rules for the words

A new workflow's strings follow five rules.

1. `<W>` comes from the registry's display name and from nothing else.
2. A string of the workflow's own that names a step in progress ends with the ellipsis character `…`. A task line takes the form W1 sets, and the words every workflow shares, the Docker wait's and the center's `Cancelling...`, keep their three dots until a words lane changes them for every operation.
3. A task line names the process, and its tag when it has one, and never the raw Nextflow line.
4. A line that arrives once the row no longer runs reaches neither the detail nor the bar nor the overlay, and the log keeps it. From a cancel on, the overlay shows the row's own `Cancelling...`. `NextflowWorkflowRowPinTests` and `TaxTriagePipelineCancelReplayTests` pin both on the TaxTriage row, the second with a stand-in engine that prints its task lines inside the grace. The app's CLI route also keeps such a line off the overlay, which `CLIClassifierRunnerOverlayTests` pins, and the lane that moves TaxTriage onto that route makes its overlay show `Cancelling...` too.
5. Only the run's own outcome makes a warning line, one for all ignored tasks, one for failed samples, one for a failed database build, and one for each read pairing fallback, which the app logs after the run. These lines alone make the label Completed with Warnings. Docker lines and task lines are information lines, and the engine's standard error stays in `nextflow.log`, so no line of standard error makes the label. The Viral Recon row reads its CLI's events through `OperationCenterCLIBridge` and keeps standard error at info, and every line of the CLI's standard error still makes the label on the Local Workflow row. The row then completes plainly with a detail that names the causes, and that detail is logged as no second warning (decision D4 of Phase 2.8).

### What each row shows today

Four rows start a Nextflow workflow today, and they do not read alike. Only TaxTriage streams Nextflow's output into its row. Viral Recon's row does not move in Phase 2.9 (decision N13). S16 moves its runner onto `CLIProcessLauncher` with a 6 s grace and a bounded output tail (decision N14), so the pins named below land first and show any change to the row in a test diff.

| | TaxTriage | Viral Recon | Local Workflow | pbAA |
|---|---|---|---|---|
| Title | `TaxTriage (N sample[s])` | `Viral Recon` | `Local Workflow` | `pbAA Amplicon Clustering` |
| First detail | `Starting TaxTriage pipeline…` | `<platform> · N sample(s) · <reference>`, which the Docker wait's three lines replace when the run waits | `Running <engine> workflow` | `Preparing...` |
| Nextflow output in the row | Each task line becomes `Running <process> (<tag>)` in the detail, the log and the overlay, and the completed rows of `trace.txt` move the bar | Each line the CLI prints, read as `--format json` events. Nextflow's output streams into `logs/nextflow.log` while the engine runs, and only the outcome lines reach the row. The bar moves only for the Docker wait | None. The CLI writes Nextflow's output into the run bundle's logs folder, and the row logs the CLI's own lines after the run | Read after the run |
| Completed detail | The result's summary, one line per fact. When tasks were ignored or samples failed, the ignored tasks' headline, `N failed sample[s]` or both, separated by a semicolon, with `(N report[s])` after them | `Viral Recon completed. Output: <folder>. Run bundle: <bundle>` | `Local workflow completed. Run bundle: <bundle>` | Not pinned in Phase 2.9 |
| Warning lines | One for all ignored tasks, one for failed samples, and one when the database build fails | One for all ignored tasks and one for failed samples, the CLI's warning events, and one for each read pairing fallback, which the app logs after the run. Its stderr lines stay at info | Every stderr line, logged after the run | Not pinned in Phase 2.9 |
| Failure | The sheet `TaxTriage Failed` with the error as its text and no detail | `Viral Recon failed with exit code N`, then a period and the last 40 stderr lines when the CLI wrote any, as the detail, with the error `Viral Recon failed` and no sheet | `Local workflow failed with exit code N`, and the whole stderr as the error detail | Not pinned in Phase 2.9 |
| Cancel | `Cancelling...`, then `Cancelled by user` | The same words. The app gives the CLI SIGTERM and 6 s to stop Nextflow before SIGKILL (decision N14) | The same words, from a Cancel button that every run has, a first run as well as a replay. The CLI records the run as cancelled in its bundle (decision N14) | The engine's 4 s grace, which pbAA's own runner applies (section 3) |

A new workflow takes the right column of the Operations row table and not one of these four. Viral Recon's row waits for the move of its runner to the executor and the engine process (decisions N13 and X2), and pbAA takes the engine process as a later move (decision N15). The lane that moves pbAA pins its completed, failed and cancelled rows before it changes them.

### What holds this section

| Suite | What it pins |
|---|---|
| `Tests/LungfishAppTests/NextflowWorkflowRowPinTests.swift` | The title and first detail of each row above, Viral Recon's row for a launch, a clean end, stderr warning lines, a failure with its 40-line tail and a cancel, Local Workflow's first run with its Cancel and its end words |
| `Tests/LungfishAppTests/ViralReconWorkflowProcessRunnerTests.swift` | The runner behind the Viral Recon and Local Workflow rows, the 6 s a cancel gives the CLI before SIGKILL, a cancel before the launch, the exit code and both streams, the last 4 MiB of each stream, and the warning line for output a child kept open |
| `Tests/LungfishAppTests/TaxTriagePipelineCancelReplayTests.swift` | On the stand-in engine, that a cancel of the pipeline or of a serial batch stops the whole engine tree before the run returns and records the cancel |
| `Tests/LungfishAppTests/CLIClassifierRunnerOverlayTests.swift` | That the app's CLI route shows no line on the overlay once the row is cancelling |
| `Tests/LungfishWorkflowTests/Nextflow/NextflowProgressReaderTests.swift` | The task line's words and the bar on the standard output and `trace.txt` of Q15's real runs |
| `Tests/LungfishWorkflowTests/TaxTriageProgressLiveConformanceTests.swift` | On a real run, with the live switch on, that the bar leaves 0.10 while the engine runs, never moves back and reaches the engine's stop by its end |
| `Tests/LungfishAppTests/TaxTriageCLIRouteRowTests.swift` | TaxTriage's clean, ignored task, failed sample, failed database, failed and cancelled rows on the CLI route, on transcripts of `taxtriage run` |
| `Tests/LungfishAppTests/ViralReconWorkflowExecutionServiceOperationTests.swift` | Viral Recon's recorded row, its bundle lock and its command |
| `Tests/LungfishCLITests/TaxTriageRunTextOutputTests.swift` | The last progress line and the closing line of `taxtriage run`, for a clean run and for a run that ignored errored tasks |

A new workflow adds a row test in the shape of `NextflowWorkflowRowPinTests` on the stand-in of section 6, and a CLI test in the shape of `TaxTriageRunTextOutputTests`, before it changes a word.

## 6. The stand-in for tests (Q9)

## 7. The executor tool (A2)

A workflow runs from the command line as an `AnalysisRunTool` under the analysis run executor, the way Kraken2 and EsViritu run. TaxTriage's tool is `TaxTriageAnalysisRunTool` in `Sources/LungfishWorkflow/TaxTriage/TaxTriageAnalysisRunTool.swift`, with its unit in `TaxTriageAnalysisRunTool+Unit.swift` and its finalize in `TaxTriageAnalysisRunTool+Finalize.swift`. `lungfish-cli taxtriage run` runs it (`Sources/LungfishCLI/Commands/TaxTriageCommand+Run.swift`), and the app's TaxTriage launch keeps its in-process route until Phase 2.10. The types take `package` access, so the module map gains no public type. The tool's identity is the kind `taxtriage` with the workflow name `lungfish.taxtriage.run`, which the root record names.

| Part | What it holds |
|---|---|
| `TaxTriageRunRequest` | The options of one command as given, with the usage conflict the command found, in `TaxTriageRunRequest.swift` |
| `TaxTriageRunServices` | What the tool calls out to, the pipeline factory, the folder expansion, the materializer, the lock, the cancel check and the text presentation. A test swaps any of them |
| `plan` | Phase P0. Every refusal before any folder exists, then the layout and the units |
| The unit | One launch through the shared pipeline body, `TaxTriagePipeline.run`, on the engine of section 3 |
| `finalize` | Phase P3. The run-level outputs and the viewer index, at the descriptor's `finalizeProgressShare` of the bar |

### The plan

The plan writes nothing. It reads TaxTriage's pin from the lock its services hold through `NextflowWorkflowDescriptor.taxTriage.resolvePin(in:)`, so a lock with no usable pin refuses the run with exit 126 and no fallback revision reaches a unit (decision N4). A blank `--revision` is refused, and a given one replaces the pin's revision. The plan resolves the samples with the refusals `taxtriage run` has always made. An `--input` folder whose loose files hold mates is refused with `The folder <folder> holds paired reads, such as <R1 file> and <R2 file>. Use --samplesheet to pair them.` (decision T8), because the folder route would run each mate as a sample of its own.

The plan lays the run out by decision T5, which keeps decisions T2 and T4 of Phase 2.8.

| Request | Layout | Units |
|---|---|---|
| `--output` | `.singleFolder` | One launch of every sample, pooled |
| `--project` with one sample | `.sharedBatchRoot` | One launch that writes into `taxtriage-batch-<timestamp>` itself |
| `--project` with several samples, or `--batch` | `.batchRoot` | One launch per sample, each in a folder that `AnalysesFolder.batchSampleDirectory(named:in:)` names |

A sample keeps the name its user gave it in the samplesheet, and only its folder takes the sanitized name, so `S.1`, `S 1` and `S__1` run in `S_1`, `S_1-2` and `S_1-3` (decision T9). A failed sample of a batch is a warning while another sample completes (`warnOnFailedUnits`), and a run of one launch fails with its launch.

### The finalize

A batch root names each completed sample's outputs with the digest and size its sample's record took, and hashes nothing again. A result in a project or a batch root then gets `taxtriage.sqlite` in process, through the index builder the executor was given. `lungfish-cli` gives `TaxTriageResultIndexer` (`Sources/LungfishCLI/Commands/TaxTriageCommand+Index.swift`), which runs the core of `build-db taxtriage` (`BuildDbCommand+TaxTriageCore.swift`) with the recorded cleanup. That cleanup is one removal step before the root record. It skips symbolic links, keeps `top/` and hashes no file it removes. It names each removed file that a record names, with the digest and size that record holds, from the sample's own record, the steps the units handed to the root record or the build's own record, and leaves out a file that no record names (decision T5 as amended in Phase 2.9, row 258 of the Phase 2.8 plan). The run level then names only kept files. A plain `--output` keeps its folder as the command has always left it, with no index and no cleanup, as a Kraken2 result outside a project does. An index that cannot be built leaves a warning and the result, since the viewer builds the index when the result opens. The bar reads `Building TaxTriage database…` from 0.9 to the end.

### The command

| End | Exit code |
|---|---|
| A refusal of the request | 3 |
| A failure after the plan, the pipeline's included | 64, `AnalysisRunExitCode.workflowError` |
| A cancel | 125 |
| A lock with no usable pin | 126 |

A SIGTERM cancels the run, so the run records `cancelled`, settles its folder and exits 125 inside the 6 s grace the app's transport gives a command (lane S2). A second SIGTERM ends the process at once. `--format json` writes the executor's events, the leaf of `taxtriage run` in `Sources/LungfishWorkflow/CLIEvents/CLIEventContract.swift`. The run level of the root record names the `taxtriage run` command as it was typed, with or without the word `run`, and the `taxtriage` step names the reproducible Nextflow argv with `-r` (section 4).

### What holds this section

| Suite | What it pins |
|---|---|
| `Tests/LungfishWorkflowTests/TaxTriageAnalysisRunToolPlanTests.swift` | The refusals with their words and codes, the pin and the layout of every request |
| `Tests/LungfishAppTests/TaxTriageAnalysisRunToolReplayTests.swift` | Units and the finalize on the stand-in engine |
| `Tests/LungfishAppTests/TaxTriageRunCommandReplayTests.swift` | The command on the executor, its folders, records and exit codes |
| `Tests/LungfishAppTests/TaxTriageRunSIGTERMReplayTests.swift` | The cancel, exit 125 and a `cancelled` record inside 6 s |
| `Tests/LungfishCLITests/BuildDbTaxTriageIndexTests.swift` | The index over the core, the recorded removal step that keeps `top/` and names each removed file with the digest its record holds, and the order of a batch's samples |
| `Tests/LungfishWorkflowTests/AnalysisRun/AnalysisRunExecutorTests.swift` | The finalize's share of the bar |
| `Tests/LungfishAppTests/TaxTriageCLIGUIParityReplayTests.swift` | The app's route against its recorded command (side B), the routed `--project` command through the built `lungfish-cli` (side C) and the argv side C's record names (side C'). C against C' declares nothing |

## 8. Adding a workflow, step by step (A2)

Each step names the section that states its rules.

| Step | What to add | Section |
|---|---|---|
| 1 | The pin in the managed tool lock, `Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json`, with its repository, commit and release tag, and the row in `AnalysisToolRegistry` provisioned as `.lockedPipeline` | 1 and 5 |
| 2 | The `NextflowWorkflowDescriptor` value in a file of its own, `Sources/LungfishWorkflow/Nextflow/NextflowWorkflowDescriptor+<Name>.swift`, with every field stated, and a fit test against today's launch when LGE launches the workflow already, as `NextflowViralReconFitTests` does | 1 |
| 3 | The samplesheet builder in `Sources/LungfishWorkflow/Nextflow/` with a test that pins the sheet's bytes | 2 |
| 4 | The launch through `NextflowEngineProcess` with the descriptor's `engineConfiguration(profile:)`, and never a launch of its own | 3 |
| 5 | Each Nextflow step recorded with `NextflowRecordFacts` | 4 |
| 6 | The words of the registry row | 5 |
| 7 | A `NextflowStandInWorkflow`, so the workflow's tests run on the stand-in engine, and a live class that the conformance tier runs | 6 |
| 8 | The executor tool, with a request, services, a plan that refuses before any folder exists, a unit on the shared pipeline body and a finalize, as `TaxTriageAnalysisRunTool` has them. Its command takes the exit codes of section 7, ends a SIGTERM in a `cancelled` record with exit 125 and has an events leaf in `CLIEventContract.swift` | 7 |
| 9 | Tests of the tool's plan, its command and its cancel in the shape section 7 lists, and, when the app runs the workflow, a parity class whose sides compare the app's route with the command it records | 7 |
| 10 | A note to the manager of the public types and folders the change adds, so the module map is regenerated, and the tables of this contract brought up to date | all |
