# Running a tool

This contract says how Lungfish Genome Explorer (LGE) code launches an external program. Every launch goes through one primitive, `ToolProcess` in `Sources/LungfishCore/Process/ToolProcess.swift`, either directly or through one of four adapters. Before Phase 2.2 each runner had its own pipe handling, its own timeout and its own way of stopping a tree, so a tool that wrote more than 64 KB could deadlock one runner and a cancelled Nextflow left its JVM running. This is review finding R7.

## Which entry point to use

Pick the first row that fits. Each adapter keeps its public API and builds a `ToolProcessSpec` underneath.

| You need to run | Use | Where |
|---|---|---|
| A managed bioinformatics tool such as samtools, bcftools, fastp, BBTools or vsearch | `NativeToolRunner.run`, `runProcess`, `runWithFileOutput` or `runPipeline` | `Sources/LungfishWorkflow/Native/NativeToolRunner.swift`, with the translation in `Sources/LungfishWorkflow/Native/NativeToolRunner+ToolProcess.swift` |
| A tool that lives in a conda environment such as kraken2, bowtie2, minimap2, Flye or SPAdes | `CondaManager.runTool` | `Sources/LungfishWorkflow/Conda/CondaManager.swift`, with the shared helpers in `CondaFamilyProcess` |
| A long-running engine whose lines you stream to a log, such as Nextflow or Snakemake | `ProcessManager.spawn` for a handle, or `ProcessManager.runAndWait` to wait | `Sources/LungfishWorkflow/ProcessManager.swift` |
| `lungfish-cli` from the app or Kit | `CLIProcessLauncher.spec` and `CLIProcessLauncher.run`, through `CLISubprocessTransport` or a `CLI*Runner` | `Sources/LungfishKit/CLIProcessLauncher.swift`, `Sources/LungfishKit/CLIRunCancellation.swift`, `Sources/LungfishKit/CLISubprocessTransport.swift` |
| Anything else, including system tools such as gzip and code in LungfishCore or LungfishIO | `ToolProcess` directly | `ToolProcess.run` when you can `await`, `ToolProcess.start` for a handle or a raw stdout stream, `ToolProcess.runBlocking` from synchronous code, `ToolProcess.runPipeline` for stages joined stdout to stdin |

A managed tool is resolved by `NativeToolRunner` or `CondaManager` and never by a path you build. The versions are pinned in `Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json`. The GUI does not call any of these in process for an operation. It runs the `lungfish-cli` command (see `docs/contracts/ADDING-AN-OPERATION.md`).

## What the primitive guarantees

Every run, from any entry point, keeps these guarantees. Do not rebuild one of them in a caller.

| Guarantee | What it means for you |
|---|---|
| Spawned with posix_spawn | The process leads its own process group, has only stdin, stdout and stderr open, default signal dispositions and an empty signal mask. A tool never inherits the app's descriptors or a blocked SIGPIPE. |
| Stdin is `/dev/null` by default | A tool that reads stdin gets end of file and never waits on a terminal. Use `.file` or `.data` on the spec to feed it. |
| The environment is complete | `ToolProcessSpec.environment` is the whole environment. Nothing is inherited unless you add it, for example with `ToolProcessSpec.inheritedEnvironment(overriding:)`. |
| Both streams are drained while the process runs | A tool that writes more than the 64 KB pipe buffer to stdout, stderr or both cannot block on a full pipe. |
| Incomplete output is a failure | If a descendant keeps a stream open after the root exits, or a read fails, the result sets `outputDrainTimedOut` or `outputReadFailed`. `isSuccess` is then false even after exit code 0. `incompleteOutputReason` is the one sentence every adapter shows. |
| A nonzero exit is a result | `ToolProcessResult.termination` carries the code or the signal. Only an invalid spec, a launch failure, a timeout or a cancellation throws a `ToolProcessError`. |
| Cancel kills the group and the tree | Cancelling the task, calling `ToolProcessRun.cancel()`, or firing a `ToolProcessCancellation` sends SIGTERM to the process group and every descendant, then SIGKILL after `terminationGracePeriod` (500 ms by default). A JVM under a wrapper script does not survive. |
| Wall and idle limits | `timeout` and `idleTimeout` run on the suspending clock, so time the Mac spends asleep does not count. An idle limit needs a captured stream. |
| Exit status is the shell's | `exit(-1)` reads 255, as `wait(2)` and every shell report it. |
| Drain grace of 5 seconds | After the root exits, captured streams get `drainGracePeriod` (`ToolProcessSpec.defaultDrainGracePeriod`) to reach end of file. Descendants still running then get SIGTERM and SIGKILL. |
| Stderr keeps its last 4 MB | `ToolProcessSpec.defaultStderrCaptureLimit` bounds memory for a run that logs for hours, and `stderrTruncated` says when it cut. Set your own `.capture(limit:)` to parse more. |
| Lines are framed at 64 KB | `ProcessOutputLineFramer` ends a line at LF, CRLF or a lone CR and cuts a line longer than `maxLineBytes`. Raise `maxLineBytes` for JSON event streams, as `CLIProcessLauncher.maxEventLineBytes` does. |
| Raw bytes with backpressure | A spec with `stdout: .stream` on `ToolProcess.start` hands you `ToolProcessRun.stdout`. The bytes keep every CR, no line is cut, and the pipe holds the process back when you read slower than it writes. |
| Registered for app quit | Every running process is in `NativeProcessRegistry`, so quitting the app reaches it. |

