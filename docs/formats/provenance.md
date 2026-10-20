# Provenance records

Lungfish Genome Explorer (LGE) writes a provenance record beside every result it makes. A record is one JSON object that says what ran, on which files, with which settings and how the run ended. This page gives the shapes of record LGE reads, the rule for changing the format, what version 2 removes, and what a reader shows for an older record or a fact a record lacks. The types are `ProvenanceEnvelope` and `ProvenanceEnvelopeReader` in the Workflow module, and `docs/contracts/RECORDING-PROVENANCE.md` says how to write a record.

## Where records live

| File | What it describes |
| --- | --- |
| `.lungfish-provenance.json` | The result folder or bundle it sits in |
| `<file>.lungfish-provenance.json` | The one file it is named after |
| `provenance/bundle.lungfish-provenance.json` | A bundle as a whole, as a roll-up of its outputs |
| `provenance/<path>.lungfish-provenance.json` | One output inside a bundle |

Some results keep a typed record of their own, such as `mapping-provenance.json` in a mapping folder or `<bam stem>.mapping-provenance.json` beside a BAM that `bam adopt-mapping` added to a bundle. A typed record keeps its own schema and is not described here.

`lungfish-cli build-db` writes the record of its run beside each file it made. A record beside the database, or beside an output of `build-db kraken2` or `build-db taxtriage`, holds the steps that name that file among their outputs and every step without outputs, so the database's record keeps every read count of the run. A record beside a BAM or BAM index that `build-db esviritu` moved to a sample's `bams/` folder holds the steps that name that file among their outputs, each with its own descriptor of the file and the digest and `originPath` that step stated, the steps without outputs whose inputs name the file or the `_temp` path it was moved from, and the steps that name no file when a kept step depends on them or no step does. The second kind covers the file's header probe, its read counts, the replacement of its bytes by duplicate marking and the removal of the `_temp` folders. The third keeps the `fixmate` and `sort` of the BAM's own duplicate marking in the record of the BAM. The record of its index keeps neither, since the index step depends on the markdup, which names the BAM and not the index. Those of other BAMs are in no record. A step that names a file of another sample, such as the move, the removal of the `_temp` folders and the run's own step, lists only the inputs of that BAM or index and the paths it came from, and names in `narrowedFrom` the record of the run that holds the step whole, the folder record or the root record of the analysis run. A folder that holds the record of another workflow has no such record, so there each step lists all its inputs. A BAM record written by an earlier release also holds the steps without outputs of every other sample, and LGE reads it as written.

## The envelope

LGE writes every new record as an envelope. The encoder sorts the keys, writes dates in ISO 8601 with whole seconds in UTC, and writes slashes as typed, so a path appears as `@/Analyses/run` in the raw bytes. A record written before version 2 escapes them, as in `@\/Analyses\/run`. A reader parses the JSON and relies on neither key order nor escaping.

| Key | What it holds |
| --- | --- |
| `schemaVersion` | The format version, an integer |
| `id` | The run's UUID |
| `createdAt` | When the run started |
| `status` | How the run ended, one of `running`, `completed`, `failed` or `cancelled` |
| `workflowName`, `workflowVersion` | The operation and the LGE version that ran it. A record that holds no workflow version leaves the key out |
| `toolName`, `toolVersion`, `tool` | The tool the run reports as its own |
| `argv`, `durableReplayArgv`, `reproducibleCommand` | The command as words, as replayable words when the run used scratch files, and as one shell line |
| `options` | `explicit`, `defaults` and `resolvedDefaults`, each a map of typed values |
| `runtimeIdentity` | The app version, executable, operating system and architecture of the run, its environment, and its dependency set with `managedToolLockSHA256`, the SHA-256 of the exact bytes of the tool lock in force. A writer names its own executable `<external>/<file name>` and records no process ID, which an older record may hold |
| `files`, `output`, `outputs` | File descriptors with a path, a role, a format, a SHA-256 and a size |
| `steps` | One entry for each tool the run invoked |
| `wallTimeSeconds`, `exitStatus`, `stderr` | How long it took, the exit status and the bounded standard error |
| `signatures` | References to signature files, empty unless a signer is set |
| `priorSignatures` | Written only when not empty. The signatures LGE removed from this file when a write with no key replaced it, oldest first. Each is `{ provider, publicKeySHA256, provenanceSHA256, signedAt }`, and LGE checked it against the bytes it covered when it removed it. `signedAt` is the time the signature file stated. The Add Annotation log puts the same key on the entry whose append removed the pair. An older build that rewrites the record drops the key |

