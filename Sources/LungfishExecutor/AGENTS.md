# LungfishExecutor

Line numbers were checked at commit 3cee435e3. When a line has moved, search for the named symbol.

## Purpose

`lungfish-executor`, the static Linux program that runs one sample's plan on a Linux machine such as a CHTC node. It is the executable product `lungfish-executor` of `Package.swift`, built for macOS and for static Linux (musl) with the swift.org toolchain and the Static Linux SDK. It reads an `ExecutionPlan` from LungfishPortable, starts the plan's tools through its own POSIX launcher, and writes one `run-record.json`. The commands are `run --plan`, `step`, `read-fastq`, `image-manifest`, three probe modes and a bare probe that prints the version and a SHA-256. CLungfishExecutor, in Sources/CLungfishExecutor, is its C wrapper of the Linux child subreaper call. Nothing in the app stack imports this module, and no target but LungfishExecutorTests depends on it.

## Allowed imports

Foundation, Dispatch, Synchronization and LungfishPortable. Glibc, Musl and Darwin only inside `#if` blocks. CLungfishExecutor only in Sources/LungfishExecutor/Process/ChildSubreaper.swift. Never another Lungfish module. The forbidden imports and tokens of LungfishPortable apply here too, and `scripts/ratchets/portable-imports.sh` counts them over this folder as well. The executor resolves every path under the plan file's folder, and HTCondor facts reach its run record only as `--site-fact` arguments, so it reads no scheduler variable and no file a scheduler names.

## Entry points

| Type | Path |
|---|---|
| `main.swift`, which blocks SIGTERM, SIGINT and SIGHUP first and then dispatches `step`, `run`, `read-fastq`, `image-manifest`, the probe modes and the bare probe | Sources/LungfishExecutor/main.swift line 5 |
| `RunCommand`, `run --plan <file> [--image-manifest <absolute file>] [--site-fact KEY=VALUE]...` | Sources/LungfishExecutor/RunCommand.swift line 35 |
| `StepCommand`, `step`, one tool run under the launcher with its record | Sources/LungfishExecutor/StepCommand.swift line 11 |
| `ReadCommand`, `read-fastq`, one FASTQ read through the portable reader and the launcher | Sources/LungfishExecutor/ReadCommand.swift line 25 |
| `ImageManifestCommand`, `image-manifest`, the tool manifest of conda environments | Sources/LungfishExecutor/ImageManifestCommand.swift line 25 |
| `ExecutorCommand`, the bare probe `lungfish-executor [--version] [<file>]` | Sources/LungfishExecutor/ExecutorCommand.swift line 9 |
| `PlanRunner`, which runs a checked plan's steps in order through one `StepController` and fills the run record | Sources/LungfishExecutor/Run/PlanRunner.swift line 18 |
| `RunFiles` (line 17) and `RuntimeObservation` (line 128), the files `run --plan` reads before any tool and what it observes of the machine | Sources/LungfishExecutor/Run/RunPreflight.swift |
| `RunRecordWriter`, which writes `run-record.json` last by one rename | Sources/LungfishExecutor/Run/RunRecordWriter.swift line 18 |
| `ExecutorToolLauncher`, the storage step's `PortableToolLauncher` on the node | Sources/LungfishExecutor/Run/ExecutorToolLauncher.swift line 17 |
| `ExecutorChildLauncher`, the `PortableChildLauncher` for the portable readers | Sources/LungfishExecutor/Process/ExecutorChildLauncher.swift line 59 |
| `ExecutorSpawn`, the posix_spawn calls, descriptor hygiene and exit observation of the launcher | Sources/LungfishExecutor/Process/ExecutorSpawn.swift line 34 |
| `StepController`, which runs one tool to its end with the wait thread, the cancel path, the grace and the sweep | Sources/LungfishExecutor/Process/StepController.swift line 69 |
| `ExecutorSignals`, SIGTERM, SIGINT and SIGHUP, and SIGPIPE for the whole process | Sources/LungfishExecutor/Process/ExecutorSignals.swift line 23 |
| `ProcessTable`, the process table and the walk of descendants, from /proc on Linux and libproc on macOS parity runs | Sources/LungfishExecutor/Process/ProcessTable.swift line 30 |
| `ProcessProbes`, three probe modes that need no tool image, so the same tests run on macOS, in the Linux tier and on a CHTC node | Sources/LungfishExecutor/Process/ProcessProbes.swift line 23 |
| `ChildSubreaper`, the one Swift caller of CLungfishExecutor | Sources/LungfishExecutor/Process/ChildSubreaper.swift line 14 |
| The C wrapper of the child subreaper call | Sources/CLungfishExecutor/ChildSubreaper.c and Sources/CLungfishExecutor/include/CLungfishExecutor.h |

## Contracts this module owns

