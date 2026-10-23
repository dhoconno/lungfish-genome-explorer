# Executor plan, schema version 1

A plan is the file Lungfish Genome Explorer (LGE) writes on the Mac so that `lungfish-executor` can run one sample's import on a Linux machine, such as a CHTC execute node. It fixes every step's argv, tool, deadline and setting before the run, so the machine reads no host memory and resolves no automatic value. The types are `ExecutionPlan` and its parts in `Sources/LungfishPortable/Plan/`, the writer is `ExecutorPlanEmitter` with `ExecutorPlanFolderWriter` in `Sources/LungfishWorkflow/ExecutorPlan/`, and the record a run leaves is described in [executor-run-record.md](executor-run-record.md).

## The plan folder

The folder that holds `plan.json` is the run's work root. The Mac writes the files first and `plan.json` last.

| Path | What it holds |
| --- | --- |
| `plan.json` | The plan |
| `bin/lungfish-executor` | The executor the plan pins |
| `recipe/<id>.recipe.json` | The recipe, when the import runs one |
| `inputs/R1<suffix>`, `inputs/R2<suffix>` | The reads |
| `databases/<id>/<file>` | Each database a recipe step reads |

Work files use the stem `sample`. The sample's real name lives only in `sample.sampleName`, so the adopt applies the one name sanitizer.

## Running a plan

`lungfish-executor run --plan <file> [--image-manifest <absolute file>] [--site-fact KEY=VALUE]...`

The executor checks, in order, the site facts, the subreaper, the plan, the running binary against the plan's `executor` entry before it reads any other file, the image's tool manifest, each step's kind, tool pin and tool path, the plan's other files and the preflight. A failed check refuses the run before any tool starts. On Linux it checks the binary the kernel started, read from `/proc/self/exe`. In a replay on the Mac it checks the file that `argv[0]` names through `realpath`, and refuses an `argv[0]` with no `/`. It never uses the copy in `bin/`. `--image-manifest` names a tool manifest in place of the image's own, as in a replay on the Mac.

## Keys

`plan.json` is UTF-8 JSON with sorted keys.

| Key | Type | Meaning |
| --- | --- | --- |
| `schemaVersion` | integer | 1. A plan from a newer schema is refused |
| `entries` | array | Each file the plan pins, `{role, relativePath, sha256, size}`. The roles are `executor`, `recipe`, `input` and `database`. A `database` entry also holds `database`, the engine's own database record, `{id, version, format, kmerLength, windowSize, lockPinned, buildSourceSHA256, buildSourceSizeBytes, buildToolVersion}` |
| `executor` | object | What built the pinned executor, `lgeVersion`, `lgeCommit`, `targetTriple`, `toolchainID`, `toolchainSHA256`, `staticLinuxSDKID` and `staticLinuxSDKSHA256` |
| `imageManifest` | object | `sha256` and `size` of the image's tool manifest. The plan names no path for it |
| `tools` | array | Every tool a step runs or launches, `{id, version, build}`, which the manifest must list. The plan writer pins the compressor for every storage route, and a plan with a `clumpify.sh` or `reformat.sh` storage step pins `bgzip`, which BBTools writes through |
| `recipe` | object or absent | The recipe's identity as the import on the Mac records it, `id`, `name`, `requestedName`, `formatVersion`, `sourceSHA256`, `presetID`, `presetName`, `switches` of `{id, label, value, source}` and `turnedOffSteps` of `{stepType, label, activeStepsBefore, switchID}`. Its `sourceSHA256` equals the `recipe` entry's SHA-256 |
| `sample` | object | `sampleName`, `originalFilenames`, `originalSizeBytes`, `platform` and `sampleSheet`, which the adopt takes from the plan |
| `storage` | object | The storage settings, below |
| `clumping` | object | The clumping choice, below |
| `graceSeconds` | number | Seconds between SIGTERM and SIGKILL for every step, above 0 |
| `steps` | array | The steps in order, below |

The plan has no statistics settings. `seqkit stats -a -T <file>` is the call the Mac makes. The Mac passes no `-j`, so seqkit runs with its own default.

## Storage and clumping

