# Executor plan, schema versions 1 and 2

A plan is the file Lungfish Genome Explorer (LGE) writes on the Mac so that `lungfish-executor` can run one sample's import on a Linux machine, such as a CHTC execute node. It fixes every step's argv, tool, deadline and setting before the run, so the machine reads no host memory and resolves no automatic value. The types are `ExecutionPlan` and its parts in `Sources/LungfishPortable/Plan/`, the writer is `ExecutorPlanEmitter` with `ExecutorPlanFolderWriter` in `Sources/LungfishWorkflow/ExecutorPlan/`, and the record a run leaves is described in [executor-run-record.md](executor-run-record.md). Schema 1 is the plan of a read import. Schema 2 is the plan of a chain of pinned tools ([Schema 2](#schema-2)), and every rule this page does not mark as schema 2 holds for both.

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

The Mac plans a recipe once for every sample of one input shape. The template, `PlanTemplate` in `Sources/LungfishPortable/Plan/PlanTemplate.swift`, holds every plan key except `sample`, the platform, and one input slot per input, such as `inputs/R1.fastq.gz`, in place of the input entries. `PlanTemplate.fill` takes one sample's name, file names, sample-sheet labels and each input's SHA-256 and size, and gives that sample's plan. It sets `sample` and the input entries' `sha256` and `size` and nothing else. It puts the input entries before the first `database` entry and states the sum of the input sizes as `sample.originalSizeBytes`. It takes no parameter, so a sample cannot change a step, a tool, a setting or a deadline. It refuses a sample with field `entries` when its number of inputs differs from the template's, and with field `sample.originalFilenames` when a file name's FASTQ suffix differs from its slot's, since the steps' argv name the slot. A sample whose files take another suffix needs a template of its own. The Mac's own plan of one sample is the fill of its template, so the two have the same bytes. The fill reads no file, clock, environment or host fact, and it builds for Linux. In a schema 2 plan the fill also sets `sample.instrument`, which changes no argv, and a plan with no `input` entry, such as an index build, has no `sample` and no fill.

The job's `request_disk` is a value of the Mac's sample row that only the submit side reads. It never reaches `plan.json`, an argv or a step's environment, so two sample sheets that differ only in it give the same plan bytes.

## The shared folder and `staging.json`

A plan folder for CHTC holds no `executor`, `database` or `reference` entry. Each such file is kept once in the group's staging folder under a name that holds its SHA-256, and the job puts it at the entry's `relativePath`. With `--staged-reads` the folder holds no `input` entry either, since those reads already sit in the staging folder, and the job places them too. No folder LGE writes holds a barcode list (Schema 2). The executor places a list from the tool image, which no staging folder holds either. The person places a list they supplied, in the staging folder as `shared/<sha256>-<file>` for CHTC, and `staging.json` names it. The folder writer's shared mode copies every other entry, checks each copy with the node's resolver, writes `staging.json` and then writes `plan.json`, whose bytes are those of the per-sample folder. A folder written for a replay on the Mac holds every entry but a barcode list, and no `staging.json`. For each list the person supplied, the folder writer gives the words its caller shows, which name the list, its SHA-256 and size and where to put it before the run (`ExecutorPlanFolderWriter.placements(of:shared:)`).

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
| `schemaVersion` | integer | 1, or 2 for a plan with a `pipeline` (Schema 2). A plan from a newer schema is refused |
| `entries` | array | Each file the plan pins, `{role, relativePath, sha256, size}`. The roles are `executor`, `recipe`, `input` and `database`. A `database` entry also holds `database`, the engine's own database record, `{id, version, format, kmerLength, windowSize, lockPinned, buildSourceSHA256, buildSourceSizeBytes, buildToolVersion}`. Schema 2 adds the roles `reference` and `barcodeList`, each with an identity key of its own (Schema 2) |
| `executor` | object | What built the pinned executor, `lgeVersion`, `lgeCommit`, `targetTriple`, `toolchainID`, `toolchainSHA256`, `staticLinuxSDKID` and `staticLinuxSDKSHA256` |
| `imageManifest` | object | `sha256` and `size` of the image's tool manifest. The plan names no path for it |
| `tools` | array | Every tool a step runs or launches, `{id, version, build}`, which the manifest must list. The plan writer pins the compressor for every storage route, and a plan with a `clumpify.sh` or `reformat.sh` storage step pins `bgzip`, which BBTools writes through |
| `recipe` | object or absent | The recipe's identity as the import on the Mac records it, `id`, `name`, `requestedName`, `formatVersion`, `sourceSHA256`, `presetID`, `presetName`, `switches` of `{id, label, value, source}` and `turnedOffSteps` of `{stepType, label, activeStepsBefore, switchID}`. Its `sourceSHA256` equals the `recipe` entry's SHA-256. Absent in schema 2 |
| `pipeline` | object or absent | Schema 2 only. The identity of the chain the plan runs ([The pipeline](#the-pipeline)) |
| `sample` | object | `sampleName`, `originalFilenames`, `originalSizeBytes`, `platform` and `sampleSheet`, which the adopt takes from the plan. Schema 2 adds `instrument`, and a schema 2 plan with no `input` entry has no `sample` |
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

Each step has `id` (1 to 64 of `A-Z a-z 0-9 . _ -`, starting with a letter or digit), `title`, `kind`, `tool` (`{id, version, build}`), `arguments`, `environment` (`{name, value}` pairs), `deadlineSeconds`, `inputs`, `outputs` and `standardOutput`, and in a schema 2 plan `outputPolicy` (Schema 2). Every path is relative to the work root. The executor builds each tool's environment from nothing, sets `PATH`, `TMPDIR` and `HOME`, and then adds the step's variables, such as `_JAVA_OPTIONS=-Xmx<heap>g` for clumpify. The executor removes `_JAVA_OPTIONS` from every launch of a storage step except clumpify.

| `kind` | What runs |
| --- | --- |
| `recipe` | A recipe step by the plan's argv, the argv the import on the Mac builds |
| `interleave` | The merged and unmerged reads joined into one mixed file. With an argv it runs by it, and with none the executor writes the file itself |
| `storage` | The storage route `storage.clumpingTool` names, which the executor builds on the machine, since its argv depends on the layout of the recipe's output |
| `compress` | A compressor by the plan's argv |
| `statistics` | `seqkit stats -a -T` of the payload, whose table is kept in `standardOutput` |
| `qualityCount` | The executor's own Q20 and Q30 count of the payload. The plan's step names no tool, and the record's step names the executor |
| `tool` | Schema 2 only. A pinned tool by the plan's argv, as a `recipe` step runs by its argv (Schema 2) |

The storage route `none` runs `reformat.sh` with the plan's binning, or the compressor alone when the plan bins nothing, as the import on the Mac does. This build has no plan form for two files with no binning, which the Mac interleaves in its own process, or for one gzip file with no binning, which the Mac keeps as it is. The decoder refuses both, and a step with more than two files, with field `steps[<i>].inputs`, so the plan writer refuses them before a run and no recipe step runs on the machine first. Nor has it a plan form for a lone trim step when duplicate removal is off, for RiboDetector or for interleaved to paired reads.

The deacon scrub step passes no `-a` or `-r`, so its thresholds are the pinned deacon's defaults. The fused fastp report of a plan is `work/sample_fused_fastp_report.json`, where the import on the Mac adds a unique suffix to the name.

## Schema 2

Schema 2 is the plan of a chain of pinned tools, such as the RNA-seq steps on Linux of Phase 5.3 (`docs/plans/2026-10-02-architecture-program.md:233-256`). This build reads and runs it. `ExecutionPlan.currentSchemaVersion` stays 1, the version of a plan with no `pipeline`, since it is the default version of every plan of a read import (`ExecutionPlan.init` and `PlanTemplate.init`). The decoder reads the versions of `ExecutionPlan.readableSchemaVersions`, 1 and 2, and a plan with a `pipeline` is written at `ExecutionPlan.pipelineSchemaVersion`, 2, so the plan of a read import keeps `"schemaVersion" : 1` byte for byte (`docs/plans/2026-10-02-architecture-program.md:242`).

### Which schema a plan states

The plan writer writes schema 2 for a plan with a `pipeline` and schema 1 for every other plan, so the plan of a read import keeps its version, its bytes and the meaning of every key (`docs/plans/2026-10-02-architecture-program.md:242,256`). A schema 2 plan keeps every key of schema 1 with its meaning, except as this table says.

| Key | In a schema 2 plan |
| --- | --- |
| `pipeline` | Present ([The pipeline](#the-pipeline)) |
| `recipe` | Absent, with no `recipe` entry |
| `storage`, `clumping` | Absent, since every step is a `tool` step |
| `sample` | Present when the plan has an `input` entry, with `instrument` too. Absent for a plan with none, such as an index build, which then pins at least one `reference` entry. A plan with an `input` entry and no `sample` is refused with field `sample` and "This plan has no sample.", and a plan with a `sample` and no `input` entry with field `sample` too |
| `entries` | The roles `executor`, `input`, `database`, `reference` and `barcodeList`. The `reference` entries follow every entry of another role and the `barcodeList` entries follow them, each in the order of `relativePath`, so every plan writer writes the same bytes. A plan in another order is refused with field `entries`. The fill puts the `input` entries before the first `database`, `reference` or `barcodeList` entry |
| `steps` | Each a `tool` step with `outputPolicy`. A step of another kind is refused with field `steps[<i>].kind` and the sentence "This plan has schema version 2 and its step <id> has kind <kind>, which a schema 2 plan does not hold." |

A chain that needs `seqkit stats -a -T` runs it as a `tool` step that keeps the table in `standardOutput`, since seqkit is a pinned tool, so a schema 2 plan needs no `statistics` step. Only `qualityCount`, the executor's own count with no tool, has no form in schema 2.

`sample.instrument` is `{model, inferred}`, the instrument the poly-G record line names, where `inferred` is true when LGE read the model from the read names and false when the person or the sample sheet gave it. It is absent when no instrument is known. It changes no argv, since poly-G trimming is off by default whatever the instrument. A `model` that is empty, has spaces at either end or holds a control character is refused with field `sample.instrument` and words that say a plan leaves `instrument` out when no instrument is known.

A schema 2 plan that holds `recipe`, `storage` or `clumping` is refused with that key as its field and the sentence "This plan has schema version 2 and holds <key>, which a schema 2 plan does not hold." A schema 2 plan with no `pipeline` is refused with field `pipeline` and "This plan has no pipeline." A `pipeline.settings` entry whose `source` is `host` or `plan` is refused with field `pipeline.settings[<i>].source`, since a plan stores `option`, `default` or, for the `duplicates` entry of deduplicated reads, `recipe`.

The executor reads `schemaVersion` alone before any other key. It refuses any number but 1 and 2 with field `schemaVersion` and the sentence "This plan has schema version <n>, and this executor reads versions 1 and 2." It reads a version 1 plan by the rules of schema 1, so one that leaves out `sample`, `storage` or `clumping` is refused at that key with the words of schema 1, such as "This plan has no storage." It refuses a version 1 plan that holds a key, role or kind schema 2 added, with the field that holds it and the sentence "This plan has schema version 1 and holds <field>, which schema 2 added." For a key `<field>` is its path, such as `pipeline` or `steps[2].outputPolicy`, and for a role or a kind it is the path and the value, such as `entries[3].role reference` or `steps[0].kind tool`. No executor before lane EX-TOOL prints either sentence.

The executor of schema 1 refuses every schema 2 plan before any tool starts, though never with the words of its version check, since it decodes the whole plan before it compares the version (`Sources/LungfishPortable/Plan/ExecutionPlan.swift:286,292`). No schema 2 plan decodes in schema 1's types, since every one leaves out `storage` and `clumping`, so the executor of schema 1 never reaches its version check (`Sources/LungfishPortable/Plan/PlanDecodeError.swift:101-102`). It refuses at the first key it cannot read, in the order the keys decode. That is `entries[<i>].role` for a `reference` or `barcodeList` entry, with "This plan's entries[<i>].role holds a value this executor does not read.", and otherwise `sample` for a plan with no `sample`, with "This plan has no sample.", or else `storage`, with "This plan has no storage." A schema 2 plan pins the executor that reads it, so only a run with an older binary than the plan pins meets this refusal.

### Reference entries

A `reference` entry pins one file of a reference set ([reference-set.md](reference-set.md)), or one file of an index built from a set, by `sha256` and `size` as every entry does. It also holds `reference`.

| Key | Meaning |
| --- | --- |
| `setID` | The set's id, such as `macaca_mulatta-Mmul_10-ensembl100-lge-3f9a1c2b7d10` (reference-set.md, The id) |
| `path` | The file's path inside the set's folder, such as `genome/<file as given>` or `derived/transcripts.fa`, or inside the index's own folder for an index file |
| `index` | For an index file only, `{key, tool}`. `key` is the index's folder name, such as `salmon-2.11.0-k31-genome-decoys` (reference-set.md, The salmon index cache), and lane EX-INDEX names a STAR index the same way. `tool` is the `{id, version, build}` that built it. Absent for a file of the set itself |

The entry's `relativePath` is `references/<set id>/<path>` for a file of the set and `references/<set id>/indexes/<key>/<path>` for an index file, so two sets or two indexes never share a path. Every `reference` entry of a plan names the one set that `pipeline.referenceSet` names, so a plan counts on one set. A shared folder holds no `reference` entry. Each is kept once in the staging folder as a `database` entry is, and the executor checks its size and SHA-256 before any tool starts, as it checks every entry. A plan names an index by its files, so a later plan pins an index that an earlier run staged on Linux, with policy `staged`, by the digests that run's record states ([executor-run-record.md](executor-run-record.md), Step keys). An entry of another role that holds `reference`, or a `reference` entry without it, is refused with field `entries[<i>].reference`.

### The barcode list

A `barcodeList` entry pins the 10x barcode list that a STARsolo step reads, by `sha256` and `size`, at `barcodes/<file>`. It also holds `barcodeList`. The list takes a role of its own and not the role `reference`, since every `reference` entry names the one set that `pipeline.referenceSet` names and a barcode list belongs to no set. As `database` and `reference` do, the role carries an identity key of its own, and the folder writer and the batch writer tell a `supplied` list from an `image` list by `barcodeList.source`.

| Key | Meaning |
| --- | --- |
| `name` | The known list whose SHA-256 the file has, `3M-february-2018` or `737K-august-2016`. The plan writer checks the SHA-256 against the known lists before it writes the plan and refuses, in words that name both, a list that is neither |
| `source` | `image` for the list LGE derives from 10x's CC BY 4.0 dataset files and ships with its NOTICE in the tool image, or `supplied` for a list the person gave |

The executor checks the list by SHA-256 before any tool starts (`docs/plans/2026-10-02-architecture-program.md:103`). LGE never writes a byte of a `supplied` list into a folder it makes, whether a replay folder, a shared folder, the staging folder, a result bundle or the project, since copying the list is the person's act (`SCR` ruling BIO-NOTHOST-BARCODE, Q2). Only its name and SHA-256 enter LGE's files. The person puts the list at the entry's `relativePath` in a replay folder, or in the staging folder for CHTC, and the executor checks it by size and SHA-256 before any tool starts, as it checks every entry. A missing or different list is refused with field `entries[<i>]` and words that say LGE does not copy a barcode list the person supplied and where to put it. An `image` list is in no plan folder or staging folder, and `staging.json` does not name it. The executor copies the file that the image's tool manifest lists in `files` with role `barcodeList` and that SHA-256 to the entry's `relativePath` and checks the copy's size and SHA-256. It writes the copy only under `barcodes/`, and it neither links to the file nor reads it in place. The resolver refuses a link whose real path leaves the work root, and a path into the image would put an absolute path in the argv, where every step path is relative to the work root (Steps), and in the run record, whose absolute paths are a closed list ([executor-run-record.md](executor-run-record.md), Reading a record). The disk the copy takes is a figure of the submit side (Request figures stay on the submit side). A manifest that lists no such file refuses the run with field `entries[<i>]` and the sentence "The tool image holds no barcode list with SHA-256 <sha256>, which this plan pins. No tool ran." The run record's `inputs` repeats the entry with its `barcodeList`, so the record says which list ran and where it came from, and the adopt writes "list supplied by the user" for a `supplied` list. LGE's list is never in the git tree or the Mac app, and LGE takes no list from a Cell Ranger install. An entry of another role that holds `barcodeList`, or a `barcodeList` entry without it, is refused with field `entries[<i>].barcodeList`.

The tool manifest lists each data file of the image under `files`, an optional array of `{path, role, sha256, size}`. `path` is absolute with no empty, `.` or `..` component, as a tool's is. `role` is the plan role the file serves, `barcodeList` for every file that schema 2 names. `sha256` and `size` are the file's own. The manifest's writer sorts `files` by path, as it sorts `tools`, and lists no path twice, and no `files` entry is a tool that a step can name. A manifest with no `files` has the bytes of today. A manifest with `files` keeps `schemaVersion` 1, since the decoder of `ImageToolManifest` (`Sources/LungfishPortable/Plan/ImageToolManifest.swift`) passes over a key it does not know, so an image with barcode lists still runs every schema 1 plan. `ImageToolManifest.files` reads the key, and its checks refuse a path that is not absolute, an empty `role`, a SHA-256 that is not 64 lowercase hexadecimal digits, a negative size and a path listed twice or as a tool. `role` is text, so a manifest that lists a file of a later role still reads. Lane EX-IMAGE writes each barcode list into the image's manifest, so the key has one reader and one writer.

### The `tool` step

A `tool` step runs one pinned tool by the plan's argv, as a `recipe` step runs by its argv. Its `tool` is a pin of `tools`, which the image's manifest must list, and the executor runs it by the manifest's absolute path with `arguments` as given. A program the tool starts itself, such as the decompressor that STAR's `--readFilesCommand` names, is pinned in `tools` as well, since `tools` holds every tool a step runs or launches. The step's `environment` is built from nothing as every step's is, and its `deadlineSeconds` keeps the rule of every step. That deadline is the limit the person named, or the longest a plan allows when the person named none, since an analysis tool has no wall-clock limit by default (`docs/contracts/SCOPE-AND-DELIVERY.md`, What the app must do). Each thread count and memory limit a tool takes, such as STAR's `--runThreadN`, sits in the argv as a fixed number that the plan writer's rule sets, and never means every core or the host's memory.

The argv holds every setting that changes counts, with the same value `pipeline` states (The pipeline). Every trimmer call passes the poly-G setting, Trim Galore 2.3.0 `--no_poly_g` by default and `--poly_g` when the person chose it, and never leaves it to the trimmer's own check (`docs/plans/2026-10-02-architecture-program.md:246`). A setting that a tool would otherwise decide from the data is passed as a value, except where the route lets the tool decide, as salmon's library type `-l A` does. Then the plan states the setting and names the tool's own report of what it decided, salmon's `aux_info/lib_format_counts.json`, as a `home` output, so the record states both. Where Trim Galore 2.3.0 would choose the adapter from the reads, each trimmer call passes the adapter as a value, by the flag that lane EX-PLAN-SALMON reads from `trim_galore --help`. The STAR then salmon step's `alignmentScoring` is `none`, which passes no flag, or `errorModel`, which passes `--errorModel` (`docs/plans/2026-10-02-architecture-program.md:247`).

A `tool` step states no read count, so its record leaves `inputReadCount` and `outputReadCount` absent. Counts come from the tool's own files, such as STAR's `Log.final.out` and salmon's `aux_info/meta_info.json`. Each output is a regular file the tool writes, as for every step. A tool that writes a folder, such as a STAR index or STARsolo's `Solo.out/`, has each file of that folder that the adopt or a later plan reads named as an output. A file the plan does not name is neither hashed nor returned. The reports the adopt reads are `home` outputs of their step. They are STAR's `Log.final.out` and, with GeneCounts, `ReadsPerGene.out.tab`, salmon's `quant.sf`, `aux_info/meta_info.json` and `aux_info/lib_format_counts.json`, featureCounts' count table and its `.summary`, STARsolo's own summary, and for a UMI chain the files lane EX-UMI names. A plan whose counting step, the step that runs the tool `pipeline.route.tool` names, names none of its tool's reports as a `home` output is refused with field `steps[<i>].outputPolicy`. A plan names no file as a report, so the decoder refuses a plan whose counting steps return no `home` output at all.

### Outputs that come home and outputs that stay

Every step of a schema 2 plan holds `outputPolicy`, an object with one key for each path of its `outputs` and the value `home`, `staged` or `stays`.

| Policy | Meaning |
| --- | --- |
| `home` | The job returns the file to the Mac at its plan path, beside the run record, for the adopt |
| `staged` | The job copies the file into the group's staging folder before it ends, under a name that holds its SHA-256, as each file `staging.json` names is kept. A later plan pins it as a `reference` entry, and the run record states its path, bytes and SHA-256 with `policy` `staged` |
| `stays` | The file is left in the job's work root on the Linux machine and goes with the job's scratch folder when the job ends. The run record states its path, bytes and SHA-256 in the step's `outputs` as evidence of what ran, and does not say the file is kept |

An index that later plans read has policy `staged`, so a STAR index stays on Linux in the staging folder (`docs/plans/2026-10-02-architecture-program.md:245`). STAR's alignments and every read file have policy `stays`, since the Mac never holds Linux reads (owner direction O59). The submit side returns the run record and each `home` output and nothing else, as for a schema 1 plan it returns the run record, the payload and the reports (`Sources/LungfishWorkflow/HTCondor/HTCondorSubmitTemplate.swift:73-80`). `standardOutput` takes no policy, since the run record holds its bytes. A step whose `outputPolicy` leaves out one of its outputs, or names a path that is not one of them, is refused with field `steps[<i>].outputPolicy`.

### The pipeline

`pipeline` is the identity of the chain a schema 2 plan runs, in the words of the result's manifest ([rnaseq-bundle.md](rnaseq-bundle.md), The manifest), so the adopt fills the result's `route`, `modality` and `referenceSet` from the plan and reads no setting from the Mac.

| Key | Meaning |
| --- | --- |
| `id`, `version` | The chain the plan writer built, such as STAR then salmon, and the chain's own version, a whole number the plan writer raises when it changes a step, a tool or an argv rule of that chain |
| `preset` | `{id, name}`, the preset the person chose, with the name the person read, such as "Exons and introns (STARsolo GeneFull_Ex50pAS)" |
| `modality` | `bulk` or `single-cell`, the result's `modality`. Absent for a plan that makes no counts, such as an index build |
| `route` | The result's `route` key for key, `{id, tool, toolVersion, settings}`. `tool` and `toolVersion` name the counting tool, and `settings` holds, as text, every setting of the chain that changes counts, whether of the counting step, such as `alignmentScoring`, or of the reads and the earlier steps, such as `trimming` and `duplicates` (`docs/plans/2026-11-13-phase-5-rnaseq-reproduction.md:103`). The export compares the whole `route`, so results that differ in one of these settings never join in one table. Absent for a plan that makes no counts |
| `referenceSet` | `{id, layout}`, the result's `referenceSet`, the one set that every `reference` entry names |
| `settings` | Each choice the chain offers, `{id, label, value, source}`, with `option` when the person chose it and `default` when LGE's default set it (Source values). Each key of `route.settings` has one entry here with the same id and value. A plan that makes counts always holds the entries `trimming` and `duplicates`, which are keys of `route.settings` too. `duplicates` reads as the paragraph on it below the table says, and `trimming` reads `Poly-G trimming: off (LGE default)`, `Poly-G trimming: on (chosen), Trim Galore <version> --poly_g` with the version of the trimmer's pin in `tools`, or `Reads not trimmed` for a plan with no trimmer step (`docs/plans/2026-11-13-phase-5-rnaseq-reproduction.md:101`). These are the words the Mac route of `lungfish-cli rnaseq quant` records, and a value is never `auto`, `false` or `no`. The record reads its poly-G line from this entry. The instrument and the thread counts are in no `route.settings` key, since they change no count |

The adopt writes `route` as the plan states it, so counts whose plans differ in a setting of `route.settings` never join in one table (rnaseq-bundle.md, One table, one route). Each setting of `settings` shows in the argv of the step it changes, such as `--no_poly_g` for poly-G trimming off and no `--errorModel` for `alignmentScoring` `none`, so the argv and the identity never disagree. The adopt checks it. It reads the recorded `argv` of each trimmer step and of the counting step ([executor-run-record.md](executor-run-record.md), Step keys) and refuses the result, in words that name the step, when the argv disagrees with `settings`, which means `--no_poly_g` for `trimming` off, `--poly_g` for on, no trimmer step for `Reads not trimmed`, and `--errorModel` only for `alignmentScoring` `errorModel`. Lane EX-ADOPT builds this check. A plan with `route` and no `modality`, or `modality` and no `route`, is refused with field `pipeline.modality`, a `route.settings` key with no entry of the same id and value in `settings` with field `pipeline.route.settings`, and a `reference` entry of another set with field `entries[<i>].reference.setID`. A `route.tool` and `route.toolVersion` that are not the `id` and `version` of a pin in `tools` that a step runs are refused with field `pipeline.route.tool`, so the route names the tool and version that the run record says ran.

The `duplicates` entry says what the counted reads lost to duplicate removal, in the words of the Mac route's record line. For reads whose bundle holds the import's metadata and no duplicate-removal step it reads `Duplicates: kept. LGE removes duplicates only with UMIs.`, with source `default` (`docs/plans/2026-11-13-phase-5-rnaseq-reproduction.md:104`). For reads whose bundle holds no import metadata, so that nothing says whether the import removed duplicates, it reads `Duplicates: Not recorded (the bundle holds no import record that names its steps)`, with source `default`, as the Mac's poly-G line reads Not recorded for an import with no record. For reads that the import deduplicated without UMIs, the plan writer reads the recipe the import recorded in the metadata of the bundle's reads, as the Mac route does, and the entry reads `Duplicates: removed at import by <step name>, without UMIs. This count removes none.`, with source `recipe` and the names of more than one such step joined by "and". For a chain with a UMI step, the entry names that step and says that it removes duplicates with UMIs, in words that lane EX-UMI sets from the kit preset, and EX-UMI also sets the words, or the refusal, for reads that the import deduplicated before a UMI step. Samples whose reads differ in this state take templates of their own, as a sample of another FASTQ suffix does, so the fill still changes no setting and a result adopted from plans holds samples of one state. The Mac route states a result of many samples as `Duplicates: removed at import for <n> of <m> samples, without UMIs. This count removes none.`, a form that a plan of one sample never states. The adopt never writes this line from a constant, and no step of a plan removes duplicates without UMIs.

### The UMI layout check

A schema 2 plan is a straight line. It fixes every step before the run, holds no step that runs only when another succeeds or fails, and the adopt asks that every planned step succeeded. So the UMI layout check of a UMI chain is the first `tool` step of the UMI branch, before UMI extraction, and it runs on Linux as the same step in every sample's plan. Its checker is an executable that the image's tool manifest lists and the plan pins in `tools`, as every step's tool is. The step's argv and `pipeline.settings`, with the kit preset and each entry's source, state the motif, the UMI length, the read that holds the UMI, the 1,000 pairs it reads and how it chooses them, and the bars (`docs/plans/2026-11-13-phase-5-rnaseq-reproduction.md:89`). A run passes when every read name is equal across mates and the motif is within one mismatch in at least 90% of the pairs. The check warns when the exact share is under 90%. The share of distinct UMIs fails the check under 50% and warns under 80%.

The step writes its shares, its verdict and the pairs it read as a `home` file, which the adopt reads for the per-sample report. On a warning it exits 0, and the warning shows from that file and not only from standard error. On a failure it exits non-zero and prints the shares and what to try, so the run record reads `failed` with `failedStepID` naming the check and the words in `reason` and the step's `stderrTail`. Each sample runs its own plan, so a failed check stops that sample alone, which then gets no UMI step and no counts. A failed check never falls back to the route without UMIs, which is another route. A check on the Mac may run as advice for reads the Mac holds, and the Linux step stays the check of record, since staged reads never reach the Mac. The import clumps short reads by default (Storage and clumping), so the first 1,000 pairs of a file may not sample the library, and lane EX-UMI pins a spread choice of pairs in the argv and measures it before the bars bind. No schema 3 is needed, since no step is skipped.

### Request figures stay on the submit side

A schema 2 plan holds no request figure. The memory, CPUs and disk a job asks for, which measured figures such as STAR's peak memory, time and disk on a node inform (`docs/plans/2026-10-02-architecture-program.md:235`), are values of the submit side, as `request_disk` is ([The template and the fill](#the-template-and-the-fill)). They never reach `plan.json`, an argv or a step's environment, so a new figure changes no plan byte and no plan key waits on a measurement.

## Refusals

A plan that breaks a rule is refused before any tool runs. The run record's `refusedField` names the field, such as `schemaVersion`, `entries[<i>]`, `imageManifest.sha256`, `tools[<i>].id`, `recipe.sourceSHA256`, `storage.compressor`, `storage.threads`, `storage.clumpifyHeapGB`, `storage.compressionLevel`, `clumping.resolved`, `clumping.heapBytes`, `clumping.reason`, `graceSeconds`, `steps[<i>].id`, `steps[<i>].kind`, `steps[<i>].tool`, `steps[<i>].deadlineSeconds`, `steps[<i>].inputs`, `steps[<i>].environment` or `tools`, and for a schema 2 plan `recipe`, `storage`, `clumping`, `sample`, `pipeline`, `pipeline.modality`, `pipeline.route.tool`, `pipeline.route.settings`, `pipeline.settings[<i>].source`, `sample.instrument`, `entries[<i>].reference`, `entries[<i>].reference.setID`, `entries[<i>].barcodeList` or `steps[<i>].outputPolicy`. The executor also refuses with `--plan` for a plan file it cannot read, `subreaper` on Linux when the subreaper cannot be set, `--site-fact <n>` for a site fact that breaks a rule, `imageManifest` when the tool manifest is missing, is named by a relative path, is over 1 MiB or differs from the plan's pin in SHA-256 or size, `imageManifest.<field>` when the manifest's own checks fail, and `storage.clumpifyHeapGB` when the preflight sees a heap at or above a limit it observed. A run refused for a pin mismatch still states the `sha256`, `size` and `source` of the manifest it read.
