# Executor run record, schema version 1

`lungfish-executor run --plan <file>` runs one plan on a Linux machine, such as a CHTC execute node, and leaves one record of the run. The record is the only channel from that machine to the bundle. The Mac's adopt reads it, checks it and writes the bundle's metadata and provenance from it. The types are `ExecutorRunRecord` and `ExecutorStepRecord` in `Sources/LungfishPortable/RunRecord/`, and the plan the run follows is described in [executor-plan.md](executor-plan.md).

## Where the record is

The work root is the folder that holds the plan file. The executor writes `run-record.json` at that root, last, by one rename of a hidden `.run-record.json.tmp-<pid>`. A second run in the same folder replaces the first record. Besides the record the executor adds these files to the work root.

| Path | What it holds |
| --- | --- |
| `tmp/`, `home/` | Each tool's `TMPDIR` and `HOME` |
| `logs/<step id>.stdout`, `logs/<step id>.stderr` | A step's standard output and standard error, when the plan keeps no standard output file for the step |
| `logs/<step id>.<n>.stdout`, `logs/<step id>.<n>.stderr` | Each tool launch of a step the executor builds itself, such as the storage step |
| The folders of each step's outputs | Such as `work/` and `out/` |

## Reading a record

`ExecutorRunRecord.decode` refuses a record whose `schemaVersion` is newer than the build reads, or whose `exitCode` disagrees with its `outcome`, and names the field. Every key added after the first shape of schema 1 is optional, so an older record opens and shows Not recorded for it. The record keys are sorted, and the encoder writes slashes unescaped.

The record never holds a metadata sidecar, a CSV file or a provenance envelope, which the Mac writes at adopt. It never holds the path of the work root, a path the run read from the Mac, a scheduler's variable or file, or a rounded percentage. Every path it holds is relative to the work root, except the image's tool paths in a step's `tool.path`, the first word of its `argv`, the folders of `searchPath` and the `path` of each `runtimes` entry, and `/proc/self/exe` for the executor.

## Exit codes and outcomes

| Exit code | `outcome` | Meaning |
| --- | --- | --- |
| 0 | `succeeded` | Every step succeeded |
| 1 | `failed` | A step failed, and `failedStepID` names it |
| 2 | `refused` | A check before the first tool failed, and `refusedField` names the plan field or argument. No tool ran |
| 3 | `interrupted` | A termination signal stopped the run, and `signal` and `signalName` name it |
| 64 | none | The arguments were wrong. The executor prints its usage and writes no record |

A refused run whose plan folder cannot be resolved also writes no record, and says so on standard error. A run whose steps all succeeded but whose record cannot be written exits 1 and leaves no record.

## Top-level keys

| Key | Type | Meaning |
| --- | --- | --- |
| `schemaVersion` | integer | 1 |
| `outcome`, `exitCode` | string, integer | As the table above |
| `reason` | string or absent | Why the run did not succeed, in the words the executor printed |
| `refusedField` | string or absent | The plan field or argument a refused run names |
| `failedStepID` | string or absent | The step a failed or interrupted run stopped at |
| `signal`, `signalName` | integer, string, or absent | The termination signal that interrupted the run |
| `executorArguments` | array of strings | The executor's argv after its own path, with the `--plan` value cut to the plan file's name, the `--image-manifest` value written as `(not recorded)` and each `--site-fact` pair as given |
| `executor` | object | `sha256` and `size` of the running binary, read from `/proc/self/exe` on Linux, and `buildPin`, the plan's `executor` build, since the binary holds no version string |
| `plan` | object or absent | `relativePath`, `sha256` and `size` of the plan file the run read |
| `recipe` | object or absent | The plan's recipe identity, `id`, `name`, `requestedName`, `formatVersion`, `sourceSHA256`, `presetID`, `presetName`, `switches` of `{id, label, value, source}` and `turnedOffSteps` of `{stepType, label, activeStepsBefore, switchID}`. It is set as soon as the plan decodes, so a refused run that decoded its plan names it too |
| `imageManifest` | object or absent | `sha256`, `size` and `source` of the tool manifest the run read. `source` is `image` for the image's own manifest and `argument` for a file `--image-manifest` named, as in a replay on the Mac. The path is never stated |
| `searchPath` | array of strings or absent | The folders of every tool's `PATH` in order, below. Absent for a refused run and in a record written before C3 |
| `runtimes` | array or absent | The runtime a BBTools wrapper needs, the manifest's first `java` as `id`, `version`, `build` and `path`, when the plan pins a tool whose id ends in `.sh`, and else an empty array. Absent for a refused run and in a record written before C3 |
| `runtimeIdentity` | object | What the executor observed of the machine, below |
| `siteFacts` | array of `{key, value}` | The `--site-fact KEY=VALUE` arguments in the order given |
| `inputs` | array of plan entries | Each plan entry but the executor's, which `executor` states, with the digest and size the executor read |
| `payloads` | array | The files the run leaves for the adopt, below |
| `steps` | array | One record for each step that started, in plan order |
| `startedAt`, `endedAt` | string | ISO 8601 times in UTC with milliseconds |
| `wallSeconds` | number | The run's wall time |