`storage` holds `clumpingTool` (`bbtools`, `trim-galore` or `none`), `compressor` (`bgzip` or `pigz`), `qualityBinning`, `threads`, `clumpifyHeapGB`, `compressionLevel` (1 to 9) and a source for each setting the user may choose, `threadsSource`, `clumpifyHeapSource`, `clumpingToolSource`, `compressorSource` and `qualityBinningSource`. No value is `auto`, and threads and heap are positive, since no value may mean every core or the host's memory. A BBTools storage step under a plan that names `pigz` is refused with the sentence "This plan names pigz as the compressor for step <step id>, which runs <clumpify.sh or reformat.sh>. BBTools compresses its output with bgzip, so the plan must name bgzip." A plan that names `bgzip` and pins none for such a step is refused with field `tools` and the sentence "This plan pins no bgzip for step <step id>, which runs <clumpify.sh or reformat.sh>. BBTools compresses its output with bgzip, so the plan must name bgzip."

`clumping` holds `requested`, `resolved`, `resolvedSource`, `heapBytes` and `reason`. When the user asks for automatic clumping, the plan writer names `bbtools` at the plan's heap for every sample and reads no sample size and no host memory, so `resolved` is never `auto` and the entry holds no input estimate. `resolved` equals `storage.clumpingTool`.

## Source values

| Value | Meaning |
| --- | --- |
| `option` | The user set the value |
| `default` | LGE's default set it |
| `host` | LGE read it from the Mac it ran on |
| `recipe` | The recipe set it |
| `plan` | `plan` means the value came from the plan the run followed, which the Mac wrote before the run. |

## Steps

Each step has `id` (1 to 64 of `A-Z a-z 0-9 . _ -`, starting with a letter or digit), `title`, `kind`, `tool` (`{id, version, build}`), `arguments`, `environment` (`{name, value}` pairs), `deadlineSeconds`, `inputs`, `outputs` and `standardOutput`. Every path is relative to the work root. The executor builds each tool's environment from nothing, sets `PATH`, `TMPDIR` and `HOME`, and then adds the step's variables, such as `_JAVA_OPTIONS=-Xmx<heap>g` for clumpify. The executor removes `_JAVA_OPTIONS` from every launch of a storage step except clumpify.

| `kind` | What runs |
| --- | --- |
| `recipe` | A recipe step by the plan's argv, the argv the import on the Mac builds |
| `interleave` | The merged and unmerged reads joined into one mixed file. With an argv it runs by it, and with none the executor writes the file itself |
| `storage` | The storage route `storage.clumpingTool` names, which the executor builds on the machine, since its argv depends on the layout of the recipe's output |
| `compress` | A compressor by the plan's argv |
| `statistics` | `seqkit stats -a -T` of the payload, whose table is kept in `standardOutput` |
| `qualityCount` | The executor's own Q20 and Q30 count of the payload. The plan's step names no tool, and the record's step names the executor |

The storage route `none` runs `reformat.sh` with the plan's binning, or the compressor alone when the plan bins nothing, as the import on the Mac does. This build has no plan form for two files with no binning, which the Mac interleaves in its own process, or for one gzip file with no binning, which the Mac keeps as it is. The decoder refuses both with field `steps[<i>].inputs`, so the plan writer refuses them before a run and no recipe step runs on the machine first. Nor has it a plan form for a lone trim step when duplicate removal is off, for RiboDetector or for interleaved to paired reads.

The deacon scrub step passes no `-a` or `-r`, so its thresholds are the pinned deacon's defaults. The fused fastp report of a plan is `work/sample_fused_fastp_report.json`, where the import on the Mac adds a unique suffix to the name.

## Refusals

A plan that breaks a rule is refused before any tool runs. The run record's `refusedField` names the field, such as `schemaVersion`, `entries[<i>]`, `imageManifest.sha256`, `tools[<i>].id`, `recipe.sourceSHA256`, `storage.compressor`, `storage.threads`, `storage.clumpifyHeapGB`, `storage.compressionLevel`, `clumping.resolved`, `clumping.heapBytes`, `clumping.reason`, `graceSeconds`, `steps[<i>].id`, `steps[<i>].kind`, `steps[<i>].tool`, `steps[<i>].deadlineSeconds`, `steps[<i>].inputs`, `steps[<i>].environment` or `tools`. The executor also refuses with `--plan` for a plan file it cannot read, `subreaper` on Linux when the subreaper cannot be set, `--site-fact <n>` for a site fact that breaks a rule, and `storage.clumpifyHeapGB` when the preflight sees a heap at or above a limit it observed.
