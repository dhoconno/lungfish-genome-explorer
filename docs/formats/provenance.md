# Provenance records

Lungfish Genome Explorer (LGE) writes a provenance record beside every result it makes. A record is one JSON object that says what ran, on which files, with which settings and how the run ended. This page gives the shapes of record LGE reads, the rule for changing the format, what version 2 removes, and what a reader shows for an older record or a fact a record lacks. The types are `ProvenanceEnvelope` and `ProvenanceEnvelopeReader` in the Workflow module, and `docs/contracts/RECORDING-PROVENANCE.md` says how to write a record.

## Where records live

| File | What it describes |
| --- | --- |
| `.lungfish-provenance.json` | The result folder or bundle it sits in |
| `<file>.lungfish-provenance.json` | The one file it is named after |
| `provenance/bundle.lungfish-provenance.json` | A bundle as a whole, as a roll-up of its outputs |
| `provenance/<path>.lungfish-provenance.json` | One output inside a bundle |

Some results keep a typed record of their own, such as `mapping-provenance.json`. A typed record keeps its own schema and is not described here.

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

A step holds `id`, `toolName`, `toolVersion`, `argv`, `reproducibleCommand`, `resolvedOptions`, `inputs`, `outputs`, `exitStatus`, `wallTimeSeconds`, `peakMemoryBytes`, `stderr`, `dependsOn`, `startedAt` and `completedAt`, and a `runtimeIdentity` of its own when it ran somewhere else. Version 2 adds three step fields, each written only when the writer fills it.

| Step field | What it holds |
| --- | --- |
| `parentStepID` | The `id` of the step this step ran under, such as the import step that ran a compression tool |
| `managedToolID` | The managed tool the step ran, by its id in the tool lock. The run's `tool` object may hold one too |
| `toolVersionEvidence` | Where `toolVersion` comes from, as an object with a `source` of `observed`, `lockPin`, `sourceBuild` or `unknown` |

An observed, pinned or source-built version holds `version`, an observed one may hold the probe's `reportedLine`, and a pin or a source build holds the lock entry's `managedToolID`. A source build is the version a lock entry builds from a source archive it pins by SHA-256, such as Bracken 3.1 beside the locked package 1.0.0. An unknown version holds a `reason`, and the reasons read from a stored value hold it as `recorded`. A reader that meets evidence in a shape it does not know reads the rest of the step and shows the evidence as Not recorded. A descriptor holds `path`, `checksumSHA256`, `fileSize`, `format`, `role`, `originPath` and `sourceProvenancePath`. A typed value is an object with a `type` and a `value`. A `file` value keeps the path the record holds, so `<workspace>/reads.fastq` reads back as written and never gains the reading folder in front.

The one home of a run's read set plan is `readSetPlan` in `options.resolvedDefaults`. Released builds also wrote it to `options.explicit`, to the `resolvedOptions` of a step and to the parameters of the run nested in an older record, and `ProvenanceEnvelope.readSetPlan` reads the home first and then those places, in that order.

## The shapes a reader accepts

Older LGE builds and early scripts wrote other shapes, and released projects still hold them. The tolerant reader tries three decoders in a fixed order.

| Shape | What it accepts | Who wrote it |
| --- | --- | --- |
| Envelope | An object with `createdAt` and `runtimeIdentity` whose known keys hold the types and values on this page | LGE since the envelope began, and some scripts |
| Bare run | A `WorkflowRun` with `id`, `name`, `startTime`, `status`, `appVersion`, `hostOS`, `steps` and `parameters` | LGE before Phase 2.4 |
| Primitive | Any other JSON object, read by the primitive adapter | Early writers, such as the first alignment and tree commands |

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

A record that decodes as a bare run or through the primitive adapter is in the Older record format. A version 1 envelope never is, and neither is a typed record such as `mapping-provenance.json`. Such a record still shows every fact it holds. A display labels it Older record format, and it is never exported as a script. Its date may be invented. The primitive adapter dates a record that holds no date by the file's modification time, or by 1970 when it has none, and the reader then reports that date as invented, so a display shows it as Not recorded.

## Not recorded

A fact a record never held is shown as Not recorded. A reader never fills it with a value from the Mac that reads the record, and never with a stand-in word. This covers the app version, the executable path, the process ID, the operating system, the architecture, the dependency set and the workflow version, each of which the readers once took from the reading process. A writer still records its own app version, operating system, architecture, dependency set and workflow version. It names its own executable `<external>/<file name>`, inside a project and outside one, because an install path names folders on one Mac while the name and the app version say which build ran. It records no process ID, which names nothing once the run has ended, so a record written today shows the process ID as Not recorded.

The legacy `WorkflowRun` view of a record needs text for its app version and operating system, and it shows the empty string when the record holds none. A record that states no status gets one derived from its exit status, and the reader reports that the status was derived. `ops stats` counts a run as completed only when its record states it, because a cancelled run can end on a step that exited 0.

A fact a shape never held reads Not recorded and does not make the record Incomplete. A fact it could hold and lacks still does.