## Pipelines

`ToolProcess.runPipeline` joins stages stdout to stdin, as `samtools view | samtools sort` does. The first stage reads its own stdin, the last writes its own stdout, and every stage keeps its own stderr. The pipeline limits cover all stages, so a stage's own `timeout` must stay nil.

| `ToolPipelineFailurePolicy` | Behavior | Who uses it |
|---|---|---|
| `stopAllOnFailure` (the default) | The first stage to exit nonzero or die by a signal stops the rest, as `pipefail` would. A stage killed by SIGPIPE does not count when the stage it fed finished cleanly. | New code |
| `runToCompletion` | Every stage runs to its own end and reports its own exit code and stderr. | `NativeToolRunner.runPipeline` and the pipe in `AlignmentDataProvider` |

`NativeToolRunner` and `AlignmentDataProvider` use `runToCompletion` because their callers read each stage's exit code and stderr to build the message the user sees. A stage stopped by the policy would report the SIGTERM it was sent and hide the real failure. The tool goldens `pipeline-samtools-missing-input` and `pipeline-mpileup-ivar-truncated-bam` pin the exit code of each stage.

## Rules

| Rule | Why |
|---|---|
| Never create `Process()` or call `.terminate()` outside `Sources/LungfishCore/Process/` | `scripts/ratchets/process-spawn.sh` counts both and fails the pre-push hook when a count rises. A raw `Process` leaves its descendants running on cancel and reads its pipes in ways that deadlock. The recorded baseline in `scripts/ratchets/process-spawn.baseline` only falls. |
| Never read a pipe after the process exits | A descendant can still hold the write end, and a tool that wrote more than 64 KB blocks until someone reads. `ToolProcess` reads from launch to end of file. |
| Never block a thread on a semaphore waiting for a `Task` | A blocked cooperative thread starves the pool the task needs, and the pair deadlocks. A synchronous caller uses `ToolProcess.runBlocking`, which needs no Swift task. An async caller uses `ToolProcess.run`. Never call `runBlocking` on the main thread. |
| Parse stdout from bytes or streamed stdout, never from line events | Lines are cut at `maxLineBytes` and a lone CR becomes a line break. Use `ToolProcessResult.stdout` or `ToolProcessOutput.stream` for BAM text, VCF records and JSON. Line events are for progress and logs. |
| Check `isSuccess`, not only the exit code | A clean exit with a lingering descendant is not a success. Map `incompleteOutputReason` into your error type, as `NativeToolProcessAdapter.requireCompleteOutput` does. |
| Register the process with the caller's cancellation | Pass the task's cancellation through `ToolProcess.run`, keep the `ToolProcessRun` from `start`, or give `runBlocking` a `ToolProcessCancellation`. A cancel that only signals a pid skips the descendants. |

## Signals in the CLI

`lungfish-cli` calls `CLITerminationSignals.install()` from `LungfishCLIMain` in `Sources/LungfishCLI/LungfishCLI.swift`. The code is in `Sources/LungfishCLI/Support/CLITerminationSignals.swift`.

