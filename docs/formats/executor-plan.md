# Executor plan, schema version 1

A plan is the file Lungfish Genome Explorer (LGE) writes on the Mac so that `lungfish-executor` can run one sample's import on a Linux machine, such as a CHTC execute node. It fixes every step's argv, tool, deadline and setting before the run, so the machine reads no host memory and resolves no automatic value. The types are `ExecutionPlan` and its parts in `Sources/LungfishPortable/Plan/`, the writer is `ExecutorPlanEmitter` with `ExecutorPlanFolderWriter` in `Sources/LungfishWorkflow/ExecutorPlan/`, and the record a run leaves is described in [executor-run-record.md](executor-run-record.md).

## The plan folder

The folder that holds `plan.json` is the run's work root. The Mac writes the files first and `plan.json` last.

| Path | What it holds |
| --- | --- |
| `plan.json` | The plan |
| `bin/lungfish-executor` | The executor the plan pins. A shared folder holds none |
| `recipe/<id>.recipe.json` | The recipe, when the import runs one |
| `inputs/R1<suffix>`, `inputs/R2<suffix>` | The reads |
| `databases/<id>/<file>` | Each database a recipe step reads. A shared folder holds none |
| `references/<set id>/<path>`, `references/<set id>/indexes/<key>/<path>` | Schema 2. Each file of a reference set, and each file of an index built from one, that a step reads. A shared folder holds none |
| `barcodes/<file>` | Schema 2. The 10x barcode list a step reads. A shared folder holds none |
| `staging.json` | In a shared folder only, the files kept in the staging folder and the image |

Work files use the stem `sample`. The sample's real name lives only in `sample.sampleName`, so the adopt applies the one name sanitizer.

## The template and the fill

The Mac plans a recipe once for every sample of one input shape. The template, `PlanTemplate` in `Sources/LungfishPortable/Plan/PlanTemplate.swift`, holds every plan key except `sample`, the platform, and one input slot per input, such as `inputs/R1.fastq.gz`, in place of the input entries. `PlanTemplate.fill` takes one sample's name, file names, sample-sheet labels and each input's SHA-256 and size, and gives that sample's plan. It sets `sample` and the input entries' `sha256` and `size` and nothing else. It puts the input entries before the first `database` entry and states the sum of the input sizes as `sample.originalSizeBytes`. It takes no parameter, so a sample cannot change a step, a tool, a setting or a deadline. It refuses a sample with field `entries` when its number of inputs differs from the template's, and with field `sample.originalFilenames` when a file name's FASTQ suffix differs from its slot's, since the steps' argv name the slot. A sample whose files take another suffix needs a template of its own. The Mac's own plan of one sample is the fill of its template, so the two have the same bytes. The fill reads no file, clock, environment or host fact, and it builds for Linux.

The job's `request_disk` is a value of the Mac's sample row that only the submit side reads. It never reaches `plan.json`, an argv or a step's environment, so two sample sheets that differ only in it give the same plan bytes.

## The shared folder and `staging.json`

A plan folder for CHTC holds no `executor`, `database` or `reference` entry, and no `barcodeList` entry whose list the person supplied. Each such file is kept once in the group's staging folder under a name that holds its SHA-256, and the job puts it at the entry's `relativePath`. With `--staged-reads` the folder holds no `input` entry either, since those reads already sit in the staging folder, and the job places them too. A barcode list from the tool image is in no folder and no staging folder, and the executor places it (Schema 2). The folder writer's shared mode copies every other entry, checks each copy with the node's resolver, writes `staging.json` and then writes `plan.json`, whose bytes are those of the per-sample folder. A folder written for a replay on the Mac holds every entry and no `staging.json`.

`staging.json` is UTF-8 JSON with sorted keys.

| Key | Meaning |
| --- | --- |
| `schemaVersion` | 1 |
| `sharedFiles` | Each entry the folder does not hold, `{role, relativePath, sha256, size}`, in plan order. For a schema 2 plan it may name the roles `reference` and `barcodeList`, and `schemaVersion` stays 1, since no key changes |
| `image` | The image the job runs in, `{fileName, sha256, size}`, as the launcher states them. The plan pins the image only by `imageManifest`, the pin the executor checks |

The shared mode refuses an image whose file name is not a plain name (field `staging.image.fileName`), whose SHA-256 is not 64 lowercase hexadecimal digits (`staging.image.sha256`) or whose size is not above 0 (`staging.image.size`).

## Running a plan

