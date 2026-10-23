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

The record never holds a metadata sidecar, a CSV file or a provenance envelope, which the Mac writes at adopt. It never holds a path outside the work root, a scheduler's variable or file, or a rounded percentage.

## Exit codes and outcomes

| Exit code | `outcome` | Meaning |
| --- | --- | --- |
| 0 | `succeeded` | Every step succeeded |
| 1 | `failed` | A step failed, and `failedStepID` names it |
| 2 | `refused` | A check before the first tool failed, and `refusedField` names the plan field or argument. No tool ran |
| 3 | `interrupted` | A termination signal stopped the run, and `signal` and `signalName` name it |
| 64 | none | The arguments were wrong. The executor prints its usage and writes no record |

A refused run whose plan folder cannot be resolved also writes no record, and says so on standard error.

## Top-level keys

| Key | Type | Meaning |
| --- | --- | --- |
| `schemaVersion` | integer | 1 |
| `outcome`, `exitCode` | string, integer | As the table above |
| `reason` | string or absent | Why the run did not succeed, in the words the executor printed |
| `refusedField` | string or absent | The plan field or argument a refused run names |
| `failedStepID` | string or absent | The step a failed or interrupted run stopped at |
| `signal`, `signalName` | integer, string, or absent | The termination signal that interrupted the run |
| `executorArguments` | array of strings | The executor's own argv, byte for byte as run |
| `executor` | object | `sha256` and `size` of the running binary, read from `/proc/self/exe` on Linux, and `buildPin`, the plan's `executor` build, since the binary holds no version string |
| `plan` | object or absent | `relativePath`, `sha256` and `size` of the plan file the run read |
| `imageManifest` | object or absent | `sha256`, `size` and `source` of the tool manifest the run read. `source` is `image` for the image's own manifest and `argument` for a file `--image-manifest` named, as in a replay on the Mac. The path is never stated |
| `runtimeIdentity` | object | What the executor observed of the machine, below |
| `siteFacts` | array of `{key, value}` | The `--site-fact KEY=VALUE` arguments in the order given |
| `inputs` | array of plan entries | Each plan entry the executor checked, with the digest and size it read |
| `payloads` | array | The files the run leaves for the adopt, below |
| `steps` | array | One record for each step that started, in plan order |
| `startedAt`, `endedAt` | string | ISO 8601 times in UTC with milliseconds |
| `wallSeconds` | number | The run's wall time |

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
| `environmentNames` | The names of the variables the tool started with. The executor builds each environment from nothing |
| `graceSeconds`, `deadlineSeconds` | The plan's grace between SIGTERM and SIGKILL and the step's deadline |
| `toolPID`, `toolExitCode`, `toolSignal`, `peakResidentBytes` | The tool's process, how it ended and its peak memory |
| `escalatedToSIGKILL`, `stoppedProcesses`, `adoptedOrphansReaped` | What the end-of-step sweep stopped and reaped |
| `startedAt`, `endedAt`, `wallSeconds` | The step's times |
| `outputs` | `path`, `bytes` and `sha256` of each output, written only for a step that succeeded |
| `stderrTail`, `stderrTruncated`, `stderrBytes` | The last 4 MiB of standard error as UTF-8 with replacement, whether it was cut and every byte written |
| `standardOutput` | `text`, `sha256` and `size` of a kept standard output |
| `inputFile` | `relativePath`, `sha256` and `size` of the file a `statistics` step read |
| `inputReadCount`, `outputReadCount` | The records a step read and wrote |
| `qualityCounts` | The executor's own count, below |
| `storage` | What a storage step did, below |

## The full passes over the stored payload

Each full pass names the file it read by its path relative to the work root, its SHA-256 and its size.

| Pass | Where | What it holds |
| --- | --- | --- |
| Record count | Inside the storage step, as on the Mac, and in `payloads` | `recordCount` of the payload and `recordCountFile`, the file the count read |
| `seqkit stats -a -T` | The `statistics` step | `standardOutput`, the table byte for byte with the SHA-256 and size of those bytes, and `inputFile`. Its argv, exit status, standard error, wall time and the manifest's version and build sit in the step's own keys |
| Q20 and Q30 count | The `qualityCount` step, titled "Count Q20 and Q30 bases" | `qualityCounts` with the integer `baseCount`, `q20Count`, `q30Count` and `recordCount` and the `file` it read |

The Q20 and Q30 count is the executor's own code, the counter the Mac uses, so the step names the tool `lungfish-executor` with `versionSource` `planPin`, the plan's LGE version and commit, and the SHA-256 of the running binary. Its `argv` is the executor's own, since the counter has none. A gzip payload is read through the decompressor the plan pins, `gzip` or else `pigz`. A failed count is a failed step with its reason and never a zero. The text of `standardOutput` is decoded as UTF-8 with replacement, and its SHA-256 and size are those of the bytes seqkit wrote.

## Payloads

Each entry of `payloads` has `relativePath`, `sha256` and `size`, with `recordCount` and `recordCountFile` from the storage step that wrote it. The adopt compares `recordCountFile` with the payload's own digest.

## Storage details

| Key | Meaning |
| --- | --- |
| `writer` | `name` and `tool` of the program that wrote the gzip bytes, such as `bgzip`, `pigz` or `BBTools native BGZF` when no `bgzip` answered the probe |
| `effectiveCompressionLevel` | The level the writer used, when the record knows it |
| `clumpifyGroups`, `clumpifyMemoryEstimateLine`, `clumpifyMemoryAvailableLine` | The N of clumpify's `Set groups to N` line and its two memory lines as printed |
| `clumpingRan` | Whether clumpify or Trim Galore sorted the reads |
| `qualityBinning` | The binning scheme that ran |
| `inputBytes`, `outputBytes` | The sizes of the step's inputs and its output |
| `mixedLayout` | `mergedReads`, `pairs` and `unpairedReads` of a mixed file |
| `launches` | Each tool launch in order, the writer probe included, with `tool`, `argv`, `environmentNames`, `outcome`, `toolExitCode`, `toolSignal`, `wallSeconds`, `stderrPath` and the clumpify lines of that launch |

A clumpify that runs out of its Java heap fails the run at the storage step, keeps no payload digest and never falls back to storing without clumping.