| Situation | What happens |
|---|---|
| SIGINT, SIGTERM or SIGHUP reaches any command | Every tree in `NativeProcessRegistry` stops, with 2 seconds between SIGTERM and SIGKILL. The CLI then gives the signal its default action and sends it again, so a shell sees the signal as the cause. |
| A second signal arrives while the tools stop | The CLI ends at once. |
| `import fastq` or `workflow run` receives the first SIGTERM | `SIGTERMCancellation` in `Sources/LungfishCLI/Support/SIGTERMCancellation.swift` turns it into task cancellation, which reaches `ToolProcess`. The command runs its own cleanup, removes partial output and exits. |
| A cancelled `workflow run` ends | It exits 125, `CLIExitCode.cancelled`, after writing "Workflow cancelled" to stderr. A cancelled `import fastq` exits 125 as well. |

The app's Cancel button sends SIGTERM to `lungfish-cli` through `CLIRunCancellation`, which keeps the `ToolProcessRun` and cancels it from any thread without waiting behind an actor.

## Adding a managed tool

A managed tool is an entry of the lock. Its identity is a `ManagedToolID` (`Sources/LungfishIO/Analysis/ToolIdentity.swift`), the entry's `id` in `tools` or `packTools`. This is review finding R2. The lock is the one place provisioning facts live. Presentation facts live in the IO registry (see `docs/contracts/ADDING-AN-ANALYSIS-SURFACE.md`), and probe facts live in one Workflow table keyed by the lock id. Do these in one change.

| Step | What to do | What fails until you do it |
|---|---|---|
| 1. Lock entry | Add the entry to `Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json` in the byte form `scripts/deps/manifest_io.py` writes, and list every executable the entry installs. Add the package to the pack in `Sources/LungfishWorkflow/Conda/PluginPack.swift` when it is a pack tool. A new entry changes `manifestHash` and the lock file SHA-256, so it ships as a deliberate dependency-set change. | `PackToolManifestConsistencyTests` |
| 2. Probe table entry | Add one `entry(...)` to the table in `Sources/LungfishWorkflow/Dependencies/ManagedToolVersionProbe.swift` with the executable, the arguments and the dialect. The executable must be one the lock entry declares. Say in a comment what the real output looks like when the tool is odd, such as a flag that errors or a version printed after a path. Parsing stays in the production parsers for now. | `ManagedToolVersionProbeTableTests` |
| 3. `NativeTool` case | Only when the tool runs through `NativeToolRunner`. Add the case with its location, its `managedToolID` arm in `Sources/LungfishWorkflow/Native/NativeTool+ManagedTool.swift` (the switch has no default, so it does not compile without one) and its `nativeToolPolicies` entry in `ScientificProvenancePolicy.swift`. The version arguments come from the probe table. | `ToolRegistryAgreementTests`, the compiler and the policy coverage test |
| 4. Analysis kind | Only when the tool produces a new kind of result. Follow `docs/contracts/ADDING-AN-ANALYSIS-SURFACE.md` and link the descriptor to the lock id with `.managedTool(ManagedToolID(rawValue: "<lock id>"))`. | `ToolRegistryAgreementTests` |
| 5. Golden | Capture the tool's output as the next section says. | `ToolOutputGoldenTests` |

Two id spaces meet here and they are not the same set. An `AnalysisToolID` names a result type (`bbmap`, `viralrecon`) and a `ManagedToolID` names a lock entry (`bbtools`). The Viral Recon pipeline entry `nf-core-viralrecon` is a pipeline id and not a `ManagedToolID`. The two sets share 12 strings and differ for the rest, so a string typed as one never stands in for the other. The agreement test joins the two sets, and a descriptor that names a lock id that does not exist fails it.

Look a lock entry up with `ManagedToolLock.entry(id:)` or `entry(environment:)`, which search `tools` and then `packTools`. `ManagedToolLock.tool(named:)` searches `tools` only, so it cannot see a pack tool such as `primalscheme3`. Callers of the old lookup move in 2.6, and `scripts/ratchets/tool-identity.sh` fails the push when their count rises.

### Which hash is which

| Name | What it hashes | Who uses it |
|---|---|---|
| `ManagedToolLock.manifestHash` | The lock decoded and re-encoded with sorted keys | Receipts, the launch fast path, Debug to Preview tool sharing and two Python copies of the rule in the release tooling |
| `ManagedToolLockIdentity.fileSHA256` | The exact bytes of the bundled lock file, from the same read that decodes `ManagedToolLock.bundled` | Nothing records it yet. 2.6 writes it into run records (`docs/contracts/RECORDING-PROVENANCE.md`) |