A step holds `id`, `toolName`, `toolVersion`, `argv`, `reproducibleCommand`, `resolvedOptions`, `inputs`, `outputs`, `exitStatus`, `wallTimeSeconds`, `peakMemoryBytes`, `stderr`, `dependsOn`, `startedAt` and `completedAt`, and a `runtimeIdentity` of its own when it ran somewhere else. Version 2 and later add these step fields, each written only when the writer fills it.

| Step field | What it holds |
| --- | --- |
| `parentStepID` | The `id` of the step this step ran under, such as the import step that ran a compression tool |
| `managedToolID` | The managed tool the step ran, by its id in the tool lock. The run's `tool` object may hold one too |
| `toolVersionEvidence` | Where `toolVersion` comes from, as an object with a `source` of `observed`, `lockPin`, `sourceBuild` or `unknown` |
| `observation` | What ToolProcess saw of the step's launch, for a step the writer declared around that one launch |
| `stdoutReadInProcess` | Written, as `true`, only when LGE read the step's standard output in the app and kept no file of it, such as the `samtools coverage` and `samtools view` passes of a mapping summary. A script export names such a step in a comment and does not run it |
| `narrowedFrom` | Written only on a step that the record of a BAM or BAM index of `build-db esviritu` narrowed. `recordPath` is the record that holds the step whole and `inputCount` how many inputs the step has there. The step keeps its `id`, so a reader finds the whole step by that id |

An observed, pinned or source-built version holds `version`, and a pin or a source build holds the lock entry's `managedToolID`. An observed version may hold `reportedLine`, the line the tool's version probe printed or, for a version read from the `conda-meta` of the environment that ran the tool, the package record as `<name>-<version>-<build>` (`minimap2-2.31-h6bd33b9_0`), which never holds a path. A step records the lock pin only when that environment holds no usable record of the package. A source build is the version a lock entry builds from a source archive it pins by SHA-256, such as Bracken 3.1 beside the locked package 1.0.0. An unknown version holds a `reason`, and the reasons read from a stored value hold it as `recorded`. A reader that meets evidence in a shape it does not know reads the rest of the step and shows the evidence as Not recorded. A descriptor holds `path`, `checksumSHA256`, `fileSize`, `format`, `role`, `originPath` and `sourceProvenancePath`. A typed value is an object with a `type` and a `value`. A `file` value keeps the path the record holds, so `<workspace>/reads.fastq` reads back as written and never gains the reading folder in front.

An `observation` holds `termination`, `stop`, `outputComplete`, `environment` and `stage`. The `termination` object has a `kind` of `exited` with its `code`, `signaled` with its `signal`, `statusLost` when something outside ToolProcess took the status, `launchFailed` with its `reason`, or `notLaunched`. A signaled step still holds the signal number in `exitStatus`, as it always has. The `stop` object says why ToolProcess ended the step itself, with a `reason` of `cancelled`, `timedOut` with its `limit` of `wallClock` or `idle` and its `seconds`, or `pipelineStageFailed` with the `stage` that failed, and it is absent when ToolProcess did not stop the step. `outputComplete` is absent for a step that streamed its standard output or never launched, and the Provenance tab reads it as Not recorded only for a step that ran and did not exit 0. The `environment` object gives the `base` of `inherited` or `hermetic`, the name of every variable the adapter set under `changed`, the sanitized `values` of the variables on the allowlist of `ToolProcessEnvironmentChange`, the `unset` names and the `pathPrefix` entries the adapter put before the base PATH. `pathReplaced` is written, as `true`, only when an adapter on an inherited base set a PATH that does not end with the inherited PATH, and `pathPrefix` then holds the whole PATH the step got. A record without it reads as false. It never holds the inherited environment. The `stage` object gives the step's `index` in its run, from 0, and the `count` of stages. An observation never holds the executed argv, which never replaces the step's own, and never a peak memory. A reader that meets an observation in a shape it does not know reads the rest of the step as a step without one, so the Provenance tab shows it as it shows a step of an older record.