- The launch exception. Every launch from the app, from `lungfish-cli` and from a Mac module still goes through `ToolProcess` in Sources/LungfishCore/Process/ToolProcess.swift. The launcher in `Sources/LungfishExecutor/Process/` is the one exception, because `ToolProcess` does not build on Linux. The exemption is written in `scripts/ratchets/process-spawn.baseline` lines 1 to 4. All three counts skip `Sources/LungfishCore/Process/`, and `raw_posix_spawn_calls` also skips `Sources/LungfishExecutor/Process/`, so this launcher holds the only raw `posix_spawn` allowed outside Core. The baseline of each count is 0. The binary also builds and runs on the Mac, for tests and parity runs, with the same launcher.
- The guarantee table. `docs/contracts/RUNNING-A-TOOL.md`, in its section The Linux executor's launcher, lists the 15 guarantees of `ToolProcess` and says for each whether the launcher keeps it, changes it or does not need it, with the test that pins it. A change to the launcher or to a `ToolProcess` guarantee updates that table in the same commit.
- The launcher belongs to this executor alone. The Rules table of the same contract says no target but its tests depends on it, and `executor_dependents` in `scripts/ratchets/portable-imports.sh` is 0. No other target lists LungfishExecutor, no product but `lungfish-executor` names it, and no Swift file outside Sources/LungfishExecutor/ and Tests/LungfishExecutorTests/ imports it.
- The C wrapper. Sources/CLungfishExecutor holds ChildSubreaper.c and include/CLungfishExecutor.h and nothing else. The header declares only `lungfish_set_child_subreaper` and `lungfish_get_child_subreaper`, the manifest call carries only a name and a path, only LungfishExecutor lists the target, and only Sources/LungfishExecutor/Process/ChildSubreaper.swift imports it. `portable-imports.sh` fails when any of these changes.
- The run record. `RunRecordWriter` writes `run-record.json` last by one rename, and the exit codes come from `ExecutorExitCode` in LungfishPortable.

## Tests

Target LungfishExecutorTests in Tests/LungfishExecutorTests, 20 files. Run only it with `swift test --skip-update --filter LungfishExecutorTests`. The launcher tests start the built `lungfish-executor` as a child.

`bash scripts/linux/portable-tier.sh` runs the target on glibc in an arm64 Swift container, with the network closed under Docker and kept under Apple container. The container builds the product first and names it to the tests through `LUNGFISH_EXECUTOR_BINARY`. The tier then runs ExecutorSignalTests, ExecutorLaunchTests, ExecutorReaderTests, RunPlanTests and ImageManifestCommandTests again against the static musl binary that ships. The reader tests need a pigz, which the tier unpacks from a package pinned in scripts/linux/toolchain.json and passes as `LUNGFISH_PIGZ` with `LUNGFISH_REQUIRE_TOOLS=1`. The tier's evidence counts only when the last line of its output reads `commit <sha> clean`.

## Known traps

| Trap | Evidence |
|---|---|
| A raw `posix_spawn` outside `Sources/LungfishExecutor/Process/` and `Sources/LungfishCore/Process/` raises `raw_posix_spawn_calls`, and a Mac module that calls into this launcher breaks the rule that every Mac launch goes through `ToolProcess` | scripts/ratchets/process-spawn.baseline lines 1 to 4, docs/contracts/RUNNING-A-TOOL.md Rules table |
| Cancel is not the `ToolProcess` cancel. The grace is the plan's (30 seconds by default, refused above 120) and the walk finds descendants through `/proc/<pid>/stat`, which works because the executor is a child subreaper on Linux | docs/contracts/RUNNING-A-TOOL.md, executor table, row Cancel kills the group and the tree |
| SIGTERM, SIGINT and SIGHUP are blocked by the first statement of `main.swift`, before any thread exists, and SIGPIPE is ignored for the whole process in place of `F_SETNOSIGPIPE` | Sources/LungfishExecutor/main.swift lines 3 to 5, docs/contracts/RUNNING-A-TOOL.md executor table row Raw bytes with backpressure |
| `run --plan` hands each step a descriptor from `PlanResourceResolver.openOutput`, but `lungfish-executor step` still opens its `--stdout` and `--stderr` files by path in `ExecutorSpawn.openDescriptor` | docs/contracts/RUNNING-A-TOOL.md executor table row Output into a descriptor you own |
| Spawn hygiene is a sweep of `/proc/self/fd` at start and one spawn lock, in place of `POSIX_SPAWN_CLOEXEC_DEFAULT` and `pipe2(O_CLOEXEC)`, which macOS offers only from version 27 | docs/contracts/RUNNING-A-TOOL.md executor table row Spawned with posix_spawn |
| A scheduler word or variable in a code line raises `forbidden_tokens`, and HTCondor facts arrive only as `--site-fact KEY=VALUE` arguments | scripts/ratchets/portable-imports.sh lines 4 to 8 and 52 to 55, Sources/LungfishExecutor/RunCommand.swift line 35 |
| No test target is cross-built for musl, and Xcode's Swift cannot use the Static Linux SDK, so the tier builds with the swift.org toolchain of the SDK's exact version and runs the tests on glibc | scripts/linux/toolchain.json lines 3 and 28 |
| A tier run that ends in `commit <sha> DIRTY` proves nothing about that commit, because the tier builds the working tree | scripts/linux/portable-tier.sh lines 37 to 39 |
| The tier needs a container runtime, and with neither Apple container nor Docker answering it stops and reports no pass | scripts/linux/portable-tier.sh lines 107 to 116 |