A whitespace edit to the lock changes the second and leaves the first. The identity is nil when the file cannot be read, never the hash of empty data.

### Checking the probes against a real root

The unit tier checks the tables against the lock and runs no tool. `ToolVersionConformanceTests` runs every probe against installed tools. It needs `LUNGFISH_STORAGE_ROOT` pointing at a root that holds every environment, including every plugin pack. Run `LUNGFISH_REQUIRE_TOOLS=1 LUNGFISH_STORAGE_ROOT=$HOME/.lungfish swift test --skip-update --filter ToolVersionConformanceTests` on a Mac that has them. Under `LUNGFISH_REQUIRE_TOOLS=1` a missing probe executable in an environment that exists fails the test, and without it the test skips and names what drifted. Classify drift with `lungfish-cli tools update --plan --storage-root <root>` and do not fix it with `--apply` while testing. A conda probe repairs launchers in that root first.

## How to test a new tool

A tool is not done until its output is pinned on this Mac. The goldens live in `Tests/Fixtures/golden/tools/`, and `Tests/Fixtures/golden/tools/README.md` explains the format.

1. Add a row to the case table in `Tests/LungfishWorkflowTests/ToolGoldens/ToolGoldenCases+Native.swift` for a `NativeToolRunner` tool or `ToolGoldenCases+Conda.swift` for a conda tool. Give it a stable ID, a small fixture, the runner call and the items to compare. A tool that runs in seconds gets stdout, exit code and output files, a case with stdout over 64 KB if it can produce one, and an error-exit case. A heavy tool such as Flye or hifiasm gets its exit code, its version and one error path.
2. Add the matching test method in `Tests/LungfishWorkflowTests/ToolGoldens/ToolOutputGoldenTests.swift`. `testCaseTableHasUniqueIDsATestPerCaseAndNoStaleGolden` fails until the table and the methods agree.
3. Capture with `LUNGFISH_STORAGE_ROOT=$HOME/.lungfish LUNGFISH_CAPTURE_TOOL_GOLDENS=1 swift test --skip-update --build-system swiftbuild --filter ToolOutputGoldenTests/test_<case>`. Capture runs the case twice and writes it only when both runs match. Remove run-to-run variation with an argv choice such as `--no-PG` or one thread. Add a mask only when no argv choice removes the variation.
4. Commit the new folder with a message that says which cases changed and why.
5. Run the compare with `LUNGFISH_REQUIRE_TOOLS=1` before release, so a missing tool fails and never skips quietly.

`ToolOutputGoldenTests` belongs to the conformance tier through `CONFORMANCE_FILTER` in `scripts/full-suite-gate.sh` and the matching entry in `config/test-catalog.json`. A new test class that runs a real tool is added to both. Tests of the primitive itself are `ToolProcessTests` and its siblings in `Tests/LungfishCoreTests/`. A new adapter behavior gets a red test there first, for example a tool writing more than 64 KB to both streams.

## Known limits

| Limit | Detail |
|---|---|
| A descendant that leaves the process group escapes cancellation | `ProcessTreeTerminator` walks the descendant tree as well as the group, which covers a JVM or a Python worker. A daemon that calls `setsid` and reparents to launchd is out of reach. The drain grace bounds the wait, and `outputDrainTimedOut` says the run lost output. |
| Close-on-exec has a window until the remaining spawns migrate | `ToolProcess` spawns with `POSIX_SPAWN_CLOEXEC_DEFAULT` and marks its pipe ends close-on-exec right after `pipe()` returns. A raw `Foundation.Process` that one of the sites the ratchet still counts launches in that instant can inherit a pipe end and hold it open past the drain grace. The window closes as those sites move onto `ToolProcess`. |
| The genotyping pipe has no stdin writer | The minimap2 to samtools pipe in `ONTBarcodeDemuxGenotypingPipeline` runs through `ToolProcess.runPipeline`. A stage that must be fed bytes from Swift while it runs has no entry point yet. |
| Events are one at a time | An `onEvent` handler must return promptly, because output is not read while it runs. Hand slow work to a queue. |

Provenance is separate. A run records its argv and tool versions through `ProvenanceEnvelope`, and `ToolProcess` does not write provenance. A provenance observer hook on the primitive is planned for sub-phase 2.7, where the run executor and the recorder rebuilt on `ProvenanceRunBuilder` consume it. `docs/contracts/RECORDING-PROVENANCE.md` holds the contract for the hook.