`lungfish-executor run --plan <file> [--image-manifest <absolute file>] [--site-fact KEY=VALUE]...`

The executor checks, in order, the site facts, the subreaper, the plan, the running binary against the plan's `executor` entry before it reads any other file, the image's tool manifest, each step's kind, tool pin and tool path, the plan's other files and the preflight, and then the manifest's `java` for a plan that runs a tool whose id ends in `.sh`, and a pinned `gzip`, `pigz` or `bgzip` for a plan with a step that reads gzip files. A failed check refuses the run before any tool starts. On Linux it checks the binary the kernel started, read from `/proc/self/exe`. In a replay on the Mac it checks the file that `argv[0]` names through `realpath`, and refuses an `argv[0]` with no `/`. It never uses the copy in `bin/`. `--image-manifest` names a tool manifest in place of the image's own, as in a replay on the Mac. In a schema 2 plan the plan's other files include each `reference` and `barcodeList` entry, and the executor places a barcode list from the image before it checks them.

## Keys

`plan.json` is UTF-8 JSON with sorted keys.

| Key | Type | Meaning |
| --- | --- | --- |
| `schemaVersion` | integer | 1. A plan from a newer schema is refused |
| `entries` | array | Each file the plan pins, `{role, relativePath, sha256, size}`. The roles are `executor`, `recipe`, `input` and `database`. A `database` entry also holds `database`, the engine's own database record, `{id, version, format, kmerLength, windowSize, lockPinned, buildSourceSHA256, buildSourceSizeBytes, buildToolVersion}`. Schema 2 adds the roles `reference` and `barcodeList`, each with an identity key of its own (Schema 2) |
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

`storage` holds `clumpingTool` (`bbtools`, `trim-galore` or `none`), `compressor` (`bgzip` or `pigz`), `qualityBinning`, `threads`, `clumpifyHeapGB`, `compressionLevel` (1 to 9) and a source for each setting the user may choose, `threadsSource`, `clumpifyHeapSource`, `clumpingToolSource`, `compressorSource` and `qualityBinningSource`. No value is `auto`, and threads and heap are positive, since no value may mean every core or the host's memory. A BBTools storage step under a plan that names `pigz` is refused with the sentence "This plan names pigz as the compressor for step <step id>, which runs <clumpify.sh or reformat.sh>. BBTools compresses its output with bgzip, so the plan must name bgzip." A plan that names `bgzip` and pins none for such a step is refused with field `tools` and the sentence "This plan pins no bgzip for step <step id>, which runs <clumpify.sh or reformat.sh>. BBTools compresses its output with bgzip, so the plan must pin bgzip in its tools."

`clumping` holds `requested`, `resolved`, `resolvedSource`, `heapBytes` and `reason`, and `operationNotice` for Trim Galore only, the sentence `ClumpingTool.operationNotice` gives, which the adopt logs as the import on the Mac does. When the user asks for automatic clumping, the plan writer decides platform first and reads no sample size and no host memory. It names `bbtools` at the plan's heap for every sample of short reads and for a sample that names no platform, and `none` for a sample whose platform is `ont`, `pacbio` or `unknown`, with source `default` and the reason `ClumpingTool` gives. `resolved` is never `auto` and the entry holds no input estimate. `resolved` equals `storage.clumpingTool`.

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

The storage route `none` runs `reformat.sh` with the plan's binning, or the compressor alone when the plan bins nothing, as the import on the Mac does. This build has no plan form for two files with no binning, which the Mac interleaves in its own process, or for one gzip file with no binning, which the Mac keeps as it is. The decoder refuses both, and a step with more than two files, with field `steps[<i>].inputs`, so the plan writer refuses them before a run and no recipe step runs on the machine first. Nor has it a plan form for a lone trim step when duplicate removal is off, for RiboDetector or for interleaved to paired reads.

The deacon scrub step passes no `-a` or `-r`, so its thresholds are the pinned deacon's defaults. The fused fastp report of a plan is `work/sample_fused_fastp_report.json`, where the import on the Mac adds a unique suffix to the name.

## Schema 2

Schema 2 is the plan of a chain of pinned tools, such as the RNA-seq steps on Linux of Phase 5.3 (`docs/plans/2026-10-02-architecture-program.md:233-256`). This page sets it first. No build reads it yet, and `ExecutionPlan.currentSchemaVersion` is 1 (`Sources/LungfishPortable/Plan/ExecutionPlan.swift:15`) until lane EX-TOOL builds it (`docs/plans/2026-10-02-architecture-program.md:242`).