## Search path and runtimes

Each tool starts with `PATH` set to the folders of the image manifest's tools, each once in the manifest's order, then `/usr/bin` and `/bin`, and nothing the executor inherited. `searchPath` states those folders in that order. The two fixed folders supply only what a BBTools wrapper script calls, such as `dirname`, `basename` and `readlink`, since the manifest's folders come first and the executor runs every tool by its absolute manifest path. A Java is never taken from them, and the run sets no `JAVA_HOME` or `BBMAP_JAVA`, which the wrappers do not read.

The manifest builder lists `lib/jvm/bin/java` as `java` for a conda environment with no `bin/java`, as in the Mac's `bbtools` environment, and keeps `bin/java` when an environment holds both. A plan that runs a tool whose id ends in `.sh` is refused before any tool starts when the manifest lists no `java`, with `refusedField` `tools` and the reason "The image's tool manifest lists no java, which clumpify.sh needs. No tool ran." The plan writer on the Mac pins the manifest's `java` beside every such tool, and refuses to write the plan with "The image's tool manifest lists no java, which step storage runs." when the manifest has none.

## Runtime identity

`runtimeIdentity` holds `kernelRelease` and `machine` from `uname`, `pidNamespaceDepth` from the `NSpid` line of `/proc/self/status`, `cgroupVersion`, `observedLimits`, `subreaper` and `orphanSweep`. Each observed limit has a `name` (`memTotalBytes`, `cpusAllowedList` or `cgroupMemoryMaxBytes`), the `value` as read and the `source` it was read from, such as `/proc/meminfo MemTotal`. A value the executor could not read is absent and never refuses a run. `subreaper` holds `state` (`set`, `notSet` or `unavailable`), `setterResult`, `setterResultName`, `getterResult` and `getterValue`.

`orphanSweep` says how the executor finds the processes a tool leaves behind.

| Value | Meaning |
| --- | --- |
| `subreaper` | `subreaper` means the executor registered with Linux to adopt every process its tools leave behind, finds them the same way and stops them. |
| `parentWalkOnly` | `parentWalkOnly` means the executor finds a tool's processes by following each one's parent from the executor, so a process that detached into its own session and outlived its parent is not found. |

A run on Linux whose subreaper cannot be set is refused with `refusedField` `subreaper`. A replay on the Mac records `parentWalkOnly`.

## Site facts

`siteFacts` lists the `--site-fact KEY=VALUE` arguments in the order given, such as the machine name or the container version that the job's launcher passes. The executor records each one verbatim and never reads it, passes it to a tool or finds a file with it. A run takes at most 64 site facts. A key is a letter followed by at most 63 letters, digits or underscores, and a value holds at most 1,024 bytes and no control character. A repeated key or a fact that breaks a rule refuses the run with `refusedField` `--site-fact <n>`, where `<n>` is the fact's position, and the reason never quotes the value.

## Step keys