The one home of a run's read set plan is `readSetPlan` in `options.resolvedDefaults`. Released builds also wrote it to `options.explicit`, to the `resolvedOptions` of a step and to the parameters of the run nested in an older record, and `ProvenanceEnvelope.readSetPlan` reads the home first and then those places, in that order. `assemble` and `map` write the plan in the home only, once for each run, so a BBMap sample that maps in two runs holds one plan and no mapper step holds a copy. Records that the Kraken2 and EsViritu pipelines save through `ProvenanceRecorder` on the legacy GUI route, and EsViritu batch sample records, still hold it in `options.explicit` until that route retires. Since 2.8 a TaxTriage record of one sample writes its plan in the home. Released TaxTriage records and a pooled `taxtriage run --output` record of several samples keep `read_set_plans` (one plan for each sample), which `ProvenanceEnvelope.readSetPlansBySample` reads by sample id. `ProvenanceEnvelope.readSetPlan` reads that form after every other place, and takes the one plan kept there as the run's plan only when the record says it ran one sample (`sample_count` 1), so a pooled record of several samples has no one plan. 12S matching keeps `readSetPlans` (one for each input) and Viral Recon keeps the `readSetPlan` inside its `readPairing` decision, which records bundle staging and means something else, so the reader takes neither for the run's plan.

## The shapes a reader accepts

Older LGE builds and early scripts wrote other shapes, and released projects still hold them. The tolerant reader tries three decoders in a fixed order.

| Shape | What it accepts | Who wrote it |
| --- | --- | --- |
| Envelope | An object with `createdAt` and `runtimeIdentity` whose known keys hold the types and values on this page | LGE since the envelope began, and some scripts |
| Bare run | A `WorkflowRun` with `id`, `name`, `startTime`, `status`, `appVersion`, `hostOS`, `steps` and `parameters` | LGE before Phase 2.4 |
| Primitive | Any other JSON object, read by the primitive adapter | Early writers, such as the first alignment and tree commands |

Through the adapter, an `options` object that holds only `explicit`, `defaults` and `resolvedDefaults`, each an object, reads as those three groups. Any other `options` object reads as explicit options.

The strict reader (`ProvenanceEnvelopeReader.loadCanonical` and `decodeCanonical`) accepts only the envelope, and a writer's test checks its record with it. `ProvenanceEnvelopeReader.read(fromSidecar:)` returns what the tolerant reader decoded together with the shape, whether the record states its status and whether its date was invented. `load(fromSidecar:)` returns the envelope alone, as before. `ProvenanceRecorder.findProvenanceReading(for:)` returns the same for the record the finder picks, where a typed mapping record reads as a typed record.

## The version rule

`schemaVersion` is an integer at the top of the record. A record without it reads as version 1.

Additions never change the number. A new key, a new step field, a new descriptor field and a new runtime fact are all additions, and each is optional, so an older record simply lacks it. A new number means a removal or a change of meaning, such as dropping a key or giving a key another type.

Readers accept any version. A reader ignores keys it does not know, reads the keys it knows at any version and never refuses a record because of its version number. LGE writes version 2. The encoder always writes its own version, even for a record rebuilt from one it read at another version, because the bytes it writes are always in its own shape.