### Reference entries

A `reference` entry pins one file of a reference set ([reference-set.md](reference-set.md)), or one file of an index built from a set, by `sha256` and `size` as every entry does. It also holds `reference`.

| Key | Meaning |
| --- | --- |
| `setID` | The set's id, such as `macaca_mulatta-Mmul_10-ensembl100-lge-3f9a1c2b7d10` (reference-set.md, The id) |
| `path` | The file's path inside the set's folder, such as `genome/<file as given>` or `derived/transcripts.fa`, or inside the index's own folder for an index file |
| `index` | For an index file only, `{key, tool}`. `key` is the index's folder name, such as `salmon-2.11.0-k31-genome-decoys` (reference-set.md, The salmon index cache), and lane EX-INDEX names a STAR index the same way. `tool` is the `{id, version, build}` that built it. Absent for a file of the set itself |

The entry's `relativePath` is `references/<set id>/<path>` for a file of the set and `references/<set id>/indexes/<key>/<path>` for an index file, so two sets or two indexes never share a path. Every `reference` entry of a plan names the one set that `pipeline.referenceSet` names, so a plan counts on one set. A shared folder holds no `reference` entry. Each is kept once in the staging folder as a `database` entry is, and the executor checks its size and SHA-256 before any tool starts, as it checks every entry. A plan names an index by its files, so a later plan pins an index that an earlier run left on Linux by the digests that run's record states ([executor-run-record.md](executor-run-record.md), Step keys). An entry of another role that holds `reference`, or a `reference` entry without it, is refused with field `entries[<i>].reference`.

### The barcode list

A `barcodeList` entry pins the 10x barcode list that a STARsolo step reads, by `sha256` and `size`, at `barcodes/<file>`. It also holds `barcodeList`.

| Key | Meaning |
| --- | --- |
| `name` | The known list whose SHA-256 the file has, `3M-february-2018` or `737K-august-2016`. The plan writer checks the SHA-256 against the known lists before it writes the plan and refuses, in words that name both, a list that is neither |
| `source` | `image` for the list LGE derives from 10x's CC BY 4.0 dataset files and ships with its NOTICE in the tool image, or `supplied` for a list the person gave |

The executor checks the list by SHA-256 before any tool starts (`docs/plans/2026-10-02-architecture-program.md:103`). A `supplied` list is kept once in the staging folder as a `database` entry is, and the executor checks it as it checks every entry. An `image` list is in no plan folder or staging folder, and `staging.json` does not name it. The executor copies the file that the image's tool manifest lists with that SHA-256 to the entry's `relativePath` and checks the copy's size and SHA-256. A manifest that lists no such file refuses the run with field `entries[<i>]` and the sentence "The tool image holds no barcode list with SHA-256 <sha256>, which this plan pins. No tool ran." The run record's `inputs` repeats the entry with its `barcodeList`, so the record says which list ran and where it came from, and the adopt writes "list supplied by the user" for a `supplied` list. LGE's list is never in the git tree or the Mac app, and LGE takes no list from a Cell Ranger install. An entry of another role that holds `barcodeList`, or a `barcodeList` entry without it, is refused with field `entries[<i>].barcodeList`.

## Refusals

A plan that breaks a rule is refused before any tool runs. The run record's `refusedField` names the field, such as `schemaVersion`, `entries[<i>]`, `imageManifest.sha256`, `tools[<i>].id`, `recipe.sourceSHA256`, `storage.compressor`, `storage.threads`, `storage.clumpifyHeapGB`, `storage.compressionLevel`, `clumping.resolved`, `clumping.heapBytes`, `clumping.reason`, `graceSeconds`, `steps[<i>].id`, `steps[<i>].kind`, `steps[<i>].tool`, `steps[<i>].deadlineSeconds`, `steps[<i>].inputs`, `steps[<i>].environment` or `tools`. The executor also refuses with `--plan` for a plan file it cannot read, `subreaper` on Linux when the subreaper cannot be set, `--site-fact <n>` for a site fact that breaks a rule, `imageManifest` when the tool manifest is missing, is named by a relative path, is over 1 MiB or differs from the plan's pin in SHA-256 or size, `imageManifest.<field>` when the manifest's own checks fail, and `storage.clumpifyHeapGB` when the preflight sees a heap at or above a limit it observed. A run refused for a pin mismatch still states the `sha256`, `size` and `source` of the manifest it read.