| Key | Meaning |
| --- | --- |
| `id`, `kind` | The plan step's id and kind |
| `tool` | `id`, `version`, `build` and `path` of the tool, with `versionSource` and `sha256`. `versionSource` is `imageManifest` for a tool the image's manifest lists, and `planPin` for the executor itself, whose version and build come from the plan. `sha256` is stated only for the executor. Absent for a step refused before its tool was looked up |
| `outcome`, `reason` | `succeeded`, `failed`, `refused` or `interrupted`, and why |
| `signal`, `signalName` | The termination signal that interrupted the step |
| `argv` | The argv as run, the tool's absolute path first and every other path relative to the work root |
| `environmentNames` | The names of the variables the tool started with. The executor builds each environment from nothing, with `PATH` as `searchPath` states it |
| `graceSeconds`, `deadlineSeconds` | The plan's grace between SIGTERM and SIGKILL and the step's deadline |
| `toolPID`, `toolExitCode`, `toolSignal`, `peakResidentBytes` | The tool's process, how it ended and its peak memory |
| `escalatedToSIGKILL`, `stoppedProcesses`, `adoptedOrphansReaped` | What the end-of-step sweep stopped and reaped |
| `startedAt`, `endedAt`, `wallSeconds` | The step's times |
| `outputs` | `path`, `bytes` and `sha256` of each output, written only for a step that succeeded |
| `stderrTail`, `stderrTruncated`, `stderrBytes` | The last 4 MiB of standard error as UTF-8 with replacement, whether it was cut and every byte written. For a step with `storage.launches` the three keys describe the last launch, and each launch's `stderrPath` names its own file |
| `standardOutput` | `text`, `sha256` and `size` of a kept standard output |
| `inputFile` | `relativePath`, `sha256` and `size` of the file a `statistics` step read |
| `inputReadCount`, `outputReadCount` | Integers counted from the step's files, below. Absent for a step that did not succeed and for a file that cannot be counted |
| `qualityCounts` | The executor's own count, below |
| `storage` | What a storage step did, below |

A step the executor builds itself, the storage step or the merged-to-mixed step, states what its launches state. Its `peakResidentBytes` is the largest of its launches, `escalatedToSIGKILL` is true when any launch was sent SIGKILL, `stoppedProcesses` lists every process its launches stopped, and `adoptedOrphansReaped` counts the orphans the run reaped since the step before it. When the executor ended a launch, the step's `reason` starts with the controller's sentence, such as "The tool ran past its deadline of N seconds. The executor stopped it.", and the storage sentence follows. No path of the work root stays in a reason.

## Read counts

A `recipe` step counts the reads files among its inputs and its outputs, the names that end in `.fastq`, `.fq`, `.fastq.gz`, `.fq.gz` or `.fastq.bgz`, in the units of the Mac's recipe engine. One file gives its records. Two files are an R1 and R2 pair, so the count is the first file's records. Three files are a merged layout, so the count is every record of the three. A database index or a report beside the reads is not counted. Each file is counted once a run, so a step's input count is the output count of the step that wrote the file. A count that cannot be made leaves the key absent, as on the Mac, and a recipe step whose plan pins no decompressor states no count of a gzip file.

A storage step states the records it read and the records it stored. A merged-to-mixed `interleave` step states the records it wrote as `outputReadCount`, with the counts by kind in `storage.mixedLayout`.

A gzip file the executor reads itself, for a count or a merged-to-mixed step, goes through the plan's pinned `gzip`, else its pinned `pigz`, else its pinned `bgzip`. A plan with a `qualityCount` step, a storage step or a merged-to-mixed step that pins none of the three is refused with `refusedField` `tools` and the reason "Step <id> reads gzip files, and the plan pins no gzip, pigz or bgzip to read them. No tool ran." A plan with a `clumpify.sh` or `reformat.sh` storage step and no pinned `bgzip` is refused first, as [executor-plan.md](executor-plan.md) says. The executor never runs a program its tool manifest does not list.

## The full passes over the stored payload