A file `format` and a file `role` are open from version 2. A reader keeps a value it does not know, such as `csv` or `sampleSheet`, and writes it back unchanged. Below version 2 a reader refuses an unknown format or role as released builds always did, so the record falls to the primitive adapter and keeps the shape and signature payload it had. A build released before LGE wrote version 2 refuses such a value at any version and reads that record through the adapter. Such a build also takes a signature over that record to cover its raw bytes, so the signature verifies only in builds that read the record as an envelope. The kinds of typed value stay closed. In the run's `options` a value of an unknown kind reads as a plain object, and in a step's `resolvedOptions` the envelope decoder refuses the record.

## What version 2 removes

Version 1 wrote 14 keys twice, once under the canonical name and once under the name an older reader of the bare run expects. Version 2 drops the second spelling. Readers keep reading every alias, so a version 1 record reads as before. A reader that decodes a record file as a bare run finds none of the keys it needs in a version 2 record, which is why every reader goes through the tolerant reader.

| Version 1 alias | Canonical key |
| --- | --- |
| `name` | `workflowName` |
| `startTime`, `endTime` | `createdAt` and `wallTimeSeconds` |
| `appVersion`, `hostOS`, `runtime` | `runtimeIdentity` |
| `parameters` | `options.explicit` |
| Step `command`, `exitCode`, `wallTime` | Step `argv`, `exitStatus`, `wallTimeSeconds` |
| Step `startTime`, `endTime` | Step `startedAt`, `completedAt` |
| Descriptor `sha256`, `sizeBytes` | Descriptor `checksumSHA256`, `fileSize` |

`status` stays, because it is the canonical status key. Version 2 also writes slashes without escapes. A signature survives that change, because signing covers the parsed object reserialized, not the raw bytes. A version 1 record keeps its whole-second `startTime` and `endTime`, and `lungfish-cli ops stats` uses them for its wall time when they are there. A version 2 record gives the same span from its canonical fields, within a second. The `ops stats` of every released build reads a bare run and counts no version 2 record, and a build before 0.4.0-alpha.14 reads none.

## Older record format

A record that decodes as a bare run or through the primitive adapter is in the Older record format, unless the adapter reads it as a typed record. A version 1 envelope never is, and neither is a typed record. A typed record keeps its own schema. `mapping-provenance.json` is one. An alignment record, a tree record or a genotype workbook receipt that reaches the adapter is one too when it states its `status`, as LGE writes them since 2.7. One written earlier states no status and keeps the Older record format. The alignment and tree records that hold `createdAt` decode as version 1 envelopes and were never in the Older record format. A record in the Older record format still shows every fact it holds. A display labels it Older record format, and it is never exported as a script. Its date may be invented. The primitive adapter dates a record that holds no date by the file's modification time, or by 1970 when it has none, and the reader then reports that date as invented, so a display shows it as Not recorded.

## Not recorded

A fact a record never held is shown as Not recorded. A reader never fills it with a value from the Mac that reads the record, and never with a stand-in word. This covers the app version, the executable path, the process ID, the operating system, the architecture, the dependency set and the workflow version, each of which the readers once took from the reading process. A writer still records its own app version, operating system, architecture, dependency set and workflow version. It names its own executable `<external>/<file name>`, inside a project and outside one, because an install path names folders on one Mac while the name and the app version say which build ran. It records no process ID, which names nothing once the run has ended. The Provenance tab shows no Process ID row for a record that holds none when the record is at version 2 or later, is a typed record, or is a version 1 envelope that states its own `status` and holds no nested run. Any other record that holds none shows its process ID as Not recorded.

The legacy `WorkflowRun` view of a record needs text for its app version and operating system, and it shows the empty string when the record holds none. A record that states no status gets one derived from its exit status, and the reader reports that the status was derived. The Provenance tab then reads its Run Status as Not recorded. `ops stats` counts a run as completed only when its record states it, because a cancelled run can end on a step that exited 0.

A fact a shape never held reads Not recorded and does not make the record Incomplete. A fact it could hold and lacks still does.