Each full pass names the file it read by its path relative to the work root, its SHA-256 and its size.

| Pass | Where | What it holds |
| --- | --- | --- |
| Record count | Inside the storage step, as on the Mac, and in `payloads` | `recordCount` of the payload and `recordCountFile`, the file the count read |
| `seqkit stats -a -T` | The `statistics` step | `standardOutput`, the table byte for byte with the SHA-256 and size of those bytes, and `inputFile`. Its argv, exit status, standard error, wall time and the manifest's version and build sit in the step's own keys |
| Q20 and Q30 count | The `qualityCount` step, titled "Count Q20 and Q30 bases" | `qualityCounts` with the integer `baseCount`, `q20Count`, `q30Count` and `recordCount` and the `file` it read |

The Q20 and Q30 count is the executor's own code, the counter the Mac uses, so the step names the tool `lungfish-executor` with `versionSource` `planPin`, the plan's LGE version and commit, and the SHA-256 of the running binary. Its `tool.path` is `/proc/self/exe` on every system, a label for the running binary, and its `argv` is the record's `executorArguments`, which start after the executor's path, since the counter has no argv of its own. A failed count is a failed step with its reason and never a zero. The text of `standardOutput` is decoded as UTF-8 with replacement, and its SHA-256 and size are those of the bytes seqkit wrote.

## Payloads

Each entry of `payloads` has `relativePath`, `sha256` and `size`, with `recordCount` and `recordCountFile` from the storage step that wrote it. The adopt compares `recordCountFile` with the payload's own digest.

## Storage details

| Key | Meaning |
| --- | --- |
| `writer` | `name` and `tool` of the program that wrote the gzip bytes. It is `bgzip` or `pigz` for a compressor launch. For a `clumpify.sh` or `reformat.sh` launch it is `bgzip`, the plan's pinned bgzip that answered the probe. A BBTools step whose probe finds no bgzip that answers fails before BBTools starts, with the step's reason "Step <step id> did not run. <clumpify.sh or reformat.sh> compresses its output with bgzip, and no bgzip answered `bgzip -h` on the step's PATH (<PATH>). The tool image must hold bgzip beside the BBTools scripts." The run's `reason` is that sentence alone, and the executor never states `BBTools native BGZF`. It is absent when Trim Galore wrote the stored gzip itself |
| `effectiveCompressionLevel` | The level the writer used, when the record knows it |
| `clumpifyGroups`, `clumpifyMemoryEstimateLine`, `clumpifyMemoryAvailableLine` | The N of clumpify's `Set groups to N` line and its two memory lines as printed. When a mixed file runs clumpify twice the keys hold the launch with more groups, and `launches` keeps each launch's own |
| `clumpingRan` | Whether clumpify or Trim Galore sorted the reads |
| `qualityBinning` | The binning scheme that ran |
| `inputBytes`, `outputBytes` | The sizes of the step's inputs and its output |
| `mixedLayout` | `mergedReads`, `pairs` and `unpairedReads` of a mixed file |
| `launches` | Each tool launch in order, the writer probe included, with `tool`, `argv`, `environmentNames`, `outcome`, `toolExitCode`, `toolSignal`, `wallSeconds`, `stderrPath`, the launch's own keys below and the clumpify lines of that launch |

Each launch runs within what is left of the step's deadline when it starts. Its own keys are absent in a record written before C3.

| Launch key | Meaning |
| --- | --- |
| `reason` | The executor's sentence for a launch that did not succeed, such as "The tool ran past its deadline of N seconds. The executor stopped it.", with each work-root path cut to a relative path. Absent for a launch that succeeded |
| `escalatedToSIGKILL` | True when a process of the launch outlived the grace and was sent SIGKILL |
| `stoppedProcesses` | The PIDs the executor signalled other than the tool |
| `peakResidentBytes` | The launch's peak resident memory in bytes from the `wait4` that reaped it, which counts the children the tool waited for, such as clumpify's JVM |

A clumpify that runs out of its Java heap fails the run at the storage step, keeps no payload digest and never falls back to storing without clumping.
